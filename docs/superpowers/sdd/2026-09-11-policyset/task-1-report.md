# Task 1 Report: MicroPaymentPolicy

## What was created

- `src/MicroPaymentPolicy.sol` — `MicroPaymentPolicy` contract implementing `IPolicy`.
  Verbatim from the brief's Step 3 code. `CAP` is an `immutable uint256` with no setter,
  refused if zero at construction (`ZeroCap` custom error). `check` is `view` (not `pure`,
  since it reads `CAP`): checks `tokenAllowed` first, then the tx cap (`OVER_TX_LIMIT`),
  then the period budget (`OVER_PERIOD_LIMIT`, guarded against underflow by checking
  `spentSoFar >= periodLimit` first). `payeeAllowed` is never read. `describe()` returns
  `"MicroPaymentPolicy/1: per-tx cap and period budget, payee allow-list ignored"`.
  Comments state its role as the exception half of `StandardPolicy`, meant to be composed
  in Task 2 as `(this) OR (StandardPolicy)`.
- `test/MicroPaymentPolicy.t.sol` — the 12 tests from the brief's Step 1, verbatim.

No other files touched. `LeashAccount`, `LeashRegistry`, `LeashResolver`,
`PolicyApprovals`, `StandardPolicy`, `Reason.sol` are untouched.

## Test commands and output

**Step 2 — tests written before the contract exists:**

```
cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest
```

```
Compiler run failed:
Error (6275): Source "src/MicroPaymentPolicy.sol" not found: File not found. Searched the following locations: "/home/ubuntu/DEV/leash".
ParserError: Source "src/MicroPaymentPolicy.sol" not found: File not found. Searched the following locations: "/home/ubuntu/DEV/leash".
 --> test/MicroPaymentPolicy.t.sol:5:1:
Error: Compilation failed
```

Confirmed: fails to compile, exactly as expected.

**Step 4 — after writing the contract:**

```
cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest -v
```

```
Ran 12 tests for test/MicroPaymentPolicy.t.sol:MicroPaymentPolicyTest
[PASS] test_a_micro_payment_that_would_exceed_the_period_budget_is_refused() (gas: 7178)
[PASS] test_a_token_nobody_allowed_is_refused_however_small() (gas: 6916)
[PASS] test_a_zero_cap_is_refused_at_construction() (gas: 35627)
[PASS] test_a_zero_period_limit_means_unlimited() (gas: 6947)
[PASS] test_allows_a_small_payment_to_a_payee_nobody_allow_listed() (gas: 7098)
[PASS] test_allows_exactly_the_cap() (gas: 7086)
[PASS] test_already_at_the_period_limit_is_refused_without_underflowing() (gas: 6965)
[PASS] test_one_unit_over_the_cap_is_over_tx_limit() (gas: 6960)
[PASS] test_spending_exactly_the_remaining_budget_is_allowed() (gas: 7199)
[PASS] test_the_cap_is_readable_and_has_no_setter() (gas: 5483)
[PASS] test_the_cap_outranks_the_budget_when_both_are_violated() (gas: 6987)
[PASS] test_the_payee_allow_list_is_ignored_in_both_directions() (gas: 8877)
Suite result: ok. 12 passed; 0 failed; 0 skipped
```

## Step 5 — mutation test (before/after)

Deleted the whole `if (ctx.periodLimit != 0) { ... }` block from `check` (leaving only the
`tokenAllowed` check, the `CAP` check, and the final `return Reason.OK`), then ran:

```
cd /home/ubuntu/DEV/leash && forge test --match-contract MicroPaymentPolicyTest
```

**With the block deleted (RED):**

```
Ran 12 tests for test/MicroPaymentPolicy.t.sol:MicroPaymentPolicyTest
[FAIL: assertion failed: 0 != 8] test_a_micro_payment_that_would_exceed_the_period_budget_is_refused() (gas: 9834)
[PASS] test_a_token_nobody_allowed_is_refused_however_small() (gas: 6916)
[PASS] test_a_zero_cap_is_refused_at_construction() (gas: 35603)
[PASS] test_a_zero_period_limit_means_unlimited() (gas: 6918)
[PASS] test_allows_a_small_payment_to_a_payee_nobody_allow_listed() (gas: 6904)
[PASS] test_allows_exactly_the_cap() (gas: 6892)
[FAIL: assertion failed: 0 != 8] test_already_at_the_period_limit_is_refused_without_underflowing() (gas: 9746)
[PASS] test_one_unit_over_the_cap_is_over_tx_limit() (gas: 6960)
[PASS] test_spending_exactly_the_remaining_budget_is_allowed() (gas: 7005)
[PASS] test_the_cap_is_readable_and_has_no_setter() (gas: 5483)
[PASS] test_the_cap_outranks_the_budget_when_both_are_violated() (gas: 6987)
[PASS] test_the_payee_allow_list_is_ignored_in_both_directions() (gas: 8489)
Suite result: FAILED. 10 passed; 2 failed; 0 skipped
```

Exactly the two named tests failed (`0 != 8`, i.e. `Reason.OK` returned instead of
`Reason.OVER_PERIOD_LIMIT`). `test_the_cap_outranks_the_budget_when_both_are_violated`
stayed green as predicted, because the cap check fires first regardless of the budget
block.

Restored the block (`Edit` reverting the deletion, textually identical to Step 3's
original), then ran the same command again:

**After restoring (GREEN):**

```
Ran 12 tests for test/MicroPaymentPolicy.t.sol:MicroPaymentPolicyTest
Suite result: ok. 12 passed; 0 failed; 0 skipped
```

(Full per-test PASS list identical to the Step 4 output above.)

Full suite afterward:

```
cd /home/ubuntu/DEV/leash && forge test
Ran 14 test suites in 63.20ms: 213 tests passed, 0 failed, 1 skipped (214 total tests)
```

201 baseline + 12 new = 213. Matches expectations. File left restored, suite green.

## Anything I was unsure about

Nothing substantive. The brief's code, test values, and interface all matched
`src/IPolicy.sol` and `src/Reason.sol` exactly as they exist in the repo, so this was a
verbatim transcription plus the required verification steps — no judgment calls needed.

## Anything noticed but not changed

- `StandardPolicy.check` is `pure`; the interface's doc comment explicitly calls out that
  implementations may tighten mutability, so `MicroPaymentPolicy` being `view` instead of
  `pure` (because it reads the `CAP` immutable) is consistent, not an inconsistency worth
  flagging further.
- Did not touch `PolicySet` — Task 2's job, per the brief. `MicroPaymentPolicy`'s own
  comments describe the intended `(this) OR (StandardPolicy)` composition but the contract
  itself has no dependency on it.

## Fix round 1: the underflow test does not test underflow

Review finding: `test_already_at_the_period_limit_is_refused_without_underflowing` set
`spentSoFar == periodLimit` (50e6 == 50e6), so `periodLimit - spentSoFar` is `0` and never
underflows regardless of the guard. Deleting only the
`if (ctx.spentSoFar >= ctx.periodLimit) return Reason.OVER_PERIOD_LIMIT;` line left all 12
tests green — the test named after the guard was blind to its removal.

**Fix:** renamed the boundary test to `test_already_at_the_period_limit_is_refused` (kept,
still asserts `spentSoFar == periodLimit` refuses cleanly) and added a new test,
`test_over_the_period_limit_is_refused_without_underflowing`, with `spentSoFar = periodLimit
+ 1` — the shape that actually underflows if the guard is removed, and the shape
`LeashAccount.tightenRule` can produce by lowering a period limit below what has already
been spent this period.

**Proof — command:** `cd /home/ubuntu/DEV/leash && forge test --match-contract
MicroPaymentPolicyTest`

**With only the guard line deleted (subtraction kept) — RED:**

```
[PASS] test_a_micro_payment_that_would_exceed_the_period_budget_is_refused() (gas: 7093)
[PASS] test_a_token_nobody_allowed_is_refused_however_small() (gas: 6894)
[PASS] test_a_zero_cap_is_refused_at_construction() (gas: 35628)
[PASS] test_a_zero_period_limit_means_unlimited() (gas: 7013)
[PASS] test_allows_a_small_payment_to_a_payee_nobody_allow_listed() (gas: 7058)
[PASS] test_allows_exactly_the_cap() (gas: 7068)
[PASS] test_already_at_the_period_limit_is_refused() (gas: 7115)
[PASS] test_one_unit_over_the_cap_is_over_tx_limit() (gas: 6961)
[FAIL: panic: arithmetic underflow or overflow (0x11)] test_over_the_period_limit_is_refused_without_underflowing() (gas: 6782)
[PASS] test_spending_exactly_the_remaining_budget_is_allowed() (gas: 7092)
[PASS] test_the_cap_is_readable_and_has_no_setter() (gas: 5549)
[PASS] test_the_cap_outranks_the_budget_when_both_are_violated() (gas: 7053)
[PASS] test_the_payee_allow_list_is_ignored_in_both_directions() (gas: 8795)
Suite result: FAILED. 12 passed; 1 failed; 0 skipped
```

The new test panics (underflow) rather than merely asserting false — confirms the guard is
load-bearing and the equal-to test alone does not detect its removal.

**After restoring the guard line — GREEN:**

```
Ran 13 tests for test/MicroPaymentPolicy.t.sol:MicroPaymentPolicyTest
Suite result: ok. 13 passed; 0 failed; 0 skipped
```

Full suite afterward: `forge test` → 14 suites, 214 passed, 0 failed, 1 skipped (213
baseline + 1 new test). File restored, suite green.
