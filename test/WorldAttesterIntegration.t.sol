// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { WorldAttester } from "../src/WorldAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract WorldAttesterIntegrationTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant WALLET_PK = 0x8A11E7;
    uint256 constant WRONG_PK = 0xBAD;

    WorldAttester att;
    LeashAccount impl;
    LeashAccount acct;
    address wallet;
    bytes32 node;
    address constant TOKEN = address(0x7ABC);
    address constant PAYEE = address(0xBEEF);

    function setUp() public {
        vm.warp(1_800_000_000);
        att = new WorldAttester(vm.addr(SIGNER_PK));
        impl = new LeashAccount(
            address(0xE45), IPolicyApprovals(address(new YesApprovals())), IAttester(address(att))
        );
        vm.signAndAttachDelegation(address(impl), WALLET_PK);
        wallet = vm.addr(WALLET_PK);
        acct = LeashAccount(payable(wallet));
        node = acct.nodeFor("vendors");
    }

    function _sign(bytes32 digest, uint64 deadline) internal view returns (bytes memory) {
        return _signWith(SIGNER_PK, digest, deadline);
    }

    function _signWith(uint256 pk, bytes32 digest, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, att.attestationHash(digest, deadline));
        return abi.encodePacked(deadline, r, s, v);
    }

    /// 🔴 The whole chain, end to end: compute the digest, sign it as the RP signer, and
    /// the widening lands. This is act three of the demo.
    function test_allowPayee_with_a_real_signature_succeeds() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(wallet);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);

        assertTrue(acct.isPayeeAllowed(node, TOKEN, PAYEE));
    }

    /// The deadline has to reach the consumer, not merely exist in the attester.
    function test_allowPayee_with_an_expired_signature_reverts() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.warp(uint256(dl) + 1);
        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// The consumer's own replay protection still holds with a real signature.
    function test_the_same_attestation_twice_reverts() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(wallet);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(LeashAccount.AttestationReused.selector, d));
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// Widening is two-of-two. A valid signature is not enough if the caller is not the
    /// wallet — this is the C1 regression, now with a real attester behind it.
    function test_a_real_signature_does_not_help_an_outsider() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(address(0xDEAD));
        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// A well-shaped, correctly-packed 73-byte blob is not enough on its own — it has to
    /// be signed by the RP signer specifically. This is the claim the file's name makes;
    /// the other five tests exercise the wiring around it, but only this one pins the
    /// signature check itself against a real (wrong) key.
    function test_a_blob_signed_by_the_wrong_key_is_rejected() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _signWith(WRONG_PK, d, dl);

        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// `setRule` is the other widening act three could show, and it is the one that had no
    /// digest getter until Task 2.
    function test_setRule_with_a_real_signature_succeeds() public {
        LeashStorage.TokenRule memory r = LeashStorage.TokenRule({
            allowed: true,
            txLimit: 500e6,
            periodLimit: 1000e6,
            period: 1 days,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
        uint64 dl = uint64(block.timestamp + 900);
        bytes memory blob = _sign(acct.ruleDigest(node, TOKEN, r, 1), dl);

        vm.prank(wallet);
        acct.setRule(node, TOKEN, r, 1, blob);

        assertEq(acct.ruleOf(node, TOKEN).periodLimit, 1000e6);
    }

    /// 🔴 **The most important test in this file.** The whole design rests on reductions
    /// being free. Making the attester real must not have quietly made any of them cost
    /// something — if it had, a compromised agent could not be stopped without a face scan.
    function test_every_reduction_is_still_free_with_a_real_attester() public {
        LeashStorage.TokenRule memory open_ = LeashStorage.TokenRule({
            allowed: true,
            txLimit: 0,
            periodLimit: 0,
            period: 0,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
        uint64 dl = uint64(block.timestamp + 900);
        vm.startPrank(wallet);
        acct.setRule(node, TOKEN, open_, 1, _sign(acct.ruleDigest(node, TOKEN, open_, 1), dl));
        acct.allowPayee(node, TOKEN, PAYEE, 2, _sign(acct.payeeDigest(node, TOKEN, PAYEE, 2), dl));
        acct.bindAgent(address(0xA6E7), node, "vendors");

        // None of the following passes an attestation at all.
        acct.removePayee(node, TOKEN, PAYEE);
        LeashStorage.TokenRule memory tighter = open_;
        tighter.txLimit = 100;
        acct.tightenRule(node, TOKEN, tighter);
        acct.revokeAgent(address(0xA6E7));
        acct.pause();
        acct.unpause();
        vm.stopPrank();

        assertFalse(acct.isPayeeAllowed(node, TOKEN, PAYEE));
        assertEq(acct.ruleOf(node, TOKEN).txLimit, 100);
        assertFalse(acct.paused());
    }
}
