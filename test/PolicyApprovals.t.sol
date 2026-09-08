// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicyApprovals } from "../src/PolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";

/// @dev 永遠拒絕 —— 用來證明「沒有背書就批准不了」。
contract RejectingAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "RejectingAttester";
    }
}

/// @dev 只認一個特定 digest —— 用來證明背書真的綁在被批准的內容上。
contract PickyAttester is IAttester {
    bytes32 public immutable ONLY;

    constructor(bytes32 only) {
        ONLY = only;
    }

    function verify(bytes32 digest, bytes calldata) external view returns (bool) {
        return digest == ONLY;
    }

    function describe() external pure returns (string memory) {
        return "PickyAttester";
    }
}

contract PolicyApprovalsTest is Test {
    PolicyApprovals list;
    MockAttester mock;
    StandardPolicy policy;

    address constant ADMIN = address(0xAD31);
    address constant STRANGER = address(0x5721);
    bytes constant ATT = hex"c0ffee";

    function setUp() public {
        mock = new MockAttester();
        policy = new StandardPolicy();
        list = new PolicyApprovals(ADMIN, mock);
    }

    // --- 批准要背書 ---

    function test_approves_with_a_valid_attestation() public {
        list.approve(address(policy), "daily cap 5k USDC", ATT);
        assertTrue(list.isApproved(address(policy)));
        assertEq(list.descriptionOf(address(policy)), "daily cap 5k USDC");
    }

    /// **門檻是背書,不是身分。** 拿得到有效背書的人就是拿到真人授權的人 ——
    /// 所以陌生人送這筆交易也行,這是刻意的。
    function test_anyone_may_submit_a_valid_attestation() public {
        vm.prank(STRANGER);
        list.approve(address(policy), "x", ATT);
        assertTrue(list.isApproved(address(policy)));
    }

    function test_rejects_when_the_attester_says_no() public {
        // 先 new 再 prank —— `vm.prank` 只作用於下一個 call,CREATE 會把它吃掉。
        RejectingAttester no = new RejectingAttester();
        vm.prank(ADMIN);
        list.setAttester(no);

        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        list.approve(address(policy), "x", ATT);
        assertFalse(list.isApproved(address(policy)));
    }

    /// attester 沒接上時**不能**變成人人可批准。fail-closed。
    function test_missing_attester_blocks_approval() public {
        PolicyApprovals bare = new PolicyApprovals(ADMIN, IAttester(address(0)));
        vm.expectRevert(PolicyApprovals.NoAttester.selector);
        bare.approve(address(policy), "x", ATT);
    }

    function test_rejects_zero_policy_and_double_approval() public {
        vm.expectRevert(PolicyApprovals.ZeroPolicy.selector);
        list.approve(address(0), "x", ATT);

        list.approve(address(policy), "x", ATT);
        vm.expectRevert(PolicyApprovals.AlreadyApproved.selector);
        list.approve(address(policy), "x", ATT);
    }

    // --- digest 綁住了什麼 ---

    /// 背書綁的是 policy 位址 + 說明 + **這份清單自己的位址和 chain id**,
    /// 所以同一張背書挪不到另一條鏈或另一份清單上。
    function test_digest_is_bound_to_this_list_and_chain() public {
        bytes32 d1 = list.approvalDigest(address(policy), "x");

        PolicyApprovals other = new PolicyApprovals(ADMIN, mock);
        assertTrue(d1 != other.approvalDigest(address(policy), "x"), "different list");

        vm.chainId(999);
        assertTrue(d1 != list.approvalDigest(address(policy), "x"), "different chain");
    }

    function test_digest_changes_with_the_description() public view {
        assertTrue(
            list.approvalDigest(address(policy), "cap 5k")
                != list.approvalDigest(address(policy), "cap 50k"),
            "description is signed too"
        );
    }

    /// 背書是針對「這一份 policy 加這一段說明」發的,換任何一項都不算。
    function test_attestation_for_one_policy_does_not_approve_another() public {
        StandardPolicy other = new StandardPolicy();
        PickyAttester picky = new PickyAttester(list.approvalDigest(address(policy), "cap 5k"));
        vm.prank(ADMIN);
        list.setAttester(picky);

        list.approve(address(policy), "cap 5k", ATT);
        assertTrue(list.isApproved(address(policy)));

        // 換 policy 位址 → 背書不算
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        list.approve(address(other), "cap 5k", ATT);

        // 換說明 → 背書也不算。要先撤銷,否則 `AlreadyApproved` 會先擋下來
        // (那也是對的行為,只是擋在我們想測的那道檢查前面)。
        list.revoke(address(policy));
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        list.approve(address(policy), "cap 50k", ATT);
    }

    // --- 撤銷:任何人都能踩煞車 ---

    /// **這是刻意的,不是漏洞。** 撤銷只會讓系統更嚴,而讓「踩煞車」需要權限,
    /// 是在真的出事的那一刻幫攻擊者省事。
    function test_anyone_can_revoke_without_attestation() public {
        list.approve(address(policy), "x", ATT);

        vm.prank(STRANGER);
        list.revoke(address(policy));

        assertFalse(list.isApproved(address(policy)));
    }

    function test_revoke_is_idempotent() public {
        list.revoke(address(policy)); // 從沒批准過
        vm.prank(STRANGER);
        list.revoke(address(policy)); // 再來一次
        assertFalse(list.isApproved(address(policy)));
    }

    /// 撤銷之後可以重新批准 —— 但要一張新的背書。
    function test_revoked_policy_can_be_reapproved() public {
        list.approve(address(policy), "x", ATT);
        list.revoke(address(policy));
        list.approve(address(policy), "y", ATT);
        assertTrue(list.isApproved(address(policy)));
        assertEq(list.descriptionOf(address(policy)), "y");
    }

    // --- 換 attester 是擴權方向 ---

    function test_only_owner_can_change_the_attester() public {
        MockAttester another = new MockAttester();
        vm.expectRevert(PolicyApprovals.NotOwner.selector);
        vm.prank(STRANGER);
        list.setAttester(another);
    }

    /// 換門不等於重新審核 —— 已經批准過的不受影響。
    function test_changing_the_attester_does_not_revisit_past_approvals() public {
        list.approve(address(policy), "x", ATT);
        RejectingAttester no = new RejectingAttester();
        vm.prank(ADMIN);
        list.setAttester(no);
        assertTrue(list.isApproved(address(policy)));
    }

    function test_ownership_transfers_and_cannot_be_burned() public {
        vm.prank(ADMIN);
        list.transferOwnership(STRANGER);
        assertEq(list.owner(), STRANGER);

        vm.expectRevert(PolicyApprovals.ZeroOwner.selector);
        vm.prank(STRANGER);
        list.transferOwnership(address(0));
    }

    // --- mock 要誠實 ---

    /// demo 畫面上會顯示 attester 的名字。我們不想假裝有真人把關。
    function test_mock_attester_admits_it_verifies_nothing() public view {
        assertEq(mock.describe(), "MockAttester (NO verification - testing only)");
        assertTrue(mock.verify(bytes32(0), ""), "accepts anything");
    }
}
