// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Reason — block reason codes
/// @notice Frozen in `docs/events.md`. **The numbers must never be renumbered**: the
///         subgraph, the frontend and the agent all depend on them.
///         1-4 and 10 are decided by `LeashAccount` before it calls the policy;
///         5-9 and 11 are decided by the policy (which only answers "does this spend
///         satisfy the rules?").
library Reason {
    uint8 internal constant OK = 0;

    // --- account layer (before calling the policy) ---
    uint8 internal constant AGENT_NOT_BOUND = 1;
    uint8 internal constant AGENT_REVOKED = 2;
    uint8 internal constant NO_POLICY = 3;
    /// @dev The approval list is keyed by **policy address**, not codehash (settled
    ///      2026-09-07; rationale in PLAN.md, "key the allow-list by address"). The
    ///      number stays 4.
    uint8 internal constant POLICY_NOT_APPROVED = 4;

    // --- policy layer ---
    uint8 internal constant TOKEN_NOT_ALLOWED = 5;
    uint8 internal constant PAYEE_NOT_ALLOWED = 6;
    uint8 internal constant OVER_TX_LIMIT = 7;
    uint8 internal constant OVER_PERIOD_LIMIT = 8;
    uint8 internal constant OUTSIDE_TIME_WINDOW = 9;

    // --- account layer ---
    uint8 internal constant PAUSED = 10;

    // --- policy layer (added later) ---
    /// @dev Returned by `SharedBudgetPolicy` when several agents draw on one pooled
    ///      budget. The account knows nothing about that — which is exactly the point.
    uint8 internal constant OVER_SHARED_LIMIT = 11;

    // --- account layer (added 2026-09-08) ---
    /// @dev **The policy is broken** — not "the policy said no". The call reverted, blew
    ///      the gas cap, or returned something other than 32 bytes. The account
    ///      fails closed and no money moves.
    ///
    ///      Deliberately not folded into 4 (`POLICY_NOT_APPROVED`): that code means "no
    ///      human approved this", and the way out is a face scan. This one means "this
    ///      policy is broken", and the way out is to replace it. The subgraph has to tell
    ///      them apart, and so does the answer an agent gets when it asks why it was
    ///      blocked.
    uint8 internal constant POLICY_FAILED = 12;
}
