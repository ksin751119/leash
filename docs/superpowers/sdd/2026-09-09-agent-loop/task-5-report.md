# Task 5 report — the loop and endpoint (Steps 1-8)

## Status
Steps 1-8 complete, committed. Step 9 (live run) NOT performed — out of scope for this
agent per the delegation.

## Commit
`5487398` — "feat: the agent loop, its state endpoint, and the guards that matter"
4 files changed, 311 insertions(+): `agent/README.md`, `agent/intents.json`,
`agent/loop.mjs`, `agent/loop.test.mjs`. Working tree clean afterward; no other files
touched. `git log` shows it on top of `d46b460` (Task 4's commit).

## Deviation from the brief, found and fixed
The brief's literal `loop.mjs` (Step 4) has no entrypoint guard around the env-var check,
`intents.json` load, and `createServer().listen()` — they run at module load time
unconditionally. Copying it verbatim, `node --test loop.test.mjs` failed immediately with
`AGENT_PK is not set` and `process.exit(1)`, before any test ran — confirmed empirically
before I touched anything. I wrapped that entire IO section in
`const isMain = import.meta.url === \`file://${process.argv[1]}\`; if (isMain) { ... }`,
the standard ESM "am I the entrypoint" check. `advance` and `initialState` are unaffected;
`intents` stays `[]` on import (tests pass their own intents array to `advance` directly, so
this doesn't matter for testing). This is the only place my `loop.mjs` differs from the
brief's listing.

## Step 6 — combined result
```
ℹ tests 48
ℹ pass 48
ℹ fail 0
```
Per-file: reason 4, decide 16, subgraph 12, send 9, loop 7 → **48 total across five files**,
not the 42 the plan states nor the 44 arithmetic in the delegation message (4+16+12+9+7=48
by my own addition — the delegation's "44" appears to be a slip, not a different measured
count). `check-reason-table.mjs` reports `all 13 codes agree`. `forge test` (repo root):
`201 passed; 1 skipped; 0 failed` — unchanged from before this task.

## Step 7 — mutation results

**Mutation A: removed `else if (prev.inFlight)` branch.**
```
✔ an eligible intent is queued to send
✖ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
tests 7, pass 6, fail 1
```
Exactly the named test went red, nothing else. Reverted; full suite back to 7/7 green
before mutation B.

**Mutation B: removed `if (prev.lastAction?.outcome === "executed")` branch.**
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✖ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
tests 7, pass 6, fail 1
```
Exactly the named test went red, nothing else. Reverted; confirmed byte-identical to the
pre-mutation file (`diff` empty), full suite 48/48 green, reason table 13/13, `forge test`
201/1/0 re-verified after restore.

## Test non-vacuity
Went through all 7 named tests in `agent/loop.test.mjs` asking whether a plausible wrong
implementation would still pass:

1. **"an eligible intent is queued to send"** — fails under any impl that never pushes to
   `toSend` or filters by the wrong verdict string. Non-vacuous.
2. **"an in-flight intent is not queued again"** — mutation-tested above (Mutation A).
   Non-vacuous, confirmed empirically.
3. **"an executed intent is terminal and never sent again"** — mutation-tested above
   (Mutation B). Non-vacuous, confirmed empirically.
4. **"a blocked intent stays eligible, so the agent retries after a widening"** — catches a
   plausible bug where terminality is keyed on `lastAction?.kind === "sent"` instead of
   `outcome === "executed"` (that wrong version would treat a blocked send as terminal too,
   and this test's `toSend` assertion would go red). Non-vacuous.
5. **"a failed read sends nothing and says so"** — catches a bug where `advance` doesn't
   route a failed read into `decide()`'s `unknown-read-failed` verdict, or hardcodes a
   different string. Non-vacuous.
6. **"a predicted block is not sent"** — catches a bug where `rec.reason` isn't wired from
   `d.reason`, or where `toSend` doesn't gate on `verdict === "will-pass"`. Non-vacuous.
7. **"the tick counter and the source block land in the state"** — non-vacuous for the tick
   counter (catches a missing/wrong increment) and for `lagBlocks` (catches a missing
   `source` object entirely). **Gap:** it does NOT assert `state.source.chainBlock`
   anywhere, and no other test in the file does either. `okSnap()` sets both
   `block.subgraph` and `block.chain` to `1`, so a bug that swapped the `subgraphBlock` and
   `chainBlock` field assignments in `advance` (i.e. `subgraphBlock: snapshot.block.chain,
   chainBlock: snapshot.block.subgraph`) would NOT be caught by this suite, because both
   values are equal in the fixture. I did not add a test for this since Step 2's test list
   is prescribed verbatim in the brief and I was not asked to add tests beyond it — flagging
   it here rather than silently leaving the gap unreported.

## Concerns
- The `chainBlock`-swap blind spot above (item 7) is the one real coverage gap I found.
- No other concerns. `forge test` unchanged, no files outside the four created/committed
  were touched, no env vars were read, no network calls were made.

## Confirmation
Step 9 was NOT performed. No Sepolia transaction was sent, no RPC call was made, `.env` at
`/home/ubuntu/DEV/ETHOnline2026/.env` was never opened, and `AGENT_PK` / `SEPOLIA_RPC` /
`WALLET_PK` / `WORLD_RP_SIGNER_PK` were never read.

## Fix round 1

Commit: `5a7df5a` — "test: close the chainBlock swap gap in the tick/source test, sync the
plan" — 2 files changed (`agent/loop.test.mjs`, `docs/superpowers/plans/2026-09-09-agent-loop.md`).

**Test strengthened.** `okSnap()`'s `block` fixture changed from `{ subgraph: 1, chain: 1,
lag: 0 }` to `{ subgraph: 11667861, chain: 11667863, lag: 2 }` (all distinct). Test 7 now
also asserts `state.source.chainBlock === 11667863` alongside `subgraphBlock` and
`lagBlocks`.

**Swap mutation.** In `advance()`, swapped the assignment to
`{ subgraphBlock: snapshot.block.chain, chainBlock: snapshot.block.subgraph, lagBlocks: snapshot.block.lag }`:
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✖ the tick counter and the source block land in the state
tests 7, pass 6, fail 1
```
Exactly the strengthened test went red, nothing else. Reverted; `diff` against the
pre-mutation backup was empty; full suite back to 48/48, reason table 13/13, `forge test`
201/1/0 re-confirmed after restore.

**Plan doc synced** (`docs/superpowers/plans/2026-09-09-agent-loop.md`, Task 5): Step 2's
`okSnap`/test-7 listing updated to match the strengthened test; Step 4's `loop.mjs` listing
now includes the `isMain` guard with the same comment as the shipped code; Step 6's count
corrected from 42 to 48.

No files outside `agent/` and the one plan file were touched. No env vars read, no network
calls, `.env` never opened, Step 9 still not run.

## Fix round 2 — the receipt-timeout duplicate-payment path

Commit: `a339335` — "fix: preserve the tx hash on a timed-out send, and stop the second
duplicate-payment path" — 5 files changed (`agent/loop.mjs`, `agent/send.mjs`,
`agent/loop.test.mjs`, `agent/README.md`, `docs/superpowers/plans/2026-09-09-agent-loop.md`).

**`send.mjs`**: `tx` is now declared outside the `try` and the catch returns
`{ tx, error }` when a hash was obtained, `{ error }` otherwise.

**`loop.mjs`**: `advance()` gained a branch — `lastAction.kind === "sent" && lastAction.tx &&
lastAction.outcome == null` — that assigns verdict `"unconfirmed"` and does not queue the
intent; the hash stays visible via `lastAction.tx` (spread from `prev`) and in `explain`. The
per-intent send was extracted out of `tick()` into an exported `sendAndRecord(rec, intent,
cfg, sendImpl = sendSpend)`, which clears `inFlight` in a `finally` and takes an injectable
`sendImpl` so the finally is testable without a chain. `tick()` now calls it directly.

**`agent/README.md`**: "Two things" → "Three things that surprise people", new bullet on the
`unconfirmed` verdict.

**Plan doc**: Task 4's `sendSpend` listing and Task 5's `advance`, the new `sendAndRecord`,
the three new tests, the README bullet, and Step 5/6 counts (7→10, 48→51) all synced.

Combined test result: **51 tests / 51 pass / 0 fail** (48 + 3 new: the timeout test, its
pre-send-failure counterpart, and the finally test). `check-reason-table.mjs`: all 13 codes
agree. `forge test`: 201 passed, 1 skipped, 0 failed — unchanged.

**Mutation 1 — removed the `unconfirmed` branch entirely** (reproduces the exact
duplicate-payment bug the review found):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✖ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✔ a pre-send failure with no hash stays eligible, since nothing was sent
✔ inFlight is cleared even when the send throws, via a finally
tests 10, pass 9, fail 1
```
Exactly the named test went red. Reverted.

**Mutation 2 — broadened the `unconfirmed` condition to drop the `kind === "sent"`
requirement** (tests the over-correction risk: would a genuine pre-send failure wrongly stop
being retried?):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✔ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✖ a pre-send failure with no hash stays eligible, since nothing was sent
✔ inFlight is cleared even when the send throws, via a finally
tests 10, pass 9, fail 1
```
Exactly the counterpart test went red. Reverted.

**Mutation 3 — moved `inFlight = false` out of the `finally`** (into the end of the `try`,
with a bare rethrow in `catch` to keep the throw propagating):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✔ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✔ a pre-send failure with no hash stays eligible, since nothing was sent
✖ inFlight is cleared even when the send throws, via a finally
tests 10, pass 9, fail 1
```
Exactly the finally test went red. Reverted; `diff` against the pre-mutation backup was
empty after each of the three reverts; full suite re-confirmed 51/51 and `forge test`
201/1/0 after all three.

No files outside `agent/` and the one plan file were touched. No env vars read, no network
calls, `.env` never opened, Step 9 still not run.

## Final review fix wave (C1 + I2/I3/I4/I5/I6/I7 + T4 Minor 2)

Commit: `1ae319b` — "fix: refuse a malformed intents.json or env value at load, contain a
bad amount per-intent, and stop silently guessing" — 10 files: `agent/README.md`,
`agent/decide.mjs`, `agent/decide.test.mjs`, `agent/loop.mjs`, `agent/loop.test.mjs`,
`agent/send.mjs`, `agent/subgraph.mjs`, `agent/subgraph.test.mjs`,
`docs/superpowers/plans/2026-09-09-agent-loop.md`,
`docs/superpowers/specs/2026-09-09-agent-loop-design.md`.

**C1** — `validateIntents` (exported, pure) refuses a duplicate id, a non-`/^[0-9]+$/`
amount, or a token/payee that isn't a 20-byte hex address, called at load before the server
starts. `advance()`'s `toSend` is also deduped by id as a second line of defense.

**I2** — `advance()` now wraps the per-intent `decide()` call in try/catch, turning a thrown
`BigInt(intent.amount)` into an `"invalid"` verdict for that intent only, so the rest of the
tick's intents are still evaluated (a single try/catch around the whole tick body would have
aborted them too). `tick()` and the `POST` handler each also gained a backstop try/catch
recording `tickError`, for anything that isn't a `decide()` throw. This is a refinement
beyond the literal "wrap tick's body" instruction — noted below.

**I7** — `validateEnvVar` (exported, pure) trims and checks shape for
`WALLET_ADDR`/`AGENT_ADDR` (20-byte hex) and `LEASH_NODE` (32-byte hex), refusing to start by
name if a value is missing or still malformed after trimming. `tick()` now reads the
validated/trimmed module-level values, not `process.env` directly.

**I5** — `decide.mjs`'s `pass()` now returns a real `explain` naming what pre-flight cannot
see, instead of `null`.

**I3** — `subgraph.mjs`'s query and snapshot now include `AgentBudget.remaining` (published
alongside `decide()`'s own computation, which still handles the rollover case) and
`Agent.node`.

**I6** — `Access-Control-Allow-Origin: *` on every response, `OPTIONS` gets a 204, and
routing matches on `new URL(req.url, "http://x").pathname` so a cache-busting query string
no longer 404s.

**T4 Minor 2** — `send.mjs`'s catch now also surfaces `err.cause`, `err.details` and
`err.metaMessages` alongside `shortMessage`, mirroring `subgraph.mjs`'s approach.

**I4** — corrected the "`unknown` → send and let the chain answer" claim in
`agent/README.md`, the spec, and the plan's self-review "known gap, deliberate" note:
`advance()` has only ever pushed to `toSend` on the literal verdict `will-pass`; `unknown`
was never sent. Also corrected the spec's related claim that the five unindexed reasons
produce `unknown` — they produce `will-pass` (I5), unless something else blocks.

**Spec reconciliation (I3's code-vs-spec question — my decision):** amended the spec's `GET
/api/agent/state` JSON example rather than the code. `agent` and `subname` are genuinely
separate subgraph entities (the spec's own prose says so, right above the JSON block it then
contradicted), so I kept them as separate top-level keys in the code and fixed the spec's
example to match, adding `node` to the `agent` object. I also documented the full verdict
list reaching the wire, split into pre-flight's own four-valued prediction (`will-pass`,
`will-be-blocked`, `unknown`, `unknown-read-failed`) and three lifecycle values `advance()`
layers on top (`in-flight`, `unconfirmed`, `done`) plus the new `invalid` (I2). Reasoning:
merging `agent`/`subname` into one object would require synthesizing a combined shape from
two independent GraphQL entities for no real benefit, and the lifecycle verdicts are useful,
demo-relevant information — removing them from the wire to match a three-valued spec would
be a regression, not a fix.

**One deliberate, disclosed deviation from the dispatch's literal wording:** the dispatch
said the I7 tests should cover "a quoted and a CR-suffixed value are rejected." I implemented
trim-then-validate (as the fix description says: "trim() everything, and validate shape"),
under which a CR-suffixed but otherwise valid address is *healed* by the trim and correctly
*accepted*, not rejected — rejecting it would mean not actually trimming. Only a value that
is still malformed after trimming (surrounding literal quote characters) is refused. My tests
reflect this actual behavior: one test for the quoted case (rejected) and one for the
CR-suffixed case (trimmed and accepted). Flagging this for you to overrule if a different
outcome was intended — happy to change to strict rejection instead of healing if so.

### Test result

**64 tests / 64 pass / 0 fail** across five files — reason 4, decide 17 (+1, I5), subgraph 14
(+2, I3), send 9 (unchanged — the `sendSpend` test gap is explicitly out of scope), loop 20
(+10: 2 for C1's dedupe/duplicate-id, 2 for I2's malformed-amount containment plus the `""`
case, 4 for `validateIntents`, 4 for `validateEnvVar`/I7). `check-reason-table.mjs`: all 13
codes agree. `forge test`: 201 passed, 1 skipped, 0 failed — unchanged.

### Mutation outputs

**C1 — removed the `!queued.has(intent.id)` dedupe guard** (leaving only `queued.add`, so a
duplicate id could be pushed twice):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✔ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✔ a pre-send failure with no hash stays eligible, since nothing was sent
✔ inFlight is cleared even when the send throws, via a finally
✖ a duplicate intent id is never queued twice, even if one slipped past validateIntents
✔ a malformed amount does not crash advance, and the error reaches that intent's state
✔ an empty-string amount is rejected at load, not silently treated as zero
✔ validateIntents rejects a duplicate id
✔ validateIntents rejects a malformed token or payee address
✔ validateIntents accepts a well-formed, unique list
✔ a quoted address value is rejected, not silently accepted
✔ a trailing CR is trimmed away, so a value that would otherwise be silently wrong is healed and accepted
✔ a missing value is rejected by name
✔ a wrong-length hash is rejected
tests 20, pass 19, fail 1
```
Exactly the named test went red. Reverted; `diff` against the pre-mutation backup was empty.

**I7 — disabled the shape check in `validateEnvVar`** (`if (false && pattern && ...)`,
leaving only the presence check):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✔ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✔ a pre-send failure with no hash stays eligible, since nothing was sent
✔ inFlight is cleared even when the send throws, via a finally
✔ a duplicate intent id is never queued twice, even if one slipped past validateIntents
✔ a malformed amount does not crash advance, and the error reaches that intent's state
✔ an empty-string amount is rejected at load, not silently treated as zero
✔ validateIntents rejects a duplicate id
✔ validateIntents rejects a malformed token or payee address
✔ validateIntents accepts a well-formed, unique list
✖ a quoted address value is rejected, not silently accepted
✔ a trailing CR is trimmed away, so a value that would otherwise be silently wrong is healed and accepted
✔ a missing value is rejected by name
✖ a wrong-length hash is rejected
tests 20, pass 18, fail 2
```
Both shape-dependent tests went red (expected — disabling the shape check entirely removes
both address-shape and hash-length enforcement), the other 18 stayed green. Reverted; `diff`
against the pre-mutation backup was empty; full suite re-confirmed 64/64, reason table
13/13, and `forge test` 201/1/0 after both restores.

No files outside `agent/` and the two named doc files were touched. No env vars read, no
network calls, `.env` never opened, no subagents dispatched, Step 9 still not run, no push.
`intents.json` verified to pass `validateIntents` with zero errors.

## Re-review fix wave (id validation, GET // crash, SEPOLIA_RPC shape)

Commit: `c6ff974` — "fix: reject a non-string or __proto__ intent id, and stop GET // from
killing the process" — 3 files: `agent/loop.mjs`, `agent/loop.test.mjs`,
`docs/superpowers/plans/2026-09-09-agent-loop.md`.

**1. Non-string / `__proto__` intent id.** `validateIntents` now requires `typeof id ===
"string"` and rejects `id === "__proto__"` by name. **Decision on `Object.create(null)`:
did it, belt-and-braces.** `initialState()`'s `intents` is now `Object.create(null)`, and
`advance()` rebuilds it each tick with `Object.assign(Object.create(null), state.intents)`
instead of `{ ...state.intents }` (plain spread would silently reintroduce
`Object.prototype` on the very next tick). Reasoning: `validateIntents` closes the vector
for the one real entry point (`intents.json` at startup), but `advance()` is a separately
tested pure function with its own call sites in tests, and this project's whole review
history has been "a single validation point is a gap waiting for a second caller" — the
null-prototype store makes the property true by construction, not by trusting the one
caller upstream of it. Cost was two one-line changes.

**2. `GET //` (and `/\`) crash.** Extracted the pathname computation into an exported pure
`routePath(url)` — `url.split("?")[0].replace(/^\/+/, "/")` — which cannot throw for any
string input, replacing `new URL(req.url, "http://x").pathname`. This also makes
`//api/agent/state` resolve (collapses the leading double slash) instead of 404ing, per your
note about the `base + "/path"` join. The whole request-handler body is now also wrapped in
a backstop `try/catch` returning 500, in case anything else in that async callback throws in
the future — `node:http` doesn't await it, so an escaped throw there is process-killing
regardless of cause.

**3. `SEPOLIA_RPC` shape.** Added to the same `envChecks` list as the others, pattern
`/^https:\/\//`.

### Test result

**70 tests / 70 pass / 0 fail** across five files — reason 4, decide 17, subgraph 14, send 9,
loop 26 (+6: non-string id, `__proto__` id rejected at load, `__proto__` id doesn't pollute
the store, `routePath` never throws including on `//`/`/\`, `routePath` strips a query
string, `routePath` collapses a leading double slash). `check-reason-table.mjs`: all 13 codes
agree. `forge test`: 201 passed, 1 skipped, 0 failed — unchanged. Manually reproduced both
of the reviewer's repro cases against `validateIntents` directly and confirmed both are now
caught: `[{id:1}, {id:"1"}]` → `["intent id must be a string, got 1 (number)"]`;
`[{id:"__proto__"}]` → `["intent id \"__proto__\" is not allowed"]`.

### Mutation output

**Removed the id-shape check** (reverted `validateIntents`'s id branch to duplicate-only
checking, the pre-fix logic):
```
✔ an eligible intent is queued to send
✔ an in-flight intent is not queued again - this is what stops duplicate payments
✔ an executed intent is terminal and never sent again
✔ a blocked intent stays eligible, so the agent retries after a widening
✔ a failed read sends nothing and says so
✔ a predicted block is not sent
✔ the tick counter and the source block land in the state
✔ a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible
✔ a pre-send failure with no hash stays eligible, since nothing was sent
✔ inFlight is cleared even when the send throws, via a finally
✔ a duplicate intent id is never queued twice, even if one slipped past validateIntents
✔ a malformed amount does not crash advance, and the error reaches that intent's state
✔ an empty-string amount is rejected at load, not silently treated as zero
✔ validateIntents rejects a duplicate id
✔ validateIntents rejects a malformed token or payee address
✔ validateIntents accepts a well-formed, unique list
✔ a quoted address value is rejected, not silently accepted
✔ a trailing CR is trimmed away, so a value that would otherwise be silently wrong is healed and accepted
✔ a missing value is rejected by name
✔ a wrong-length hash is rejected
✖ a non-string intent id is rejected at load
✖ an intent id of "__proto__" is rejected at load
✔ a "__proto__" id does not pollute the intents store or vanish from state
✔ routePath never throws, including on // and /\
✔ routePath strips a cache-busting query string
✔ routePath collapses a leading double slash, so base + "/path" joins still resolve
tests 26, pass 24, fail 2
```
Exactly the two named tests went red — including confirming the third `__proto__` test (the
store-pollution one) stayed green under this mutation, since that property is independently
guaranteed by the null-prototype store rather than by `validateIntents`. Reverted; `diff`
against the pre-mutation backup was empty; full suite re-confirmed 70/70, reason table
13/13, and `forge test` 201/1/0 after restore.

No files outside `agent/` and the plan file were touched. No env vars read, no network
calls, `.env` never opened, no subagents dispatched, Step 9 still not run, no push.

## SEPOLIA_RPC key-leak correction (severity re-classified from item 3)

Commit: `2edcde2` — "fix: treat a scheme-less SEPOLIA_RPC as the API-key leak it is, not
tidying" — 3 files: `agent/loop.mjs`, `agent/loop.test.mjs`,
`docs/superpowers/plans/2026-09-09-agent-loop.md`.

`validateEnvVar` gained two more parameters: `hint` (a per-check explanation, so the
`SEPOLIA_RPC` rejection names the redaction risk directly instead of the generic "stray
quotes or a trailing CR" message) and `showValue` (defaults `true`; `false` for
`SEPOLIA_RPC`'s check only). While writing this I found and fixed a second-order instance of
the same class of bug on myself: the first version of the hint echoed the rejected value back
via `JSON.stringify(rawValue)` in the very error message explaining that the value can't be
safely echoed — the key would have appeared once in the terminal at startup, before the
server ever exists to leak it further. `showValue: false` suppresses that. `WALLET_ADDR`/
`AGENT_ADDR`/`LEASH_NODE` keep echoing their rejected values (public addresses; seeing the
malformed value is a debugging aid, not a leak).

### An anomaly to flag, not a problem I introduced

Between my `c6ff974` and this commit, `git log` shows an unexpected intermediate commit
`769176d` — "fix: complete the per-variable hint that c6ff974 committed only half of" —
authored under my git identity with the same session attribution, timestamped 17:48:29,
between my two working sessions on this fix (`c6ff974` at 17:46:05, `2edcde2` at 17:52:10). I
did not run that commit. Its content is an exact snapshot of my own in-progress, not-yet-
committed edit at that moment (the `hint` parameter added, before I added `showValue`) —
something else appears to have committed directly from this shared worktree while I was
mid-edit. I did not lose or overwrite any work: `git diff 769176d 2edcde2` is a small, clean,
non-duplicated diff (exactly the `showValue` addition), tests are 72/72, and `forge test` is
201/1/0. Flagging in case it's useful to know the worktree isn't as exclusively single-writer
as I'd assumed, since a less clean interleaving next time could cause a real conflict.

### Test result

**72 tests / 72 pass / 0 fail** across five files — reason 4, decide 17, subgraph 14, send 9,
loop 28 (+2: the scheme-less RPC rejection explaining why and not echoing the key, and an
accepted `https://` URL). `check-reason-table.mjs`: all 13 codes agree. `forge test`: 201
passed, 1 skipped, 0 failed — unchanged. Manually verified the production error string no
longer contains the fake key: `SEPOLIA_RPC is not shaped like an https:// RPC URL. A
scheme-less URL cannot be safely redacted...` (no `(got "...")` clause).

No files outside `agent/` and the plan file were touched. No env vars read, no network
calls, `.env` never opened, no subagents dispatched, Step 9 still not run, no push.
