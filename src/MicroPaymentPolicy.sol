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

        // **Not optional.** Without it the exception swallows the rule — an agent drains a
        // whole period budget in sub-cap slices and never meets a human.
        if (ctx.periodLimit != 0) {
            // Reject "already over budget" first, so the subtraction cannot underflow.
            if (ctx.spentSoFar >= ctx.periodLimit) return Reason.OVER_PERIOD_LIMIT;
            if (ctx.amount > ctx.periodLimit - ctx.spentSoFar) return Reason.OVER_PERIOD_LIMIT;
        }

        // `payeeAllowed` is deliberately never read. That is the entire point of this policy.
        return Reason.OK;
    }

    function describe() external pure returns (string memory) {
        return "MicroPaymentPolicy/1: per-tx cap and period budget, payee allow-list ignored";
    }
}
