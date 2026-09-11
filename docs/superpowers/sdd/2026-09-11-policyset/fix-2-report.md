# Fix wave 2 — report

Branch `policyset`, one commit on top of `6a238c9`.

Status: **DONE_WITH_CONCERNS** — implemented exactly as specified and green; the concern is a
fourth hole in the fingerprint design, reported rather than fixed, per instruction.

Commit: **`ce9a942`** `fix(agent): a payment the chain refused is not asked for again every
five seconds`

Files, staged by name (`git add agent/loop.mjs agent/loop.test.mjs`, no `-A`):
`agent/loop.mjs`, `agent/loop.test.mjs`. Nothing else — no `.sol`, no `world/`, no
`agent/decide.mjs`. `git status --short` before the commit showed exactly those two.

Tests: `node --test agent/*.test.mjs` 94 passed, 0 failed (was 86). `forge test` 241 passed,
0 failed, 1 skipped — unchanged, as expected, since no Solidity was touched. `agent/loop.mjs`
was not run.

---

## What was built

### `inputFingerprint(snapshot, intent)`

Exported and pure. Returns

```
policy=<lower>|allowed=<true|false|>|token=<lower>|limit=<>|spent=<>|periodEnd=<>
```

built field by field in a fixed order — not via `JSON.stringify`, whose key order comes from a
GraphQL response nothing in this repo controls. Addresses are lower-cased on the way in, the
same normalisation `decide` uses, because the index reports them lower-cased while the
environment carries them checksummed.

Two deliberate omissions, both commented in the source:

- **The payee address is not a field.** The allow-flag is looked up with this intent's own
  payee, so the string is already about that payee, and fingerprints are only ever compared
  with another fingerprint for the same intent id.
- **`nowSec` is not a field.** It changes every tick; including it would re-arm the latch
  continuously and the mechanism would be decorative. (This is also the source of the concern
  below.)

### The fourth terminal branch

In `advance`, after `inFlight` and before the `else` that calls `decide`:

```js
} else if (prev.lastAction?.outcome === "blocked" && prev.sentFingerprint === fingerprint) {
```

The intent reaches neither `decide` nor `toSend`. The comparison is against the fingerprint
recorded at **send time** (`rec.sentFingerprint = fingerprint`, set where the intent is pushed
to `toSend`), so the latch engages after exactly one block, not two.

`sentFingerprint` is not listed among the fields the record rebuild overwrites. There is a
comment at that site saying so and naming the test that pins it, because the mutation is
invisible from the outside: the code still reads as a working latch.

### No new verdict string

`rec.verdict`, `rec.reason` and `rec.reasonName` are left exactly as the tick that decided them
wrote them; they arrive through the `...prev` spread. Only `rec.explain` changes.

### The `explain` sentence (the delegated call)

With the chain's own reason interpolated, e.g. for a receipt carrying `7 OVER_TX_LIMIT`:

> the chain refused this payment (7 OVER_TX_LIMIT), so the agent has stopped asking. Sending it
> again against the same rules would only be refused again, twelve times a minute. It will try
> once more on its own as soon as the index shows something that could change the answer: this
> payee allow-listed, the budget moved, or a different policy installed. Restarting the agent
> also clears this, because it is remembered in memory and not on disk.

Four things, in the order someone reading it aloud would want them: what happened, why the
agent stopped, what would restart it, and where the state lives. "Twelve times a minute" is the
real figure at the default `TICK_MS` of 5000, and it is the phrase already used a few lines up
in this file for the same hazard. When the receipt carried no reason code — `send.mjs` returns
`reason: null` when the logs are too short to parse — the parenthetical reads "no reason code
in the receipt" instead, so the sentence never degrades into "(null)".

---

## Tests

Eight added, one replaced (see below). All in `agent/loop.test.mjs`.

1. **It latches.** First tick sends and records the fingerprint; `lastAction` is set to a chain
   block; the next tick's `toSend` is empty, and so is the one after it. Also asserts the
   recorded fingerprint equals `inputFingerprint(okSnap(), intents[0])`, so "it latched"
   cannot be satisfied by the intent having never been eligible.
2. **A widening re-arms it**, in the shape it actually happens: policy is the PolicySet, the
   payee is on nobody's allow-list, the pre-flight sends it (F1's behaviour), the chain refuses
   with 6, the latch holds for a tick, then the face scan lands and `payees` gains the entry.
   Asserted on `toSend`, not on a verdict string.
3. **A changed `policy.address` re-arms it** — the demo's `setPolicy` finale.
4. **A changed `budget.spent` re-arms it.**
5. **The latch leaves `verdict` and `reason` alone** and the explain contains both the chain's
   reason code and the word "restarting".
6. **The latch survives the per-tick record rebuild** — the mutation guard (step 6).
7. **Fingerprint stability** across a snapshot with different key order and checksummed
   address values. (The payee *key* stays lower-cased in that fixture: the index reports it
   that way and `decide` looks it up that way, so an upper-cased key would be testing a
   configuration that cannot occur, and failing for the same reason `decide` would.)
8. **Fingerprint sensitivity**: each of the seven facts moved individually changes the string,
   including deleting the payee entry entirely.
9. **A failed read neither sends a latched intent nor loses the fingerprint** — a read failure
   produces a fingerprint of empty fields that matches nothing, so the latch branch is
   bypassed, but `decide` answers `unknown-read-failed` on that same snapshot and nothing is
   sent; the tick after the index recovers is latched again.

### The existing blocked-path test DID change meaning

`agent/loop.test.mjs:46`, **"a blocked intent stays eligible, so the agent retries after a
widening"**, went red against the new code, and it was right to. It sent the intent, marked it
blocked, re-ran `advance` **with the identical snapshot**, and asserted the intent was queued
again — which is the defect, stated as an assertion. Its name promised a widening and its body
never widened anything.

It is replaced by two tests: `a blocked intent is not sent again while nothing it depends on
has changed` and `a widening re-arms a latched intent, which is the whole point of keying on
the inputs`. A comment at the replacement site records what the old test asserted and why the
first half of it was pinning the defect. No other test changed meaning; the only other
occurrence of "blocked" in that file is F1's `under the known policy the same payment is still
predicted blocked and not sent`, which is about a *predicted* block and never reaches the new
branch.

### Step-6 mutation — observed

Adding `sentFingerprint: null` to the `rec` rebuild turns **three** tests red (the brief
predicted one; the other two are tests 6 and 9 above, which is the redundancy working):

```
✖ a blocked intent is not sent again while nothing it depends on has changed
  AssertionError [ERR_ASSERTION]: Expected values to be strictly deep-equal:
  + actual - expected
  + [ { amount: '5000000', id: 'a', note: '',
  +     payee: '0x000000000000000000000000000000000000beef',
  +     token: '0x768f42455a2d082e23ceef7d51e5787c82d67a39' } ]
  - []
      at agent/loop.test.mjs:68:10
✖ the latch survives the per-tick record rebuild
✖ a failed read neither sends a latched intent nor loses the fingerprint
ℹ pass 42  ℹ fail 3
```

The intent is back in `toSend` — the failure says in full what the mutation costs: one real
transaction, per tick, forever. Reverted; 94/94 green.

---

## Concerns

1. **A fourth hole, in the fingerprint design, reported as instructed and not fixed.**
   `decide` reads one fact that is not in the fingerprint and cannot be: the clock. Its budget
   branch computes `rolledOver = periodEnd > 0 && periodEnd <= nowSec` and treats `spent` as 0
   once the period has passed, because the chain resets the budget at the boundary while the
   index keeps reporting the old figure until a spend is indexed.

   So: an intent blocked with `8 OVER_PERIOD_LIMIT` at 23:59 latches. Midnight passes. The
   chain would now allow the payment, and `decide` would now predict `will-pass` — but no
   fingerprinted field has moved (`spent`, `limit` and `periodEnd` all stay put precisely
   *because* no spend has been indexed), so the intent stays latched until an unrelated change
   or an agent restart. This is the counter design's second hole — a beat that re-arms itself
   in the real world but not in the model — reappearing in a different place.

   It is narrower than the holes it replaced: it needs a period boundary to fall between a
   block and the next relevant index change, it fails safe (an unsent payment, not a repeated
   one), and the live demo rule's period is 86400s with the window open all day, so it cannot
   fire during a recording of any plausible length. I did not implement a remedy. The
   one-line one, if you rule for it, is to add a seventh field
   `rolled=${periodEnd > 0 && periodEnd <= nowSec}` — a boolean derived from the clock that
   flips exactly once per period rather than changing every tick, so it does not reintroduce
   the reason `nowSec` itself is excluded. It would need `nowSec` threaded into
   `inputFingerprint`, which changes its signature from what the brief specifies, which is why
   it is a question rather than a commit.

2. **The latch is per-process and per-intent-id, and `intents.json` is read once at startup.**
   If an operator edits an intent's `amount` or `payee` in place, keeping the id, and restarts
   — the restart clears the latch anyway, so this is benign today. But if a future change ever
   makes the loop re-read `intents.json` without restarting, a latched intent whose amount was
   edited downward would stay latched even though the edit is exactly the change that would
   make it succeed. The fingerprint covers snapshot facts only; the intent's own fields are
   assumed immutable for the process's lifetime. Worth a line in whatever adds hot-reloading,
   if anything ever does.

3. **`no-event` is still not terminal.** `send.mjs` classifies a receipt with neither a
   `SpendExecuted` nor a `SpendBlocked` log as `outcome: "no-event"`, and that outcome reaches
   none of the four terminal branches — so such an intent is re-evaluated and can be
   resubmitted every tick, which is the same defect this wave fixed, through a narrower door.
   It is out of this brief's scope and I have not touched it. Whether it is reachable depends
   on whether a `spend` can produce a receipt with neither event, which is a question about
   `LeashAccount`, not about the loop.

4. From wave 1, unchanged and still true: the differential fuzz test compares two live
   contracts, so it cannot catch both copies of `_inWindow` being edited the same wrong way.
   Recorded here only so it does not fall off the list.

---

# Addendum — rulings on concerns 1 and 2

Commit **`4ef55df`** `fix(agent): the latch closes over the clock, and over an empty receipt`,
on top of `ce9a942`. Files, staged by name: `agent/loop.mjs`, `agent/loop.test.mjs`. Nothing
else.

Tests: `node --test agent/*.test.mjs` **99 passed, 0 failed** (was 94). `forge test` 241 passed,
0 failed, 1 skipped — unchanged. The loop was not run.

## Concern 1 — the seventh field

`inputFingerprint(snapshot, intent, nowSec)`. Seventh field:

```js
`rolled=${periodEnd > 0 && periodEnd <= nowSec}`
```

with `periodEnd` read as `Number(budget?.periodEnd ?? 0)` — the same expression `decide` uses,
so the two cannot disagree about when a period has ended. The derived boolean goes in rather
than `nowSec` itself: it flips once per period instead of once per tick, so it cannot cause
churn. The comment above the function now explains both halves — why the clock is read and why
the time itself stays out — and states the dated consequence of having omitted it.

Both call sites updated (`advance`'s, and every call in `agent/loop.test.mjs`). One existing
assertion moved with it: the third-tick check in `the latch survives the per-tick record
rebuild` now compares against `inputFingerprint(okSnap(), intents[0], NOW + 5)`, the time that
tick actually ran at, rather than `NOW`.

### The test that is the point of the change

`a latched over-budget intent re-arms when its period ends, with the index unchanged`:

- snapshot with `periodEnd = NOW + 60`; first tick sends (the index showed room) and records
  the fingerprint;
- `lastAction` set to a chain block with `8 OVER_PERIOD_LIMIT`;
- tick at `NOW + 30` — still inside the period — asserts `toSend` is empty, so a later tick on
  its own is not a change and the latch still holds;
- tick at `NOW + 61` passes **the same snapshot object**, not an equal copy, so the only thing
  that has moved in the entire universe of this test is the clock crossing `periodEnd`, and
  asserts the intent is back in `toSend`.

Plus a unit-level companion, `the fingerprint ignores the clock ticking but not the period
ending`: equal strings at `NOW` and `NOW + 30`, different at `NOW + 61`. Together they pin both
directions — that the clock alone does not re-arm, and that the boundary does.

### Mutation A — `rolled` deleted from the string

```
✖ a latched over-budget intent re-arms when its period ends, with the index unchanged
  AssertionError [ERR_ASSERTION]: the chain has reset the budget; the agent must be
  willing to ask again
  + actual - expected
  + []
  - [ 'a' ]
      at agent/loop.test.mjs:217:10
✖ the fingerprint ignores the clock ticking but not the period ending
ℹ pass 48  ℹ fail 2
```

The intent stays latched with an empty `toSend` — the exact hole, reproduced on demand.
Reverted; green.

## Concern 2 — `no-event` folded into the latch

The branch condition is now
`(outcome === "blocked" || outcome === "no-event") && prev.sentFingerprint === fingerprint`.
The comment above it records both reasons for latching an empty receipt: it means "sent,
outcome unknown", so resending risks paying twice — the hazard the `unconfirmed` branch already
guards against, arriving through a different door — and it is the shape a missing EIP-7702
delegation makes, since `spend` calldata sent to an account with no code succeeds and emits
nothing, which is the condition `LeashLens` exists to detect. A designed-for state, named as
one in the source rather than left as a puzzle.

### The `no-event` sentence

> this payment went through, but its receipt says neither paid nor refused, so the agent cannot
> tell whether the money moved and has stopped resending it rather than risk paying twice for
> one instruction. Look up transaction 0xfeed… to see what happened. An empty receipt is also
> what it looks like when the leash is no longer on this wallet at all — a spend sent to a plain
> account succeeds and does nothing — so it is worth checking that the wallet still delegates to
> LeashAccount. It will try once more on its own as soon as the index shows something that could
> change the answer: this payee allow-listed, the budget moved, or a different policy installed.
> Restarting the agent also clears this, because it is remembered in memory and not on disk.

The closing two sentences are shared with the blocked case (one `willRetry` constant, so the
two cannot drift apart); everything before them is specific. When `lastAction.tx` is null it
reads "Look up the transaction" rather than naming a hash that does not exist.

Three tests: the latch holds across two ticks; the sentence names the hash, says "neither paid
nor refused", names the delegation check, and does **not** contain the blocked wording; and an
empty-receipt latch re-arms on a changed input like any other.

### Mutation B — `no-event` removed from the condition (extra, same method)

```
✖ a send that came back with an empty receipt is not repeated either
✖ an empty receipt explains itself differently from a refusal
ℹ pass 48  ℹ fail 2
```

Reverted; green.

## Concern 3

Accepted with no change, as ruled. The comment on `inputFingerprint` covering the
intent-fields assumption stays where it is.

## Remaining concerns

None new. The two from wave 2 that were ruled on are closed by this commit. The standing one
from wave 1 is unchanged and not actionable here: the differential fuzz test compares two live
contracts, so it cannot catch both copies of `_inWindow` being edited the same wrong way — only
review can.

One note for whoever runs the demo, not a defect: the latch lives in memory, so a restart
clears every latched intent and the agent will resubmit each of them once. That is stated in
both explain sentences, which is where an operator will actually read it.
