// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

contract MicroPaymentPolicyTest is Test {
    MicroPaymentPolicy policy;
    StandardPolicy standard;

    address constant AGENT = address(0xA6E17);
    address constant STRANGER = address(0xF00D);
    address constant USDC = address(0x05DC);

    uint256 constant CAP = 1e6; // 1 USDC, 6 decimals

    function setUp() public {
        policy = new MicroPaymentPolicy(CAP);
        standard = new StandardPolicy();
    }

    /// A small payment to a payee the allow-list has never heard of, well inside a
    /// period budget: exactly the case this policy exists to allow.
    function _ok() internal pure returns (SpendContext memory c) {
        c = SpendContext({
            agent: AGENT,
            payee: STRANGER,
            token: USDC,
            amount: 5e5, // 0.50 USDC
            tokenAllowed: true,
            payeeAllowed: false, // <-- the point
            txLimit: 0,
            periodLimit: 50e6,
            spentSoFar: 5e6,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    function test_allows_a_small_payment_to_a_payee_nobody_allow_listed() public view {
        assertEq(policy.check(_ok()), Reason.OK);
    }

    function test_the_payee_allow_list_is_ignored_in_both_directions() public view {
        SpendContext memory c = _ok();
        c.payeeAllowed = true;
        assertEq(policy.check(c), Reason.OK);
        c.payeeAllowed = false;
        assertEq(policy.check(c), Reason.OK);
    }

    function test_allows_exactly_the_cap() public view {
        SpendContext memory c = _ok();
        c.amount = CAP;
        assertEq(policy.check(c), Reason.OK);
    }

    function test_one_unit_over_the_cap_is_over_tx_limit() public view {
        SpendContext memory c = _ok();
        c.amount = CAP + 1;
        assertEq(policy.check(c), Reason.OVER_TX_LIMIT);
    }

    function test_a_token_nobody_allowed_is_refused_however_small() public view {
        SpendContext memory c = _ok();
        c.tokenAllowed = false;
        c.amount = 1;
        assertEq(policy.check(c), Reason.TOKEN_NOT_ALLOWED);
    }

    /// Without this the exception swallows the rule: an agent drains a 50 USDC period
    /// budget in sub-cap slices and never meets a human.
    function test_a_micro_payment_that_would_exceed_the_period_budget_is_refused() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 50e6 - 2e5; // 0.20 USDC of room left
        c.amount = 5e5; // asking for 0.50
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    function test_already_at_the_period_limit_is_refused() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 50e6; // exactly at the limit
        c.amount = 1;
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    /// Past the limit, not merely at it. This is the only shape that underflows if the
    /// `spentSoFar >= periodLimit` guard is removed, and it is reachable in practice:
    /// tightening a period limit below what has already been spent this period is a
    /// permitted reduction (`LeashAccount.tightenRule`).
    function test_over_the_period_limit_is_refused_without_underflowing() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 50e6 + 1; // past it
        c.amount = 1;
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    function test_spending_exactly_the_remaining_budget_is_allowed() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 50e6 - 5e5;
        c.amount = 5e5;
        assertEq(policy.check(c), Reason.OK);
    }

    function test_a_zero_period_limit_means_unlimited() public view {
        SpendContext memory c = _ok();
        c.periodLimit = 0;
        c.spentSoFar = type(uint256).max;
        assertEq(policy.check(c), Reason.OK);
    }

    /// The precedence: a payment can be over the cap AND over budget at once. The cap is
    /// checked first, so that is what an agent is told to fix.
    function test_the_cap_outranks_the_budget_when_both_are_violated() public view {
        SpendContext memory c = _ok();
        c.amount = CAP + 1;
        c.spentSoFar = 50e6;
        assertEq(policy.check(c), Reason.OVER_TX_LIMIT);
    }

    // --- the owner's other controls still hold ---

    /// `CAP` substitutes for the owner's per-transaction limit; it does not repeal it. A
    /// payment under the cap but over `txLimit` is refused, so deploying this policy with a
    /// cap above the owner's limit cannot be used to widen it.
    function test_under_the_cap_but_over_the_owners_tx_limit_is_over_tx_limit() public view {
        SpendContext memory c = _ok();
        c.txLimit = 4e5; // 0.40 USDC, below the 1 USDC CAP
        c.amount = 5e5; // 0.50: inside CAP, outside txLimit
        assertEq(policy.check(c), Reason.OVER_TX_LIMIT);
    }

    /// The window is one of the five fields `tightenRule` writes. Without this check a
    /// sub-cap payment would run at any hour, and "nothing outside business hours" would
    /// quietly stop being true the moment this policy joined the set.
    function test_outside_the_time_window_is_outside_time_window() public view {
        SpendContext memory c = _ok();
        c.windowStart = 540; // 09:00 UTC
        c.windowEnd = 1020; // 17:00 UTC
        c.nowTs = uint64(3 * 3600); // 03:00 UTC
        assertEq(policy.check(c), Reason.OUTSIDE_TIME_WINDOW);
    }

    /// The differential proof that the verbatim `_inWindow` copy is honest. `StandardPolicy`
    /// is deployed and approved on Sepolia, so the duplication cannot be refactored away —
    /// this test is what it is paid for. Inside the cap and with the payee allowed, the two
    /// contracts are answering the same question, so they must return the **same uint8**:
    /// not both-OK-or-both-not, which would let the reason codes drift apart unnoticed.
    ///
    /// `bound(amount, 0, CAP)` keeps the CAP branch out of it, so any difference this finds
    /// is a difference in a rule both contracts are meant to share.
    function testFuzz_inside_the_cap_and_with_an_allowed_payee_it_agrees_with_StandardPolicy(
        uint64 nowTs,
        uint16 windowStart,
        uint16 windowEnd,
        uint256 amount,
        uint256 txLimit,
        uint256 periodLimit,
        uint256 spentSoFar
    ) public view {
        SpendContext memory c = SpendContext({
            agent: AGENT,
            payee: STRANGER,
            token: USDC,
            amount: bound(amount, 0, CAP),
            tokenAllowed: true,
            payeeAllowed: true, // the one rule they are allowed to disagree about
            txLimit: txLimit,
            periodLimit: periodLimit,
            spentSoFar: spentSoFar,
            nowTs: nowTs,
            // A minute of the day. Values above 1439 are unreachable through
            // `tightenRule`, and feeding them in would only compare two copies of the
            // same arithmetic on inputs neither can receive.
            windowStart: uint16(bound(windowStart, 0, 1439)),
            windowEnd: uint16(bound(windowEnd, 0, 1439))
        });
        assertEq(policy.check(c), standard.check(c));
    }

    function test_a_zero_cap_is_refused_at_construction() public {
        vm.expectRevert(MicroPaymentPolicy.ZeroCap.selector);
        new MicroPaymentPolicy(0);
    }

    function test_the_cap_is_readable_and_has_no_setter() public view {
        assertEq(policy.CAP(), CAP);
    }

    /// `describe()` is the only human-readable text at approval time and on the demo's POLICY
    /// panel. Approving this policy on its own allows any payee under the cap, so the string
    /// has to say so rather than describing the hole as a feature.
    function test_describe_warns_that_this_policy_is_not_safe_alone() public view {
        assertEq(
            policy.describe(),
            "MicroPaymentPolicy/1: any payee under a per-tx cap; NOT SAFE ALONE - use only inside a PolicySet OR"
        );
    }
}
