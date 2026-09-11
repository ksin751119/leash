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

