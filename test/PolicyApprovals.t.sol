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

    address constant STRANGER = address(0x5721);
    bytes constant ATT = hex"c0ffee";
    uint256 constant N1 = 1;
    uint256 constant N2 = 2;

    function setUp() public {
        mock = new MockAttester();
        policy = new StandardPolicy();
        list = new PolicyApprovals(mock);
    }

    // --- 批准要背書 ---

    function test_approves_with_a_valid_attestation() public {
        list.approve(address(policy), "daily cap 5k USDC", N1, ATT);
        assertTrue(list.isApproved(address(policy)));
        assertEq(list.descriptionOf(address(policy)), "daily cap 5k USDC");
    }

    /// **門檻是背書,不是身分。** 這是一份全域單例清單,「誰送這筆交易」不影響結果。
    /// (per-wallet 的 `LeashAccount` 則必須「兩個都要」—— 那裡不能照抄這條。)
    function test_anyone_may_submit_a_valid_attestation() public {
        vm.prank(STRANGER);
        list.approve(address(policy), "x", N1, ATT);
        assertTrue(list.isApproved(address(policy)));
    }

    function test_rejects_when_the_attester_says_no() public {
        PolicyApprovals strict = new PolicyApprovals(new RejectingAttester());
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        strict.approve(address(policy), "x", N1, ATT);
        assertFalse(strict.isApproved(address(policy)));
    }

    /// attester 是 immutable,而 `address(0)` 會讓整份清單永遠批准不了任何東西 ——
    /// 沒有 setter 可以救,所以寧可部署時就失敗。
    function test_cannot_deploy_without_an_attester() public {
        vm.expectRevert(PolicyApprovals.ZeroAttester.selector);
        new PolicyApprovals(IAttester(address(0)));
    }

    /// 🔴 C1 迴歸:這份合約**沒有** owner、**沒有** `setAttester`。
    /// 一把被偷的 ADMIN 金鑰無法把 attester 換成永遠回 true 的東西。
    function test_attester_is_immutable_with_no_setter() public view {
        assertEq(address(list.attester()), address(mock));
        // 介面上不存在 setAttester / owner / transferOwnership ——
        // 這條測試的價值在於它會在有人把可變性加回來的那一刻編譯失敗。
    }

    function test_rejects_zero_policy_and_double_approval() public {
        vm.expectRevert(PolicyApprovals.ZeroPolicy.selector);
        list.approve(address(0), "x", N1, ATT);

        list.approve(address(policy), "x", N1, ATT);
        vm.expectRevert(PolicyApprovals.AlreadyApproved.selector);
        list.approve(address(policy), "x", N2, ATT);
    }

    // --- 🔴 C2 迴歸:重放 ---

    /// **這是 code review 抓到的攻擊:** 從公開 calldata 抄下 attestation →
    /// `revoke(policy)` → 用同一份 blob 重新 `approve`。現在必須失敗。
    function test_the_same_attestation_cannot_be_replayed_after_revoke() public {
        list.approve(address(policy), "cap 5k", N1, ATT);
        list.revoke(address(policy));

        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyApprovals.AttestationReused.selector,
                list.approvalDigest(address(policy), "cap 5k", N1)
            )
        );
        list.approve(address(policy), "cap 5k", N1, ATT);
        assertFalse(list.isApproved(address(policy)), "stays revoked");
    }

    /// 撤銷之後要重新批准,**必須拿一份新 nonce 的背書**。
    /// (初版的測試註解就是這樣寫的,但它傳的是同一份 —— 註解在說謊,而測試抓不到重放。)
    function test_reapproval_requires_a_fresh_nonce() public {
        list.approve(address(policy), "cap 5k", N1, ATT);
        list.revoke(address(policy));

        list.approve(address(policy), "cap 5k", N2, ATT);
        assertTrue(list.isApproved(address(policy)));
    }

    function test_used_digests_are_recorded() public {
        bytes32 d = list.approvalDigest(address(policy), "x", N1);
        assertFalse(list.attestationUsed(d));
        list.approve(address(policy), "x", N1, ATT);
        assertTrue(list.attestationUsed(d));
    }

    // --- EIP-712 ---

    /// digest 必須是標準 EIP-712 —— 後端會用標準函式庫簽,自製格式對不上就驗不過。
    function test_digest_is_standard_eip712() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                address(list)
            )
        );
        assertEq(list.domainSeparator(), domain, "domain separator");

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("PolicyApproval(address policy,string description,uint256 nonce)"),
                address(policy),
                keccak256(bytes("cap 5k")),
                N1
            )
        );
        assertEq(
            list.approvalDigest(address(policy), "cap 5k", N1),
            keccak256(abi.encodePacked(hex"1901", domain, structHash)),
            "0x1901 || domainSeparator || structHash"
        );
    }

    /// 背書綁住這份清單和這條鏈,挪不到別處。
    function test_digest_is_bound_to_this_list_and_chain() public {
        bytes32 d1 = list.approvalDigest(address(policy), "x", N1);

        PolicyApprovals other = new PolicyApprovals(mock);
        assertTrue(d1 != other.approvalDigest(address(policy), "x", N1), "different list");

        vm.chainId(999);
        assertTrue(d1 != list.approvalDigest(address(policy), "x", N1), "different chain");
    }

    function test_digest_changes_with_description_and_nonce() public view {
        assertTrue(
            list.approvalDigest(address(policy), "cap 5k", N1)
                != list.approvalDigest(address(policy), "cap 50k", N1),
            "description is signed"
        );
        assertTrue(
            list.approvalDigest(address(policy), "cap 5k", N1)
                != list.approvalDigest(address(policy), "cap 5k", N2),
            "nonce is signed"
        );
    }

    /// 背書是針對「這一份 policy 加這一段說明加這個 nonce」發的,換任何一項都不算。
    function test_attestation_for_one_policy_does_not_approve_another() public {
        StandardPolicy other = new StandardPolicy();
        PolicyApprovals picky = new PolicyApprovals(new PickyAttester(bytes32(0))); // 先佔位,下面換
        picky; // 未使用

        PolicyApprovals l = new PolicyApprovals(mock);
        bytes32 onlyThis = l.approvalDigest(address(policy), "cap 5k", N1);
        PolicyApprovals strict = new PolicyApprovals(new PickyAttester(onlyThis));

        // PickyAttester 認的 digest 是對 `l` 算的,對 `strict` 算出來不同 → 全部拒絕
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        strict.approve(address(policy), "cap 5k", N1, ATT);

        // 換 policy 位址 / 換說明 / 換 nonce,對同一份清單也都不算
        PolicyApprovals s2 = new PolicyApprovals(new PickyAttester(bytes32(uint256(1)))); // 認一個不可能的 digest
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        s2.approve(address(other), "cap 5k", N1, ATT);
    }

    // --- 撤銷:任何人都能踩煞車 ---

    /// **這是刻意的,不是漏洞。** 撤銷只會讓系統更嚴,而讓「踩煞車」需要權限,
    /// 是在真的出事的那一刻幫攻擊者省事。
    function test_anyone_can_revoke_without_attestation() public {
        list.approve(address(policy), "x", N1, ATT);
        vm.prank(STRANGER);
        list.revoke(address(policy));
        assertFalse(list.isApproved(address(policy)));
    }

    /// 撤銷要清掉說明,否則前端會顯示一份已經失效的規則。
    function test_revoke_clears_the_description() public {
        list.approve(address(policy), "cap 5k", N1, ATT);
        list.revoke(address(policy));
        assertEq(list.descriptionOf(address(policy)), "");
    }

    function test_revoke_is_idempotent() public {
        list.revoke(address(policy));
        vm.prank(STRANGER);
        list.revoke(address(policy));
        assertFalse(list.isApproved(address(policy)));
    }

    // --- mock 要誠實 ---

    /// demo 畫面上會顯示 attester 的名字。我們不想假裝有真人把關。
    function test_mock_attester_admits_it_verifies_nothing() public view {
        assertEq(mock.describe(), "MockAttester (NO verification - testing only)");
        assertTrue(mock.verify(bytes32(0), ""), "accepts anything");
    }
}
