// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";
import { SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

contract MicroPaymentPolicyTest is Test {
    MicroPaymentPolicy policy;

    address constant AGENT = address(0xA6E17);
    address constant STRANGER = address(0xF00D);
    address constant USDC = address(0x05DC);

    uint256 constant CAP = 1e6; // 1 USDC, 6 decimals

    function setUp() public {
        policy = new MicroPaymentPolicy(CAP);
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

    function test_already_at_the_period_limit_is_refused_without_underflowing() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 50e6;
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

    function test_a_zero_cap_is_refused_at_construction() public {
        vm.expectRevert(MicroPaymentPolicy.ZeroCap.selector);
        new MicroPaymentPolicy(0);
    }

    function test_the_cap_is_readable_and_has_no_setter() public view {
        assertEq(policy.CAP(), CAP);
    }
}
