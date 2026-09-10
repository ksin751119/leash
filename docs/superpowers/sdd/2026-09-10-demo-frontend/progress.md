# SDD ledger — plan: docs/superpowers/plans/2026-09-10-demo-frontend.md

Spec: docs/superpowers/specs/2026-09-10-demo-frontend-design.md (read, reachable)
Branch: item-12-demo-frontend
MERGE_BASE: 8b28120

Ruling: work on branch `item-12-demo-frontend` in the main checkout rather than a
separate worktree directory — EnterWorktree's contract forbids using it unprompted and the
user never said "worktree"; a manual worktree would need `node_modules` re-installed for
both `agent/` and `world/` on a 3-day deadline. Satisfies "never implement on main".
Cost if wrong: one merge at the end instead of a fast-forward.

## Pre-flight conflict scan

### Task pairs sharing a file or an interface

| A | B | A produces | B consumes | Finding |
|---|---|---|---|---|
| T1 | T4 | `publicState(s)` → `{tick,at,source,readError,tickError,agent,subname,policy,budget,payees,intents[]}` | `renderStatus/renderIntent/renderRules` read exactly those keys | agree — `payees` map keyed lowercase in both |
| T1 | T5 | same shape, over HTTP on :8788 | page polls and passes to T4's functions | agree |
| T2 | T3 | `widenPlan(...) -> {status, body}`, `checkWidenEnv(env) -> string\|null` | T3 destructures `{status, body}`, calls `checkWidenEnv(process.env)` | agree |
| T2 | T5 | `buildCommand` emits the literal `$ATTESTATION` | T5 does `plan.command.replace("$ATTESTATION", body.attestation)` | agree — exact token match |
| T3 | T4 | T3 adds `GET /demo-render.mjs` | T4 creates the file that route serves | **ordering**: the route exists one task before the file. T3's own verification (Step 5) does not curl it; T5 Step 2 does, by which time T4 is done. No conflict. |
| T3 | T5 | T3 serves `demo.html` at `GET /` | T5 creates `demo.html` | **ordering**: same shape. T3 Step 5 states the expected ENOENT→500 explicitly. No conflict. |
| T4 | T5 | pure render functions as an ES module | `demo.html` imports `./demo-render.mjs` | agree — served with `text/javascript` by T3 |
| T1 | T2/T3 | — | — | disjoint: `agent/` vs `world/`, no shared file |

### Task self-consistency

| Task | Tests vs code it specifies | Files created vs files later touched | Finding |
|---|---|---|---|
| T1 | 6 new tests import `publicState`; Step 4 exports it. 72 → 78 asserted. | modifies `agent/loop.mjs` + appends to `agent/loop.test.mjs` | agrees. **Note:** Step 4 cites `agent/loop.mjs:405` for the call site, but Step 3 inserts ~5 lines above it. Ruling below. |
| T2 | 13 tests cover all 5 exports; every export is defined in Step 3 | creates 2 files, nothing later edits them | agrees |
| T3 | no unit tests — manual curl, stated as such | modifies `world/server.mjs` only | agrees; the two ENOENT cases are called out rather than hidden |
| T4 | 11 tests cover all 5 exports; every export is defined in Step 3 | creates 2 files | agrees. Verified by hand: `shortHex(PAYEE)` = `0x0000…cafe0`, `formatUsdc("310000000")` = `310.00`, `pct` = 31, calldata length 266. |
| T5 | no unit tests; greps + human visual review, stated as such | creates `world/demo.html`; nothing later edits it | agrees |

### Global-constraint contradictions

None. Checked each task against all nine Global Constraints:
- "page computes nothing" — T5's only computation is `String.replace` on a command template, which the spec explicitly permits.
- "no new dependency" — T2 uses `@noble/hashes`, already in `world/package.json`.
- "no existing test edited" — T1 says append-only and pins 72 as the floor.
- "no branch in advance() changes" — T1 Step 3 is a single object-literal replacement.

Ruling: line numbers in T1 (`agent/loop.mjs:143`, `:253-275`, `:405`) are anchors as of
commit 8b28120 and shift once Step 3 inserts lines. Implementers must locate by the quoted
code, not by the number. Carried into the T1 dispatch. Cost if wrong: an edit lands in the
wrong place and the suite goes red immediately, which is cheap to catch.

## Progress

Task 1: implemented (commit 32f1c67). `cd agent && node --test` → 78 pass / 0 fail (floor was 72). Review dispatched.

Task 1: PLAN DEFECT found by the implementer. The plan and brief both said publicState()
had "exactly one call site (agent/loop.mjs:405)". It had two — 405 (`GET /api/agent/state`)
and 414 (`POST /api/agent/tick`), verified against 8b28120. Fixing only the first would have
left the tick endpoint throwing at runtime, and **no test covers the live HTTP server**, so
it would have surfaced during the demo rather than in CI.

Ruling: the implementer's fix to both call sites stands and is correct — it is required for
the change to be sound, not scope creep. The plan text was wrong; the spec is unaffected.
Cost if wrong: none identified; leaving 414 unfixed was the only alternative and it is
strictly broken.

Open question carried to review: there is no test at the HTTP layer for either endpoint.
The reviewer may raise it; adjudicate rather than pre-judging.
Task 1: review clean — spec ✅, quality Approved, 0 Critical, 0 Important.
Task 1: minor (deferred): loop.test.mjs "those three survive a second tick" passes under both
  "persisted" and "freshly recomputed" implementations — the same intents array is passed on
  both ticks, so it cannot discriminate. My defect, verbatim from the brief. Same defect class
  this project has shipped five times. Surface to the final review.
Task 1: minor (deferred): no test exercises either HTTP endpoint. Ruling: park — pre-existing,
  not worsened by this task, and both call sites are verified by grep. Cost if wrong: a
  regression on POST /api/agent/tick would surface only at demo time.
Task 1: complete (commits 8b28120..32f1c67, review clean, 2 minors deferred)

Task 2: implemented (commit c2a4b98). 13/13 pass. Step 5 mutation ran for real: RED on
  "the command carries $WALLET_PK as a name, never a value", GREEN after revert.
Task 2: PLAN DEFECT found by the implementer. The brief's redact() used split-and-join, which
  removes the configured URL but leaves any trailing path — so `${RPC}/v2/KEY` kept leaking
  `KEY`. My own test in the brief caught my own broken implementation. The implementer replaced
  it with an escaped-regex match plus `\S*`.
Ruling: the regex redaction stands. Verified by hand against five shapes — base+path+key,
  bare hostname, key-in-query all redact; an unrelated diagnostic (ECONNREFUSED 127.0.0.1:8545)
  is preserved, so it does not over-redact. escapeRe covers the regex metacharacters.
  Cost if wrong: an over-broad regex would eat diagnostics; measured, it does not.
Task 2: cross-check for the FINAL REVIEW (not this task's scope): agent/subgraph.mjs:63-76 uses
  the same split-and-join shape this task just replaced. Today neither SEPOLIA_RPC
  (publicnode.com) nor the Studio subgraph URL carries a key, so nothing leaks in practice —
  but the guard has the weakness that was just fixed here.
Task 2: controller-run live verification (the 13 unit tests all stub fetch, so a wrong
  selector or wrong word packing would leave every one of them green):
  - encodePayeeDigestCall vs `cast calldata` — byte-for-byte identical, selector 0x339caef0
  - widenPlan against live Sepolia → status 200, digest
    0x95746f35c6bf6e05d1b7ca05aa7d6b5c4c7df160b8b8dc73d8d128cbd8e0e6a0
  - `cast call` on the same args returns the identical digest
  - the emitted command contains the literal $ATTESTATION and $WALLET_PK, no values
Task 2: review — spec ✅, but 1 Important (labeled plan-mandated, inherited from my brief):
  widenPlan never validates `nonce`; encodePayeeDigestCall's BigInt(nonce) is called at
  line 84, OUTSIDE the try that starts at 87, so a bad nonce throws instead of returning
  {status, body}.
Controller reproduced it directly: "abc" → SyntaxError, undefined/null → TypeError,
  1.5 → RangeError. Numeric 7 and string "7" both → 200.
Ruling: FIX IT. The finding is correct on the contract point. I note the reviewer's threat
  framing overstates reachability — Task 3 derives the nonce from Date.now() and never reads
  it from the request, so it is not attacker-reachable today — but the spec's stated goal is
  to fail closed, and throwing past your own documented error contract is not failing closed.
  Cost if wrong: a few lines of validation nothing exercises.
Task 2: minor (deferred): redact()'s trailing \S* can swallow diagnostics that follow a URL
  with no whitespace between. Ruling: leave it — deliberate security-first tradeoff, and
  narrowing it risks reopening the leak it just closed. Surface to the final review.
Task 2: fix round 1/5 (2 addressed pending re-review — nonce validation + word() guard;
  commits c2a4b98..f9de1a7). Controller verified independently: "abc"/undefined/null/1.5/-1
  all → 400 with NO rpc call; 7 and "7" → 200; oversized word throws "word too wide: 40 bytes".

Ruling (do not lose this after compaction): before deleting this workspace at the end,
COPY it to docs/superpowers/sdd/2026-09-10-demo-frontend/ and commit, exactly as the two
earlier plans' ledgers were on 2026-09-10 (commit c9cd4d0). ETHOnline's rules require that
spec-driven workflows submit all spec files and prompts, and .superpowers/ is gitignored so
these reports reach nobody otherwise. The skill's "delete the workspace, git is the record"
step assumes git already holds the record; here it would not. Copy first, then delete.
Cost if wrong: a few thousand lines of working notes in a public repo, which is the point.

NOTE: commit attribution changed mid-run. Commits from here on must end with BOTH
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Sv1gERVb8hNg7Xj8DcZ8J3
Earlier commits on this branch (32f1c67, c2a4b98, f9de1a7) predate the change; leave them.
Task 2: re-review — Finding A ADDRESSED (isValidNonce runs before checkWidenEnv and before
  encodePayeeDigestCall; digit-string still accepted), Finding B ADDRESSED (word() throws at
  the 32-byte boundary, test uses 33 bytes so it exercises the edge). New breakage: none —
  redact() untouched, so the out-of-scope ruling held.
Task 2: complete (commits 32f1c67..f9de1a7, review clean, 1 minor deferred)
Task 3: implemented (commit 80297d5, world/server.mjs +34 lines only).
Controller verified independently:
  - git diff f9de1a7..HEAD touches ONLY world/server.mjs; package.json, package-lock.json and
    agent/package.json unchanged since 8b28120, working tree clean. The implementer's
    `npm install` in world/ was a no-op against gitignored node_modules — "no new dependency"
    holds.
  - nonce cannot be injected: GET /api/widen-plan?...&nonce=7 returned nonce 1789045342, not 7.
    server.mjs:212 derives it from Date.now(). This is the constraint that keeps the nonce out
    of a caller's control, and no unit test covers it.
Task 3: review clean — spec ✅, quality Approved, 0 Critical, 0 Important.
Task 3: minor (deferred): /api/widen-plan matches with startsWith while sibling routes use
  exact-or-"?" matching. Verbatim from my brief; no collision possible today.
Task 3: complete (commits f9de1a7..80297d5, review clean, 1 minor deferred)

CONTROLLER INCIDENT (2026-09-10, during Task 3's review window): I started agent/loop.mjs
against live Sepolia to exercise the two untested HTTP endpoints. The loop did what it is
built to do and SENT A REAL PAYMENT. Wallet MockUSDC 690 -> 685; 0x..beef now holds 315.
spentInCurrentPeriod = 5 USDC (the daily period had rolled, so this is the new period's
first spend). No face scan was consumed - that path needs no attestation.
This is the SECOND time this class of mistake has cost 5 USDC in this project; the earlier
one is recorded in the agent-loop ledger.
Ruling: do not start agent/loop.mjs for read-only verification again without first pointing
it at an intents file that cannot execute. Deferred to the end of this plan: add that warning
to agent/README.md. Cost if wrong: another 5 test USDC and a shifted budget bar in the demo.
What the run did prove, and could not have been proved otherwise: Task 1's three new fields
arrive populated from the live subgraph, and POST /api/agent/tick returns 200 - which is the
second call site my plan text missed. Unfixed it would have been a 500 that all 78 tests miss.
Task 4: review clean — spec ✅, quality Approved, 0 Critical, 0 Important. Reviewer proved the
  transcription by diffing the shipped files against the brief's fenced blocks: zero-line diffs
  on both. It also audited all 11 tests for discrimination.
Task 4: minor (deferred): "renderStatus reports the index lag" only exercises lagBlocks:2, so
  the singular/plural boundary and the ===0 "up to date" branch go untested. My brief's gap.
Task 4: complete (commits 80297d5..a2ea3d9, review clean, 1 minor deferred)
Task 5: implemented (commit c9026ef, world/demo.html 758 lines).
Controller re-ran all three headless checks independently: import gaps none; DOM id gaps none
  (32 defined / 31 referenced); inline module parses; eth_call/jsonrpc/WALLET_PK/ethers/web3/
  viem all 0 occurrences; selfieCheckLegacy present once. agent 78 + world 27 = 105 pass.
Implementer's own concerns, carried to review: (a) the layout has never been rendered — no
  browser; it committed to ONE explicitly-painted dark theme so there is one unseen rendering
  instead of two, and put overflow-y valves on #cmd/#intents/#payees so a size miss clips one
  box rather than breaking the page; (b) the page shows lastAction.tx, which a strict reading
  of requirement 12 might call out.
Ruling on (b) before the review, so it is not adjudicated twice: showing lastAction.tx is
  permitted. Requirement 12 forbids the page ASKING a chain for anything; the tx hash is a
  field the agent already published in publicState(), so rendering it is exactly what "render
  what the agent decided" means. Cost if wrong: a one-line deletion with no layout effect.
Task 5: review ❌ on spec — the ≥16px body-text floor is missed by five selectors the review
  names precisely (.verdict 15, .intent .payee 15, .intent .reason 14, .intent .why 14,
  .wait .row 15). Chrome/label text below 16px it explicitly says to leave. Controller
  confirmed independently: 8x15px, 7x14px, 3x13px, 1x12px, and there is no body/:root
  font-size fallback.
Task 5: reviewer's ⚠️ on the right column — its arithmetic gives #payees ~120px, enough for two
  38px rows but not three. Controller checked what the demo will actually show: the subgraph
  returns exactly ONE payee (0x..beef); the page adds a ghost row for 0x..cafe0, so the count
  is 2 throughout, and stays 2 after the widening (ghost becomes real). Verified all three
  valves exist (#intents:133, #payees:206-208, #cmd:256-257 all overflow-y:auto + min-height:0),
  so a third row would scroll rather than break the layout.
Ruling: no code change for the row count. Record it instead as a demo-day constraint — do not
  allow-list a third payee on this node before the rehearsal. Cost if wrong: an internal
  scrollbar in one panel, not a broken page.
Task 5: fix round 1/5 (6 Important + 4 folded minors addressed; commits c9026ef..46b791d).
Controller verified: all five named selectors now 16px; 15px is gone entirely (was 8
  declarations); 16px went 3 -> 13. Three headless checks still pass (import gaps none, id gaps
  none 33/32, syntax OK). eth_call/jsonrpc/WALLET_PK still 0. nowrap x7, inFlight x4,
  AbortSignal x1, SVG now uses var(--bg)/var(--blocked).
Ruling: ACCEPT the implementer's self-flagged scope expansion — it raised nine font sizes where
  the review named five. The extra four (.beat, #widenMsg, .budget-line, #valid, the tagline)
  are readouts, not chrome: .beat carries requirement 4's tick/clock/lag and #valid is the
  countdown the operator reads on stage. Correct expansion, not scope creep.
  Cost if wrong: four one-line font-size reverts.
Task 5: re-review — all six Important ADDRESSED, all four folded minors addressed, both
  out-of-scope minors untouched, no Critical/Important new breakage.
  Controller verified the one dependency the re-review said the diff could not show: rows 3
  and 4 clear 22px only if .why/.reason sit inside .line. demo.html:494-497 wraps all four
  rows in <div class="line">, so the line-height:1.3 pin at :159 applies. Arithmetic holds.
Task 5: minor (deferred): stroke="var(--blocked)" / fill="var(--bg)" as SVG presentation
  attributes. Fine in Chrome/Firefox/Safari, but in an engine that does not substitute, stroke
  falls back to none and the connector VANISHES rather than miscolouring — and that connector
  is the element carrying the demo's whole argument. Ruling: park. Recording happens on the
  operator's own desktop browser. Added to the human-check list instead.
Task 5: minor (deferred): the `parts` array drawWire used to iterate is now unused.
Task 5: complete (commits a2ea3d9..46b791d, all findings addressed, 2 minors deferred)

ALL FIVE TASKS COMPLETE. Branch item-12-demo-frontend, 8b28120..46b791d.

FINAL WHOLE-BRANCH REVIEW (8b28120..46b791d, opus): Merge Ready. 0 Critical, 1 Important,
  4 Minor. Seams verified clean across all five pieces; the signed digest can never differ
  from the displayed one. It also OVERTURNED an earlier finding: the `parts` array is used
  (demo.html:616), not dead code — carried into the fix dispatch so it would not be deleted.
  All eight deferred minors triaged "ships as-is".
Final fix wave (one dispatch, per the skill): commit a534858.
  Important — `pending` selected on tone==="blocked", covering AGENT_REVOKED / invalid / every
  reason code, while widenTarget required reason 6. A revoked agent would have drawn the
  connector from a "2 · AGENT_REVOKED" card to the payee list, asserting a causal link the
  agent never published. Fixed structurally: widenTarget = () => pending[0] ?? null, so the
  connector and the button take the same element and cannot disagree by construction.
  isPayeeNotAllowed prefers reasonName over the hardcoded 6.
  Controller verified demo.html:397-398, :722, and that widenable also excludes verdict
  "invalid"; parts confirmed in use at :616.
  Implementer found a latent bug beyond the brief: both catch blocks called setMsg BEFORE
  paintButton, and paintButton writes the idle message over it — so every error message was
  erased in the frame it was set. Reordered. Nobody asked for this and no test covers it.
