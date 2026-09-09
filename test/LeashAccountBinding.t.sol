// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract MockApprovals is IPolicyApprovals {
    mapping(address => bool) public approved;

    function set(address p, bool v) external {
        approved[p] = v;
    }

    function isApproved(address p) external view returns (bool) {
        return approved[p];
    }
}

/// @dev Always refuses — used to prove nothing can be restored without a valid
///      attestation. Defined in this test file rather than imported from
///      LeashRegistry.t.sol, so the two stay independent.
contract RejectingAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "RejectingAttester";
    }
}

contract LeashAccountBindingTest is Test {
    LeashAccount impl;
    MockApprovals approvals;
    MockAttester attester;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant AGENT = address(0xA6E17);
    address constant ATTACKER = address(0xBAD);
    address constant ETH_REGISTRY = address(0xE45);

    bytes constant ATT = hex"c0ffee";
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    /// The delegated EOA, addressed through LeashAccount's interface.
    LeashAccount acct;

    function setUp() public {
        approvals = new MockApprovals();
        attester = new MockAttester();
        impl = new LeashAccount(ETH_REGISTRY, approvals, attester);
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    // --- 7702 semantics ---

    /// After delegation the EOA's code is the 23 bytes `0xef0100 || impl`.
    function test_delegation_layout() public view {
        assertEq(wallet.code.length, 23);
        assertEq(uint8(wallet.code[0]), 0xef);
        assertEq(uint8(wallet.code[1]), 0x01);
        assertEq(uint8(wallet.code[2]), 0x00);
    }

    /// 🔴 **C2 regression: a delegated wallet must still be able to receive ETH.**
    ///
    /// A plain ETH transfer is a call to the delegate with **empty calldata**. Without a
    /// `receive()`, Solidity's dispatcher reverts — which means faucets, exchanges and
    /// `cast send --value` all stop working, and the wallet can never be topped up with
    /// gas again after delegating.
    function test_delegated_wallet_can_still_receive_eth() public {
        deal(address(this), 1 ether);
        uint256 before = wallet.balance;
        (bool ok,) = payable(wallet).call{ value: 1 ether }("");
        assertTrue(ok, "empty calldata must hit receive()");
        assertEq(wallet.balance - before, 1 ether);
    }

    /// An unknown selector must revert explicitly rather than be swallowed — accepting it
    /// silently would make a mistyped selector look like success.
    function test_unknown_selector_reverts() public {
        vm.expectRevert(LeashAccount.UnknownSelector.selector);
        (bool ok,) = wallet.call(abi.encodeWithSignature("notAFunction()"));
        ok; // judged by expectRevert
    }

    /// Inside a delegate, `address(this)` is the **EOA**, while `SELF` is the impl's own
    /// address. They are different values, and an attestation digest needs **both**:
    /// `address(this)` binds which wallet, `SELF` binds which impl version.
    function test_address_this_is_the_eoa_but_self_is_the_impl() public view {
        assertEq(acct.SELF(), address(impl), "SELF is baked in at deploy time");
        // domainSeparator uses address(this) — inside a delegate, that is the wallet
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                wallet
            )
        );
        assertEq(acct.domainSeparator(), expected, "verifyingContract is the EOA");
    }

    /// Two EOAs delegating to the same impl have entirely independent storage.
    function test_two_wallets_sharing_one_impl_are_independent() public {
        uint256 pk2 = 0xB0B;
        address w2 = vm.addr(pk2);
        vm.signAndAttachDelegation(address(impl), pk2);

        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        (bytes32 n1,,) = acct.bindingOf(AGENT);
        (bytes32 n2,,) = LeashAccount(payable(w2)).bindingOf(AGENT);
        assertEq(n1, NODE);
        assertEq(n2, bytes32(0), "the other wallet knows nothing about this agent");
    }

    // --- 🔴 decision 2 regression: no initialize, so nothing to front-run ---

    /// **Storage is empty right after delegation, and that is the attacker's only window.**
    ///
    /// A spike demonstrated it: with an `initialize()`, anyone can call it first and set
    /// themselves as admin. Our approach is to have **no initialisation step at all** —
    /// the global configuration is immutable, per-EOA authority is always
    /// `msg.sender == address(this)`, and only the wallet's private key can make that EOA
    /// send a transaction.
    ///
    /// This test walks through and shows an attacker can do nothing in that window.
    function test_attacker_cannot_seize_a_freshly_delegated_wallet() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.bindAgent(ATTACKER, NODE, LABEL);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(NODE, address(0xDEAD), ATTACKER, 1, ATT);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.setRule(NODE, address(0xDEAD), LeashStorage.TokenRule(true, 0, 0, 0, 0, 0, 0), 1, ATT);

        vm.stopPrank();

        (bytes32 n,,) = acct.bindingOf(ATTACKER);
        assertEq(n, bytes32(0), "nothing was seized");
    }

    /// Calls to the **impl itself** must be inert. Nobody delegates to the impl, and its
    /// `address(this)` is itself, so in principle it could give itself orders. That harms
    /// no wallet (the state lives in the impl's own storage and no EOA reads it), but we
    /// still confirm an **outsider** cannot move it.
    function test_calling_the_impl_directly_does_nothing_for_an_outsider() public {
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(ATTACKER);
        impl.bindAgent(ATTACKER, NODE, LABEL);
    }

    // --- attestation ---

    /// The digest must include `SELF`, otherwise an attestation can be replayed across
    /// versions after redelegating to a new impl.
    function test_attestation_digest_is_bound_to_the_impl_version() public {
        LeashAccount impl2 = new LeashAccount(ETH_REGISTRY, approvals, attester);
        bytes32 d1 = acct.payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        vm.signAndAttachDelegation(address(impl2), walletPk);
        bytes32 d2 = LeashAccount(payable(wallet)).payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        assertTrue(d1 != d2, "same wallet, different impl version, different digest");
    }

    // --- 🔴 M2 regression: node and label must agree ---

    /// **`node` is not only the resolver's key — it is also the key for `rules` / `payees`
    /// / `spent`.**
    ///
    /// So `bindAgent(agentB, node=vendors, label="payroll")` would let agentB spend
    /// **vendors' human-approved limits and budget** while being judged by **payroll's
    /// policy**. And since the `AgentBound(agent, node)` event carries no label, that would
    /// be **completely invisible** offchain.
    ///
    /// Under a fixed parent, computing the namehash costs **two keccaks** (around 200 gas),
    /// which trades an invisible misconfiguration for a revert.
    function test_bind_rejects_a_node_label_mismatch() public {
        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashAccount.NodeLabelMismatch.selector, acct.nodeFor(LABEL), payrollNode
            )
        );
        vm.prank(wallet);
        acct.bindAgent(AGENT, payrollNode, LABEL);
    }

    function test_nodeFor_matches_the_recorded_namehashes() public view {
        assertEq(acct.nodeFor("vendors"), NODE);
        assertEq(
            acct.nodeFor("payroll"),
            0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8
        );
    }

    // --- 🔴 M4 regression: no free rebind after a revocation ---

    /// What the frozen document says about reason code 2 is "reductions need no face scan,
    /// **restoring does**". If `bindAgent` could overwrite an existing binding, a free
    /// rebind after a revocation would sidestep that rule.
    function test_bind_rejects_an_existing_binding() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        vm.expectRevert(LeashAccount.AlreadyBound.selector);
        acct.bindAgent(AGENT, NODE, LABEL);
        vm.stopPrank();
    }

    /// Restoring a revoked agent requires an attestation — **both halves are needed**.
    ///
    /// This test originally only walked "valid attestation → success", which would still
    /// pass with the whole `_consumeAttestation` block deleted from `restoreAgent`. It now
    /// first uses an always-refusing attester to show nothing can be restored without a
    /// valid attestation, then walks the success path to show a valid one does restore —
    /// and each half can fail on its own if the check is removed.
    function test_restore_requires_an_attestation() public {
        // No valid attestation: restoreAgent must revert even when the caller is the
        // wallet itself.
        RejectingAttester rejecting = new RejectingAttester();
        LeashAccount strictImpl = new LeashAccount(ETH_REGISTRY, approvals, rejecting);
        uint256 strictPk = 0xBAD5EED;
        address strictWallet = vm.addr(strictPk);
        vm.signAndAttachDelegation(address(strictImpl), strictPk);
        LeashAccount strictAcct = LeashAccount(payable(strictWallet));

        vm.startPrank(strictWallet);
        strictAcct.bindAgent(AGENT, NODE, LABEL);
        strictAcct.revokeAgent(AGENT);

        vm.expectRevert(LeashAccount.NotAttested.selector);
        strictAcct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
        vm.stopPrank();

        // With a valid attestation: the restore succeeds as before (the pre-existing
        // success-path assertion, kept).
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        (,, bool revoked) = acct.bindingOf(AGENT);
        assertTrue(revoked);

        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
        (,, bool after_) = acct.bindingOf(AGENT);
        assertFalse(after_, "restored");
        vm.stopPrank();
    }

    /// Restoring a revoked agent requires `msg.sender == address(this)` — the other half
    /// of "both conditions". An agent can `revokeAgent` itself for free, but cannot restore
    /// itself while skipping the human attestation.
    function test_restore_requires_self() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(AGENT);
        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
    }

    /// One attestation is void after a single use — the same nonce cannot be replayed to
    /// restore again. A fresh nonce is required, which shows what is consumed is *this
    /// attestation* rather than the weaker state of "this agent has been restored before".
    function test_restore_attestation_cannot_be_replayed() public {
        bytes32 d = _restoreDigest(AGENT, NODE, LABEL, 1);

        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);

        // A reduction needs no attestation, so it can be revoked again.
        acct.revokeAgent(AGENT);

        vm.expectRevert(abi.encodeWithSelector(LeashAccount.AttestationReused.selector, d));
        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);

        acct.restoreAgent(AGENT, NODE, LABEL, 2, ATT);
        (,, bool revoked) = acct.bindingOf(AGENT);
        assertFalse(revoked, "restored with a fresh nonce");
        vm.stopPrank();
    }

    /// `LeashAccount` does expose a public `restoreDigest()` (see
    /// `test/LeashAccountDigests.t.sol`), but this test deliberately recomputes the digest
    /// independently from `_consumeAttestation`'s formula instead of calling it. Calling
    /// `restoreDigest()` here would compare the getter to itself and prove nothing; an
    /// independent reconstruction is the stronger test, in the same spirit as the replay
    /// tests in `LeashRegistry.t.sol` — except those borrow a ready-made digest from
    /// `reg.renewDigest(...)`, while this one is rebuilt from scratch on purpose.
    function _restoreDigest(address agent, bytes32 node, string memory label, uint256 nonce)
        private
        view
        returns (bytes32)
    {
        bytes32 restoreTypehash = keccak256(
            "RestoreAgent(address impl,address agent,bytes32 node,string label,uint256 nonce)"
        );
        bytes32 structHash = keccak256(
            abi.encode(restoreTypehash, acct.SELF(), agent, node, keccak256(bytes(label)), nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", acct.domainSeparator(), structHash));
    }

    /// **But binding to the wrong name must not be permanent.** `unbindAgent` is free for a
    /// binding that has not been revoked (unbinding is a reduction), after which it can be
    /// bound to the correct name — both steps are reductions, and at no point in between
    /// does it hold more authority than before. A *revoked* binding is the one exception:
    /// `unbindAgent` reverts `RevokedNeedsRestore` there, because deleting it would erase
    /// the `revoked` flag that keeps `bindAgent` from restoring an agent for free. This
    /// test's agent is never revoked, so it exercises the free path.
    function test_a_mis_binding_is_correctable_for_free() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        acct.unbindAgent(AGENT);
        (bytes32 n,,) = acct.bindingOf(AGENT);
        assertEq(n, bytes32(0), "back to unbound");

        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        acct.bindAgent(AGENT, payrollNode, "payroll");
        (bytes32 n2,,) = acct.bindingOf(AGENT);
        assertEq(n2, payrollNode, "rebound with no attestation");
        vm.stopPrank();
    }

    // --- 🔒 revoke-bypass regression: unbindAgent must refuse a revoked binding ---

    /// `unbindAgent` must refuse a revoked binding. Deleting it would clear `node` back to
    /// zero, and `bindAgent`'s `AlreadyBound` guard only fires while `node` is non-zero —
    /// so allowing this delete would let `revoke → unbind → bind` restore full authority
    /// with no attestation at all.
    function test_unbind_reverts_on_a_revoked_binding() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);

        vm.expectRevert(LeashAccount.RevokedNeedsRestore.selector);
        acct.unbindAgent(AGENT);
        vm.stopPrank();
    }

    /// The full old bypass — revoke, unbind, bind — can no longer reach an active binding.
    /// `unbindAgent` reverts before `node` is ever cleared, so `bindAgent` still sees a
    /// non-zero `node` and still reverts with `AlreadyBound`; the binding is left exactly
    /// where `revokeAgent` put it.
    function test_revoke_unbind_bind_no_longer_restores_authority_for_free() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);

        vm.expectRevert(LeashAccount.RevokedNeedsRestore.selector);
        acct.unbindAgent(AGENT);

        vm.expectRevert(LeashAccount.AlreadyBound.selector);
        acct.bindAgent(AGENT, NODE, LABEL);

        (bytes32 n, string memory l, bool revoked) = acct.bindingOf(AGENT);
        assertEq(n, NODE, "binding untouched by the blocked bypass");
        assertEq(l, LABEL);
        assertTrue(revoked, "still revoked, never restored");
        vm.stopPrank();
    }

    /// The legitimate route out of `revoked` is untouched by the new guard: a valid
    /// attestation still restores the agent. Mirrors the success half of
    /// `test_restore_requires_an_attestation`, kept as its own test so the mutation check
    /// on the new `unbindAgent` guard has a dedicated "restore still works" witness.
    function test_restore_with_valid_attestation_still_works_after_the_fix() public {
        bytes32 d = _restoreDigest(AGENT, NODE, LABEL, 1);

        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);

        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
        (bytes32 n, string memory l, bool revoked) = acct.bindingOf(AGENT);
        assertEq(n, NODE);
        assertEq(l, LABEL);
        assertFalse(revoked, "restored via a valid attestation");

        // Sanity: the digest this attestation consumed is the one for this exact
        // (agent, node, label, nonce) tuple — replaying it must now fail.
        vm.expectRevert(abi.encodeWithSelector(LeashAccount.AttestationReused.selector, d));
        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
        vm.stopPrank();
    }

    /// Bind → unbind with **no** revocation in between must still work for free — the
    /// mis-binding remedy this guard must not break. Already covered end-to-end by
    /// `test_a_mis_binding_is_correctable_for_free` above (bind, unbind, rebind, all
    /// without ever calling `revokeAgent`), so no duplicate test is added here.

    // --- reductions are always available ---

    /// An agent can revoke itself — a reduction should have no gate.
    function test_an_agent_can_revoke_itself() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.prank(AGENT);
        acct.revokeAgent(AGENT);
        (,, bool revoked) = acct.bindingOf(AGENT);
        assertTrue(revoked);
    }

    function test_a_stranger_cannot_revoke_someone_elses_agent() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.expectRevert(LeashAccount.NotSelfOrAgent.selector);
        vm.prank(ATTACKER);
        acct.revokeAgent(AGENT);
    }

    // --- 🔴 M6 regression: pause is free, so unpause must be free too ---

    /// Any bound agent that has not been revoked can hit the brake — hitting the brake can
    /// only make the system stricter.
    function test_any_bound_agent_can_pause() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.prank(AGENT);
        acct.pause();
        assertTrue(acct.paused());
    }

    function test_a_revoked_agent_cannot_pause() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.NotBoundAgent.selector);
        vm.prank(AGENT);
        acct.pause();
    }

    /// **`unpause` must not require an attestation.** Otherwise a compromised agent can
    /// `pause` for free and force the holder to scan their face over and over — a DoS. A
    /// free brake demands a free release. The frozen document also lists reason code 10 as
    /// "an ADMIN's routine operation", needing no scan.
    function test_unpause_is_free_and_only_the_wallet_can_do_it() public {
        vm.prank(wallet);
        acct.pause();

        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(AGENT);
        acct.unpause();

        vm.prank(wallet);
        acct.unpause();
        assertFalse(acct.paused());
    }
}
