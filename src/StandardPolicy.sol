// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "./IPolicy.sol";
import { Reason } from "./Reason.sol";

/// @title StandardPolicy — the default rules: token allow-list, payee allow-list,
///        per-tx cap, period budget, time window
/// @notice The interface permits side effects; this implementation deliberately narrows
///         itself to `pure`. No storage, no owner, no constructor arguments, and it reads
///         no external contract — so the verdict is a total function of its inputs, and
///         both the agent and the frontend can reproduce it exactly offchain.
///
///         The price is recorded here so it is not forgotten later: this policy **cannot
///         read external state** — no price oracle, no shared blocklist, no budget pooled
///         across agents. Those need a separate implementation (say
///         `SharedBudgetPolicy`); the interface already leaves the door open.
contract StandardPolicy is IPolicy {
    /// @dev The order of the checks *is* the precedence of the reason codes. When
    ///      several are violated at once, report the **outermost** one. That way an agent
    ///      that fixes one item and retries converges, instead of circling on one layer.
    function check(SpendContext calldata ctx) external pure returns (uint8) {
        if (!ctx.tokenAllowed) return Reason.TOKEN_NOT_ALLOWED;
        if (!ctx.payeeAllowed) return Reason.PAYEE_NOT_ALLOWED;

        if (ctx.txLimit != 0 && ctx.amount > ctx.txLimit) return Reason.OVER_TX_LIMIT;

        if (ctx.periodLimit != 0) {
            // Reject "already over budget" first, so the subtraction below cannot underflow
            if (ctx.spentSoFar >= ctx.periodLimit) return Reason.OVER_PERIOD_LIMIT;
            if (ctx.amount > ctx.periodLimit - ctx.spentSoFar) return Reason.OVER_PERIOD_LIMIT;
        }

        if (!_inWindow(ctx.nowTs, ctx.windowStart, ctx.windowEnd)) {
            return Reason.OUTSIDE_TIME_WINDOW;
        }

        return Reason.OK;
    }

    function describe() external pure returns (string memory) {
        return "StandardPolicy/1: token+payee allowlist, per-tx cap, period budget, daily window";
    }

    /// @dev `start == end` means open all day. `start > end` is a window that crosses
    ///      midnight (say 22:00-06:00). Computed in UTC — timezone conversion is the
    ///      frontend's job; the chain does not guess.
    function _inWindow(uint64 nowTs, uint16 start, uint16 end) private pure returns (bool) {
        if (start == end) return true;
        uint256 minuteOfDay = (uint256(nowTs) % 1 days) / 60;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }
}
