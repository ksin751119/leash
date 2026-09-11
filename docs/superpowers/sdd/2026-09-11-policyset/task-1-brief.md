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

