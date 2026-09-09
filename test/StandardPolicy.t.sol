// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

contract StandardPolicyTest is Test {
    StandardPolicy policy;

    address constant AGENT = address(0xA6E17);
    address constant PAYEE = address(0xBEEF);
    address constant USDC = address(0x05DC);

    function setUp() public {
        policy = new StandardPolicy();
    }

    /// The baseline context where everything is fine: cap 5000, 4200 already spent,
    /// 200 for this request, open all day.
    function _ok() internal pure returns (SpendContext memory c) {
        c = SpendContext({
            agent: AGENT,
            payee: PAYEE,
            token: USDC,
            amount: 200e6,
            tokenAllowed: true,
            payeeAllowed: true,
            txLimit: 1000e6,
            periodLimit: 5000e6,
            spentSoFar: 4200e6,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    // --- allowed ---

    function test_allows_a_normal_payment() public view {
        assertEq(policy.check(_ok()), Reason.OK);
    }

    function test_allows_spending_exactly_the_remaining_budget() public view {
        SpendContext memory c = _ok();
        c.amount = 800e6; // 4200 + 800 == 5000
        assertEq(policy.check(c), Reason.OK);
    }

    function test_allows_exactly_the_per_tx_cap() public view {
        SpendContext memory c = _ok();
        c.txLimit = 200e6;
        assertEq(policy.check(c), Reason.OK);
    }

    function test_zero_means_unlimited() public view {
        SpendContext memory c = _ok();
        c.txLimit = 0;
        c.periodLimit = 0;
        c.amount = type(uint256).max;
        assertEq(policy.check(c), Reason.OK);
    }

    // --- blocked ---

    function test_blocks_unlisted_token() public view {
        SpendContext memory c = _ok();
        c.tokenAllowed = false;
        assertEq(policy.check(c), Reason.TOKEN_NOT_ALLOWED);
    }

    function test_blocks_unlisted_payee() public view {
        SpendContext memory c = _ok();
        c.payeeAllowed = false;
        assertEq(policy.check(c), Reason.PAYEE_NOT_ALLOWED);
    }

    function test_blocks_over_per_tx_cap() public view {
        SpendContext memory c = _ok();
        c.amount = 1000e6 + 1;
        c.periodLimit = 0; // isolate: exercise the per-tx cap alone
        assertEq(policy.check(c), Reason.OVER_TX_LIMIT);
    }

    function test_blocks_over_period_budget() public view {
        SpendContext memory c = _ok();
        c.amount = 801e6; // 4200 + 801 > 5000
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    /// Being already over budget must not underflow — the guard on the
    /// `periodLimit - spentSoFar` line.
    function test_blocks_when_already_over_budget_without_underflow() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 6000e6;
        c.amount = 1;
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    // --- time window ---

    function test_blocks_outside_daytime_window() public view {
        SpendContext memory c = _ok();
        c.windowStart = 540; // 09:00 UTC
        c.windowEnd = 1020; // 17:00 UTC
        c.nowTs = uint64(3 days + 8 hours); // 08:00 UTC
        assertEq(policy.check(c), Reason.OUTSIDE_TIME_WINDOW);
    }

    function test_allows_inside_daytime_window() public view {
        SpendContext memory c = _ok();
        c.windowStart = 540;
        c.windowEnd = 1020;
        c.nowTs = uint64(3 days + 12 hours);
        assertEq(policy.check(c), Reason.OK);
    }

    function test_window_wrapping_past_midnight() public view {
        SpendContext memory c = _ok();
        c.windowStart = 1320; // 22:00
        c.windowEnd = 360; // 06:00 the next day

        c.nowTs = uint64(3 days + 23 hours);
        assertEq(policy.check(c), Reason.OK, "23:00 should be inside");

        c.nowTs = uint64(3 days + 2 hours);
        assertEq(policy.check(c), Reason.OK, "02:00 should be inside");

        c.nowTs = uint64(3 days + 12 hours);
        assertEq(policy.check(c), Reason.OUTSIDE_TIME_WINDOW, "12:00 should be outside");
    }

    // --- precedence ---

    /// Act two of the demo: pay 5000 to an address never seen before, violating both the
    /// allow-list and the period budget at once. What is reported must be the
    /// **outermost** violation, PAYEE_NOT_ALLOWED, so that a retrying agent converges.
    function test_reports_outermost_violation_first() public view {
        SpendContext memory c = _ok();
        c.payeeAllowed = false;
        c.amount = 5000e6;
        assertEq(policy.check(c), Reason.PAYEE_NOT_ALLOWED);
    }

    function test_token_outranks_payee() public view {
        SpendContext memory c = _ok();
        c.tokenAllowed = false;
        c.payeeAllowed = false;
        assertEq(policy.check(c), Reason.TOKEN_NOT_ALLOWED);
    }

    // --- invariants ---

    /// This policy is pure: the same inputs always give the same output, unaffected by
    /// block number, timestamp or caller — which is what lets an offchain dry run be
    /// guaranteed to agree with the chain.
    function testFuzz_is_deterministic(uint256 amount, uint256 limit, uint256 spent, uint64 ts)
        public
    {
        SpendContext memory c = _ok();
        c.amount = amount;
        c.periodLimit = limit;
        c.spentSoFar = spent;
        c.nowTs = ts;

        uint8 first = policy.check(c);

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 90 days);
        vm.prank(address(0xDEAD));
        uint8 second = policy.check(c);

        assertEq(first, second);
    }

    /// When a spend is allowed, the running total never exceeds the period cap. This is
    /// the core guarantee of the whole system.
    function testFuzz_never_allows_budget_overrun(uint128 amount, uint128 limit, uint128 spent)
        public
        view
    {
        vm.assume(limit > 0);
        SpendContext memory c = _ok();
        c.txLimit = 0;
        c.amount = amount;
        c.periodLimit = limit;
        c.spentSoFar = spent;

        if (policy.check(c) == Reason.OK) {
            assertLe(uint256(spent) + uint256(amount), uint256(limit));
        }
    }
}
