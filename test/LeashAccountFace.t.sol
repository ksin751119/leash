// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

contract NoApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Verifies only attestations issued for one exact digest, so a test can prove that a
///      widening was authorised for THIS struct and not merely that some blob was accepted.
///      `MockAttester` returns true for everything, which would make every refusal below
///      pass for the wrong reason.
contract DigestBoundAttester is IAttester {
    mapping(bytes32 => bool) public issued;

    function issue(bytes32 digest) external {
        issued[digest] = true;
    }

    function verify(bytes32 digest, bytes calldata) external view returns (bool) {
        return issued[digest];
    }

    function describe() external pure returns (string memory) {
        return "DigestBoundAttester (test only)";
    }
}

/// The face-authorised widening path.
///
/// The question every test here asks is the one the design rests on: **can anything other
/// than the registered human's scan open this wallet?** `allowPayeeByFace` has no
/// `onlySelf`, so the nullifier check and the digest binding are the only things standing
/// between a live face and somebody else's money.
contract LeashAccountFaceTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    DigestBoundAttester attester;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address relayer = address(0x9E1A4);

    address constant TOKEN = address(0x05DC);
    address constant PAYEE = address(0xBEEF);
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    bytes constant ATT = hex"c0ffee";

    // Measured on Sepolia 2026-09-11: the nullifier two scans of the same action returned.
    uint256 constant OWNER_FACE =
        0x1218592f43ca8e5703acfe9ded3c9a4853280242d8b2d0de90dafce9b168144f;
    // A different person, or the same person on a different action - the distinction the
    // contract cannot make and does not need to.
    uint256 constant OTHER_FACE =
        0x219b2715d17de9d822de4ba04ab250ada109fd24f55f387c83008eb18cb540c9;

    function setUp() public {
        vm.warp(1_757_000_000);
        attester = new DigestBoundAttester();
        impl = new LeashAccount(address(0xE45), new NoApprovals(), attester);
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    /// First registration only - no attestation is required or consumed.
    function _register(uint256 nullifier) internal {
        vm.prank(wallet);
        acct.setOwnerNullifier(nullifier, 0, "");
    }

    function _issue(uint256 nonce, uint256 nullifier) internal returns (bytes32 d) {
        d = acct.payeeFaceDigest(NODE, TOKEN, PAYEE, nonce, nullifier);
        attester.issue(d);
    }

    // --- registering a face ---

    function test_no_face_is_registered_until_the_wallet_registers_one() public view {
        assertEq(acct.ownerNullifier(), 0);
    }

    function test_registering_a_face_needs_the_wallet_key() public {
        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.setOwnerNullifier(OWNER_FACE, 0, "");
    }

    function test_the_wallet_can_register_and_the_value_reads_back() public {
        _register(OWNER_FACE);
        assertEq(acct.ownerNullifier(), OWNER_FACE);
    }

    /// 🔴 The claim the whole design rests on: **the wallet key alone cannot change whose
    /// face governs this wallet.** If this passes with the rebind gate removed, the face is
    /// decoration and the key is still in charge.
    function test_the_wallet_key_alone_cannot_change_whose_face_governs_this_wallet() public {
        _register(OWNER_FACE);
        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.setOwnerNullifier(OTHER_FACE, 1, ATT);
        assertEq(acct.ownerNullifier(), OWNER_FACE, "the registered face must not move");
    }

    /// And with the outgoing face's approval it does move - the gate is a gate, not a wall.
    function test_the_registered_face_can_hand_the_wallet_to_another_face() public {
        _register(OWNER_FACE);
        attester.issue(acct.rebindDigest(OWNER_FACE, OTHER_FACE, 1));

        vm.expectEmit(true, true, true, true);
        emit LeashAccount.OwnerFaceSet(OWNER_FACE, OTHER_FACE, wallet);
        vm.prank(wallet);
        acct.setOwnerNullifier(OTHER_FACE, 1, ATT);
        assertEq(acct.ownerNullifier(), OTHER_FACE);
    }

    /// An approval to hand the wallet to A does not authorise handing it to B.
    function test_a_rebind_attestation_names_the_incoming_face_too() public {
        _register(OWNER_FACE);
        attester.issue(acct.rebindDigest(OWNER_FACE, OTHER_FACE, 1));

        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.setOwnerNullifier(uint256(0xDECAF), 1, ATT);
        assertEq(acct.ownerNullifier(), OWNER_FACE);
    }

    /// Once the face has moved on, an older approval is dead: `previous` no longer matches.
    function test_an_old_rebind_approval_cannot_be_replayed_after_the_face_moved() public {
        _register(OWNER_FACE);
        attester.issue(acct.rebindDigest(OWNER_FACE, OTHER_FACE, 1));
        vm.prank(wallet);
        acct.setOwnerNullifier(OTHER_FACE, 1, ATT);

        // the same blob, now that OTHER_FACE is registered
        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.setOwnerNullifier(OWNER_FACE, 1, ATT);
        assertEq(acct.ownerNullifier(), OTHER_FACE);
    }

    /// The stated price. Everything that makes the wallet stricter must keep working with
    /// no face at all, or "lost your World ID" would mean "lost your wallet".
    function test_a_wallet_whose_face_is_gone_can_still_be_tightened() public {
        _register(OWNER_FACE);
        _issue(1, OWNER_FACE);
        vm.prank(relayer);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));

        // The face is now unreachable. Removing the payee is a reduction: no attestation.
        vm.prank(wallet);
        acct.removePayee(NODE, TOKEN, PAYEE);
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
    }

    // --- the widening itself ---

    /// The whole point: the sender is a stranger paying gas, and it still works.
    function test_anyone_may_relay_a_widening_the_registered_face_authorised() public {
        _register(OWNER_FACE);
        _issue(1, OWNER_FACE);

        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
        vm.prank(relayer);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
    }

    /// 🔴 Without this, "any live human may widen any wallet".
    function test_another_persons_face_cannot_widen_this_wallet() public {
        _register(OWNER_FACE);
        _issue(1, OTHER_FACE); // a genuine attestation - for the wrong human

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(LeashAccount.NotTheOwnersFace.selector, OWNER_FACE, OTHER_FACE)
        );
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OTHER_FACE, ATT);
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
    }

    /// Claiming to be the owner is not the same as being attested as the owner: the digest
    /// carries the nullifier, so lying about it produces a digest nobody signed.
    function test_claiming_the_owners_nullifier_without_an_attestation_for_it_fails() public {
        _register(OWNER_FACE);
        _issue(1, OTHER_FACE); // attested for the other face...

        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT); // ...but claiming ours
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
    }

    function test_an_account_with_no_registered_face_refuses_every_widening() public {
        _issue(1, OWNER_FACE);
        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NoOwnerFace.selector);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);
    }

    function test_the_attestation_is_single_use() public {
        _register(OWNER_FACE);
        bytes32 d = _issue(1, OWNER_FACE);

        vm.prank(relayer);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(LeashAccount.AttestationReused.selector, d));
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);
    }

    /// Each field is inside the signed digest, so a relayer cannot redirect the widening it
    /// was handed. Payee is the one that moves money; the others are the same argument.
    function test_a_relayer_cannot_redirect_the_widening_to_another_payee() public {
        _register(OWNER_FACE);
        _issue(1, OWNER_FACE); // attested for PAYEE

        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayeeByFace(NODE, TOKEN, address(0xDEAD), 1, OWNER_FACE, ATT);
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, address(0xDEAD)));
    }

    function test_a_relayer_cannot_redirect_the_widening_to_another_token() public {
        _register(OWNER_FACE);
        _issue(1, OWNER_FACE);

        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayeeByFace(NODE, address(0xDEAD), PAYEE, 1, OWNER_FACE, ATT);
    }

    /// The two paths must not share attestations in either direction, or the separation
    /// between "the key approved this" and "the face approved this" is cosmetic.
    function test_a_face_attestation_cannot_be_replayed_on_the_onlySelf_path() public {
        _register(OWNER_FACE);
        _issue(1, OWNER_FACE);

        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayee(NODE, TOKEN, PAYEE, 1, ATT);
    }

    function test_an_onlySelf_attestation_cannot_be_replayed_on_the_face_path() public {
        _register(OWNER_FACE);
        attester.issue(acct.payeeDigest(NODE, TOKEN, PAYEE, 1));

        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayeeByFace(NODE, TOKEN, PAYEE, 1, OWNER_FACE, ATT);
    }

    /// The old path keeps working untouched - it is the fallback if anything about the new
    /// one misbehaves in front of a camera.
    function test_the_onlySelf_path_still_works_exactly_as_before() public {
        attester.issue(acct.payeeDigest(NODE, TOKEN, PAYEE, 1));
        vm.prank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, 1, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
    }

    function test_the_face_path_still_refuses_a_stranger_sending_the_onlySelf_one() public {
        attester.issue(acct.payeeDigest(NODE, TOKEN, PAYEE, 1));
        vm.prank(relayer);
        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(NODE, TOKEN, PAYEE, 1, ATT);
    }
}
