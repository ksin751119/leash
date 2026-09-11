# Fix wave 1 — findings from the final whole-branch review of `policyset` (660e4f7..8f3aeed)

These are your requirements. Exact values here are to be used verbatim. Do not read the
plan file; everything you need is below.

Repo: /home/ubuntu/DEV/leash   Branch: `policyset` (already checked out)
Tests: `forge test` (236 pass, 1 skipped today) and `node --test agent/` (78 pass today).
Both must be green when you finish, with the counts risen by the tests you add.

The controller has already ruled on every finding. The rulings are not open for
re-litigation — implement them. If implementing one is impossible as stated, stop and report
`BLOCKED` with the specific obstacle.

---

## F1 — CRITICAL. `agent/decide.mjs` re-derives `StandardPolicy`'s rules

`agent/decide.mjs:4` states: "This function is trustworthy when it refuses and not when it
permits." `decide.mjs:19` states: "What this function must never do is re-derive policy
logic."

It breaks both. It hard-codes two POLICY-LAYER rules:

```js
  const payee = snapshot.payees?.[lower(intent.payee)];
  if (!payee || payee.allowed !== true) {
    return blocked(REASON.PAYEE_NOT_ALLOWED, "...");
  }
```

and the period-budget block below it. Those are `StandardPolicy`'s rules. With the new
`PolicySet` installed, `decide` refuses a payment the chain would allow — which inverts the
safety direction the module claims about itself.

### What to do

`decide` gains a **required 4th parameter** `knownPolicy` — the address of the
`StandardPolicy` whose rules this module encodes.

```js
export function decide(snapshot, intent, nowSec, knownPolicy) {
```

- The three ACCOUNT-layer checks stay exactly as they are and stay unconditional: agent
  revoked → 2, no policy → 3, policy not approved → 4. Those are `LeashAccount`'s checks,
  not the policy's.
- **After** those, and **before** the payee check, compare `lower(snapshot.policy.address)`
  with `lower(knownPolicy)`. If they differ, return `pass()`-shaped result whose `explain`
  says the installed policy is not the one this pre-flight understands and that only the
  chain can decide. Both policy-layer rules — payee AND period budget — are skipped.
- If `knownPolicy` is missing or is not a 0x-prefixed 40-hex-digit address, **throw**. Do
  not default it. `loop.mjs` already wraps `decide` in a try/catch that turns a throw into
  verdict `invalid`, which is not sent — so a misconfiguration fails closed.

**The fallback MUST be `pass()`, not `unknown(...)`.** This is the part that is easy to get
wrong and it is why the finding exists: `loop.mjs:197` sends only `will-pass`, so an
`unknown` verdict is just as unsent as a block. A fix that returns `unknown` changes the
label and changes nothing observable. Write a test that would catch that mistake — assert
the intent reaches `toSend`, not merely that the verdict string changed.

### Wiring it up

- `agent/loop.mjs` validates its environment at startup around line 379 with a table of
  `[NAME, REGEX, label, hint]`. Add `STANDARD_POLICY` to that table with the same
  40-hex-address pattern the other address vars use, store it in a module-level
  `STANDARD_POLICY` alongside `LEASH_NODE`, and pass it as the 4th argument at the `decide(...)`
  call site (~line 180).
- Add `STANDARD_POLICY=0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b` to `.env.example` (or the
  equivalent file this repo uses to document required environment — find it; do not invent a
  new one) with a one-line comment saying what it is for.
- Every existing call site in `agent/decide.test.mjs` must be updated to pass the address its
  `base()` snapshot reports. Do not weaken an existing assertion to make it compile.

### Tests to add in `agent/decide.test.mjs`

1. A snapshot whose `policy.address` is some other address, with a payee that is NOT on the
   allow-list → verdict `will-pass` (this is `apitopup` under `PolicySet`).
2. The same snapshot, with an amount that would exceed the indexed period budget → still
   `will-pass`, because the budget rule is gated too.
3. The known policy, payee not allowed → still `will-be-blocked` with reason exactly
   `REASON.PAYEE_NOT_ALLOWED` (today's behaviour, unchanged).
4. `decide(...)` with `knownPolicy` omitted → throws.
5. In `agent/loop.test.mjs` (or wherever `computeTick`/`publicState` is tested): an unknown
   policy + a not-allow-listed payee results in that intent appearing in `toSend`. This is
   the test that actually pins the finding; the verdict-string tests alone do not.

---

## F2 — IMPORTANT. `MicroPaymentPolicy` ignores `ctx.txLimit` and the time window

Under the OR, two of the five fields `tightenRule` writes become vacuous for any sub-cap
payment — including the time window, which is one of the owner's controls.

The rule this policy now states, and which its comments must say: **it relaxes exactly one
thing, the payee allow-list, and substitutes its own `CAP` for the per-transaction limit.
Every other control the owner set still holds.**

Add to `src/MicroPaymentPolicy.sol`, in this order (the order is the reason-code precedence,
and it must match `StandardPolicy`'s):

1. `!ctx.tokenAllowed` → `Reason.TOKEN_NOT_ALLOWED`   *(already there)*
2. `ctx.amount > CAP` → `Reason.OVER_TX_LIMIT`   *(already there)*
3. **NEW:** `ctx.txLimit != 0 && ctx.amount > ctx.txLimit` → `Reason.OVER_TX_LIMIT`
4. period budget → `Reason.OVER_PERIOD_LIMIT`   *(already there, unchanged)*
5. **NEW:** `!_inWindow(ctx.nowTs, ctx.windowStart, ctx.windowEnd)` →
   `Reason.OUTSIDE_TIME_WINDOW`
6. `Reason.OK`

`payeeAllowed` is still never read. Keep that comment.

`_inWindow` must be copied **verbatim** from `src/StandardPolicy.sol:49-55`, including its
doc comment. `StandardPolicy` is deployed AND approved on Sepolia: extracting a shared
library would mean redeploying it, which invalidates its approval and the ENS pointer
pointing at it. So do not touch `src/StandardPolicy.sol` — do not touch any deployed
contract.

Verbatim duplication is a review defect, so it is paid for with a differential test. Add to
`test/MicroPaymentPolicy.t.sol`:

```
testFuzz_inside_the_cap_and_with_an_allowed_payee_it_agrees_with_StandardPolicy
```

Fuzz `nowTs`, `windowStart`, `windowEnd` (bound the two window values to 0..1439),
`amount`, `txLimit`, `periodLimit`, `spentSoFar`. Build one context with
`tokenAllowed = true` and `payeeAllowed = true`, `bound(amount, 0, CAP)` so the CAP branch
cannot be what differs, and assert
`micro.check(ctx) == standard.check(ctx)` — the same uint8, not merely both-OK-or-both-not.
Then mutate: delete the new window check and confirm this test goes red. Report the observed
failure. A differential test that passes with the check deleted is worthless and this repo
has shipped eight tests of exactly that shape.

Also add two ordinary tests: over `ctx.txLimit` but under `CAP` → exactly
`Reason.OVER_TX_LIMIT`; outside the window → exactly `Reason.OUTSIDE_TIME_WINDOW`.

**Do not change `CAP`, and do not change the existing period-budget logic.**

---

## F3 — IMPORTANT. `PolicySet._ask` never consults `PolicyApprovals`

Revoking a *member* is a no-op: the set keeps running it. The controller has ruled **no code
change**, for three reasons, which you are to write into `src/PolicySet.sol`'s contract-level
doc comment as a short, numbered `@dev` note:

1. `PolicyApprovals` approves the address the account POINTS AT. A `PolicySet` is its own
   address with its own approval, and its member list is immutable — so approving the set is
   approving the whole composition.
2. A revoked member surfacing as `12 POLICY_FAILED` would read as "this policy is broken,
   replace it" and send the operator somewhere other than where the truth is.
3. The brake still exists and is still permissionless: revoke the SET. `revoke` is open to
   anyone (`src/PolicyApprovals.sol`) precisely so that this needs no authority.

Then **pin the behaviour with a test** in `test/PolicySet.t.sol`, so it is deliberate rather
than incidental:

```
test_revoking_a_member_does_not_disable_the_set
```

Deploy a real `PolicyApprovals` with a mock attester that returns true, approve a member,
build a set containing it, `revoke` that member, and assert `set.check(okCtx())` still
returns `Reason.OK`. Give the test a comment saying it pins a ruling, and naming reason (3) —
that revoking the set is the supported brake — so a future reader does not "fix" it.
Look at `test/PolicyApprovals.t.sol` for how this repo builds an attester mock; reuse it
rather than writing a new one.

---

## F4 — IMPORTANT. `describe()` advertises the hole as a feature

Current: `"MicroPaymentPolicy/1: per-tx cap and period budget, payee allow-list ignored"`

This string is the only human-readable text a person sees at approval time and on the demo's
POLICY panel. Replace it with, verbatim:

```
"MicroPaymentPolicy/1: any payee under a per-tx cap; NOT SAFE ALONE - use only inside a PolicySet OR"
```

Update any test asserting the old string.

---

## Out of scope — do NOT do these

- Deployment, `docs/deployments.md`, `README.md` — the controller handles those, because
  deployment produces the addresses.
- `world/` — do not touch the demo page.
- Any contract already deployed to Sepolia: `LeashAccount`, `LeashRegistry`,
  `LeashResolver`, `PolicyApprovals`, `StandardPolicy`, `WorldAttester`, `LeashLens`.
- `test/PolicySetDemo.t.sol`'s `setUp()` over-deployment and `GasHogPolicy`'s comment — both
  were reviewed and are shipping as-is.
- Do not run `agent/loop.mjs`. It sends real transactions on Sepolia. Unit tests only.

## Global constraints, still binding

- `PolicySet.check` and `MicroPaymentPolicy.check` stay declared `view`.
- Members are reached by `staticcall`, never `call`.
- Any member anomaly is `12 POLICY_FAILED` immediately, with no fall-through.
- When no clause passes, the LAST clause's reason is reported.
- No setter on `CAP` or on the member list.
- The reason codes in `src/Reason.sol` are frozen — use them, do not add one.
- Every test that pins a reason code asserts the exact number, never "not OK".
- Commit as you go, one commit per finding, message prefixed `fix(policyset):`.
  End every commit message with these two lines:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Sv1gERVb8hNg7Xj8DcZ8J3
  ```

## Report

Write your full report to
`/home/ubuntu/DEV/leash/.superpowers/sdd/2026-09-11-policyset/fix-1-report.md`.
Return to the controller only: status (DONE / DONE_WITH_CONCERNS / BLOCKED), the commit
SHAs, one line of test counts, the observed result of the F2 mutation, and any concerns.
Do not paste diffs or file contents into your reply.

You do not dispatch subagents. Review arrives from the controller after your report.
