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

    /// 一切都對的基準脈絡:額度 5000,已花 4200,這筆 200,全天開放。
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

    // --- 放行 ---

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

    // --- 攔截 ---

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
        c.periodLimit = 0; // 隔離:只測單筆上限
        assertEq(policy.check(c), Reason.OVER_TX_LIMIT);
    }

    function test_blocks_over_period_budget() public view {
        SpendContext memory c = _ok();
        c.amount = 801e6; // 4200 + 801 > 5000
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    /// 已經超支的情況不可以 underflow —— `periodLimit - spentSoFar` 那行的護欄。
    function test_blocks_when_already_over_budget_without_underflow() public view {
        SpendContext memory c = _ok();
        c.spentSoFar = 6000e6;
        c.amount = 1;
        assertEq(policy.check(c), Reason.OVER_PERIOD_LIMIT);
    }

    // --- 時段 ---

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
        c.windowEnd = 360; // 06:00 隔天

        c.nowTs = uint64(3 days + 23 hours);
        assertEq(policy.check(c), Reason.OK, "23:00 should be inside");

        c.nowTs = uint64(3 days + 2 hours);
        assertEq(policy.check(c), Reason.OK, "02:00 should be inside");

        c.nowTs = uint64(3 days + 12 hours);
        assertEq(policy.check(c), Reason.OUTSIDE_TIME_WINDOW, "12:00 should be outside");
    }

    // --- 優先序 ---

    /// Demo 第 2 幕:付一個沒見過的地址 5000,同時違反白名單與週期預算。
    /// 回報的必須是**最外層**的 PAYEE_NOT_ALLOWED,agent 才會逐步收斂。
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

    // --- 不變式 ---

    /// policy 是 pure 的前提:同樣的輸入永遠得到同樣的輸出,
    /// 不受 block number、timestamp、caller 影響。codehash 允許清單靠這條成立。
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

    /// 放行時,累計花費永遠不會超過週期上限。這是整個系統的核心保證。
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
