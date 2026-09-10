# Task 2 report: `decide()` — the pure pre-flight

## Status: complete

Commit: `dbd8bdb` — "feat: the agent's pre-flight decision, as a pure function"

Created only `agent/decide.mjs` and `agent/decide.test.mjs`, exactly as specified in
`task-2-brief.md` (verbatim code and tests, no adjustments to field names, no new
dependencies). `agent/reason.mjs` matched the expected interface (`REASON`, `reasonName`,
`REASON_NAMES`, `buildNames`) and was not touched. Nothing under `src/`, `test/`, `script/`,
`subgraph/`, or `world/` was touched. `SEPOLIA_RPC`, `AGENT_PK`, `WALLET_PK`,
`WORLD_RP_SIGNER_PK`, and `/home/ubuntu/DEV/ETHOnline2026/.env` were never read.

No subagents were dispatched.

## Test run

```
cd agent && node --test decide.test.mjs
```

Result: `tests 16, pass 16, fail 0, cancelled 0, skipped 0, todo 0`

## Mutation testing (Step 5)

For each mutation: applied to `agent/decide.mjs`, ran `node --test decide.test.mjs`, recorded
the failing test and message, then restored the file from a saved pristine copy and confirmed
the md5 hash matched the pre-mutation hash (`2b719540da7c339a5017f929f67f14d8`) each time.

**Mutation 1 — drop the `rolledOver` handling (always `BigInt(budget.spent)`)**
Went RED: `a rolled-over period frees the whole limit again`
```
AssertionError [ERR_ASSERTION]: spent must be treated as 0 once the period has reset
+ actual - expected
+ 'will-be-blocked'
- 'will-pass'
```
Reverted; hash matched.

**Mutation 2 — change `periodEnd > 0 && periodEnd <= nowSec` to `periodEnd <= nowSec`**
Went RED: `periodEnd 0 means a lifetime budget and never rolls over`
```
AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
null !== 8
```
(`8` is `REASON.OVER_PERIOD_LIMIT`; the mutated code returned `will-pass`/`reason: null`
instead, because `periodEnd 0 <= nowSec` is always true, incorrectly treating a lifetime
budget as perpetually rolled over.)
Reverted; hash matched.

**Mutation 3 — move the payee check above the `agent.revoked` check**
Went RED: `the account layer is checked before the policy layer, as the contract does`
```
AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
6 !== 2
```
(`6` is `REASON.PAYEE_NOT_ALLOWED`, reported instead of the expected `2`
`REASON.AGENT_REVOKED`, confirming the account layer must be checked first.)
Reverted; hash matched.

All three named tests went red exactly as the mutation table predicted; no surprises, no
mismatch between the mutation table and the tests.

## forge test

Ran once at the end, after the commit was in place:

```
Ran 13 test suites in 73.84ms (249.38ms CPU time): 201 tests passed, 0 failed, 1 skipped (202 total tests)
```

Matches the required 201 passed / 1 skipped / 0 failed.

## Concerns

None. The implementation matched the brief verbatim; the only judgment calls were in how to
apply/revert the three mutations (Python in-place string replacement plus a saved pristine
copy compared by md5), which is scaffolding only and never touched the committed file.
