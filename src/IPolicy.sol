// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The full context of one spend request. **Assembled by `LeashAccount` and
///         handed to the policy in one piece.**
/// @dev    Why this struct exists: a policy does not need — and should not be able — to
///         reach into the account for anything. The account does the lookups and passes
///         the conclusions in; the policy only judges. Two consequences:
///         1. The policy is an external contract reached by `call`, so it **cannot touch
///            the account's storage** (only `delegatecall` would break that, and we never
///            use it)
///         2. The frontend and the agent can dry-run the same inputs through `eth_call`
///            and are guaranteed the same verdict
struct SpendContext {
    address agent;
    address payee;
    address token;
    uint256 amount;
    // --- filled in by the account after its lookups ---
    bool tokenAllowed;
    bool payeeAllowed;
    uint256 txLimit; // per-tx cap. 0 = unlimited
    uint256 periodLimit; // per-period cap. 0 = unlimited
    uint256 spentSoFar; // already spent this period (excluding this request)
    uint64 nowTs; // block.timestamp, passed in by the account
    uint16 windowStart; // start of the allowed window, as minute of the day UTC (0-1439)
    uint16 windowEnd; // end of the window (exclusive). start == end means all day
}

/// @title IPolicy — the swappable rule implementation
/// @notice The policy address lives in the ENS name's resolver record and is set by
///         ADMIN; but whether that address has *ever been approved* is decided by the
///         approval list, and getting onto that list costs a face scan. Splitting the two
///         means a stolen ADMIN key still cannot install unapproved rules.
interface IPolicy {
    /// @return reason `Reason.OK` means allow; anything else is a block reason code
    /// @dev **Deliberately not `view`.** A policy is allowed its own storage — "several
    ///      agents share one pooled budget" needs someone to keep the ledger, and letting
    ///      the policy keep it is the only way that does not carve a special case into the
    ///      account.
    ///
    ///      No security guarantee weakens as a result: the policy is a separate contract
    ///      reached by `call`, and it writes **its own** storage. Only `delegatecall`
    ///      could reach the account's storage, and we never use it.
    ///
    ///      **It has side effects, so the account calls it exactly once, and only when it
    ///      genuinely intends to pay.** Dry runs go through `eth_call`. The caller must:
    ///      hold a reentrancy lock, cap the gas, and treat any unexpected return length as
    ///      a block (fail closed).
    ///
    ///      Implementations may tighten the mutability (Solidity permits tightening on
    ///      override) — `StandardPolicy` is `pure`.
    ///
    ///      🔴 **A policy may only write to its ledger when it returns `Reason.OK`.**
    ///
    ///      Because the account **does not revert** when it blocks: if a policy debits the
    ///      shared budget and *then* returns "over limit", that debit is never rolled back
    ///      and the shared budget leaks. The way `SharedBudgetPolicy` is written today
    ///      happens to be correct (check first, then accumulate), but that was an accident
    ///      rather than a requirement. **It is a requirement now.**
    function check(SpendContext calldata ctx) external returns (uint8 reason);

    /// @notice Human-readable identifier; shown in the frontend and in the demo
    function describe() external pure returns (string memory);
}
