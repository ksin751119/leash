# Task 3 report: the demo composition, its gas, and the third intent

## What was created / modified

- **Created** `test/PolicySetDemo.t.sol` — the six tests from the brief verbatim, plus one
  extra (`test_member_gas_cap_makes_a_costly_member_fail_closed`), plus a helper mock
  (`GasHogPolicy`) local to the file.
- **Modified** `agent/intents.json` — appended the `apitopup` entry exactly as specified,
  first two entries untouched.
- **Modified** `src/PolicySet.sol` — comment-only change on `MEMBER_GAS` (correction 3).
  `MEMBER_GAS`'s value (60,000) and every line of executable code are untouched.

## Correction 1 applied: `view` dropped

`test_it_fits_inside_the_account_s_gas_cap` is declared `public` (not `public view`) because
its body calls `emit log_named_uint(...)`. `set.check(c)` inside it is still called through
the `view` interface — nothing about what is measured changed. Confirmed this was necessary:
the brief's literal signature does not compile (`emit` in a `view` function is rejected).

## Measured gas figure

```
PolicySet.check gas (worst case: both clauses evaluated): 29506
```

(29,494 with the mutation in place — the log line differs by a few gas units run to run
depending on other in-file changes at compile time, both comfortably clear both assertions.)

Both `assertLt` pass:
- `29506 < 200000` (the account's `POLICY_GAS` cap) — yes, by a wide margin.
- `29506 < 100000` (half the cap) — yes.

This did not require stopping to report a finding — the measured number is well under half
the cap, so `MEMBER_GAS = 60_000` needs no adjustment for this composition.

## Additional scope 1: pinning `MEMBER_GAS`

Added `contract GasHogPolicy` inside `test/PolicySetDemo.t.sol` (not in
`test/mocks/PolicyMocks.sol`, to avoid touching Task 2's own test file): a member whose
`check` runs a 2000-round `keccak256` loop over an accumulator, costing far more than
`MEMBER_GAS` (60,000) but nowhere near a test's own budget. Its return value depends on the
loop's result (`h == bytes32(0) ? POLICY_FAILED : OK`) so the compiler cannot elide the
computation as dead code.

New test: `test_member_gas_cap_makes_a_costly_member_fail_closed` — builds a one-member,
one-clause `PolicySet` around `GasHogPolicy` and asserts `Reason.POLICY_FAILED`.

**Mutation proof, performed and then reverted:**

1. Removed `{ gas: MEMBER_GAS }` from the `staticcall` in `PolicySet._ask`
   (`src/PolicySet.sol:119`).
2. Ran `forge test --match-contract PolicySetDemoTest -vv`. Result:
   `[FAIL: assertion failed: 0 != 12] test_member_gas_cap_makes_a_costly_member_fail_closed()`
   — every other test in the file stayed green, confirming this is the one test that catches
   the mutation.
3. Restored `{ gas: MEMBER_GAS }` exactly as it was. Re-ran the same command: all 7 tests
   pass again (see full-suite output below).

## Additional scope 2: the `MEMBER_GAS` comment

Old comment (incorrect claim):

> Per-member gas ceiling. The account caps this whole call at `LeashAccount.POLICY_GAS`
> (200,000), so a member that runs away must not be able to take the set down with it.

New comment (`src/PolicySet.sol:27-33`):

> Per-member gas ceiling. This does not protect the set from a runaway member — with the
> account's own 200,000-gas budget for the whole call, enough runaway members exhaust it
> regardless, and because `check` returns immediately on 12 the observable result is the
> same either way. What it actually does is set an eligibility ceiling: any member costing
> more than 60,000 gas — including a nested `PolicySet` — becomes `POLICY_FAILED` here even
> though that same policy works correctly as the account's direct policy.

Only the comment changed; `MEMBER_GAS = 60_000` is untouched, as is every line of code in
the file (confirmed via `git diff src/PolicySet.sol` — a comment-only hunk).

## Exact commands and their output

**Step 1-2 — new test file, run in isolation:**
```
$ cd /home/ubuntu/DEV/leash && forge test --match-contract PolicySetDemoTest -vv
Ran 7 tests for test/PolicySetDemo.t.sol:PolicySetDemoTest
[PASS] test_a_micro_payment_over_the_period_budget_is_still_refused() (gas: 30434)
[PASS] test_apitopup_passes_through_the_micro_clause_with_no_human() (gas: 20657)
[PASS] test_it_fits_inside_the_account_s_gas_cap() (gas: 32825)
Logs:
  PolicySet.check gas (worst case: both clauses evaluated): 29506

[PASS] test_member_gas_cap_makes_a_costly_member_fail_closed() (gas: 574688)
[PASS] test_newvendor_is_blocked_with_exactly_reason_6() (gas: 30366)
[PASS] test_retainer_passes_through_the_standard_clause() (gas: 30930)
[PASS] test_the_only_difference_between_the_two_strangers_is_the_amount() (gas: 35785)
Suite result: ok. 7 passed; 0 failed; 0 skipped
```

**Step 3 — full suite:**
```
$ cd /home/ubuntu/DEV/leash && forge test
Ran 16 test suites in 61.20ms: 236 tests passed, 0 failed, 1 skipped (237 total tests)
```
Baseline was 229 passed / 0 failed / 1 skipped / 230 total. 236 = 229 + 7 (six from the
brief plus the `MEMBER_GAS` test). The 1 pre-existing skip is untouched and unrelated to
this work.

**Step 4 — `agent/intents.json`:** edited to the exact JSON in the brief (payee
`0x000000000000000000000000000000000000f00d`, verified programmatically to be `0x` plus
exactly 40 hex digits: `len('000000000000000000000000000000000000f00d') == 40`).

**Step 5 — agent acceptance:**
```
$ cd /home/ubuntu/DEV/leash/agent && node --input-type=module -e '...'
ok — 3 intents

$ node --test
ℹ tests 78
ℹ pass 78
ℹ fail 0
```
Matches the brief's expectation exactly. `agent/loop.mjs` was never started — only
`validateIntents` (a pure function) and the existing `node --test` suite ran; no tick, no
send, no cost.

## Things noticed but not changed

- The gas figure (29,506) leaves roughly 170,000 gas of headroom under `POLICY_GAS`
  (200,000) for this two-clause, two-member composition — comfortably inside the "less than
  half" bar the brief set. No action needed, but noted in case a future clause is added to
  this specific demo set: at ~15,000 gas per `MicroPaymentPolicy`/`StandardPolicy`-shaped
  member, there is room for several more members before the cap becomes a real constraint.
- `GasHogPolicy` was deliberately kept local to `test/PolicySetDemo.t.sol` rather than added
  to `test/mocks/PolicyMocks.sol`, since `test/PolicySet.t.sol` and its mocks belong to
  Task 2's closed, reviewed scope. This avoids touching a file outside Task 3's stated scope
  even though the mock itself is generic enough to belong there.
- Did not lower `MEMBER_GAS` or touch the assertion in
  `test_it_fits_inside_the_account_s_gas_cap` — not needed, since the measured number is
  well within bounds.
