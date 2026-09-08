// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashResolver } from "../src/LeashResolver.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";

contract MockApprovals is IPolicyApprovals {
    mapping(address => bool) public approved;

    function set(address policy, bool ok) external {
        approved[policy] = ok;
    }

    function isApproved(address policy) external view returns (bool) {
        return approved[policy];
    }
}

/// @dev 沒有 describe() 的合約 —— text("description") 必須回空字串而不是爆炸。
contract NotAPolicy {
    // 故意留空
}

contract LeashResolverTest is Test {
    LeashResolver resolver;
    MockApprovals approvals;
    StandardPolicy policy;

    address constant ADMIN = address(0xAD31);
    address constant STRANGER = address(0x5721);

    /// namehash("vendors.acme.eth") 的替身 —— resolver 不重算 node,值是什麼不影響行為。
    bytes32 constant NODE = keccak256("vendors.acme.eth");
    bytes32 constant OTHER_NODE = keccak256("payroll.acme.eth");

    /// ENSIP-10 的 `name` 參數我們不使用,但要傳一個像樣的值進去。
    /// 0x07 "vendors" 0x04 "acme" 0x03 "eth" 0x00
    bytes constant DNS_NAME = hex"0776656e646f72730461636d650365746800";

    function setUp() public {
        approvals = new MockApprovals();
        policy = new StandardPolicy();
        vm.prank(ADMIN);
        resolver = new LeashResolver(ADMIN, approvals);
    }

    function _resolveAddr(bytes32 node) internal view returns (address) {
        bytes memory inner = abi.encodeWithSignature("addr(bytes32)", node);
        bytes memory out = resolver.resolve(DNS_NAME, inner);
        return abi.decode(out, (address));
    }

    function _resolveText(bytes32 node, string memory key) internal view returns (string memory) {
        bytes memory inner = abi.encodeWithSignature("text(bytes32,string)", node, key);
        return abi.decode(resolver.resolve(DNS_NAME, inner), (string));
    }

    // --- 核心:解析 policy 位址 ---

    function test_resolves_the_policy_address_via_ensip10() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveAddr(NODE), address(policy));
    }

    /// 沒設過的名字回 0 位址 —— 帳戶層看到 0 就是理由碼 3(NO_POLICY),錢不動。
    function test_unset_node_resolves_to_zero() public view {
        assertEq(_resolveAddr(NODE), address(0));
    }

    /// 清空指標是縮權,永遠不需要刷臉。這是「全面停機」那顆按鈕。
    function test_clearing_the_pointer_is_always_allowed() public {
        vm.startPrank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        resolver.setPolicy(NODE, address(0));
        vm.stopPrank();
        assertEq(_resolveAddr(NODE), address(0));
    }

    function test_nodes_are_independent() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveAddr(OTHER_NODE), address(0));
    }

    // --- 指標與批准是分開的兩層 ---

    /// ADMIN 金鑰被偷也只能改指標。「批准過嗎」是另一把鎖,而且答案會被記進事件。
    function test_pointer_can_be_set_to_an_unapproved_policy_but_is_reported_as_such() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));

        (address p, bool approved) = resolver.policyAndApproval(NODE);
        assertEq(p, address(policy));
        assertFalse(approved, "not on the approval list yet");

        approvals.set(address(policy), true);
        (, approved) = resolver.policyAndApproval(NODE);
        assertTrue(approved);
    }

    /// 🔴 C1 迴歸:批准清單的指標是 **immutable,沒有 setter**。
    ///
    /// 初版有 `setApprovalsSource(onlyOwner)`。就算把 `PolicyApprovals.setAttester`
    /// 鎖死,只要這個指標可改,被偷的 ADMIN 金鑰就能部署自己的清單 + 自己的 attester
    /// 再指過去 —— 兩道鎖仍然是同一把鑰匙開的。
    function test_approvals_source_is_immutable_with_no_setter() public view {
        assertEq(address(resolver.approvals()), address(approvals));
        // 介面上不存在 setApprovalsSource —— 有人把可變性加回來時這裡會編譯失敗
    }

    /// 建構時不接受 `address(0)`:沒有 setter 可以補救,寧可部署時就失敗。
    function test_cannot_deploy_without_an_approvals_source() public {
        vm.expectRevert(LeashResolver.ZeroApprovals.selector);
        new LeashResolver(ADMIN, IPolicyApprovals(address(0)));
    }

    function test_zero_policy_is_never_approved() public {
        approvals.set(address(0), true); // 就算清單荒謬地批准了 0 位址
        (, bool approved) = resolver.policyAndApproval(NODE);
        assertFalse(approved);
    }

    function test_emits_pointer_set_with_the_approval_state_at_that_moment() public {
        approvals.set(address(policy), true);
        vm.expectEmit(true, true, true, true);
        emit LeashResolver.PolicyPointerSet(NODE, address(policy), ADMIN, true);
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
    }

    // --- 存取控制 ---

    function test_only_owner_can_set_the_pointer() public {
        vm.expectRevert(LeashResolver.NotOwner.selector);
        vm.prank(STRANGER);
        resolver.setPolicy(NODE, address(policy));
    }

    function test_ownership_transfers() public {
        vm.prank(ADMIN);
        resolver.transferOwnership(STRANGER);
        assertEq(resolver.owner(), STRANGER);

        vm.expectRevert(LeashResolver.NotOwner.selector);
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
    }

    function test_ownership_cannot_be_burned() public {
        vm.expectRevert(LeashResolver.ZeroOwner.selector);
        vm.prank(ADMIN);
        resolver.transferOwnership(address(0));
    }

    // --- ENSIP-10 的其餘表面 ---

    function test_addr_with_coin_type_60_matches_plain_addr() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));

        bytes memory inner = abi.encodeWithSignature("addr(bytes32,uint256)", NODE, uint256(60));
        bytes memory raw = abi.decode(resolver.resolve(DNS_NAME, inner), (bytes));
        assertEq(raw, abi.encodePacked(address(policy)));
    }

    function test_rejects_other_coin_types() public {
        bytes memory inner = abi.encodeWithSignature("addr(bytes32,uint256)", NODE, uint256(0));
        vm.expectRevert(
            abi.encodeWithSelector(LeashResolver.UnsupportedCoinType.selector, uint256(0))
        );
        resolver.resolve(DNS_NAME, inner);
    }

    function test_text_policy_returns_the_lowercase_hex_address() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveText(NODE, "policy"), vm.toLowercase(vm.toString(address(policy))));
    }

    function test_text_policy_is_empty_when_unset() public view {
        assertEq(_resolveText(NODE, "policy"), "");
    }

    function test_text_description_comes_from_the_policy_itself() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveText(NODE, "description"), policy.describe());
    }

    /// 指標指到一個沒有 describe() 的合約時,顯示路徑必須降級而不是爆炸。
    function test_text_description_degrades_to_empty_for_a_non_policy() public {
        address junk = address(new NotAPolicy());
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, junk);
        assertEq(_resolveText(NODE, "description"), "");
    }

    function test_text_leash_marks_the_name_as_governed() public view {
        assertEq(_resolveText(NODE, "leash"), "leash-v1");
    }

    /// 未知的 text key 回**空字串**,不 revert。
    ///
    /// ENS 的 UI 常常一次批次查 `avatar` / `com.twitter` / `description` ——
    /// 其中一個 revert 會讓整批查詢掛掉,這個名字在 ENS 前端就變成壞的。
    /// (`resolve` 的**未知 selector** 仍然 revert:那在強制路徑上,fail-closed 有意義。)
    function test_unknown_text_key_returns_empty_not_revert() public view {
        assertEq(_resolveText(NODE, "avatar"), "");
        assertEq(_resolveText(NODE, "com.twitter"), "");
    }

    /// 不認識的內層呼叫要 revert,不能回空值 —— 呼叫端得分得出
    /// 「沒設定」和「不支援」,fail-closed 才做得到。
    function test_unsupported_inner_call_reverts() public {
        bytes memory inner = abi.encodeWithSignature("contenthash(bytes32)", NODE);
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashResolver.UnsupportedResolverCall.selector,
                bytes4(keccak256("contenthash(bytes32)"))
            )
        );
        resolver.resolve(DNS_NAME, inner);
    }

    // --- ERC-165 ---

    function test_advertises_ensip10_and_erc165_only() public view {
        assertTrue(resolver.supportsInterface(0x9061b923), "ENSIP-10 resolve()");
        assertTrue(resolver.supportsInterface(0x01ffc9a7), "ERC-165");
        // legacy 介面刻意不宣告 —— 我們沒有這兩個外部函式
        assertFalse(resolver.supportsInterface(0x3b3b57de), "legacy addr()");
        assertFalse(resolver.supportsInterface(0x59d1d43c), "legacy text()");
    }

    /// ENSv2 實測抄下來的 selector 必須跟編譯器算出來的一致 —— 抄錯就整條解析走不通。
    function test_selectors_match_the_measured_values() public pure {
        assertEq(bytes4(keccak256("resolve(bytes,bytes)")), bytes4(0x9061b923));
        assertEq(bytes4(keccak256("addr(bytes32)")), bytes4(0x3b3b57de));
        assertEq(bytes4(keccak256("text(bytes32,string)")), bytes4(0x59d1d43c));
    }
}
