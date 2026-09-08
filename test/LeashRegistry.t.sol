// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashRegistry } from "../src/LeashRegistry.sol";
import { IRegistry, IERC1155Singleton } from "../src/IRegistry.sol";

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

    function setUp() public {
        vm.warp(1_757_000_000);
        reg = new LeashRegistry(ADMIN);
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, true);
    }

    function _register(uint64 duration) internal returns (uint256) {
        vm.prank(REGISTRAR);
        return reg.register(LABEL, HOLDER, address(0), RESOLVER, duration);
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
        reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY);
    }

    function test_rejects_empty_label_and_zero_duration() public {
        vm.startPrank(REGISTRAR);
        vm.expectRevert(LeashRegistry.EmptyLabel.selector);
        reg.register("", HOLDER, address(0), RESOLVER, DAY);
        vm.expectRevert(LeashRegistry.ZeroDuration.selector);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, 0);
        vm.expectRevert(LeashRegistry.ZeroOwner.selector);
        reg.register(LABEL, address(0), address(0), RESOLVER, DAY);
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
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY);

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
        reg.renew(LABEL, 30 * DAY);

        vm.warp(block.timestamp + DAY + 1);
        assertEq(reg.getResolver(LABEL), RESOLVER, "survived the original expiry");
    }

    /// 續期是**擴權方向**(延長 agent 存活),所以要 registrar。
    function test_renew_is_registrar_only() public {
        _register(DAY);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(STRANGER);
        reg.renew(LABEL, DAY);
    }

    function test_cannot_renew_a_dead_name() public {
        _register(DAY);
        vm.warp(block.timestamp + DAY + 1);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY);
    }

    // --- 撤銷:三層撤銷的中間那一層 ---

    /// 殺掉一個 agent,不影響其他 agent,而且**不需要任何背書**。
    function test_admin_can_revoke_instantly_without_attestation() public {
        uint256 tokenId = _register(30 * DAY);
        vm.prank(REGISTRAR);
        reg.register("payroll", HOLDER, address(0), RESOLVER2, 30 * DAY);

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
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, DAY);
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

    function test_name_owner_can_repoint_too() public {
        _register(30 * DAY);
        vm.prank(HOLDER);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
    }

    function test_stranger_cannot_repoint() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(STRANGER);
        reg.setResolver(LABEL, RESOLVER2);
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
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY);

        // owner 不必先把自己加進 registrar
        vm.prank(ADMIN);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY);
        assertEq(reg.getResolver(LABEL), RESOLVER);
    }

    function test_registrar_can_be_revoked() public {
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, false);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY);
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

        // 而且新持有者真的握有名字的權限
        vm.prank(STRANGER);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER2);

        // 舊持有者已經沒有了
        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(HOLDER);
        reg.setResolver(LABEL, RESOLVER);
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
