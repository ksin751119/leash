# SDD ledger — plan: docs/superpowers/plans/2026-09-11-policyset.md

Spec: docs/superpowers/specs/2026-09-11-policyset-design.md (read, reachable)
Branch: policyset
MERGE_BASE: 660e4f7

Ruling: branch `policyset` in the main checkout rather than a separate worktree — same as
the demo-frontend plan. EnterWorktree's contract forbids using it unprompted and the user
never said "worktree"; a manual worktree costs a Foundry `lib/` re-fetch on a two-day
deadline. Satisfies "never implement on main". Cost if wrong: one merge instead of a
fast-forward.

## Pre-flight conflict scan

### Task pairs sharing a file or an interface

| A | B | A produces | B consumes | Finding |
|---|---|---|---|---|
| T1 | T2 | `MicroPaymentPolicy` | nothing — T2's mocks are self-contained | disjoint, no shared file |
| T1 | T3 | `MicroPaymentPolicy(uint256 cap_)`, `CAP()` | `new MicroPaymentPolicy(CAP)` with `CAP = 1e6` | agree |
| T2 | T3 | `PolicySet(address[][] memory clauses)` | `new PolicySet(clauses)`, `address[][]` built in `setUp` | agree |
| T2 | T3 | `test/mocks/PolicyMocks.sol` | T3 imports none of it | disjoint |
| T1/T2/T3 | deployed contracts | — | T3 imports `StandardPolicy` read-only | no deployed contract is edited |

### Task self-consistency

| Task | Tests vs code | Files created vs later touched | Finding |
|---|---|---|---|
| T1 | 12 tests; `MicroPaymentPolicy.ZeroCap.selector` needs the error declared — it is | creates 2 files, nothing later edits them | agrees |
| T2 | 15 tests; imports 7 mock names | creates 3 files | **two defects, ruled below** |
| T3 | 6 tests; 201 + 12 + 15 + 6 = 234 arithmetic checks out | creates 1 file, modifies `agent/intents.json` | **one defect, ruled below** |

### Defects found, and the rulings

**T2-a — `CountingOK` in the mocks file is never imported by any test.** The plan defines 8
mocks and `test/PolicySet.t.sol` imports 7. Dead code is exactly what the review rubric
flags, and the plan's own comment on it ("use this one only through a direct call") describes
a use no test makes.
Ruling: **omit `CountingOK`.** Short-circuiting is already proved by
`test_a_passing_first_clause_is_enough` without a counter, and a counter would have to write
storage — which `staticcall` forbids, so the mock could never have worked as a spy anyway.
Carried into the T2 dispatch. Cost if wrong: a mock nobody needed.

**T2-b — `GasBurnerPolicy` as written may not compile cleanly.** `while (true) { … }` followed
by `return 0` is unreachable, and `i` is assigned but never read; Solidity warns on both, and
this project treats warnings in test output as findings.
Ruling: the implementer **may reshape any mock's body** so long as the observable behaviour
the test names is unchanged — reverts, returns 33 bytes, returns 256, burns all its gas. The
behaviour is the contract; the body is not. Carried into the T2 dispatch. Cost if wrong: a
mock that proves the same thing by slightly different means.

**T3-a — `test_it_fits_inside_the_account_s_gas_cap` is declared `view` but emits an event.**
`emit log_named_uint(...)` is a state-changing operation and cannot appear in a `view`
function; this will not compile.
Ruling: **drop `view` from that one test.** `set.check()` stays `view`, so nothing about what
is being measured changes. Carried into the T3 dispatch. Cost if wrong: nothing — the
alternative is deleting the measurement, and the gas number is the point of the test.

### Global-constraint contradictions

None. Checked all nine constraints against all three tasks:
- `staticcall` not `call` — only `PolicySet._ask` makes an external call, and it uses
  `staticcall`.
- `check` declared `view` — both contracts' signatures say so.
- Any member anomaly → 12, no fall-through — `_ask` returns 12 and `check` returns it
  immediately without advancing the clause.
- Last clause's reason — `test_when_nothing_passes_the_last_clauses_reason_is_reported`
  asserts both orderings, so a first/last mix-up cannot pass.
- Constructor refuses empty/empty/zero — three tests.
- No setter — neither contract declares one.
- Reason codes frozen — every `Reason.` name used exists in `src/Reason.sol`.
- No deployed contract edited — T3 imports `StandardPolicy` but does not modify it.
- Exact reason numbers — every assertion is `assertEq` against a `Reason.` constant.

## Progress

Task 1: implemented (commit f6d5498). forge test → 213 passed, 0 failed, 1 skipped (201 + 12).
Task 1: PLAN DEFECT (mine). Step 5 says "three tests go RED" and then lists two, naming the
  third as staying green. Self-contradictory. The implementer read it correctly — 2 red,
  1 green — and reported the actual result rather than the predicted count.
Ruling: no action. The mutation did what it was for; only my sentence was wrong, and the
  report records the real numbers. Cost if wrong: none.
Task 1: review — spec ✅, contract correct (reviewer verified the arithmetic independently,
  including by mutation), 1 Important on a TEST not the contract.
Task 1: EIGHTH instance of the recurring defect class, found by the reviewer attacking the
  test rather than the code: test_already_at_the_period_limit..._without_underflowing used
  spentSoFar == periodLimit, so the subtraction yielded 0 and never underflowed. Deleting the
  `spentSoFar >= periodLimit` guard alone left all 12 tests green.
Task 1: fix round 1/5 (1 addressed, 0 open; commits f6d5498..0b8ddf5). New test uses
  periodLimit + 1; mutation makes it panic with arithmetic underflow while the other 12 stay
  green. Controller verified src/MicroPaymentPolicy.sol is byte-identical across the fix —
  only the test file changed — and re-ran the suite: 214 passed, 0 failed, 1 skipped.
Task 1: minor (deferred): test_the_cap_is_readable_and_has_no_setter overpromises — "no
  setter" is a compile-time property, not runtime-testable. Verbatim from my plan.
Ruling: leave it. The getter value it does assert is real, and renaming costs more risk than
  the imprecise name does. Cost if wrong: a test name slightly wider than its assertion.
Task 1: complete (commits 660e4f7..0b8ddf5, review clean, 1 minor deferred)
Task 2: implemented (commit effbe1f). forge test → 229 passed, 0 failed, 1 skipped (214 + 15).
  Both Step 6 mutations run for real: dropping the length check reddened the wrong-length and
  no-code tests; dropping the uint8 clamp reddened the 256 test with the observed return value
  0 (Reason.OK) — the payment would have gone through.
Task 2: implementer reshaped GasBurnerPolicy to `assembly { invalid() }` because neither
  while(true) nor for(;;) suppressed solc's unassigned-return-variable warning. Controller
  verified: the test passes, INVALID consumes the staticcall's own gas allowance and fails,
  so _ask returns 12 — the named behaviour is intact. Within the pre-flight ruling that a
  mock's body may change so long as its behaviour does not.
Task 2: controller-found fact, handed to the reviewer unjudged: `forge lint` went 7 -> 8.
  The new one is src/PolicySet.sol:123 `return uint8(raw);` [unsafe-typecast]. The line above
  it is the `raw > type(uint8).max` guard, so the cast is in fact checked.
Task 2: review — spec ✅, 0 Critical, 0 Important, 5 Minor. The reviewer traced the index
  arithmetic by hand against [[A,B],[C]] and reached the same result the controller did
  independently, and it probed three plausible index mutations to confirm the coverage gap it
  found is not a live risk.
Task 2: minor (deferred): MEMBER_GAS is pinned by NO test. Deleting `{ gas: MEMBER_GAS }`
  leaves the gas-burn test green, because invalid() halts exceptionally on any budget.
Task 2: minor (deferred): the MEMBER_GAS doc comment overclaims. Its real effect is an
  ELIGIBILITY CEILING — any member costing over 60k, including a nested PolicySet, becomes
  POLICY_FAILED even though it works as the account's direct policy. The "runaway member"
  framing is not what the cap does.
Task 2: minor (deferred): "a broken member is reported, never routed around" reads as absolute,
  but an earlier passing clause short-circuits and the broken member is never called.
Task 2: minor (deferred): no check() is run against a multi-member clause in non-first
  position; test_the_shape_is_readable builds that shape but only inspects accessors.
Task 2: minor (deferred): the new unsafe-typecast lint at PolicySet.sol:123 is a false
  positive; the reviewer's view is to leave it unsuppressed so it stays consistent with the
  identical line already accepted in LeashAccount._askPolicy. Controller agrees.
Ruling: carry the FIRST TWO minors into Task 3's scope rather than deferring them to the
  final review. Task 3 is the gas task — it already measures PolicySet.check against the
  account's 200k cap — so pinning MEMBER_GAS and correcting the comment that describes it
  belong there, not in a separate pass. This is scoping the next task from what the review
  taught, not fixing a minor inside the loop. The other three stay deferred.
  Cost if wrong: Task 3 grows by one test and a comment edit.
Task 2: complete (commits 0b8ddf5..effbe1f, review clean — Approved, 0 Critical, 0 Important,
  5 minors of which 2 carried into Task 3 and 3 deferred)
Task 3: implemented (commit 8f3aeed). forge test → 236 passed, 0 failed, 1 skipped; agent 78.
  Measured gas: PolicySet.check on the demo composition, both clauses evaluated = 29,506 —
  15% of the account's 200,000 cap, so MEMBER_GAS needed no change.
Controller verified: only 3 files changed; filtering comment lines out of the src/PolicySet.sol
  diff leaves nothing, so that contract's change really is comment-only. All three intents
  carry 40-hex addresses. The rewritten MEMBER_GAS comment says what was ruled — an
  eligibility ceiling, not a runaway guard.
Task 3: review — spec ✅, Approved, 0 Critical, 0 Important, 2 Minor, 1 ⚠️.
Task 3: ⚠️ RESOLVED by the controller, as required. The reviewer flagged that the MEMBER_GAS
  comment's claim — "enough runaway members exhaust the 200k regardless, and the observable
  result is the same either way" — depends on LeashAccount._askPolicy, outside its scope. It
  was right to refuse to settle text the controller dictated. Both halves verified:
  (a) _askPolicy is `policy.call{gas: POLICY_GAS}` then `if (!ok || ret.length != 32) return
      POLICY_FAILED`. A PolicySet that runs out of gas gives ok == false, so the account
      returns 12 — the identical code a failing member produces. Observable result is the same.
  (b) Under the 63/64 rule from 200,000: members get 60,000 / 60,000 / 60,000 / 19,687 before
      the budget is gone. Four runaway members exhaust it. "Enough" is four.
  The comment stands as written.
Task 3: minor (deferred): setUp() deploys the full demo composition before every test,
  including the MEMBER_GAS test that never touches it.
Task 3: minor (deferred): GasHogPolicy's comment argues its cost empirically; the reviewer
  established the real floor independently — keccak256 is a fixed 42 gas/call and the loop
  runs 2000 of them, so ~84,000 gas from the opcode alone, already above MEMBER_GAS before
  any loop overhead. Worth writing into the comment; not worth a round.
Task 3: complete (commits effbe1f..8f3aeed, review clean, 2 minors deferred)

ALL THREE TASKS COMPLETE. Branch policyset, 660e4f7..8f3aeed.

FINAL WHOLE-BRANCH REVIEW (660e4f7..8f3aeed, opus): 1 CRITICAL, 4 Important, 2 Minor.

CRITICAL — and it refutes a sentence in my own spec. The spec says "Nothing already deployed
changes." That is false: agent/decide.mjs encodes StandardPolicy's rule set. Verified by the
controller against the source:
  decide.mjs:~68  if (!payee || payee.allowed !== true) return blocked(PAYEE_NOT_ALLOWED)
  loop.mjs:197    if (d.verdict === "will-pass") toSend.push(intent)
  decide.mjs:4    "This function is trustworthy when it REFUSES and not when it permits,
                   and that is by design, not a limitation to fix later"
With PolicySet installed, apitopup (0.50 USDC to a payee nobody allow-listed) is judged
will-be-blocked(6) by the agent and NEVER SENT, while the chain would allow it. The third
demo row — the entire argument for OR — never reaches the chain. And decide now refuses
something the chain permits, which inverts the safety direction it states about itself in
its own first comment.
Reviewer's reply on the Critical: agrees, and names the same precedent (the 2026-09-09
Critical where a JS reimplementation of a hashing rule diverged and no test could see it).
Its Assessment: "Needs fixes" — the two contracts are sound in isolation and at the account
seam, and the OR does NOT make the period budget escapable, because the account keeps the
ledger and both members honour `periodLimit` identically.

CONTROLLER FINDING — both proposed fix shapes are WRONG, and I verified it against source
before dispatching. Reviewer and I both said "drop the payee rule to `unknown`". But
`loop.mjs:197` sends only `will-pass`; `unknown` is not sent either. Degrading to `unknown`
would have left `apitopup` exactly as stranded as before while reading as a fix. The trap
here is that the verdict NAME changes and the observable behaviour does not — the same shape
as the eight tests this project has shipped that pass without exercising the property they
name. The fallback must be `pass()`.

Ruling F1 (the Critical): `decide` applies its POLICY-LAYER rules — payee allow-list and
period budget — only when `snapshot.policy.address` equals a configured known
`StandardPolicy`. Anything else: no policy-layer refusal at all, return `pass()` naming the
unknown policy. Account-layer checks (agent revoked, no policy, not approved) stay
unconditional — those are `LeashAccount`'s, not the policy's.
  - The budget rule is gated too, not just the payee rule. Gating one and not the other is
    inconsistent reasoning: `spentSoFar`/`periodLimit` are enforced by the POLICY, and an
    arbitrary policy need not honour them. That both members of today's composition do
    happen to honour them is a fact about this composition, not a licence.
  - `knownPolicy` is a REQUIRED 4th parameter, not one with a default. A defaulted parameter
    would leave every existing call site silently on the old behaviour, which is a fix that
    does not fail closed. Missing/malformed throws; `loop.mjs` already wraps `decide` in
    try/catch → verdict `invalid` → not sent.
  - Cost if wrong: with an unrecognised policy installed the agent sends spends the chain
    then blocks, costing gas. That is the correct direction — `decide`'s refusals were never
    the security boundary (`decide.mjs:4`), the account is.

Ruling F1b — THE DEMO ORDERING, and why the pointer is NOT swapped before the face scan.
I traced the consequence of F1 through the demo and found a second-order break the review
did not reach: `world/demo.html:505` gates the widen button on `verdict === "will-be-blocked"`
— an AGENT-side refusal. If the pointer is on `PolicySet` from the start, `newvendor` becomes
`pass` → sent → the CHAIN blocks it with 6 → the widen button never appears, and the
face-scan beat dies. Worse, `loop.mjs:155-176` routes an intent that already has a tx to
`done`, so after a widening it would never be re-sent: "refused, then paid" would lose "paid".
Re-arming a blocked intent needs change-detection state and a re-send guard — a real loop
change two days before the video, so it is refused.
Ruling: the live demo STARTS on `StandardPolicy` and swaps to `PolicySet` as the FINALE,
after the face-scan beat has completed. Then:
  retainer  → pass → paid                                    (StandardPolicy)
  newvendor → will-be-blocked(6) → widen button → face scan → paid   (StandardPolicy)
  <swap the ENS pointer to PolicySet — the POLICY panel updates live>
  apitopup  → was blocked(6), now `pass` under F1 → sent → chain allows it   (PolicySet)
`apitopup` has never been sent at that point, so it is still in the not-yet-sent branch and
no re-arm machinery is needed. This delivers the spec's demo table AND keeps the face-scan
beat, with no change to `loop.mjs`'s send logic. The ordering is now a rehearsal constraint
and must be written into the demo script. Cost if wrong: the operator swaps too early and
loses the widen button; recoverable by swapping the pointer back.

Ruling F2 (Important — MicroPaymentPolicy ignores ctx.txLimit and the window): FIX IT.
Verified against the live rule on Sepolia before ruling, so the demo cost is known rather
than assumed — `ruleOf(vendors.leash.eth, MOCK_USDC)` = enabled, txLimit 500.000000,
periodLimit 50.000000, period 86400, window 0/0. `apitopup` is 0.50 and the window is open
all day, so honouring both changes no demo row. The principle the exception now states:
**it relaxes exactly one thing, the payee allow-list, and substitutes its own CAP for the
per-tx limit. Every other control the owner set still holds.** That takes the reviewer's
"two of tightenRule's five fields are vacuous" down to zero.
  - `_inWindow` must be duplicated from `StandardPolicy` — that contract is DEPLOYED and
    APPROVED and extracting a shared library would mean redeploying it, which invalidates
    both the approval and the ENS pointer. Verbatim duplication is a review defect, so it is
    paid for with a DIFFERENTIAL FUZZ TEST: on any context where the payee is allowed and
    the amount is within CAP, the two policies must return the identical code. That converts
    a copy nobody can check into a copy a test checks.
Ruling F3 (Important — `PolicySet._ask` never consults `PolicyApprovals`, so revoking a
MEMBER is a no-op): NO CODE CHANGE. Three reasons.
  (a) `PolicyApprovals` approves the address the account POINTS AT. A `PolicySet` is its own
      address with its own approval; its members are immutable constituents of that approved
      artifact, not separately-installed rules. Approving the set IS approving the
      composition — the member list cannot change afterwards.
  (b) A revoked member would surface as `12 POLICY_FAILED`, which means "this policy is
      broken, replace it" and sends the operator somewhere other than where the truth is.
  (c) The brake still exists and is still permissionless: revoke the SET. `revoke` is open to
      anyone precisely so this needs no authority.
  This is an undocumented decision, not a missing check — so it is fixed as documentation
  plus a test that PINS "revoking a member does not disable the set", making the behaviour
  deliberate and visible instead of incidental. Cost if wrong: a second revoke transaction
  per approved composition.
Ruling F4 (Important — `describe()` reads as if the ignored allow-list were a feature): FIX.
  That string is the only human-readable text at approval time and on the demo's POLICY
  panel. It must name the constraint, not advertise the hole.
Ruling F5 (Important — nothing deploys the contracts or updates the docs): SPLIT. The fixer
  does code + tests only; deployment produces the addresses, so `docs/deployments.md` and
  `README.md` are mine to write after the deploy. The user authorised deployment earlier.
Minors (setUp over-deploys; GasHogPolicy's comment argues empirically): ship as-is, per the
  reviewer.
SPEC CORRECTION: "Nothing already deployed changes" (specs/2026-09-11-policyset-design.md
  line 168) is false and is the sentence this Critical came through. It must be corrected in
  the spec, not quietly dropped — the spec is the record of what was believed at design time
  and why it was wrong.

FIX WAVE 1 (one dispatch, complete findings list, per the skill): commits
8f3aeed..6a238c9 — 998d116 (F1), a44af85 (F2), b08c7dc (F3), 6a238c9 (F4).
Status DONE_WITH_CONCERNS. forge 241 passed / 0 failed / 1 skipped (was 236/1);
node 86 passed / 0 failed (was 78).

Controller verified before dispatching the re-review:
  - Both suites re-run here: 241 forge, 86 node. Counts match the report.
  - decide.mjs's fallback IS `pass()`-shaped, not `unknown` — read the diff directly. The
    comment at the return site states why, which is the part a future reader needs.
  - loop.test.mjs:319-324 asserts `toSend.map(i => i.id)` equals `["a"]`, not merely that
    the verdict string changed. And :328-334 is its counterpart: with the KNOWN policy
    installed the same unknown payee is still refused and still not sent. The pair cannot
    both pass if `advance` simply stopped checking — which is the failure mode that would
    have made this test worthless.
  - F2 mutation results reported with specific observed values: window deleted → fuzz fails
    `0 != 9` at run 3; txLimit deleted → fuzz fails `8 != 7`, a PRECEDENCE divergence that a
    both-OK-or-both-not assertion would not have seen. That is the differential test earning
    its keep.

Ruling on concern 1 (commit hygiene): 998d116 also carries docs/architecture.md, the spec
  and script/DeployPolicySet.s.sol under an F1 message. Those are MINE — I wrote them while
  the fixer was running and its `git add -A` swept them up. No rebase: the branch had a
  concurrent writer, nothing is lost or altered, and rewriting history to tidy a message is
  not worth the risk two days out. Recorded here so the mixed commit is explained rather
  than mysterious. Cost if wrong: one commit message that undersells its contents.
Ruling on concern 2 (agent/README.md touched, beyond the brief's file list): correct call by
  the implementer, and I would rather it had. The loop now exits 1 without STANDARD_POLICY,
  and that README's snippet is the operative start command — leaving it stale would have
  handed me a demo that will not boot, discovered at rehearsal.
Ruling on concern 3 (`advance` takes knownPolicy as a 5th parameter rather than reading the
  module-level STANDARD_POLICY): correct, and for the reason given — the call site is inside
  the file's pure half, which 25 tests exercise without starting the loop; reading module
  state there would have turned every one of them into `invalid`. It also keeps `advance` a
  total function of its arguments, which is the same property `publicState(s)` was changed to
  have.
Ruling on concern 4 (the gate keys on an ADDRESS, so a redeployed StandardPolicy silently
  switches the policy layer off, with no alarm beyond the `explain` text): accept, no change.
  The direction is the safe one — the agent stops predicting and defers to the chain, and its
  refusals were never the security boundary (decide.mjs:4); the account is. An alarm would
  mean the agent deciding it knows better than the installed policy, which is the mistake
  this whole finding was about. The `explain` string is surfaced by `publicState` and shown
  on the demo page, so it is visible where it matters. Cost if wrong: a redeploy of
  StandardPolicy costs gas on refused sends until STANDARD_POLICY is updated.

Controller's own work during the wave, committed inside 998d116:
  - docs/architecture.md: corrected a stale claim. It said WorldAttester "is not deployed"
    and "nothing about World ID is enforced onchain yet". Verified against Sepolia:
    LeashAccount.ATTESTER() == 0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26 (WorldAttester,
    3535 bytes of code), so the face-scan beat IS gated by a real Selfie Check. But
    PolicyApprovals.attester() == 0x268990a91B0727E80d38d5ED4Ab10d8889754124 (MockAttester),
    so approving a POLICY is not human-gated. Both halves are now written down, including
    that the field is immutable so loading it means a fresh PolicyApprovals and re-approving
    everything. The asymmetry is stated rather than fixed.
  - specs/2026-09-11-policyset-design.md: the refuted sentence is corrected IN PLACE with a
    dated note, not deleted. The spec is the record of what was believed at design time and
    why it was wrong; deleting the sentence would delete the lesson, which is that "nothing
    already deployed changes" is a claim about CONTRACTS and was used as a claim about the
    SYSTEM — the offchain half had absorbed a copy of the onchain rules.
  - script/DeployPolicySet.s.sol: deploys MicroPaymentPolicy(1_000_000) and the two-clause
    set, and stops. It does NOT approve and does NOT setPolicy, because neither is ADMIN's to
    do — approve needs a face scan, and the pointer move is the demo finale per F1b. No
    WALLET_PK. Compiles.

Re-review dispatched (opus, scoped to 8f3aeed..6a238c9 + the four findings), with
script/DeployPolicySet.s.sol explicitly in scope on the grounds that an error in it costs
real money on Sepolia.

SCOPED RE-REVIEW (8f3aeed..6a238c9, opus): ALL FOUR FINDINGS ADDRESSED, no new Critical or
Important breakage in the fix diff.
  - It verified the Critical the way it needed verifying: loop.test.mjs:317 asserts `toSend`,
    and loop.mjs:202 is the only path into `toSend`, so an `unknown` fallback fails that
    assertion directly rather than merely changing a string. The counterpart at :328 rules
    out the test passing because `advance` stopped checking anything.
  - It did NOT take the F2 mutation report on trust. It recomputed the counterexample by
    hand: args=[27599, 44297, 0] → bound(44297,0,1439) = 0 + ((44297-1439) % 1440) - 1 =
    1097, windowEnd 0, so start > end (crosses midnight); nowTs 27599 → minute-of-day 459,
    neither >= 1097 nor < 0 → 9 from StandardPolicy against 0 from the mutated
    MicroPaymentPolicy. That is the reported `0 != 9`, arrived at independently.
  - It checked the fuzz BOUNDS, which is where this class of test usually dies: nowTs,
    txLimit, periodLimit and spentSoFar are unbounded, so both new checks can fire. A test
    whose bounds forbid the new checks from firing would have proved nothing.
  - _inWindow verified byte-identical to StandardPolicy's by extracting both bodies and
    diffing them, and src/StandardPolicy.sol confirmed absent from the diff's file list.
  - script/DeployPolicySet.s.sol reviewed on its merits as asked. Clause ordering correct
    (clause 0 = micro, clause 1 = standard → newvendor reports the LAST clause's 6, which is
    what the widen button requires). CAP correct: it confirmed 6 decimals from onchain
    CALLDATA in docs/deployments.md:288 rather than from a comment.

CONTROLLER CORRECTION ACCEPTED BY THE REVIEWER. It first classified the re-send loop as
breakage this fix introduced. I disputed it and asked it to check me rather than agree. It
withdrew: the loop is PRE-EXISTING. decide's pass() explain at decide.mjs:46-53 has always
named the five unindexed reasons, so a paused wallet or an over-txLimit intent was already
sent, blocked, and re-predicted will-pass every tick at 8f3aeed. What this branch does is
widen the reasons that reach it from {5,7,9,10,11,12} to include 6 and 8. Recorded as a
pre-existing defect this branch makes more reachable — the fix is not credited with creating
it. Verified independently by the controller against loop.mjs:158-179 before disputing.

Ruling: FIX IT ANYWAY, in one scoped extra round (fix wave 2, dispatched to the same
implementer). This is me extending the loop past the skill's one-wave-one-re-review shape,
deliberately and for a stated reason: the defect submits real transactions without bound, and
in front of a judge a blocked intent would fill the page with a transaction every five
seconds. Pre-existing is a reason not to blame the fix, not a reason to ship it.

Design ruled: LATCH ON AN INPUT FINGERPRINT, not a retry counter. I proposed a counter and
the re-reviewer found three holes in it, all of which I accept:
  (a) it latches the face-scan beat OFF. Under PolicySet the reason-6 refusal is no longer
      predicted, so newvendor is chain-blocked and a 3-strike counter trips in ~15s; the
      face scan lands later, the payee becomes allowed, but the REASON never changed across
      those three blocks, so a reason-keyed reset never fires and the intent stays dead.
      My setPolicy-last ordering avoids this, but that makes the guard depend on the demo
      choreography rather than the other way round — the reviewer's phrasing, and it is the
      right objection.
  (b) alternating reasons (a budget oscillating near its boundary) reset a reason-keyed
      counter forever.
  (c) "reset on a successful send" is dead code: an executed intent is already terminal at
      loop.mjs:158-163.
  The fingerprint keys the re-arm on the INPUTS changing — the payee's allowed flag, the
  budget row, the policy address — which is the set of things that can actually make a
  blocked payment succeed. It has no arbitrary N, no alternation hole, and it fixes the
  pre-existing {5,7,9,10,11} cases too. Cost if wrong: a blocked intent needs an agent
  restart to retry, which the explain string is required to say.

Ruling: no new verdict string. world/demo.html styles verdicts by value, so an unrecognised
one renders unstyled in front of judges. The latch changes only `explain`.

Re-review's two remaining Minors, both in script/DeployPolicySet.s.sol: the STANDARD_POLICY
dependency is undocumented and there is no .env in /home/ubuntu/DEV/leash for foundry to
auto-load, so the variable must be passed explicitly at deploy time. Controller's, handled at
deploy.

Out-of-scope observation carried forward, and it is now LOAD-BEARING rather than stylistic:
world/demo.html:500-519 gates the widen button on the AGENT's prediction (`verdict ===
"will-be-blocked"` plus reason 6), so once the pointer moves to PolicySet that verdict cannot
occur and the button is permanently dark. The setPolicy-last ordering (ruling F1b) is the
mitigation. Written into the deploy script's NatSpec so it travels with the thing that would
break it. Also: docs/superpowers/plans/2026-09-11-policyset.md:228 still carries the old
describe() string — historical, harmless, left alone.

Controller fixed the operative-env Minor directly: STANDARD_POLICY added at
/home/ubuntu/DEV/ETHOnline2026/.env:42. Without it the agent exits 1 at loop.mjs:404-408 and
the demo would not have booted — found by the reviewer, not by me.

FIX WAVE 2 (commit ce9a942): the input-fingerprint latch. node 94 passed (was 86); forge
241/1 unchanged, no Solidity touched. Staged by name, so the wave-1 sweep did not repeat.
  Mutation (`sentFingerprint: null` added to the rec rebuild): THREE tests red, not one —
  the latch test, the survives-the-rebuild test, and the failed-read test. Reverted, green.

NINTH INSTANCE of the recurring defect class, and the worst one yet, because this one was
LOAD-BEARING. agent/loop.test.mjs:46 was named "a blocked intent stays eligible, so the agent
retries after a widening". Its body sent the intent, marked it blocked, re-ran advance with
an IDENTICAL snapshot, and asserted it was queued again. It never widened anything. So it was
not merely a test that proved nothing — it was **the defect written as an assertion**, which
would have failed any correct fix and argued for reverting it. The previous eight instances
were tests that passed vacuously; this is the first that actively defended a bug.
Ruling: replaced, not deleted, with a latch test plus a real widening test that asserts on
`toSend`. The implementer flagged the meaning change rather than editing quietly, which is
the behaviour that made this visible at all. Comment left at the site recording what the old
test claimed. Cost if wrong: none — the old assertion is preserved in the comment and in git.

FIX WAVE 2b, ruled on the implementer's two concerns, both FOR:
Ruling (concern 1, the period-rollover hole): implement the seventh fingerprint field and
  take the signature change to inputFingerprint(snapshot, intent, nowSec). The implementer's
  own reasoning decides it: the fingerprint's contract is "the facts decide reads", and
  decide reads the clock at `rolledOver = periodEnd > 0 && periodEnd <= nowSec`. Omitting an
  input decide reads makes the fingerprint incomplete BY ITS OWN DEFINITION. That the live
  86400s period puts it out of reach of a four-minute recording is a reason it is not urgent,
  not a reason it is correct. `rolled` flips once per period, not once per tick, so it cannot
  cause churn. Cost if wrong: one more field in a string.
Ruling (concern 2, `no-event` reaches no terminal branch): fold it into the latch. The
  implementer called its reachability "a LeashAccount question"; I traced it and it is more
  reachable than that. `no-event` is a status-1 receipt with neither SpendExecuted nor
  SpendBlocked from the wallet, and **an EIP-7702 delegation that is gone produces exactly
  that** — spend() calldata sent to an EOA with no code succeeds and emits nothing. That is
  the precise state LeashLens was built to detect, so it is designed-for, not hypothetical.
  Today it resubmits every tick forever while showing the operator nothing. Latching is also
  the safe reading for a second reason: `no-event` means "sent, outcome unknown", and
  resending an unknown-outcome payment risks paying twice — the same hazard the `unconfirmed`
  branch at loop.mjs:164-174 already exists to prevent. Its explain string must differ from
  the blocked case, because the operator's next move differs: look the transaction up, and
  check whether the leash is still on the wallet.
Ruling (concern 3, the fingerprint covers snapshot facts only and assumes intent fields are
  immutable): accept, no change. AGENT_INTENTS is read once at startup and nothing hot-reloads
  intents.json. The implementer's comment at the site is the right weight of response.
