// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPolicyApprovals — the read-only face of the approval list
/// @notice Answers "has a real human approved this policy address?". **Writing** to the
///         list costs a face scan (`AttesterGate`), but reading it is needed everywhere —
///         the resolver logs it, `LeashAccount` enforces on it, the frontend displays it.
/// @dev    The key is the **policy address**, not a codehash (settled 2026-09-07; see
///         "Policy layer design decisions" in `docs/PLAN.md`). Since EIP-6780 the
///         address → code binding is permanent, so the old CREATE2-redeploy objection
///         no longer holds.
interface IPolicyApprovals {
    function isApproved(address policy) external view returns (bool);
}
