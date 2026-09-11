// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "./IPolicy.sol";
import { Reason } from "./Reason.sol";

/// @title PolicySet — several policies composed in disjunctive normal form
/// @notice AND inside a clause, OR between clauses. No nesting: `(A ∧ B) ∨ (C ∧ D)` covers
///         every rule anyone has asked for, and nesting would need a parser onchain.
///
///         Because `PolicySet` itself implements `IPolicy`, nothing else in the system
///         changes to accommodate it — the account calls it through the same interface, ENS
///         points at it through the same record, and the approval list gates it through the
///         same entry.
/// @dev **Members are reached by `staticcall`, and that is load-bearing.** `IPolicy` says a
///      policy may only write to its ledger when it returns `Reason.OK`, because the account
///      does not revert when it blocks and a write made on the way to a refusal is never
///      rolled back. Composition walks straight into that: a member returns `OK` and writes,
///      a sibling then fails, and this contract returns a block — with the write standing and
///      no way to undo it, since a policy may not revert either.
///
///      `staticcall` removes the hazard rather than documenting it. The price is that a
///      stateful policy can never be a member; that is a deliberate trade, taken because a
///      composer that can silently leak a pooled budget is worse than one that cannot hold
///      one.
contract PolicySet is IPolicy {
    /// @dev Per-member gas ceiling. This does not protect the set from a runaway member —
    ///      with the account's own 200,000-gas budget for the whole call, enough runaway
    ///      members exhaust it regardless, and because `check` returns immediately on 12 the
    ///      observable result is the same either way. What it actually does is set an
    ///      eligibility ceiling: any member costing more than 60,000 gas — including a nested
    ///      `PolicySet` — becomes `POLICY_FAILED` here even though that same policy works
    ///      correctly as the account's direct policy.
    uint256 public constant MEMBER_GAS = 60_000;

    /// @dev Clauses flattened into one array, with `_clauseEnd[i]` the exclusive end index of
    ///      clause `i`. Solidity has no immutable dynamic array; these are written once in the
    ///      constructor and there is no function anywhere that writes them again.
    address[] private _members;
    uint256[] private _clauseEnd;

    error EmptySet();
    error EmptyClause();
    error ZeroMember();

    /// @dev A clause passes when all of its members return `OK`, so a clause with **no**
    ///      members passes vacuously — and one vacuous clause makes this contract return `OK`
    ///      for every payment ever submitted. Refusing at construction rather than at runtime
    ///      means a `PolicySet` that exists is one that is well-formed, and the approval list
    ///      never sees a broken one.
    constructor(address[][] memory clauses) {
        if (clauses.length == 0) revert EmptySet();
        for (uint256 i = 0; i < clauses.length; i++) {
            if (clauses[i].length == 0) revert EmptyClause();
            for (uint256 j = 0; j < clauses[i].length; j++) {
                if (clauses[i][j] == address(0)) revert ZeroMember();
                _members.push(clauses[i][j]);
            }
            _clauseEnd.push(_members.length);
        }
    }

    /// @dev `view`, which `IPolicy` explicitly permits an implementation to tighten to. The
    ///      tightening is worth having: it makes "this contract cannot write" a fact the
    ///      compiler enforces rather than a claim in a comment.
    function check(SpendContext calldata ctx) external view returns (uint8) {
        uint256 start = 0;
        // Fails closed if the loop below somehow never assigns — it always does, because an
        // empty clause list is refused at construction.
        uint8 lastReason = Reason.POLICY_FAILED;

        for (uint256 c = 0; c < _clauseEnd.length; c++) {
            uint256 end = _clauseEnd[c];
            uint8 clauseReason = Reason.OK;

            for (uint256 m = start; m < end; m++) {
                uint8 r = _ask(_members[m], ctx);
                // A broken member is reported, never routed around: letting a later clause
                // rescue a set containing one would hide the breakage, and code 12 already
                // means "replace this policy" rather than "scan your face".
                if (r == Reason.POLICY_FAILED) return Reason.POLICY_FAILED;
                if (r != Reason.OK) {
                    clauseReason = r;
                    break; // the clause's reason is its first failing member
                }
            }

            if (clauseReason == Reason.OK) return Reason.OK;
            lastReason = clauseReason;
            start = end;
        }

        // The last clause, not the first. Clauses read as "exception OR general rule", so the
        // last one is the general rule and its reason is the one an operator can act on —
        // the same principle `StandardPolicy` states for its own ordering: report the code
        // that converges once fixed.
        return lastReason;
    }

    function clauseCount() external view returns (uint256) {
        return _clauseEnd.length;
    }

    function memberCount() external view returns (uint256) {
        return _members.length;
    }

    function memberAt(uint256 i) external view returns (address) {
        return _members[i];
    }

    function describe() external pure returns (string memory) {
        return "PolicySet/1: disjunctive normal form over IPolicy members, AND within a clause, OR between";
    }

    /// @dev Every anomaly is `POLICY_FAILED`, on the same reasoning as
    ///      `LeashAccount._askPolicy`. Two of them are easy to miss: a `staticcall` to an
    ///      address with **no code succeeds** and returns zero bytes, which without the length
    ///      check reads as `OK`; and a member returning 256 truncates to 0, which is also
    ///      `OK`. Both would pay.
    function _ask(address member, SpendContext calldata ctx) private view returns (uint8) {
        (bool ok, bytes memory ret) =
            member.staticcall{ gas: MEMBER_GAS }(abi.encodeCall(IPolicy.check, (ctx)));
        if (!ok || ret.length != 32) return Reason.POLICY_FAILED;
        uint256 raw = abi.decode(ret, (uint256));
        if (raw > type(uint8).max) return Reason.POLICY_FAILED;
        return uint8(raw);
    }
}
