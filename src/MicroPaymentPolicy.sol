// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "./IPolicy.sol";
import { Reason } from "./Reason.sol";

/// @title MicroPaymentPolicy — a payment small enough not to need a human
/// @notice `StandardPolicy` ANDs `payeeAllowed` into every verdict, so a payment to an
///         address nobody has allow-listed is refused however small it is. That is a real
///         limitation: you cannot pre-approve the world, and an agent topping up an API for
///         fifty cents should not need someone to find their phone.
///
///         This policy is the exception half of that rule, and it is only safe as one half.
///         On its own it would allow any small payment to anyone; composed under `PolicySet`
///         as `(this) OR (StandardPolicy)` it says what every corporate card already says —
///         under the threshold, no approval; over it, the full rules.
///
///         **It relaxes exactly one thing: the payee allow-list.** It substitutes its own
///         `CAP` for the per-transaction limit, and every other control the owner set still
///         holds — the token allow-list, the period budget, and the time window. Under an
///         OR, a check this contract omits is a check the composition no longer has for any
///         sub-cap payment, so an omission here silently deletes one of the five fields
///         `LeashAccount.tightenRule` writes.
/// @dev `view` rather than the interface's non-`view`, which the interface explicitly
///      permits. It cannot be `pure`: reading the `CAP` immutable requires `view`.
contract MicroPaymentPolicy is IPolicy {
    /// @notice The per-transaction ceiling, in the token's base units.
    /// @dev Immutable with no setter, for the same reason `PolicySet`'s member list is: a
    ///      different cap is a different address, which needs its own trip through the
    ///      approval list, which costs a face scan.
    uint256 public immutable CAP;

    error ZeroCap();

    constructor(uint256 cap_) {
        // A zero cap would allow nothing at all, which is a policy nobody wants and an easy
        // constructor argument to get wrong. Refuse it rather than deploy a dead rule.
        if (cap_ == 0) revert ZeroCap();
        CAP = cap_;
    }

    function check(SpendContext calldata ctx) external view returns (uint8) {
        // A small payment in a token nobody allowed is still a payment in a strange token.
        if (!ctx.tokenAllowed) return Reason.TOKEN_NOT_ALLOWED;

        // Checked before the budget so that a payment violating both is told about the cap:
        // that is the one an agent can act on by asking for less.
        if (ctx.amount > CAP) return Reason.OVER_TX_LIMIT;

        // The owner's own per-transaction limit, which `CAP` substitutes for but does not
        // repeal. Both must hold, so the effective ceiling is the lower of the two: a cap
        // deployed above the owner's `txLimit` cannot be used to widen it. Same reason code
        // as the line above, and immediately after it, because both say "ask for less".
        if (ctx.txLimit != 0 && ctx.amount > ctx.txLimit) return Reason.OVER_TX_LIMIT;

        // **Not optional.** Without it the exception swallows the rule — an agent drains a
        // whole period budget in sub-cap slices and never meets a human.
        if (ctx.periodLimit != 0) {
            // Reject "already over budget" first, so the subtraction cannot underflow.
            if (ctx.spentSoFar >= ctx.periodLimit) return Reason.OVER_PERIOD_LIMIT;
            if (ctx.amount > ctx.periodLimit - ctx.spentSoFar) return Reason.OVER_PERIOD_LIMIT;
        }

        // The window is one of the owner's controls, not a payee rule: "nothing outside
        // business hours" is a statement about when the agent may act at all, and a sub-cap
        // exception that ignored it would run at 3am. Checked last, matching
        // `StandardPolicy`'s order, so the reason codes rank the same way under either
        // branch of the OR.
        if (!_inWindow(ctx.nowTs, ctx.windowStart, ctx.windowEnd)) {
            return Reason.OUTSIDE_TIME_WINDOW;
        }

        // `payeeAllowed` is deliberately never read. That is the entire point of this policy.
        return Reason.OK;
    }

    /// @dev `start == end` means open all day. `start > end` is a window that crosses
    ///      midnight (say 22:00-06:00). Computed in UTC — timezone conversion is the
    ///      frontend's job; the chain does not guess.
    ///
    ///      Copied verbatim from `StandardPolicy._inWindow`, and deliberately not extracted
    ///      into a shared library: `StandardPolicy` is deployed and **approved** on Sepolia,
    ///      and extracting it would change its bytecode, which means redeploying it, which
    ///      invalidates both its approval and the ENS record pointing at it. The duplication
    ///      is paid for by
    ///      `testFuzz_inside_the_cap_and_with_an_allowed_payee_it_agrees_with_StandardPolicy`,
    ///      which fuzzes both contracts against each other and fails on the exact uint8 the
    ///      moment the two copies diverge.
    function _inWindow(uint64 nowTs, uint16 start, uint16 end) private pure returns (bool) {
        if (start == end) return true;
        uint256 minuteOfDay = (uint256(nowTs) % 1 days) / 60;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }

    /// @dev This string is the only human-readable text a person sees at approval time and on
    ///      the demo's POLICY panel, so it has to say the dangerous half out loud. The
    ///      previous wording ("payee allow-list ignored") described the hole as a feature and
    ///      read like a complete rule, which is exactly what someone approving this alone
    ///      would need to be warned about.
    function describe() external pure returns (string memory) {
        return "MicroPaymentPolicy/1: any payee under a per-tx cap; NOT SAFE ALONE - use only inside a PolicySet OR";
    }
}
