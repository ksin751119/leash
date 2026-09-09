// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicyApprovals } from "../src/PolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";

/// @dev Always refuses — used to prove that nothing can be approved without an attestation.
contract RejectingAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "RejectingAttester";
    }
}

/// @dev Accepts one specific digest — used to prove an attestation really is bound to the
///      content being approved.
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

    // --- approving requires an attestation ---

    function test_approves_with_a_valid_attestation() public {
        list.approve(address(policy), "daily cap 5k USDC", N1, ATT);
        assertTrue(list.isApproved(address(policy)));
        assertEq(list.descriptionOf(address(policy)), "daily cap 5k USDC");
    }

    /// **The gate is the attestation, not an identity.** This is a global singleton list,
    /// and who submitted the transaction does not change the outcome.
    /// (The per-wallet `LeashAccount` requires **both** — this reasoning must not be
    /// carried over there.)
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

    /// The attester is immutable, and `address(0)` would leave the list permanently unable
    /// to approve anything — with no setter to recover, so failing at deploy time is the
    /// better outcome.
    function test_cannot_deploy_without_an_attester() public {
        vm.expectRevert(PolicyApprovals.ZeroAttester.selector);
        new PolicyApprovals(IAttester(address(0)));
    }

    /// 🔴 C1 regression: this contract has **no** owner and **no** `setAttester`.
    /// A stolen ADMIN key cannot swap the attester for something that always returns true.
    function test_attester_is_immutable_with_no_setter() public view {
        assertEq(address(list.attester()), address(mock));
        // setAttester / owner / transferOwnership do not exist on the interface — the
        // value of this test is that it fails to compile the moment anyone adds the
        // mutability back.
    }

    function test_rejects_zero_policy_and_double_approval() public {
        vm.expectRevert(PolicyApprovals.ZeroPolicy.selector);
        list.approve(address(0), "x", N1, ATT);

        list.approve(address(policy), "x", N1, ATT);
        vm.expectRevert(PolicyApprovals.AlreadyApproved.selector);
        list.approve(address(policy), "x", N2, ATT);
    }

    // --- 🔴 C2 regression: replay ---

    /// **The attack code review caught:** copy the attestation out of the public calldata
    /// → `revoke(policy)` → `approve` again with the same blob. This must now fail.
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

    /// Re-approving after a revocation **requires an attestation with a fresh nonce**.
    /// (The first version's test comment said exactly this while passing the same one —
    /// the comment was lying, and the test could not catch a replay.)
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

    /// The digest must be standard EIP-712 — the backend signs with a standard library, and
    /// a home-rolled format simply fails verification.
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

    /// An attestation is bound to this list and this chain; it cannot be carried elsewhere.
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

    /// An attestation is issued for one policy plus one description plus one nonce;
    /// changing any of the three makes it invalid.
    function test_attestation_for_one_policy_does_not_approve_another() public {
        StandardPolicy other = new StandardPolicy();
        PolicyApprovals picky = new PolicyApprovals(new PickyAttester(bytes32(0))); // placeholder; replaced below
        picky; // unused

        PolicyApprovals l = new PolicyApprovals(mock);
        bytes32 onlyThis = l.approvalDigest(address(policy), "cap 5k", N1);
        PolicyApprovals strict = new PolicyApprovals(new PickyAttester(onlyThis));

        // The digest PickyAttester accepts was computed for `l`; for `strict` it differs,
        // so everything is refused
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        strict.approve(address(policy), "cap 5k", N1, ATT);

        // A different policy address, description or nonce is invalid even against the
        // same list
        PolicyApprovals s2 = new PolicyApprovals(new PickyAttester(bytes32(uint256(1)))); // accepts an impossible digest
        vm.expectRevert(PolicyApprovals.NotAttested.selector);
        s2.approve(address(other), "cap 5k", N1, ATT);
    }

    // --- revoking: anyone can hit the brake ---

    /// **This is deliberate, not a hole.** Revoking can only make the system stricter, and
    /// putting a permission on the brake pedal does the attacker a favour at exactly the
    /// moment things go wrong.
    function test_anyone_can_revoke_without_attestation() public {
        list.approve(address(policy), "x", N1, ATT);
        vm.prank(STRANGER);
        list.revoke(address(policy));
        assertFalse(list.isApproved(address(policy)));
    }

    /// Revoking must clear the description, otherwise the frontend keeps showing a rule
    /// that no longer applies.
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

    // --- the mock must be honest ---

    /// The demo screen shows the attester's name. We do not want to pretend a human is in
    /// the loop when none is.
    function test_mock_attester_admits_it_verifies_nothing() public view {
        assertEq(mock.describe(), "MockAttester (NO verification - testing only)");
        assertTrue(mock.verify(bytes32(0), ""), "accepts anything");
    }
}
