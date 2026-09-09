// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { Reason } from "../src/Reason.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import {
    MockRegistry,
    MockResolver,
    NameCheckingResolver,
    MalformedHeaderResolver,
    DirtyPaddingResolver,
    DirtyAddressRegistry,
    GasBurningRegistry
} from "./mocks/MockRegistry.sol";
import { MockToken } from "./mocks/MockToken.sol";
import {
    FalseReturnToken,
    NoReturnToken,
    ReenteringToken,
    GarbageReturnToken,
    GasBurningPolicy,
    OverflowingPolicy,
    ShortReturnPolicy
} from "./mocks/BadTokens.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Name-clashes with `NoApprovals` in `LeashAccountRules.t.sol` — Foundry treats the
///      whole test/ directory as one compilation unit, so top-level contract names must be
///      globally unique; hence the 2.
contract NoApprovals2 is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return false;
    }
}

contract LeashAccountSpendTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    MockRegistry ethRegistry;
    MockRegistry leashRegistry;
    MockResolver resolver;
    MockToken token;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant POLICY = address(0xB01C);
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    address constant AGENT = address(0xA6E17);
    address constant PAYEE = address(0xBEEF);

    uint256 nonce;
    bytes constant ATT = hex"c0ffee";

    function setUp() public {
        ethRegistry = new MockRegistry();
        leashRegistry = new MockRegistry();
        resolver = new MockResolver();

        ethRegistry.set(address(leashRegistry), address(0));
        leashRegistry.set(address(0), address(resolver));
        resolver.set(POLICY);

        // POLICY (0xB01C) was invented in task 5 as a dead address that was never actually
        // called. `spend()` really does `call` it, and a call to a codeless address
        // "succeeds" while returning empty returndata, so every happy path would be
        // misread as 12 POLICY_FAILED. `vm.etch` pastes `StandardPolicy`'s runtime bytecode
        // onto that fixed address — the resolver needs no change at all, and task 5's ten
        // address-comparison-only tests are unaffected.
        vm.etch(POLICY, address(new StandardPolicy()).code);

        impl = new LeashAccount(address(ethRegistry), new YesApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));

        token = new MockToken();
        token.mint(wallet, 1_000_000);
    }

    /// A fully open rule: allowed, all three caps 0 (= unlimited), window open all day.
    function _openRule() internal pure returns (LeashStorage.TokenRule memory) {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: 0,
            periodLimit: 0,
            period: 1 days,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
    }

    /// Binds AGENT to NODE, opens a fully permissive rule for `token`, and allow-lists
    /// PAYEE. Most `spend()` tests just want a happy path that is certain to pass as their
    /// starting point.
    function _bindAndAllow() internal {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.setRule(NODE, address(token), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(token), PAYEE, ++nonce, ATT);
        vm.stopPrank();
    }

    // ============================================================
    // Carried over from task 5: the three-hop ENS resolution (unchanged)
    // ============================================================

    /// The happy path: all three hops connect and a policy address comes out.
    function test_resolves_the_policy_through_three_hops() public view {
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY);
    }

    /// Hop one returning 0 = the `leash.eth` subtree was taken back = **every agent halts
    /// at once**.
    function test_hop1_zero_is_the_kill_switch() public {
        ethRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// Hop two returning 0 = the subname was revoked or expired = **that one agent dies**.
    function test_hop2_zero_kills_only_this_agent() public {
        leashRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// Hop three returning 0 = the policy pointer was cleared = the swap-the-rules layer.
    function test_hop3_zero_means_no_policy() public {
        resolver.set(address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// A revert on any hop must **fail closed** rather than take the whole transaction
    /// down. ENS's contracts are still in their audit window — another contract reverting
    /// must not wedge the account.
    function test_a_reverting_hop_fails_closed() public {
        ethRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        ethRegistry.setRevert(false);

        leashRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        leashRegistry.setRevert(false);

        resolver.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 🔴 **A wrong return length must fail closed too.**
    ///
    /// And note that each hop's expected length is **different**: hop1/hop2 are 32 (an
    /// address), hop3 is **96** (`bytes` = offset 32 + length 32 + inner 32).
    /// Check hop3 for `== 32` and the happy path never succeeds, while the reported reason
    /// says "ENS has no policy pointer" — sending you to debug entirely the wrong thing.
    function test_a_malformed_return_length_fails_closed() public {
        leashRegistry.setPad(1);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// `_dnsEncode` uses a hardcoded `leash.eth` suffix. This test confirms what it
    /// assembles matches the measured value — get it wrong and the resolver receives a
    /// broken name.
    function test_dns_encoding_matches_the_measured_value() public {
        // Verified indirectly through resolvePolicy: MockResolver ignores `name`, so this
        // swaps in a resolver that does check it
        NameCheckingResolver nc =
            new NameCheckingResolver(hex"0776656e646f7273056c656173680365746800", POLICY);
        leashRegistry.set(address(0), address(nc));
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY, "dns name matched exactly");
    }

    /// resolve() returns exactly 96 bytes with a forged offset in the header (0x40 rather
    /// than the legal 0x20). **Checking the total length is not enough** — data with the
    /// right length and a forged structure must fail closed too, and must not let
    /// `abi.decode` revert on such input and break `resolvePolicy`'s never-reverts
    /// guarantee.
    function test_a_malformed_header_fails_closed() public {
        MalformedHeaderResolver bad = new MalformedHeaderResolver(POLICY);
        leashRegistry.set(address(0), address(bad));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// A legal header (both offset and length 0x20) whose payload has nonzero high 12
    /// bytes. `abi.decode(bytes, (address))` catches this and reverts, while truncating to
    /// uint160 in assembly silently lets through an address that looks legitimate — neither
    /// is safe, so the padding must be validated here.
    function test_dirty_address_padding_on_hop3_fails_closed() public {
        DirtyPaddingResolver dirty = new DirtyPaddingResolver(POLICY);
        leashRegistry.set(address(0), address(dirty));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// Hops 1 and 2 share `_staticAddress`, which like hop 3 must never pass externally
    /// returned data to `abi.decode` — the same class of hole in the same function, so it
    /// gets the matching test: a legal return length (32 bytes) with dirty high 12 bytes.
    ///
    /// **The low 160 bits deliberately hold a genuinely usable resolver (`resolver`,
    /// already configured to return `POLICY`)** rather than an arbitrary dead address. With
    /// a dead address, removing the padding check would still make hop 3 return
    /// `address(0)` naturally — because it would be calling an address with no code — and
    /// the test could not detect hop 2's padding check being removed. (This trap was walked
    /// into once already: with 0xDEAD in the low bits, the test still passed after removing
    /// the check, because the error happened to be caught by hop 3.) With a working
    /// resolver there, removing the check makes the whole path "succeed" and resolve
    /// `POLICY` — which is the failure this test actually needs to catch.
    function test_dirty_address_padding_on_hop2_fails_closed() public {
        DirtyAddressRegistry dirty = new DirtyAddressRegistry(address(resolver));
        ethRegistry.set(address(dirty), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    // ============================================================
    // Task 6: spend() — stringing the four gates together
    // ============================================================

    // --- 🔴 C3 regression: fake success ---

    /// **`token` and `payee` are chosen by the agent, and could be `address(this)`.**
    ///
    /// When step 11's `token.transfer(...)` goes out, `msg.sender == address(this)` — which
    /// is exactly the authority `bindAgent` / `tightenRule` / `removePayee` accept.
    /// And with SafeERC20's permissive return check:
    ///   - `token == address(this)` → hits our own fallback
    ///   - `token == address(0)` → a call to an empty address always succeeds, returning
    ///     empty returndata
    /// Both cases mean **`spent` increases and `SpendExecuted` is emitted while not a cent
    /// moved.** The subgraph would record a payment that never happened.
    function test_rejects_targets_that_point_back_at_the_account() public {
        _bindAndAllow();
        vm.startPrank(AGENT);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(wallet, PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), wallet, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(0), PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), address(0), 1);

        vm.stopPrank();
    }

    /// An address with no code cannot be a token.
    function test_rejects_a_token_with_no_code() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.BadTarget.selector);
        vm.prank(AGENT);
        acct.spend(address(0xC0DE1E55), PAYEE, 1);
    }

    /// **The return check is strict: exactly 32 bytes that decode to `true`.**
    /// Not SafeERC20's permissive variant — we only need to support the tokens our own demo
    /// uses, and the compatibility permissiveness buys is paid for here with a fake
    /// success.
    function test_rejects_tokens_that_do_not_return_true() public {
        _bindAndAllow();
        FalseReturnToken f = new FalseReturnToken();
        NoReturnToken n = new NoReturnToken();

        vm.startPrank(wallet);
        acct.setRule(NODE, address(f), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(f), PAYEE, ++nonce, ATT);
        acct.setRule(NODE, address(n), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(n), PAYEE, ++nonce, ATT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(f), PAYEE, 1);

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(n), PAYEE, 1);
    }

    /// A Minor found in review: a token returning exactly 32 bytes that are not 0/1 (say
    /// `2`) used to make `abi.decode(ret, (bool))` throw a bare `Panic`, burying the real
    /// reason for the failure. **What is asserted here is `TransferFailed()`, not any
    /// panic** — `vm.expectRevert` names the exact selector, so if the actual revert were
    /// `Panic(uint256)` rather than this custom error, the test would fail.
    function test_a_garbage_but_32_byte_return_fails_cleanly_not_a_panic() public {
        _bindAndAllow();
        GarbageReturnToken g = new GarbageReturnToken();

        vm.startPrank(wallet);
        acct.setRule(NODE, address(g), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(g), PAYEE, ++nonce, ATT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(g), PAYEE, 1);
    }

    function test_zero_amount_reverts() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.ZeroAmount.selector);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 0);
    }

    // --- 🔴 reentrancy ---

    /// The reentrancy lock is the first line of defence and **writing the ledger first is
    /// the second** — it takes both failing to cause harm.
    ///
    /// **The reentrant call takes a path that is entirely legitimate apart from the lock
    /// itself**: `address(rt)` is bound as an agent too, and `payee` is the genuinely
    /// allowed `PAYEE` (not `msg.sender`). That arrangement is deliberate — if the
    /// reentrant call were blocked by `NotBoundAgent` or `BadTarget`, guards that have
    /// nothing to do with reentrancy, the test would stay green even with the lock removed
    /// entirely and a mutation check could not catch it. (This trap was walked into once
    /// already.)
    function test_reentrancy_is_blocked_and_the_ledger_is_already_updated() public {
        ReenteringToken rt = new ReenteringToken();
        vm.startPrank(wallet);
        acct.setRule(NODE, address(rt), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(rt), PAYEE, ++nonce, ATT);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.bindAgent(address(rt), NODE, LABEL); // the reentrant call's msg.sender is rt itself
        vm.stopPrank();

        rt.arm(wallet, PAYEE, NODE);
        vm.prank(AGENT);
        acct.spend(address(rt), PAYEE, 100);

        // Booked once only — the inner spend was blocked by the lock. Without the lock the
        // reentrant call would run to completion (it is legitimate on its own) and make
        // this 101.
        assertEq(acct.spentInCurrentPeriod(NODE, address(rt)), 100);

        // The second line of defence: ledger before transfer. The lock stopping the inner
        // call does not prove the ordering is right — move the `$.spent` write after the
        // transfer and the lock still works and the assertion above is still 100 (once the
        // outer call returns, both orderings look the same). The only moment that can tell
        // them apart is *during* the transfer. `observedSpent` is the value read back at
        // the instant `rt.transfer` was called: 100 with the right ordering (already
        // booked), 0 with the ordering swapped.
        assertEq(rt.observedSpent(), 100, "spend must be recorded before the external transfer");
    }

    // --- 🔴 the happy path: everything above tests blocks or broken tokens, so here is
    //     one that really succeeds ---

    /// Pins the OK path: the money really moves and `SpendExecuted` carries the right
    /// fields.
    function test_happy_path_executes_and_emits_spend_executed() public {
        _bindAndAllow();
        uint256 beforeWallet = token.balanceOf(wallet);
        uint256 beforePayee = token.balanceOf(PAYEE);
        uint64 expectedPeriodEnd = uint64(((block.timestamp / 1 days) + 1) * 1 days);

        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendExecuted(
            NODE, AGENT, PAYEE, address(token), 1, POLICY, 1, 0, expectedPeriodEnd
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);

        assertEq(token.balanceOf(wallet), beforeWallet - 1, "wallet balance decreased");
        assertEq(token.balanceOf(PAYEE), beforePayee + 1, "payee balance increased");
        assertEq(acct.spentInCurrentPeriod(NODE, address(token)), 1);
    }

    // --- 🔴 full reason-code coverage: each one needs an event AND an unchanged balance ---

    function test_blocked_paths_emit_and_do_not_move_money() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        // 10 PAUSED
        vm.prank(wallet);
        acct.pause();
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.PAUSED, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "paused: no movement");
        vm.prank(wallet);
        acct.unpause();

        // 3 NO_POLICY
        resolver.set(address(0));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.NO_POLICY, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no policy: no movement");
        resolver.set(POLICY);

        // 2 AGENT_REVOKED — **does not revert**; it must leave an indexable record
        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.AGENT_REVOKED, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "revoked: no movement");
    }

    /// **2a not bound → revert; 2b revoked → no revert.**
    /// The frozen document confines the revert exception to "the caller is **not** a bound
    /// agent at all", and a revoked agent *is* bound — revocation is an administrative act,
    /// and that agent should be able to look up why it is stuck (logs from a reverted call
    /// are discarded).
    function test_unbound_reverts_but_revoked_does_not() public {
        _bindAndAllow();

        vm.expectRevert(LeashAccount.NotBoundAgent.selector);
        vm.prank(address(0x4007));
        acct.spend(address(token), PAYEE, 1);

        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1); // does not revert
    }

    /// 🔴 M8 regression: `PolicyResolved.approved` must carry the **real value**.
    /// The first version emitted the event after the approval check, where it could only
    /// ever be `true` — leaving that field in the frozen schema permanently dead. And "the
    /// pointer aims at an unapproved policy" is exactly the one onchain signal that the
    /// ADMIN key has been stolen.
    function test_policy_resolved_carries_the_real_approval_flag() public {
        _bindAndAllow();
        LeashAccount implNo =
            new LeashAccount(address(ethRegistry), new NoApprovals2(), new MockAttester());
        vm.signAndAttachDelegation(address(implNo), walletPk);
        uint256 before = token.balanceOf(wallet);

        vm.expectEmit(true, true, false, true);
        emit LeashAccount.PolicyResolved(NODE, POLICY, false);
        // As with the other reason-code tests: not just PolicyResolved, but whether
        // SpendBlocked itself fired and with the right reason. `PolicyResolved.approved`
        // being false does not by itself mean the account really blocked this and recorded
        // it as POLICY_NOT_APPROVED.
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_NOT_APPROVED, POLICY, 0, 0
        );
        vm.prank(AGENT);
        LeashAccount(payable(wallet)).spend(address(token), PAYEE, 1);

        assertEq(token.balanceOf(wallet), before, "not approved: no movement");
    }

    /// The three ways to trigger 12 POLICY_FAILED.
    function test_policy_failure_modes_all_fail_closed() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        GasBurningPolicy gasBurner = new GasBurningPolicy();
        resolver.set(address(gasBurner));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(gasBurner), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "gas burner: no movement");

        ShortReturnPolicy shortReturn = new ShortReturnPolicy();
        resolver.set(address(shortReturn));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(shortReturn), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "short return: no movement");

        resolver.set(address(0xDEAD)); // no code
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(0xDEAD), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no code: no movement");
    }

    /// 🔴 The `uint8` clamp in `_askPolicy`: a policy returns 256, whose low byte is
    /// exactly `Reason.OK` (0). Without the
    /// `if (raw > type(uint8).max) return POLICY_FAILED` line this would be read as an
    /// allow and the money really would move — the one fail-*open* path in the whole
    /// branch.
    function test_policy_return_over_uint8_max_is_clamped_to_policy_failed() public {
        _bindAndAllow();
        OverflowingPolicy overflowing = new OverflowingPolicy();
        resolver.set(address(overflowing));
        uint256 before = token.balanceOf(wallet);

        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(overflowing), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(
            token.balanceOf(wallet),
            before,
            "a policy return > uint8.max must fail closed, not truncate to OK"
        );
    }

    // --- 🔴 the two gas caps: "was it reached at all" cannot show whether a cap took
    //     effect ---
    //
    //     EIP-150's 63/64 rule leaves the account enough gas to emit SpendBlocked whether
    //     or not the call was really constrained by `{gas: ...}` — so the assertion has to
    //     measure the gas actually burned, not merely that it was blocked.

    /// The `POLICY_GAS` cap: `GasBurningPolicy` burns right up to it, so the gas the
    /// account consumes must land in a band far below "burn to the end with no cap" and
    /// comfortably above what the honest path actually costs.
    function test_policy_gas_is_capped() public {
        _bindAndAllow();
        GasBurningPolicy gasBurner = new GasBurningPolicy();
        resolver.set(address(gasBurner));

        vm.prank(AGENT);
        uint256 g = gasleft();
        acct.spend(address(token), PAYEE, 1);
        uint256 consumed = g - gasleft();
        // Measured: the honest path (StandardPolicy, see test_happy_path) is about 94,789
        // gas; this one (with the POLICY_GAS cap in effect) about 243,458 gas; and with
        // `{gas: POLICY_GAS}` removed it burns about 1,040,101,586 gas (the entire block
        // gas limit). 500_000 sits comfortably between the capped and uncapped magnitudes.
        assertLt(consumed, 500_000, "POLICY_GAS must cap the policy call");
    }

    /// The `HOP_GAS` cap: swap the registry hop 1 resolves to for a mock whose
    /// `getResolver` burns all the gas, applying the same measurement reasoning to the three
    /// ENS hops.
    function test_hop_gas_is_capped() public {
        _bindAndAllow();
        GasBurningRegistry gbr = new GasBurningRegistry();
        ethRegistry.set(address(gbr), address(0)); // hop 1 resolves gbr as `reg`
        uint256 before = token.balanceOf(wallet);

        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.NO_POLICY, address(0), 0, 0
        );
        vm.prank(AGENT);
        uint256 g = gasleft();
        acct.spend(address(token), PAYEE, 1);
        uint256 consumed = g - gasleft();
        // Measured: this one (with the HOP_GAS cap in effect) is about 114,976 gas; with
        // `{gas: HOP_GAS}` removed it burns about 1,040,090,224 gas. The same 500_000
        // boundary, for the same reason as `test_policy_gas_is_capped`.
        assertLt(consumed, 500_000, "HOP_GAS must cap each ENS hop");
        assertEq(token.balanceOf(wallet), before, "hop gas exhaustion: no movement");
    }

    // --- 🔴 C4 regression: the WALLET key is unconstrained, and that is the escape hatch ---

    /// **This test pins the boundary as a specification.**
    /// EIP-7702 constrains only calls *to* that EOA; the WALLET key can still sign
    /// `USDC.transfer` directly, and the policy path never executes.
    /// Saying "the only spending path" collapses under the first question a judge asks —
    /// the accurate claim is "**the agent's** only spending path", and the wallet being
    /// unconstrained is both the boundary and the escape hatch: the owner can always
    /// retrieve their own funds and can never be locked out by a policy they installed.
    function test_the_wallet_key_can_always_transfer_directly() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(PAYEE);

        vm.recordLogs();
        vm.prank(wallet);
        token.transfer(PAYEE, 500); // never went through spend()

        assertEq(token.balanceOf(PAYEE) - before, 500, "the money moved");
        // and no SpendExecuted was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != LeashAccount.SpendExecuted.selector,
                "no SpendExecuted for a direct transfer"
            );
        }
    }
}
