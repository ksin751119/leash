# Fix wave 1 — report

Branch `policyset`, four commits on top of `8f3aeed`. All four findings implemented as ruled.

Status: **DONE_WITH_CONCERNS** — the work is complete and green; the one concern is a commit
hygiene accident described under "Concerns", not a defect in the fixes.

| Finding | Commit | Files |
|---|---|---|
| F1 pre-flight re-derives StandardPolicy's rules | `998d116` | `agent/decide.mjs`, `agent/loop.mjs`, `agent/decide.test.mjs`, `agent/loop.test.mjs`, `.env.example`, `agent/README.md` |
| F2 `MicroPaymentPolicy` ignores `txLimit` and the window | `a44af85` | `src/MicroPaymentPolicy.sol`, `test/MicroPaymentPolicy.t.sol` |
| F3 `PolicySet._ask` never consults `PolicyApprovals` | `b08c7dc` | `src/PolicySet.sol`, `test/PolicySet.t.sol` |
| F4 `describe()` advertises the hole as a feature | `6a238c9` | `src/MicroPaymentPolicy.sol`, `test/MicroPaymentPolicy.t.sol` |

Tests: `forge test` 241 passed, 0 failed, 1 skipped (was 236/1). `node --test agent/*.test.mjs`
86 passed, 0 failed (was 78).

Note on the node invocation: `node --test agent/` fails with `MODULE_NOT_FOUND` on Node
v24.14.1 — the runner resolves the bare directory as a module. `node --test agent/*.test.mjs`
(or `cd agent && node --test .`) is what runs the suite. That is pre-existing, not something
this wave changed.

---

## F1 — `decide` gains a required `knownPolicy`

`agent/decide.mjs`:

- Signature is now `decide(snapshot, intent, nowSec, knownPolicy)`.
- `knownPolicy` is validated first, against `/^0x[0-9a-fA-F]{40}$/`, and **throws** when
  missing or malformed. No default. Validated ahead of the snapshot check so a
  misconfiguration cannot be masked by a failed read.
- The three account-layer checks (2 `AGENT_REVOKED`, 3 `NO_POLICY`, 4 `POLICY_NOT_APPROVED`)
  are untouched and unconditional.
- Immediately after them, and before the payee check:
  `lower(snapshot.policy.address) !== lower(knownPolicy)` returns a `pass()`-shaped result
  (`verdict: "will-pass"`, `reason: null`) with its own `explain` saying the installed policy
  is not the `StandardPolicy` this pre-flight encodes and only the chain can decide. Both
  policy-layer rules — payee allow-list and period budget — are behind that gate.
- The comparison is case-insensitive on both sides. This is load-bearing rather than
  defensive: the subgraph reports addresses lower-cased and `.env.example` carries the
  checksummed form, so a case-sensitive comparison would gate the rules off for the exact
  configuration that is deployed, and every other test would still have passed. There is a
  test for it.

`agent/loop.mjs`:

- `STANDARD_POLICY` added to the startup `envChecks` table with `ADDR_RE` and a hint, stored
  in the module-level `let` alongside `LEASH_NODE`.
- `advance` takes `knownPolicy` as a **5th parameter** rather than reading the module-level
  variable. The brief said to pass it at the `decide(...)` call site; that call site is inside
  `advance`, which `loop.mjs` itself describes as "the pure half", and which 25 tests call
  directly without ever starting the loop. Reading module state there would have made the
  pure half depend on a variable only the `isMain` block assigns — every one of those tests
  would have seen `undefined` and gone to verdict `invalid`. Threading it in is the same shape
  as `publicState(s)` taking the state. `tick()` passes the module-level `STANDARD_POLICY`;
  the tests pass the address their fixture reports.
- The `try/catch` comment around `decide` now also names the `knownPolicy` throw as a
  deliberate fail-closed path, so the next reader does not "fix" it into a default.

`.env.example` — this is the file the repo uses to document required environment (there is no
other; `agent/README.md` documents how to extract values from it). Added under a new
`# --- The agent's pre-flight ---` heading:

```
STANDARD_POLICY=0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b
```

with a three-line comment saying what it is for.

`agent/README.md` — **one file beyond the brief's list, and deliberately.** Its run snippet is
the operative instruction for starting the loop, and after this change a start without
`STANDARD_POLICY` exits 1 at the env check. Leaving that snippet stale would have handed the
controller a demo that refuses to boot. Added the variable to the snippet, to the sentence
listing what startup validates, and a short paragraph explaining what it is for. Root
`README.md` was not touched.

### Tests added (F1)

`agent/decide.test.mjs` (+5, all existing call sites updated to pass `KNOWN`; no assertion
weakened):

1. unknown policy + payee not on the allow-list → `will-pass`
2. unknown policy + amount over the indexed period budget → `will-pass`
3. known policy + payee not allow-listed → `will-be-blocked`, reason exactly
   `REASON.PAYEE_NOT_ALLOWED`
4. checksummed `knownPolicy` against the lower-cased snapshot → still recognised, still blocks
5. `knownPolicy` omitted / `"0xnothex"` / `null` → throws

`agent/loop.test.mjs` (+3; the fixture's `policy.address` changed from the malformed stub
`"0xbb"` to the real StandardPolicy address — nothing asserted on the old value):

6. **unknown policy + empty `payees` → the intent appears in `toSend`.** This is the one that
   pins the finding.
7. the counterpart: known policy, same empty `payees` → `toSend` empty, reason 6. Without it,
   test 6 could pass by `advance` having stopped checking anything at all.
8. `advance(..., undefined)` → nothing sent, verdict `invalid`, explain mentions
   `knownPolicy`.

### F1 mutation check (not required, run anyway)

Changing the fallback from `pass()` to `unknown("unknown", …)` — the shape both the review and
the controller first proposed — turns 3 tests red, including test 6:

```
✖ an unrecognised policy skips the payee allow-list, because it is not that policy's rule
✖ an unrecognised policy skips the period budget too
✖ under a policy this pre-flight does not know, a payment to a stranger is still sent
```

Reverted; 86/86 green.

---

## F2 — the exception relaxes one thing

`src/MicroPaymentPolicy.check` now runs, in this order:

1. `!ctx.tokenAllowed` → `TOKEN_NOT_ALLOWED`
2. `ctx.amount > CAP` → `OVER_TX_LIMIT`
3. **new:** `ctx.txLimit != 0 && ctx.amount > ctx.txLimit` → `OVER_TX_LIMIT`
4. period budget → `OVER_PERIOD_LIMIT` (unchanged, including the underflow guard)
5. **new:** `!_inWindow(ctx.nowTs, ctx.windowStart, ctx.windowEnd)` → `OUTSIDE_TIME_WINDOW`
6. `OK`

`CAP` unchanged. `payeeAllowed` still never read, comment kept. The contract-level notice now
states the rule: it relaxes exactly one thing, the payee allow-list, substitutes `CAP` for the
per-transaction limit, and every other control the owner set still holds — with the reason
why an omission here matters more than it looks (under an OR, a check this contract omits is a
check the composition no longer has for any sub-cap payment).

`_inWindow` is byte-identical to `src/StandardPolicy.sol:49-55`; verified with `diff` over the
extracted function including its doc comment. Its doc comment carries an added `@dev`
paragraph naming why it is duplicated rather than extracted (StandardPolicy is deployed and
approved; changing its bytecode invalidates the approval and the ENS pointer) and naming the
differential test that pays for the duplication. `src/StandardPolicy.sol` was not modified.

### Tests added (F2)

- `testFuzz_inside_the_cap_and_with_an_allowed_payee_it_agrees_with_StandardPolicy` — fuzzes
  `nowTs`, `windowStart`, `windowEnd` (bounded 0..1439), `amount` (bounded 0..CAP),
  `txLimit`, `periodLimit`, `spentSoFar`; `tokenAllowed = true`, `payeeAllowed = true`; asserts
  `policy.check(c) == standard.check(c)` on the exact `uint8`.
- `test_under_the_cap_but_over_the_owners_tx_limit_is_over_tx_limit` — `txLimit` 0.40 USDC,
  amount 0.50 USDC, CAP 1 USDC → exactly `Reason.OVER_TX_LIMIT`.
- `test_outside_the_time_window_is_outside_time_window` — window 09:00–17:00 UTC, `nowTs`
  03:00 UTC → exactly `Reason.OUTSIDE_TIME_WINDOW`.

### F2 mutation results (both observed, both reverted)

**Window check deleted** (the one the brief asked for):

```
[FAIL: assertion failed: 0 != 9; counterexample: args=[27599, 44297, 0, …]]
  testFuzz_inside_the_cap_and_with_an_allowed_payee_it_agrees_with_StandardPolicy (runs: 3)
[FAIL: assertion failed: 0 != 9] test_outside_the_time_window_is_outside_time_window
Suite result: FAILED. 14 passed; 2 failed
```

`0 != 9` is `Reason.OK` where `StandardPolicy` says `OUTSIDE_TIME_WINDOW`. The fuzzer found it
on run 3 — the differential test is not a decoration.

**`txLimit` check deleted** (extra, same method):

```
[FAIL: assertion failed: 8 != 7] testFuzz_…_it_agrees_with_StandardPolicy
[FAIL: assertion failed: 0 != 7] test_under_the_cap_but_over_the_owners_tx_limit_is_over_tx_limit
Suite result: FAILED. 14 passed; 2 failed
```

`8 != 7` — the fuzz case reached the period-budget branch where StandardPolicy had already
answered `OVER_TX_LIMIT`, which is exactly the precedence divergence the exact-uint8 assertion
exists to catch and which a both-OK-or-both-not assertion would have missed.

---

## F3 — no code change, written down and pinned

`src/PolicySet.sol`'s contract doc gains a numbered `@dev` note carrying the three reasons
verbatim in substance: approval attaches to the address the account points at and the member
list is immutable, so approving the set approves the composition; a revoked member surfacing
as `12 POLICY_FAILED` misdirects the operator; the brake is to revoke the SET, and
`PolicyApprovals.revoke` is permissionless precisely so that needs no authority. The note ends
by naming the test, so the two cannot drift apart.

`test/PolicySet.t.sol` gains `test_revoking_a_member_does_not_disable_the_set`: deploys a real
`PolicyApprovals` with `MockAttester` (the repo's existing attester mock, reused rather than
rewritten), approves `ok1`, asserts the set returns `OK`, revokes `ok1`, asserts the member is
really revoked and that `set.check(_ctx())` is still `Reason.OK`. Its comment opens with "This
pins a ruling; it is not a bug to be fixed" and names reason (3). `_ctx()` is the file's
existing context helper (the brief called it `okCtx()`).

`_ask` is unchanged. `check` is still `view`, members still reached by `staticcall`.

---

## F4 — `describe()`

Replaced verbatim with:

```
MicroPaymentPolicy/1: any payee under a per-tx cap; NOT SAFE ALONE - use only inside a PolicySet OR
```

No existing test asserted the old string (the only other occurrence is in
`docs/superpowers/plans/2026-09-11-policyset.md`, a historical plan document, left alone). Added
`test_describe_warns_that_this_policy_is_not_safe_alone` asserting the exact new string, since
this is the only human-readable text at approval time and on the demo's POLICY panel, and a
string with no test is one edit from drifting back.

---

## Out of scope, untouched

No deployed contract was edited: `LeashAccount`, `LeashRegistry`, `LeashResolver`,
`PolicyApprovals`, `StandardPolicy`, `WorldAttester`, `LeashLens` are all byte-identical to
`8f3aeed`. `world/` untouched. `test/PolicySetDemo.t.sol` untouched. Root `README.md` and
`docs/deployments.md` untouched. `agent/loop.mjs` was never run. `src/Reason.sol` unchanged —
no reason code added; every new assertion pins an exact number.

---

## Concerns

1. **Three files that are not mine are inside commit `998d116`.** `git status` was clean when
   this wave started; between that check and the first commit, another agent working in the
   same checkout wrote `docs/architecture.md`, `docs/superpowers/specs/2026-09-11-policyset-design.md`
   and `script/DeployPolicySet.s.sol` (file mtimes 05:11–05:12, first commit 05:15). `git add -A`
   swept them in, so they are committed under an F1 commit message that says nothing about
   them. **Nothing was lost or altered** — the content is exactly as that agent wrote it, and
   the later three commits contain only files this wave edited. I did not rewrite history to
   split them out: another agent is committing to this branch concurrently, and a rebase of
   four commits is a worse risk than a misattributed commit message. If the controller wants
   them separated, `git diff 8f3aeed..HEAD -- docs/ script/` is exactly that content.
   The lesson for the rest of this branch is to stage explicit paths, not `-A`.

2. **`decide`'s gate keys on the policy address, so a redeployed StandardPolicy silently
   disables the pre-flight's policy layer.** That is the fail-safe direction (it stops
   refusing, it never starts permitting something the chain would block) and is what the
   ruling asks for, but it means the pre-flight goes quiet with no alarm. The verdict's
   `explain` says so on every intent and the demo panel shows it, which is the only warning
   there is. Worth knowing before the finale, since the demo's ENS `setPolicy` beat is exactly
   the moment the installed policy changes.

3. **F2 tightens `MicroPaymentPolicy` against the live rule's window and `txLimit`, which is
   the intent, and the live rule (`txLimit` 500 USDC, window 0/0) makes both inert today.**
   The consequence to keep in mind is the other direction: if anyone tightens the window
   before the demo, sub-cap payments now stop outside it — correctly, and that is the point of
   the fix, but it is a new way for a demo row to go red that did not exist at `8f3aeed`.

4. The fuzz test compares two live contracts, so it will keep passing if someone edits *both*
   copies of `_inWindow` in the same wrong way. Nothing catches that but review; it is called
   out here because the duplication is now permanent for as long as the deployed
   `StandardPolicy` stands.
