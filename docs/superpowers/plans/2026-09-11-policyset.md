# PolicySet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two contracts that let "small payments to anyone, larger ones only to a vetted payee" be expressed — a rule `StandardPolicy` cannot write, because it ANDs `payeeAllowed` into every verdict.

**Architecture:** `PolicySet` evaluates disjunctive normal form over `IPolicy` members — AND inside a clause, OR between clauses — reaching every member by `staticcall` so no member can write state. `MicroPaymentPolicy` is the exception clause: a per-transaction cap that ignores the payee allow-list but still honours the period budget. Neither contract changes anything already deployed; both are reached through the `IPolicy` interface the account already calls.

**Tech Stack:** Solidity 0.8.28, Foundry (`forge test`), `evm_version = prague`, `via_ir = false`, optimizer on at 200 runs. No new dependency.

**Spec:** [`docs/superpowers/specs/2026-09-11-policyset-design.md`](../specs/2026-09-11-policyset-design.md)

## Global Constraints

- **Members are reached by `staticcall`, never `call`.** A member that tries to write must revert. This is the whole reason composition is safe: `IPolicy` forbids writing on any path that does not return `OK`, and a composite cannot roll back a member's write because it may not revert.
- **`PolicySet.check` and `MicroPaymentPolicy.check` are declared `view`.** `IPolicy` permits tightening the mutability, and tightening makes "this contract cannot write" a compiler guarantee.
- **Any member anomaly returns `Reason.POLICY_FAILED` (12) immediately** — a revert, a return length other than 32, or a value above `type(uint8).max`. Do not fall through to another clause.
- **When no clause passes, report the LAST clause's reason.** Within a clause, the reason is the first member that failed. Getting this backwards silently breaks the demo: the blocked intent would report 7 instead of 6, and the demo page's widen button requires `reason === 6`.
- **The constructor reverts on an empty clause list, an empty clause, or a zero member address.** An empty clause passes vacuously and one of those returns `OK` for every payment ever submitted.
- **Member lists and `CAP` are fixed at construction with no setter.** A different composition is a different address, which is a different entry in the approval list, which costs a human.
- **Reason codes are frozen** (`src/Reason.sol`). Use the existing numbers; never add one.
- **No contract already deployed may be edited.** `LeashAccount`, `LeashRegistry`, `LeashResolver`, `PolicyApprovals`, `StandardPolicy` are untouched.
- Every test that pins a reason code asserts the exact number, never merely "not OK". This project has shipped seven tests that passed without exercising the property they named.

---

### Task 1: `MicroPaymentPolicy`

**Files:**
- Create: `src/MicroPaymentPolicy.sol`
- Test: `test/MicroPaymentPolicy.t.sol`

**Interfaces:**
- Consumes: `IPolicy`, `SpendContext` from `src/IPolicy.sol`; `Reason` from `src/Reason.sol`
- Produces: `MicroPaymentPolicy(uint256 cap_)`, `CAP() -> uint256`, `check(SpendContext) -> uint8` (`view`), `describe() -> string`

- [ ] **Step 1: Write the failing tests**

Create `test/MicroPaymentPolicy.t.sol`:

```solidity
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest`
Expected: FAIL — the compiler cannot find `src/MicroPaymentPolicy.sol`.

- [ ] **Step 3: Write the contract**

Create `src/MicroPaymentPolicy.sol`:

```solidity
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
```

- [ ] **Step 4: Run them to verify they pass**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest -v`
Expected: PASS — 12 tests, 0 failed.

- [ ] **Step 5: Prove the budget test is not vacuous**

Temporarily delete the whole `if (ctx.periodLimit != 0) { … }` block, then:

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest`
Expected: **three tests go RED** — `test_a_micro_payment_that_would_exceed_the_period_budget_is_refused`, `test_already_at_the_period_limit_is_refused_without_underflowing`, and `test_the_cap_outranks_the_budget_when_both_are_violated` stays green (the cap fires first). Restore the block and confirm all 12 pass again. A guard that cannot fail is not a guard.

- [ ] **Step 6: Commit**

```bash
cd /home/ubuntu/DEV/leash
git add src/MicroPaymentPolicy.sol test/MicroPaymentPolicy.t.sol
git commit -m "feat: a payment small enough not to need a human"
```

---

### Task 2: `PolicySet`

**Files:**
- Create: `src/PolicySet.sol`
- Create: `test/mocks/PolicyMocks.sol`
- Test: `test/PolicySet.t.sol`

**Interfaces:**
- Consumes: `IPolicy`, `SpendContext`, `Reason`
- Produces: `PolicySet(address[][] memory clauses)`, `check(SpendContext) -> uint8` (`view`), `clauseCount() -> uint256`, `memberCount() -> uint256`, `memberAt(uint256) -> address`, `describe() -> string`, and the errors `EmptySet()`, `EmptyClause()`, `ZeroMember()`

- [ ] **Step 1: Write the mock members**

Create `test/mocks/PolicyMocks.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "../../src/IPolicy.sol";
import { Reason } from "../../src/Reason.sol";

/// Always allows.
contract AlwaysOK is IPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        return Reason.OK;
    }
    function describe() external pure returns (string memory) { return "AlwaysOK"; }
}

/// Always blocks with the code it was constructed with.
contract AlwaysBlock is IPolicy {
    uint8 public immutable CODE;
    constructor(uint8 code_) { CODE = code_; }
    function check(SpendContext calldata) external view returns (uint8) { return CODE; }
    function describe() external pure returns (string memory) { return "AlwaysBlock"; }
}

/// Records that it was called, so a test can prove short-circuiting really short-circuits.
/// The recording is a write, which means `PolicySet` cannot call it — which is itself the
/// point of `SpyPolicy` below. Use this one only through a direct call.
contract CountingOK is IPolicy {
    uint256 public calls;
    function check(SpendContext calldata) external returns (uint8) {
        calls++;
        return Reason.OK;
    }
    function describe() external pure returns (string memory) { return "CountingOK"; }
}

/// Writes storage on every call. Under `staticcall` the write reverts, which is exactly what
/// `PolicySet` relies on to make "a member cannot have side effects" a property of the EVM
/// rather than a promise in a comment.
contract StatefulPolicy is IPolicy {
    uint256 public seen;
    function check(SpendContext calldata) external returns (uint8) {
        seen++;
        return Reason.OK;
    }
    function describe() external pure returns (string memory) { return "StatefulPolicy"; }
}

/// Reverts.
contract RevertingPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        revert("nope");
    }
}

/// Returns 33 bytes: the right kind of answer at the wrong length.
contract LongReturnPolicy {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encodePacked(uint256(0), uint8(0));
    }
}

/// Returns 256 — one past what a `uint8` can hold. Truncating it would produce 0, which is
/// `Reason.OK`, and the payment would go through. This is the same shape of bug that a
/// mutation sweep found load-bearing in `LeashAccount._askPolicy`.
contract HugeReturnPolicy {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(256));
    }
}

/// Burns all the gas it is given.
contract GasBurnerPolicy {
    function check(SpendContext calldata) external view returns (uint8) {
        uint256 i;
        while (true) { i = uint256(keccak256(abi.encode(i))); }
        return 0;
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `test/PolicySet.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { IPolicy, SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";
import {
    AlwaysOK, AlwaysBlock, StatefulPolicy, RevertingPolicy,
    LongReturnPolicy, HugeReturnPolicy, GasBurnerPolicy
} from "./mocks/PolicyMocks.sol";

contract PolicySetTest is Test {
    AlwaysOK ok1;
    AlwaysOK ok2;
    AlwaysBlock blockPayee;   // 6
    AlwaysBlock blockTxLimit; // 7

    function setUp() public {
        ok1 = new AlwaysOK();
        ok2 = new AlwaysOK();
        blockPayee = new AlwaysBlock(Reason.PAYEE_NOT_ALLOWED);
        blockTxLimit = new AlwaysBlock(Reason.OVER_TX_LIMIT);
    }

    function _ctx() internal pure returns (SpendContext memory c) {
        c = SpendContext({
            agent: address(0xA6E17),
            payee: address(0xF00D),
            token: address(0x05DC),
            amount: 5e5,
            tokenAllowed: true,
            payeeAllowed: false,
            txLimit: 0,
            periodLimit: 50e6,
            spentSoFar: 5e6,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    function _one(address a) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = a;
        m[1] = b;
    }

    function _set(address[][] memory clauses) internal returns (PolicySet) {
        return new PolicySet(clauses);
    }

    function _clauses1(address[] memory a) internal pure returns (address[][] memory c) {
        c = new address[][](1);
        c[0] = a;
    }

    function _clauses2(address[] memory a, address[] memory b)
        internal pure returns (address[][] memory c)
    {
        c = new address[][](2);
        c[0] = a;
        c[1] = b;
    }

    // --- AND inside a clause ---

    function test_a_clause_of_two_passes_only_when_both_pass() public {
        PolicySet both = _set(_clauses1(_two(address(ok1), address(ok2))));
        assertEq(both.check(_ctx()), Reason.OK);

        PolicySet oneFails = _set(_clauses1(_two(address(ok1), address(blockPayee))));
        assertEq(oneFails.check(_ctx()), Reason.PAYEE_NOT_ALLOWED);
    }

    function test_a_clause_reports_its_first_failing_member() public {
        PolicySet s = _set(_clauses1(_two(address(blockTxLimit), address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.OVER_TX_LIMIT);
    }

    // --- OR between clauses ---

    function test_a_later_clause_rescues_an_earlier_failure() public {
        PolicySet s = _set(_clauses2(_one(address(blockPayee)), _one(address(ok1))));
        assertEq(s.check(_ctx()), Reason.OK);
    }

    function test_a_passing_first_clause_is_enough() public {
        PolicySet s = _set(_clauses2(_one(address(ok1)), _one(address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.OK);
    }

    /// The decision that keeps the demo working: the last clause is the general rule, and
    /// its reason is the one an operator can act on. Reporting the first clause's reason
    /// would tell an agent "over the cap" when the fix is "get this payee allow-listed".
    function test_when_nothing_passes_the_last_clauses_reason_is_reported() public {
        PolicySet s = _set(_clauses2(_one(address(blockTxLimit)), _one(address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.PAYEE_NOT_ALLOWED);

        PolicySet reversed = _set(_clauses2(_one(address(blockPayee)), _one(address(blockTxLimit))));
        assertEq(reversed.check(_ctx()), Reason.OVER_TX_LIMIT);
    }

    // --- a member that misbehaves ---

    /// The guarantee the whole design rests on: a member cannot write, because it is reached
    /// by `staticcall` and the write reverts.
    function test_a_member_that_writes_storage_cannot_be_a_member() public {
        StatefulPolicy stateful = new StatefulPolicy();
        PolicySet s = _set(_clauses1(_one(address(stateful))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
        assertEq(stateful.seen(), 0, "the write must not have landed");
    }

    function test_a_reverting_member_fails_the_whole_set() public {
        PolicySet s = _set(_clauses2(_one(address(new RevertingPolicy())), _one(address(ok1))));
        // Not rescued by the second clause: a broken member is reported, not routed around.
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    function test_a_member_returning_the_wrong_length_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(new LongReturnPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    /// 256 truncated to a `uint8` is 0, which is `Reason.OK`, which pays.
    function test_a_member_returning_256_does_not_truncate_into_OK() public {
        PolicySet s = _set(_clauses1(_one(address(new HugeReturnPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    /// A `staticcall` to an address with no code SUCCEEDS and returns zero bytes. Without
    /// the length check that reads as `OK` and the payment goes through.
    function test_a_member_with_no_code_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(0xDEAD))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    function test_a_member_that_burns_all_its_gas_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(new GasBurnerPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    // --- the constructor refuses a set that would allow everything ---

    function test_an_empty_clause_list_is_refused() public {
        address[][] memory none = new address[][](0);
        vm.expectRevert(PolicySet.EmptySet.selector);
        new PolicySet(none);
    }

    function test_an_empty_clause_is_refused() public {
        address[][] memory c = new address[][](2);
        c[0] = _one(address(ok1));
        c[1] = new address[](0);
        vm.expectRevert(PolicySet.EmptyClause.selector);
        new PolicySet(c);
    }

    function test_a_zero_member_is_refused() public {
        vm.expectRevert(PolicySet.ZeroMember.selector);
        new PolicySet(_clauses1(_one(address(0))));
    }

    // --- shape is readable and fixed ---

    function test_the_shape_is_readable() public {
        PolicySet s = _set(_clauses2(_two(address(ok1), address(ok2)), _one(address(blockPayee))));
        assertEq(s.clauseCount(), 2);
        assertEq(s.memberCount(), 3);
        assertEq(s.memberAt(0), address(ok1));
        assertEq(s.memberAt(2), address(blockPayee));
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract PolicySetTest`
Expected: FAIL — the compiler cannot find `src/PolicySet.sol`.

- [ ] **Step 4: Write the contract**

Create `src/PolicySet.sol`:

```solidity
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
    /// @dev Per-member gas ceiling. The account caps this whole call at
    ///      `LeashAccount.POLICY_GAS` (200,000), so a member that runs away must not be able
    ///      to take the set down with it.
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
```

- [ ] **Step 5: Run them to verify they pass**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract PolicySetTest -v`
Expected: PASS — 15 tests, 0 failed.

- [ ] **Step 6: Prove the two easy-to-miss guards are not vacuous**

Two mutations, one at a time, reverting after each:

1. Change `if (!ok || ret.length != 32)` to `if (!ok)`.
   Run the suite. Expected: `test_a_member_returning_the_wrong_length_fails_closed` and `test_a_member_with_no_code_fails_closed` go **RED**.
2. Change `if (raw > type(uint8).max) return Reason.POLICY_FAILED;` to nothing.
   Run the suite. Expected: `test_a_member_returning_256_does_not_truncate_into_OK` goes **RED** — and note in the report that the observed value was `OK`, i.e. the payment would have gone through.

Restore both and confirm 15 pass.

- [ ] **Step 7: Commit**

```bash
cd /home/ubuntu/DEV/leash
git add src/PolicySet.sol test/PolicySet.t.sol test/mocks/PolicyMocks.sol
git commit -m "feat: compose policies in disjunctive normal form, with staticcall as the guarantee"
```

---

### Task 3: The demo composition, its gas, and the third intent

**Files:**
- Create: `test/PolicySetDemo.t.sol`
- Modify: `agent/intents.json`

**Interfaces:**
- Consumes: `PolicySet` and `MicroPaymentPolicy` from Tasks 1-2, plus the deployed `StandardPolicy`
- Produces: nothing further tasks rely on

- [ ] **Step 1: Write the failing test**

Create `test/PolicySetDemo.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { IPolicy, SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

/// The composition the demo actually runs, pinned so that a change to any of the three
/// contracts that would alter what a judge sees on screen fails here first.
contract PolicySetDemoTest is Test {
    PolicySet set;

    address constant BEEF = address(0xBEEF); // allow-listed
    address constant CAFE = address(0xCAFE0); // not allow-listed, 5 USDC
    address constant FOOD = address(0xF00D); // not allow-listed, 0.50 USDC
    address constant USDC = address(0x768F);

    uint256 constant CAP = 1e6; // 1 USDC
    uint256 constant PERIOD_LIMIT = 50e6; // 50 USDC, as tightened on chain 2026-09-11
    uint256 constant SPENT = 5e6; // 5 USDC already spent this period

    /// `LeashAccount.POLICY_GAS` — the ceiling the account puts on this whole call.
    uint256 constant POLICY_GAS = 200_000;

    function setUp() public {
        address[][] memory clauses = new address[][](2);
        address[] memory micro = new address[](1);
        micro[0] = address(new MicroPaymentPolicy(CAP));
        address[] memory standard = new address[](1);
        standard[0] = address(new StandardPolicy());
        clauses[0] = micro;
        clauses[1] = standard;
        set = new PolicySet(clauses);
    }

    function _intent(address payee, uint256 amount, bool payeeAllowed)
        internal pure returns (SpendContext memory c)
    {
        c = SpendContext({
            agent: address(0xA6E17),
            payee: payee,
            token: USDC,
            amount: amount,
            tokenAllowed: true,
            payeeAllowed: payeeAllowed,
            txLimit: 500e6,
            periodLimit: PERIOD_LIMIT,
            spentSoFar: SPENT,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    /// Over the micro cap, so clause 1 fails; allow-listed, so clause 2 carries it.
    function test_retainer_passes_through_the_standard_clause() public view {
        assertEq(set.check(_intent(BEEF, 5e6, true)), Reason.OK);
    }

    /// Over the cap AND not allow-listed. The reported reason must be 6, because that is
    /// what the demo page's widen button keys on — reporting clause 1's 7 would leave the
    /// button disabled and the face-scan beat dead.
    function test_newvendor_is_blocked_with_exactly_reason_6() public view {
        assertEq(set.check(_intent(CAFE, 5e6, false)), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The whole argument for OR: same unknown payee situation, allowed because it is small.
    function test_apitopup_passes_through_the_micro_clause_with_no_human() public view {
        assertEq(set.check(_intent(FOOD, 5e5, false)), Reason.OK);
    }

    /// Two payments to strangers, one refused and one allowed, and the only difference is
    /// the size. If this ever stops holding, the demo has lost its point.
    function test_the_only_difference_between_the_two_strangers_is_the_amount() public view {
        SpendContext memory big = _intent(CAFE, 5e6, false);
        SpendContext memory small = _intent(CAFE, 5e5, false); // same payee, smaller
        assertEq(set.check(big), Reason.PAYEE_NOT_ALLOWED);
        assertEq(set.check(small), Reason.OK);
    }

    /// The exception must not be able to swallow the rule.
    function test_a_micro_payment_over_the_period_budget_is_still_refused() public view {
        SpendContext memory c = _intent(FOOD, 5e5, false);
        c.spentSoFar = PERIOD_LIMIT; // nothing left
        // clause 1 fails on the budget, clause 2 fails on the payee — last clause reported
        assertEq(set.check(c), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The account gives this call 200,000 gas and treats anything else as reason 12. Two
    /// members plus the loop must fit, with room to spare.
    function test_it_fits_inside_the_account_s_gas_cap() public view {
        SpendContext memory c = _intent(CAFE, 5e6, false);
        uint256 before = gasleft();
        set.check(c);
        uint256 used = before - gasleft();
        emit log_named_uint("PolicySet.check gas (worst case: both clauses evaluated)", used);
        assertLt(used, POLICY_GAS, "over the account's cap");
        assertLt(used, POLICY_GAS / 2, "less than half the cap, so there is headroom");
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract PolicySetDemoTest`
Expected: FAIL at compile if Tasks 1-2 are not committed; otherwise all six run. If `test_it_fits_inside_the_account_s_gas_cap` fails, **stop and report the measured number** — the plan's `MEMBER_GAS = 60_000` may need lowering, and that is a finding for the controller, not something to adjust silently.

- [ ] **Step 3: Run the whole suite**

Run: `cd /home/ubuntu/DEV/leash && forge test`
Expected: PASS — 201 tests before this plan, plus 12 (Task 1) + 15 (Task 2) + 6 (Task 3) = **234 passing, 0 failed, 1 skipped**. Report the actual numbers; do not adjust a test to reach them.

- [ ] **Step 4: Add the third intent**

Edit `agent/intents.json` to exactly this, appending the third entry and leaving the first two untouched:

```json
[
  {
    "id": "retainer",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x000000000000000000000000000000000000beef",
    "amount": "5000000",
    "note": "monthly retainer, already allow-listed"
  },
  {
    "id": "newvendor",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x00000000000000000000000000000000000cafe0",
    "amount": "5000000",
    "note": "a vendor the policy has never seen"
  },
  {
    "id": "apitopup",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x000000000000000000000000000000000000f00d",
    "amount": "500000",
    "note": "50 cents, under the micro cap"
  }
]
```

The payee is `0x` plus exactly 40 hex digits — 36 zeros then `f00d`. `validateIntents` refuses to start on a malformed address, and its error names the field rather than the character count, so a miscount here reads as a confusing startup failure rather than an obvious typo. Step 5 checks it before anything else runs.

- [ ] **Step 5: Verify the agent accepts it**

```bash
cd /home/ubuntu/DEV/leash/agent
node --input-type=module -e '
import { validateIntents } from "./loop.mjs";
import { readFile } from "node:fs/promises";
const intents = JSON.parse(await readFile("./intents.json", "utf8"));
const errors = validateIntents(intents);
console.log(errors.length ? errors : `ok — ${intents.length} intents`);
'
node --test
```

Expected: `ok — 3 intents`, then 78 passing.

**Do not start `agent/loop.mjs`.** It has no read-only mode: a tick reads, decides and SENDS, and it would pay the retainer. That has already cost 5 test USDC twice on this project.

- [ ] **Step 6: Commit**

```bash
cd /home/ubuntu/DEV/leash
git add test/PolicySetDemo.t.sol agent/intents.json
git commit -m "test: pin the demo composition, and add the intent that only OR allows"
```

---

## Self-Review

**1. Spec coverage.**

| Spec requirement | Task |
|---|---|
| DNF: AND in a clause, OR between | 2 (`test_a_clause_of_two_passes_only_when_both_pass`, `test_a_later_clause_rescues_an_earlier_failure`) |
| `check` declared `view` | 1, 2 (both signatures) |
| Members reached by `staticcall` | 2 (`test_a_member_that_writes_storage_cannot_be_a_member`) |
| Member list fixed at construction, no setter | 2 (contract has no setter; `test_the_shape_is_readable` reads it) |
| Any member anomaly → 12, no fall-through | 2 (five tests: revert, wrong length, 256, no code, gas burn) |
| Last clause's reason when nothing passes | 2 (`test_when_nothing_passes_the_last_clauses_reason_is_reported`, both orders) |
| First failing member within a clause | 2 (`test_a_clause_reports_its_first_failing_member`) |
| Constructor refuses empty set / empty clause / zero member | 2 (three tests) |
| `MicroPaymentPolicy`: cap, token, budget; payee ignored | 1 (all of it) |
| `CAP` immutable, no setter, zero refused | 1 |
| Gas fits under `POLICY_GAS` | 3 (`test_it_fits_inside_the_account_s_gas_cap`) |
| The three demo intents produce ✅ / 6 / ✅ | 3 |
| Reason-code tests assert the exact number | every one of them uses `assertEq` against a `Reason.` constant |

**2. Placeholder scan.** No "TBD", no "add validation", no "similar to Task N". Every step carries the code it needs. Every address in this plan was checked to be `0x` plus exactly 40 hex digits — an earlier draft of Task 3 carried a malformed one with a warning attached, which an implementer would have copied verbatim.

**3. Type consistency.** `PolicySet(address[][] memory clauses)` in Task 2 is constructed the same way in Task 3. `MicroPaymentPolicy(uint256 cap_)` with `CAP()` in Task 1 is read as `CAP` in Task 3's `setUp`. `Reason.PAYEE_NOT_ALLOWED` / `OVER_TX_LIMIT` / `OVER_PERIOD_LIMIT` / `TOKEN_NOT_ALLOWED` / `POLICY_FAILED` / `OK` are the names in `src/Reason.sol`. `MEMBER_GAS` is referenced only inside `PolicySet`; Task 3 refers to the account's `POLICY_GAS` as its own local constant rather than importing `LeashAccount`.

**4. Not in this plan, deliberately.** Deploying the two contracts, approving `PolicySet` and repointing ENS are onchain actions needing the ADMIN and WALLET keys, so they stay with the operator. The recipe and the resulting addresses go into `docs/deployments.md` after the deployment, not before it.
