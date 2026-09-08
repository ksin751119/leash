// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashRegistry } from "../src/LeashRegistry.sol";
import { IRegistry, IERC1155Singleton } from "../src/IRegistry.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

/// @dev 永遠拒絕 —— 用來證明「沒有背書就發不出子名」。
contract RejectingAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "RejectingAttester";
    }
}

/// @dev 可以中途關掉 —— 用來把「發子名」和「續期」兩條路徑分開測。
///      attester 是 immutable,所以要測「續期需要背書」就得讓同一份 attester
///      先接受再拒絕,而不是換一份。
contract ToggleAttester is IAttester {
    bool public accepting = true;

    function setAccepting(bool v) external {
        accepting = v;
    }

    function verify(bytes32, bytes calldata) external view returns (bool) {
        return accepting;
    }

    function describe() external pure returns (string memory) {
        return "ToggleAttester";
    }
}

contract LeashRegistryTest is Test {
    LeashRegistry reg;

    address constant ADMIN = address(0xAD31);
    address constant REGISTRAR = address(0x8E61);
    address constant HOLDER = address(0x0E11);
    address constant STRANGER = address(0x5721);
    address constant RESOLVER = address(0x0501);
    address constant RESOLVER2 = address(0x0502);
    address constant SUBREG = address(0x5B6E);

    uint64 constant DAY = 1 days;
    string constant LABEL = "vendors";
    bytes constant ATT = hex"c0ffee";

    /// namehash("leash.eth") —— 09-08 算出並與 docs/deployments.md 對過
    bytes32 constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    MockAttester attester;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_757_000_000);
        attester = new MockAttester();
        reg = new LeashRegistry(ADMIN, attester, PARENT_NODE);
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, true);
    }

    /// @dev 每次用新的 nonce —— 背書用過就不能重放(與 PolicyApprovals 同語意)。
    function _register(uint64 duration) internal returns (uint256) {
        vm.prank(REGISTRAR);
        return reg.register(LABEL, HOLDER, address(0), RESOLVER, duration, ++nonce, ATT);
    }

    // --- tokenId 推導:對照鏈上實測的規則 ---

    /// `leash.eth` 實測 tokenId 是 labelhash 低 32 bits 清零。
    /// 抄錯這條,發出來的名字父層就認不得。
    function test_canonical_id_matches_the_measured_ens_rule() public view {
        uint256 cid = reg.canonicalIdOf("leash");
        assertEq(cid, 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000);
        // 上位 224 bits 就是 labelhash 本身
        assertEq(cid >> 32, uint256(keccak256("leash")) >> 32);
        // 低 32 bits 一定是 0
        assertEq(cid & 0xffffffff, 0);
    }

    // --- 發名字 ---

    function test_registers_a_name_and_resolves_it() public {
        uint256 tokenId = _register(30 * DAY);

        assertEq(reg.getResolver(LABEL), RESOLVER);
        assertEq(reg.ownerOf(tokenId), HOLDER);
        assertEq(reg.balanceOf(HOLDER, tokenId), 1, "singleton: supply 1");
        assertEq(reg.tokenIdOf(LABEL), tokenId);
    }

    function test_first_token_id_has_version_zero() public {
        uint256 tokenId = _register(30 * DAY);
        assertEq(tokenId, reg.canonicalIdOf(LABEL));
    }

    function test_unregistered_name_resolves_to_zero() public view {
        assertEq(reg.getResolver("never-issued"), address(0));
        assertEq(address(reg.getSubregistry("never-issued")), address(0));
        assertEq(reg.tokenIdOf("never-issued"), 0);
    }

    function test_live_name_cannot_be_taken_over() public {
        _register(30 * DAY);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);
    }

    function test_rejects_empty_label_and_zero_duration() public {
        vm.startPrank(REGISTRAR);
        vm.expectRevert(LeashRegistry.EmptyLabel.selector);
        reg.register("", HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
        vm.expectRevert(LeashRegistry.ZeroDuration.selector);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, 0, ++nonce, ATT);
        vm.expectRevert(LeashRegistry.ZeroOwner.selector);
        reg.register(LABEL, address(0), address(0), RESOLVER, DAY, ++nonce, ATT);
        vm.stopPrank();
    }

    // --- expiry:免費的 dead-man's switch ---

    /// **這是整份合約存在的主要理由。** 沒有人送任何交易,時間到了 resolver 就消失,
    /// agent 因此解不出 policy(理由碼 3),錢動不了。
    function test_expiry_kills_resolution_with_no_transaction() public {
        _register(DAY);
        assertEq(reg.getResolver(LABEL), RESOLVER);

        vm.warp(block.timestamp + DAY + 1);

        assertEq(reg.getResolver(LABEL), address(0), "resolver gone");
        assertEq(address(reg.getSubregistry(LABEL)), address(0));
        assertEq(reg.ownerOf(reg.canonicalIdOf(LABEL)), address(0), "ownerOf agrees");
    }

    /// 到期的那一秒還活著,下一秒才死 —— 邊界不能差一格。
    function test_expiry_boundary_is_exclusive() public {
        _register(DAY);
        uint256 exp = block.timestamp + DAY;

        vm.warp(exp - 1);
        assertEq(reg.getResolver(LABEL), RESOLVER, "still live one second before");

        vm.warp(exp);
        assertEq(reg.getResolver(LABEL), address(0), "dead at expiry");
    }

    /// 過期之後可以重發,而且**舊 tokenId 從此指不到東西**。
    function test_expired_name_can_be_reissued_and_the_old_token_dies() public {
        uint256 oldId = _register(DAY);
        vm.warp(block.timestamp + DAY + 1);

        vm.prank(REGISTRAR);
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);

        assertTrue(newId != oldId, "version bumped");
        assertEq(newId, reg.canonicalIdOf(LABEL) | 1);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
        assertEq(reg.ownerOf(newId), STRANGER);
        assertEq(reg.ownerOf(oldId), address(0), "old token points at nothing");
        assertEq(reg.balanceOf(HOLDER, oldId), 0, "old token burned");
    }

    // --- 續期 ---

    function test_renew_extends_the_leash() public {
        _register(DAY);
        vm.prank(REGISTRAR);
        reg.renew(LABEL, 30 * DAY, ++nonce, ATT);

        vm.warp(block.timestamp + DAY + 1);
        assertEq(reg.getResolver(LABEL), RESOLVER, "survived the original expiry");
    }

    /// 續期是**擴權方向**(延長 agent 存活),所以要 registrar。
    function test_renew_is_registrar_only() public {
        _register(DAY);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(STRANGER);
        reg.renew(LABEL, DAY, ++nonce, ATT);
    }

    function test_cannot_renew_a_dead_name() public {
        _register(DAY);
        vm.warp(block.timestamp + DAY + 1);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, ++nonce, ATT);
    }

    // --- 撤銷:三層撤銷的中間那一層 ---

    /// 殺掉一個 agent,不影響其他 agent,而且**不需要任何背書**。
    function test_admin_can_revoke_instantly_without_attestation() public {
        uint256 tokenId = _register(30 * DAY);
        vm.prank(REGISTRAR);
        reg.register("payroll", HOLDER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);

        vm.prank(ADMIN);
        reg.revoke(LABEL);

        assertEq(reg.getResolver(LABEL), address(0), "this agent is dead");
        assertEq(reg.getResolver("payroll"), RESOLVER2, "the other agent is untouched");
        assertEq(reg.balanceOf(HOLDER, tokenId), 0, "token burned");
    }

    function test_name_owner_can_revoke_their_own_name() public {
        _register(30 * DAY);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0));
    }

    function test_stranger_cannot_revoke() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(STRANGER);
        reg.revoke(LABEL);
    }

    function test_revoked_name_can_be_reissued_under_a_new_token() public {
        uint256 oldId = _register(30 * DAY);
        vm.prank(ADMIN);
        reg.revoke(LABEL);

        vm.prank(REGISTRAR);
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, DAY, ++nonce, ATT);
        assertTrue(newId != oldId);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
    }

    // --- 換 resolver:三層撤銷最輕的那一層 ---

    function test_admin_can_repoint_a_name_without_touching_the_agent() public {
        _register(30 * DAY);
        vm.prank(ADMIN);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
    }

    /// 🔴 #6 迴歸:**名字持有者不能改自己的 resolver。**
    ///
    /// 這刻意偏離 ENS 的常態 —— 標準 ENS 裡持有者當然能設自己的 resolver。
    /// 在 Leash 的模型裡**名字是韁繩,不是財產**:它管住持有者,不屬於持有者。
    /// 初版接受 `msg.sender == e.owner`,那讓「把子名發給 WALLET」變成
    /// 「WALLET 可以改自己的 policy」—— 與實測的 `roles(WALLET) = 0` 直接矛盾。
    function test_name_owner_cannot_repoint_their_own_leash() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(HOLDER);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER, "unchanged");
    }

    function test_name_owner_cannot_repoint_subregistry_either() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(HOLDER);
        reg.setSubregistry(LABEL, SUBREG);
    }

    function test_stranger_cannot_repoint() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(STRANGER);
        reg.setResolver(LABEL, RESOLVER2);
    }

    /// 但持有者仍然能**撤銷**自己的名字 —— 縮權永遠不該被擋。
    /// 這條測試守住那個不對稱:不能放寬,可以放棄。
    function test_name_owner_can_still_revoke_but_not_repoint() public {
        _register(30 * DAY);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0));
    }

    function test_subregistry_can_be_set_and_read() public {
        _register(30 * DAY);
        vm.prank(ADMIN);
        reg.setSubregistry(LABEL, SUBREG);
        assertEq(address(reg.getSubregistry(LABEL)), SUBREG);
    }

    // --- 存取控制 ---

    function test_only_registrar_or_owner_can_register() public {
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(STRANGER);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);

        // owner 不必先把自己加進 registrar
        vm.prank(ADMIN);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
        assertEq(reg.getResolver(LABEL), RESOLVER);
    }

    function test_registrar_can_be_revoked() public {
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, false);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
    }

    function test_only_owner_manages_registrars_and_parent() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.setRegistrar(STRANGER, true);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.setParent(IRegistry(address(1)), "leash");
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.transferOwnership(STRANGER);
        vm.stopPrank();
    }

    function test_ownership_cannot_be_burned() public {
        vm.expectRevert(LeashRegistry.ZeroOwner.selector);
        vm.prank(ADMIN);
        reg.transferOwnership(address(0));
    }

    // --- 父層指標 ---

    function test_parent_is_reported_for_indexers() public {
        vm.prank(ADMIN);
        reg.setParent(IRegistry(address(0xBEEF)), "leash");
        (IRegistry p, string memory l) = reg.getParent();
        assertEq(address(p), address(0xBEEF));
        assertEq(l, "leash");
    }

    // --- ERC-1155 singleton 語意 ---

    /// 轉讓之後 `ownerOf` 和 token 餘額必須是同一套說法 ——
    /// 這兩個地方存同一件事,不同步就會出現「token 在 A 手上但名字歸 B」。
    function test_transfer_keeps_ownerOf_and_balance_in_sync() public {
        uint256 tokenId = _register(30 * DAY);

        vm.prank(HOLDER);
        reg.safeTransferFrom(HOLDER, STRANGER, tokenId, 1, "");

        assertEq(reg.ownerOf(tokenId), STRANGER, "ownerOf followed the token");
        assertEq(reg.balanceOf(STRANGER, tokenId), 1);
        assertEq(reg.balanceOf(HOLDER, tokenId), 0);

        // 而且新持有者真的握有名字的權限 —— 用 revoke 驗證,
        // 因為 setResolver 已經收窄成 registry owner 專屬(見 #6)
        vm.prank(STRANGER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0), "new holder could revoke");
    }

    /// 轉讓之後,舊持有者不能再撤銷這個名字。
    function test_old_holder_loses_authority_after_transfer() public {
        uint256 tokenId = _register(30 * DAY);
        vm.prank(HOLDER);
        reg.safeTransferFrom(HOLDER, STRANGER, tokenId, 1, "");

        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
    }

    function test_advertises_iregistry_and_erc1155() public view {
        assertTrue(reg.supportsInterface(type(IRegistry).interfaceId), "IRegistry");
        assertTrue(reg.supportsInterface(type(IERC1155Singleton).interfaceId), "singleton");
        assertTrue(reg.supportsInterface(0xd9b67a26), "ERC-1155");
        assertTrue(reg.supportsInterface(0x01ffc9a7), "ERC-165");
    }

    // --- entryOf:過期和從未存在要分得出來 ---

    function test_entryOf_distinguishes_expired_from_never_issued() public {
        (address o,,,, bool live) = reg.entryOf(LABEL);
        assertEq(o, address(0));
        assertFalse(live);

        _register(DAY);
        vm.warp(block.timestamp + DAY + 1);

        (address o2, address r2,, uint64 exp, bool live2) = reg.entryOf(LABEL);
        assertEq(o2, HOLDER, "expired but we remember who had it");
        assertTrue(exp != 0, "expiry is visible");
        assertFalse(live2, "not usable");
        assertEq(r2, RESOLVER, "record kept; the live flag is the answer");
    }

    // --- 🔴 #5 迴歸:發子名與續期都要背書 ---

    /// `PLAN.md` 的不對稱表寫「開新 agent 子名 → ✅ 要刷臉」。
    /// 初版整個合約裡**沒有任何需要背書的路徑** —— 那句話當時是假的。
    function test_register_requires_an_attestation() public {
        LeashRegistry strict = new LeashRegistry(ADMIN, new RejectingAttester(), PARENT_NODE);
        vm.prank(ADMIN);
        strict.setRegistrar(REGISTRAR, true);

        vm.expectRevert(LeashRegistry.NotAttested.selector);
        vm.prank(REGISTRAR);
        strict.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);

        assertEq(strict.getResolver(LABEL), address(0), "nothing was issued");
    }

    /// 續期延長 dead-man's switch,那是擴權,所以也要背書。
    ///
    /// attester 是 immutable(C1 修正),所以用一份**可以中途關掉**的 attester:
    /// 先讓它接受、把名字發出來,再關掉、證明續期過不了。
    function test_renew_requires_an_attestation() public {
        ToggleAttester toggle = new ToggleAttester();
        LeashRegistry r = new LeashRegistry(ADMIN, toggle, PARENT_NODE);
        vm.prank(ADMIN);
        r.setRegistrar(REGISTRAR, true);

        vm.prank(REGISTRAR);
        r.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);
        assertEq(r.getResolver(LABEL), RESOLVER);

        toggle.setAccepting(false);

        vm.expectRevert(LeashRegistry.NotAttested.selector);
        vm.prank(REGISTRAR);
        r.renew(LABEL, DAY, 2, ATT);

        // 而**撤銷**在同樣的狀況下必須仍然可行 —— 縮權不需要背書
        vm.prank(ADMIN);
        r.revoke(LABEL);
        assertEq(r.getResolver(LABEL), address(0), "reduction never needs attestation");
    }

    /// 背書用過就不能重放 —— 語意與 `PolicyApprovals` 一致。
    /// **必須用同一組參數**:digest 包含 label / owner / resolver / duration / nonce,
    /// 換任何一項都是另一份背書。
    function test_renew_attestation_cannot_be_replayed() public {
        _register(DAY);
        bytes32 d = reg.renewDigest(LABEL, DAY, 42);

        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, 42, ATT);
        assertTrue(reg.attestationUsed(d), "digest recorded");

        vm.expectRevert(abi.encodeWithSelector(LeashRegistry.AttestationReused.selector, d));
        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, 42, ATT);
    }

    /// 發子名的重放:發 → 撤銷 → 用**同一個 nonce** 再發一次,必須失敗。
    /// (撤銷之後重新發需要一份新 nonce 的背書。)
    function test_register_attestation_cannot_be_replayed_after_revoke() public {
        bytes32 d = reg.registerDigest(LABEL, HOLDER, RESOLVER, DAY, 7);

        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 7, ATT);
        assertTrue(reg.attestationUsed(d));

        vm.prank(ADMIN);
        reg.revoke(LABEL);

        vm.expectRevert(abi.encodeWithSelector(LeashRegistry.AttestationReused.selector, d));
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 7, ATT);

        // 換一個新 nonce 就可以
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 8, ATT);
        assertEq(reg.getResolver(LABEL), RESOLVER);
    }

    function test_attestation_digest_is_standard_eip712() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                address(reg)
            )
        );
        assertEq(reg.domainSeparator(), domain);
    }

    // --- 其他護欄 ---

    /// 沒有上限的話,一次 `register(..., type(uint64).max)` 就**靜默地關掉**
    /// dead-man's switch —— 而那正是這份合約存在的主要理由。
    function test_duration_is_capped() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashRegistry.DurationTooLong.selector, 400 days, reg.MAX_DURATION()
            )
        );
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, 400 days, 1, ATT);
    }

    /// 反覆續期也不能繞過上限。
    function test_renew_cannot_exceed_the_cap() public {
        _register(300 days);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.renew(LABEL, 300 days, 99, ATT);
    }

    /// label 裡有 `.` 會發出一個永遠解析不到的名字 —— ENS 是逐層走 label 的。
    function test_label_with_a_dot_is_rejected() public {
        vm.expectRevert(LeashRegistry.LabelHasDot.selector);
        vm.prank(REGISTRAR);
        reg.register("a.b", HOLDER, address(0), RESOLVER, DAY, 1, ATT);
    }

    function test_cannot_deploy_without_an_attester() public {
        vm.expectRevert(LeashRegistry.ZeroAttester.selector);
        new LeashRegistry(ADMIN, IAttester(address(0)), PARENT_NODE);
    }

    // --- 🔴 I3 迴歸:事件要帶 node,subgraph 才對得起來 ---

    /// 凍結的 schema 以 `node`(namehash)為 join key。初版只發 tokenId,
    /// 讓 subgraph 無法跟 `PolicyPointerSet` / `SpendExecuted` / `AgentBound` 對接。
    function test_events_carry_the_namehash_node() public {
        bytes32 node = reg.nodeOf(LABEL);
        assertEq(node, 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121);

        vm.expectEmit(true, true, false, false);
        emit LeashRegistry.SubnameRegistered(node, LABEL, HOLDER, 0, 0);
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);
    }

    /// `nodeOf` 必須跟完整的 namehash 遞迴一致 —— 算錯的話 resolver 讀不到記錄。
    function test_nodeOf_matches_full_namehash_recursion() public view {
        // namehash("payroll.leash.eth"),09-08 用 cast 算出
        assertEq(
            reg.nodeOf("payroll"),
            0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8
        );
    }

    // --- fuzz ---

    /// 任何期限,過期前後的行為都必須一致。
    function testFuzz_resolution_follows_expiry(uint32 duration, uint32 skip) public {
        duration = uint32(bound(duration, 1, 365 days));
        skip = uint32(bound(skip, 0, 2 * 365 days));

        uint256 start = block.timestamp;
        _register(duration);
        vm.warp(start + skip);

        bool shouldBeLive = start + duration > block.timestamp;
        assertEq(reg.getResolver(LABEL) != address(0), shouldBeLive);
    }
}
