# Fix wave 2 — one defect: a chain-blocked intent is re-submitted forever

Repo /home/ubuntu/DEV/leash, branch `policyset`, base `6a238c9`.
Tests today: `forge test` 241 pass / 1 skipped; `node --test agent/*.test.mjs` 86 pass.
Forge is untouched by this work — no Solidity changes at all.

## The defect

`agent/loop.mjs:149-201` has three terminal branches for an intent: `executed` → `done`,
a hash with no outcome → `unconfirmed`, `inFlight` → wait. **A chain BLOCK is in none of
them.** It falls through to `decide` and is re-evaluated every tick, and if `decide` says
`will-pass` it is submitted again — a real Sepolia transaction every `TICK_MS` (default
5000), without limit.

This is **pre-existing**, not something this branch introduced: `decide`'s own `pass()`
explain at `agent/decide.mjs:46-53` already says the per-tx cap, token allow-list, time
window and pause are not indexed, so a paused wallet or an over-`txLimit` intent has always
been predicted `will-pass`, sent, blocked, and predicted `will-pass` again. What this branch
did was widen the set of reasons that reach the loop from {5, 7, 9, 10, 11, 12} to include
6 and 8 as well, because under a `PolicySet` those two stop being predicted.

## The fix: re-send only when the inputs change

Not a retry counter. A counter has three holes that were found and are worth knowing, so
you do not reinvent one:

- Reasons that alternate (a budget oscillating near its boundary as other spends land)
  reset a reason-keyed counter forever.
- A counter that latches after N blocks latches the demo's face-scan beat off: the payee
  becomes allow-listed several ticks later, but the reason code never changed across those
  blocks, so nothing re-arms it.
- "Reset on a successful send" is dead code — an executed intent is already terminal at
  `agent/loop.mjs:158-163`.

Key the re-arm on **the inputs changing**, which is the thing that can actually make a
blocked payment succeed.

### What to build

1. A pure exported helper in `agent/loop.mjs`:

```js
export function inputFingerprint(snapshot, intent)
```

   It returns a stable string over exactly the facts `decide` reads for THIS intent:
   `snapshot.policy?.address`, `snapshot.payees?.[payee.toLowerCase()]?.allowed`,
   and `snapshot.budget`'s `token`, `limit`, `spent` and `periodEnd`. Lowercase every
   address before it goes in. It must be deterministic for equal inputs — do not
   `JSON.stringify` an object whose key order you do not control; build the string
   explicitly, field by field, in a fixed order.

2. In `advance`, when an intent is pushed to `toSend`, record the fingerprint it was sent
   under: `rec.sentFingerprint = inputFingerprint(snapshot, intent)`.

3. Add a **fourth terminal branch**, after the `inFlight` branch and before the `else` that
   calls `decide`: if `prev.lastAction?.outcome === "blocked"` and
   `prev.sentFingerprint === inputFingerprint(snapshot, intent)`, the intent does not go to
   `decide` and does not go to `toSend`.

   Latching on the fingerprint recorded at SEND time — not one recorded when the block is
   observed — is what makes it latch after exactly one block instead of two.

4. **Do not introduce a new verdict string.** `world/demo.html` styles verdicts by value and
   an unrecognised one would render unstyled on the demo page. Leave `rec.verdict`,
   `rec.reason` and `rec.reasonName` exactly as the previous tick left them (they come
   through the `{...prev}` spread at `agent/loop.mjs:149-156`) and change only `rec.explain`,
   to say: the chain blocked this with the reason it gave, the agent has stopped resubmitting
   it, and it will try again when the index shows something relevant has changed. Mention
   that restarting the agent clears the latch, because the state is in memory and an operator
   needs to know that.

   **Do not add `sentFingerprint` to the list of fields that block unconditionally overwrites**
   at `agent/loop.mjs:149-156`. It must survive via `...prev` or it is zeroed every tick and
   the latch never engages. Write a test that would catch that specific mistake.

5. Do not touch `world/`, any `.sol` file, or `agent/decide.mjs`.

### Tests — `agent/loop.test.mjs`

The first two are the ones that matter; the rest guard the edges.

1. **It latches.** An intent whose `lastAction` is a chain block with an unchanged snapshot:
   `toSend` is empty, and stays empty across a second `advance` call.
2. **A widening re-arms it.** Same intent, but the snapshot now has that payee `allowed:
   true`. It reaches `toSend`. **Assert on `toSend`, not on the verdict string** — this
   repo has shipped eight tests that passed without exercising the property they named, and
   a verdict-only assertion here would be the ninth.
3. A changed `policy.address` re-arms it (this is the demo's `setPolicy` finale).
4. A changed `budget.spent` re-arms it.
5. `rec.verdict` and `rec.reason` are unchanged by the latch branch — the last decided
   values survive.
6. The mutation guard: after writing them, temporarily add `sentFingerprint: null` to the
   `rec` rebuild at `:149-156`, confirm test 1 goes RED, revert, confirm green. Report the
   observed failure text. If it does not go red, your test is not pinning the property and
   you must fix the test, not the code.

Also re-run the two existing tests that cover the blocked path (`agent/loop.test.mjs:46` is
one) and report whether either changed meaning. If one of them asserted the old re-send
behaviour, it was pinning the defect — update it and say so explicitly in your report rather
than quietly editing it.

## Commit

One commit, message prefixed `fix(agent):`. End it with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Sv1gERVb8hNg7Xj8DcZ8J3
```

`git add` only the files you changed — name them explicitly, do not use `git add -A`. Another
agent writes to this branch concurrently and a previous wave swept three unrelated files into
a commit that way.

## Report

Full report to `/home/ubuntu/DEV/leash/.superpowers/sdd/2026-09-11-policyset/fix-2-report.md`.
Return only: status, the commit SHA, one line of test counts, the observed result of the
step-6 mutation, whether either existing blocked-path test changed meaning, and concerns.

You do not dispatch subagents. Do not run `agent/loop.mjs` — it sends real transactions.
