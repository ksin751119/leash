# SDD ledger — plan: docs/superpowers/plans/2026-09-09-world-attester.md

Spec: docs/superpowers/specs/2026-09-09-world-attester-design.md (read; binding authority)
Worktree: .worktrees/world-attester on branch world-attester, from fee6fce
Baseline: forge build clean, 170 passed / 1 skipped

## Pre-flight conflict scan

Pairs sharing a file or an interface:

| Tasks | Produces vs consumes | Finding |
|---|---|---|
| 1 → 3 | `WorldAttester(address)` ctor, `attestationHash(bytes32,uint64) view` | agree |
| 1 → 4 | `attestationHash(bytes32,uint64)`; the four EIP-712 constants | agree — T4's attest.mjs uses the same four strings verbatim |
| 1 → 5 | `SIGNER()` getter from `address public immutable SIGNER` | agree |
| 2 → 3 | `ruleDigest(bytes32,address,TokenRule calldata,uint256)` called externally with a `memory` struct | agree — verified `public` + `calldata` struct param compiles under 0.8.28 in a throwaway project |
| 4 → 5 | `WORLD_ATTESTER` env var written in T5 Step 3, read by crosscheck.mjs | **CONFLICT (B)** — see rulings |
| files | LeashAccount.sol only T2; server.mjs only T4; README/deployments only T5 | no two tasks write one file |

Each task against itself:

| Task | Finding |
|---|---|
| 1 | **DEFECT (A)** — `test_attestationHash_matches_a_recorded_value` records no value; it asserts determinism and non-zero, which the rubric treats as a test that asserts nothing. Mutation table otherwise consistent: signing the raw digest fails both named tests. |
| 2 | agrees — the two hardcoded TYPEHASH strings match src/LeashAccount.sol byte for byte (checked) |
| 3 | agrees — traced `tightenRule` against `_isTighter` by hand: period 0==0, `_lteOrUnlimited(100, 0)` true (old unlimited), `_windowIsSubset(0,0,0,0)` true. `onlySelf` calls work under `startPrank(wallet)` because `address(this)` is the EOA. |
| 4 | **DEFECTS (C, D)** — `u256` used a regex to pad odd-length hex; a mid-file `import` |
| 5 | agrees — Step 6 records the hashes Step 7 documents |

## Rulings

Ruling A: replaced the assert-nothing test with `test_attestationHash_depends_on_both_inputs`, asserting the hash changes with the deadline and with the digest — real behaviour, and it stops the two swap tests above from passing for the wrong reason. The encoding's anchor stays Task 4 Step 5's comparison against a locally-deployed copy. Cost if wrong: a self-consistently wrong Solidity encoding is caught at Task 4 instead of Task 1. Accepted, because a pasted constant can be computed the same wrong way twice and agree with itself.

Ruling B: `crosscheck.mjs` now reads the chain id via `eth_chainId` instead of hardcoding 11155111, and Task 4 Step 5 runs the script itself rather than an inline variant. The EIP-712 domain binds chainId, so a hardcoded Sepolia value would have made the local anvil check compare two different domains and always mismatch — the workaround in the original Step 5 hid that rather than fixing it. Cost if wrong: none material.

Ruling C: `u256` is now `Buffer.from(BigInt(n).toString(16).padStart(64, "0"), "hex")` — padStart(64) guarantees both even length and exactly 32 bytes. Cost if wrong: a malformed chainId word, which the cross-check catches immediately.

Ruling D: moved `crosscheck.mjs`'s `keccak_256` import to the top. Cosmetic; ES imports hoist either way.

## Progress

Task 1: dispatched (BASE 5925343) — implementer t1-worldattester on sonnet.
  Model note: the brief carries complete code, which the skill puts at the cheapest tier,
  but the task ends with three edit/verify/revert mutation cycles on a security contract
  and a missed revert commits a mutated guard. Stepped up one tier for that reason alone.

Task 1: implementer reported DONE_WITH_CONCERNS (2d38ac5, 185 passed / 1 skipped).
  Concern was correct and well-diagnosed: my brief's mutation table named
  test_a_deadline_swapped_after_signing_fails as failing under "replace
  attestationHash(digest, deadline) with digest". It does not — that mutation destroys the
  typehash, domain and deadline together, so recovery lands on a random address and the
  test's assertFalse holds trivially. The implementer did not bend the test or the contract
  to match my table, and said so.

  Ruling: the test is sound; the plan specified too coarse a mutation to validate it. The
  mutation that isolates "deadline is inside the signed struct" keeps the EIP-712 wrapper
  and drops only deadline from structHash — then both sides compute the same deadline-free
  hash, the happy path still passes, and the swap test is the only thing that can catch it.
  Plan's table split into two rows accordingly, and the implementer is resumed to run the
  narrow mutation before review. Cost if wrong: none to the code; if the narrow mutation
  also leaves that test green, the test IS vacuous and has to be rewritten, which is why it
  is being run before review rather than parked.

Task 1: narrow mutation run — test_a_deadline_swapped_after_signing_fails went RED, plus
  test_attestationHash_depends_on_both_inputs failed independently; happy path stayed
  green. The test is sound, not vacuous. Ruling above stands; no code or test change.
  Revert confirmed byte-identical against backup; tree clean at 2d38ac5.
Task 1: task review dispatched (t1-review, opus) over 5925343..e45287a.
  Model note: opus rather than a mid tier. This contract decides whether a widening is
  authorised — a missed defect here is the worst outcome available in this plan — and the
  diff is signature verification plus EIP-712 encoding plus a never-revert property, which
  is the "subtle" case the skill reserves a capable model for.
  The dispatch tells the reviewer that the brief it reads carries the wrong mutation row,
  gives it my ruling, and invites disagreement rather than hiding the correction.

Task 1: review returned ✅ spec compliant, Critical 0, Important 0, Minor 4 (one bullet
  truncated in transit; tail requested). Reviewer independently agreed with the mutation
  ruling and derived the reason itself.

  Three ⚠️ cannot-verify items, all resolved by me:
   1. prague + baseline — foundry.toml:9 confirms prague; I verified 170 passed / 1 skipped
      in this worktree at setup, before Task 1.
   2. Replay inside the deadline window — resolved and it is the design working. Consumer
      LeashAccount._consumeAttestation:505-507 checks attestationUsed[d] BEFORE calling
      verify and marks it permanently after, so a digest is single-use for good, not merely
      within the window. This is exactly why verify can be `view`: replay protection lives
      where state can be written. Task 3 pins it with test_the_same_attestation_twice_reverts.
   3. Real-signer deployment — Task 5, not this diff.

  Ruling: elevating the fuzz finding from Minor to Important.
   testFuzz_verify_never_reverts(bytes32, bytes calldata) lands on length 73 essentially
   never, so ~all 256 runs exit at the length gate and tryRecover is fuzzed by nothing. The
   rubric puts "tests that assert nothing" at Important, and a test named for a never-revert
   property that cannot reach the code capable of reverting asserts far less than its name
   claims. It is plan-mandated — I wrote it — and authorship does not grade its own work.
   The property does hold structurally (the reviewer established that by reading the code),
   so nothing is broken today; what is broken is the test that is supposed to keep it true.
   Cost if wrong: one extra fuzz test, which is strictly better regardless of the grading.
   Folding in the one-word `view` fix for pristine test output, same file, same concern.

Task 1: review tail — Task quality APPROVED. Reviewer confirmed the fuzz elevation is
  "not an over-reaction", and gave a better reason than mine: the property holds
  structurally today, so the weak test costs nothing now, but "the day someone adds
  decoding after the gate, that test is the one everyone will believe is guarding it, and
  it will not be." Ruling stands; that framing is the one to keep.

  attestationHash being `public` — resolved, no action. Costs a selector and a little
  bytecode; no state, no writes, no new surface.

>>> CARRY FORWARD TO TASK 4 <<<
  New ⚠️ from the reviewer, and it is the sharpest thing in the review: because every test
  helper in Task 1 signs `att.attestationHash(...)`, NO test in Task 1 can catch a
  self-consistently wrong encoding — both sides would be wrong the same way and agree.
  Task 4 Step 5 is the only anchor, and it only works if the JS is a genuinely INDEPENDENT
  implementation. If Task 4's implementer "simplifies" attest.mjs by fetching the hash from
  the contract via eth_call, the cross-check compares the contract against itself and the
  whole check silently collapses to nothing. Name this risk in Task 4's dispatch explicitly.

Task 1: minor (deferred): describe() hardcodes rp_ef35d4e2d4f1a031 with nothing binding it
  to SIGNER; if the RP app changes the string silently lies. Cosmetic, plan-mandated, and
  changing SIGNER means redeploying anyway so the string ships with it.
Task 1: fix round 1 dispatched (FIX_BASE e45287a) — the shape-preserving fuzz plus the
  state-mutability warning. Resumed the original implementer per rounds 1-3.
Task 1: fix round 1/5 — implementer a4aea3b (16/16, zero warnings after forge clean,
  186 passed / 1 skipped, contract untouched, no disagreement with either finding).
  Scoped re-review dispatched (t1-rereview, haiku) over e45287a..a4aea3b.
  Told it the two ways this fix could fail quietly: a stray un-reverted mutation hunk in
  src/WorldAttester.sol (the implementer ran three mutation experiments on that file
  earlier), and a wrongly-typed fuzz parameter making abi.encodePacked produce something
  other than 73 bytes — which would reproduce the exact defect the test was added to fix.
Task 1: fix round 1/5 (2 addressed, 0 open; commits e45287a..a4aea3b)
Task 1: complete (commits 5925343..a4aea3b, review clean)
  Re-review confirmed both named risks clear: src/WorldAttester.sol untouched by the fix,
  and the new fuzz's abi.encodePacked(uint64, bytes32, bytes32, uint8) is exactly 73 bytes
  so arbitrary r/s/v reach tryRecover on every run.

Task 2: dispatched (BASE a4aea3b) — implementer t2-digests on sonnet.
  Model note: the brief carries complete code, which the skill puts at the cheapest tier,
  but this task's three mutations edit src/LeashAccount.sol — and unlike Task 1, a stray
  un-reverted mutation here would be INVISIBLE to the existing 170 tests, because nothing
  existing calls ruleDigest or restoreDigest. Task 3 would eventually fail on it, loudly
  but a task later. Stepped up one tier for that reason.
Task 2: implementer reported DONE (d767443, 190 passed / 1 skipped, pristine-copy diff
  confirmed only the two new functions, no storage). Three mutations each failed exactly
  the named test and were reverted.

  Ruling: the implementer is right that the brief's expected count was stale, and the cause
  is my arithmetic, not merged work. I computed each task's total from the 170 pre-plan
  baseline without accumulating the earlier tasks' new tests. Task 1 added 16 (15 plus one
  from its fix round), so Task 2 lands at 190, not 174; Task 3 lands at 196, not 180. Both
  numbers corrected in the plan, and the Global Constraints line now says explicitly that
  170 is the pre-plan baseline and not a per-task target, so the next reader does not repeat
  the mistake. Cost if wrong: an implementer or reviewer chasing a phantom regression — which
  is exactly what this implementer correctly refused to do.
  Local check while Task 2's review ran: this worktree has no world/node_modules (fresh
  checkout), so nothing in world/ runs until Task 4 Step 1 installs. Step 1 now says so and
  gives a one-liner to confirm @noble/hashes resolves, so the implementer does not read
  ERR_MODULE_NOT_FOUND as a defect in its own code. Not a plan conflict — a gap.

  Ruling: Task 1's carry-forward is now IN THE PLAN, not just in my dispatch notes. The
  reviewer's point was that every Solidity test signs whatever att.attestationHash()
  returned, so a self-consistently wrong encoding is invisible to all of them; attest.mjs's
  independent JS reimplementation is the only anchor. The brief computed the hash in JS but
  never forbade the shortcut, so an implementer "simplifying" it to an eth_call would
  collapse the cross-check into comparing the contract with itself and every step would
  still pass. Task 4 Step 2 now carries an explicit prohibition. Cost if wrong: none - it
  documents an invariant the code already satisfies.
Task 2: complete (commits a4aea3b..d767443, review clean)
  Reviewer verified both getters byte-for-byte against their setRule/restoreAgent consumers
  in the source outside the diff, confirmed the src/LeashAccount.sol hunk is confined to the
  two functions with no LeashStorage change anywhere, and confirmed the test reconstructs the
  EIP-712 digest with its own local TYPEHASH constants rather than comparing the getter to
  itself. Spec compliance yes, task quality Approved, Critical 0, Important 0.
  I independently ran the suite at HEAD: 190 passed / 1 skipped / 0 failed, matching the
  implementer's report exactly (WorldAttesterTest 16, LeashAccountDigestsTest 4).

  Ruling on the one Minor (test file inlines its own Approvals mock instead of importing a
  shared helper - the reviewer could not see outside the diff to check): no change. There is
  no shared approvals mock to import. All six IPolicyApprovals mocks in the suite are defined
  inline in their own .t.sol (LeashAccountSpend, LeashAccountBinding, LeashResolver,
  LeashAccountRules, LeashAccountDigests), and test/mocks/ holds only tokens, a registry and
  policies. Inline-per-file IS the established pattern here, so extracting one would make
  this file the odd one out. Cost if wrong: one duplicated four-line mock.

Task 3: dispatched (BASE 9b9179c) — implementer t3-integration on sonnet.
  Model note: the brief carries the complete test code, which the skill puts at the cheapest
  tier, but these are 7702 integration tests against a real attester - a failure here is as
  likely to be a genuine contract-behaviour surprise needing judgment as a transcription slip.
  Mid tier for the debugging, not for the typing.

  Pre-flight for Task 4, checked and CLEAR (I expected a defect and there is none). I thought
  `npm i @noble/curves@2` would break the existing `import { keccak_256 } from
  "@noble/hashes/sha3"` at world/server.mjs:14, because curves 2.4.0 pins @noble/hashes to
  EXACTLY 2.4.0 while package.json asks for ^1.5.0, and 2.x changed its subpath exports.
  Tested it in a throwaway copy instead of asserting it: npm NESTS hashes 2.4.0 under
  node_modules/@noble/curves/ and leaves top-level at 1.8.0, so both "@noble/hashes/sha3" and
  "@noble/hashes/sha3.js" resolve and work. keccak256("") came back 0xc5d2...a470, consistent
  with the world/README signal_hash("") baseline under the >>8 relation. No plan change.
  Recorded because the two import forms now differ between server.mjs (no extension) and the
  Task 4 files (with extension) - both correct, and NOT to be "unified" by anyone later:
  attest.mjs must keep resolving to a hashes build whose subpath it actually exports.

Task 3: implementer reported DONE_WITH_CONCERNS (f135c1d, 196 passed / 1 skipped / 0 failed,
  matching the corrected prediction exactly).

  Ruling on concern 1 - the brief's own test code was wrong, and the implementer was right to
  fix it. `_sign` makes a real staticcall to att.attestationHash, so `_sign(...)` written
  inline as a call argument fires AFTER vm.prank / vm.expectRevert and spends the single-shot
  cheatcode on that staticcall; the widening then arrives from the test contract instead of
  `wallet` and the test dies with NotSelf(), which reads as an access-control bug in src/ and
  is not one. I reproduced it rather than accepting the diagnosis: reverted one test to the
  brief's inline form and got exactly [FAIL: NotSelf()]. Three of six tests were affected;
  the reduction test survives only because startPrank is not single-shot. Plan synced to the
  committed file in a6dc608 with a warning naming the symptom. Cost if wrong: none, the fix
  changes no test name, constant or assertion.

  Ruling on concern 2 - the implementer was blocked by its session's permission classifier
  from mutating src/, which is consistent with my own dispatch telling it not to touch src/.
  It did not route around the block and src/ is verified unchanged. I ran both candidate
  mutations myself, as I did for Tasks 1 and 2:
    Mutation B (drop `if (block.timestamp > deadline) return false;` from WorldAttester):
      3 RED - Task 1's test_an_expired_deadline_fails and test_the_deadline_is_inclusive, AND
      Task 3's test_allowPayee_with_an_expired_signature_reverts. So the deadline demonstrably
      reaches the consumer and is not merely checked inside the attester.
    Mutation A (swap token and payee inside allowPayee's own abi.encode, desynchronising it
      from payeeDigest): 3 RED, ALL of them Task 3's - allowPayee_with_a_real_signature,
      the_same_attestation_twice, every_reduction_is_still_free. All 190 pre-existing tests
      PASSED, because MockAttester returns true regardless of the digest.
  Mutation A is the whole justification for this task existing: a digest desync between a
  widening entry point and its public getter is invisible to the entire pre-plan suite and is
  caught only here. Both mutations reverted; src/ verified byte-identical to HEAD and the
  suite back to 196 passed / 1 skipped / 0 failed.

Task 3: review dispatched over 9b9179c..a6dc608 — t3-review on sonnet, five named risks.

Task 3: review returned spec ✅, task quality Approved, Critical 0, Important 1.

  Ruling on the Important (4 of 6 tests would also pass against an always-true MockAttester,
  so the file's "real signature verification" framing exceeds its content): PARTLY ACCEPTED,
  and the reviewer's criterion is the wrong one. "Would this test still pass if the attester
  were always-true?" measures whether a test's ASSERTION depends on the attester. It does not
  measure what matters here - whether the test DETECTS defects the mock-based suite cannot.
  My Mutation A settles that empirically: test_allowPayee_with_a_real_signature_succeeds is
  precisely the test that catches a digest desync between allowPayee and payeeDigest, and all
  190 mock-based tests missed it. A happy-path test against a REAL verifier is a conformance
  test - it passes only if the whole encoding chain agrees end to end - and swapping in an
  always-true mock is what makes it vacuous, which is the reviewer's own observation pointing
  the opposite way from its conclusion.
  What survives of the finding is narrower and real: nothing at the INTEGRATION level rejects
  a validly-shaped blob signed by the wrong key. Task 1's test_a_different_signer_fails covers
  it at the unit level and the expired test proves the false-return-to-revert wiring, so no
  realistic mutation is caught ONLY by an integration wrong-signer test - I checked each
  candidate (ignoring verify's return, verifying a constant digest) and each is already caught.
  So it buys documentation, not detection. Adding it anyway, because this file is the one a
  judge reads to see the claim demonstrated, and 6 lines is cheap for that. Dispatched as fix
  round 1/5 to t3-integration. Cost if wrong: one redundant test.

  MY OWN PROCESS ERROR, recorded because it degraded this review. I ran the two src/ mutations
  in the SAME worktree while t3-review was reading it. The reviewer saw a live, changing
  uncommitted edit to src/LeashAccount.sol mid-review, correctly refused to run `forge test`
  because results would reflect my edit rather than a6dc608, and fell back to static
  verification via `git show`. Its conclusions held up, but I took away its most direct
  instrument and it had to flag the worktree as possibly unsafely shared. Correction for the
  rest of this plan: no src/ mutation while a review is in flight - either serialise it before
  dispatching the reviewer, or run it in a throwaway clone. Cost of the error as it stands:
  one review conducted statically instead of dynamically.

  Pre-flight for Task 4, DEFECT FOUND and fixed. Step 5's local cross-check said `cd
  ~/DEV/leash`, which is the MAIN checkout - it sits on `main`, where src/WorldAttester.sol
  does not exist (verified: `ls` fails there). `forge create` would have died with a
  source-file-not-found error that reads as a Foundry problem and is really a
  wrong-directory problem, in the one step whose whole purpose is catching an encoding
  mismatch. Replaced with `cd "$(git rev-parse --show-toplevel)"`, which resolves to this
  branch's own checkout in a linked worktree, plus a warning naming the symptom. Also noted
  in the plan that the private key in that step is anvil's published account #0 test key,
  holding nothing on any real network, so nobody substitutes a real one. anvil 1.7.1 is
  installed, so the step is otherwise unblocked. Cost if wrong: none.
Task 3: fix round 1/5 (1 addressed, 0 open; commits a6dc608..acf6b33)
  Implementer added test_a_blob_signed_by_the_wrong_key_is_rejected, parameterising _sign into
  _signWith(pk, digest, deadline) so WRONG_PK = 0xBAD can sign without touching any existing
  test. Its -vvvv trace shows ecrecover returning a non-SIGNER address, verify returning false,
  and allowPayee reverting NotAttested() specifically rather than merely reverting.
  197 passed / 1 skipped / 0 failed; forge fmt clean.
  I also re-synced the plan's embedded copy of the test file (the fix made a6dc608's
  byte-identity claim stale) and corrected the expected total 196 -> 197. A stale embedded
  copy is worse than none: a later reader seeing a difference cannot tell which side is
  authoritative.
  Note on commit ordering: my docs commit 592fc0e and the implementer's 9004885 were created
  concurrently. History is linear (verified: no merges in the range) and the tree is clean,
  so no recovery needed - but this is the second consequence of working in the same worktree
  as a live subagent, after the review-time hazard above.
Task 3: scoped re-review dispatched over a6dc608..acf6b33 — t3-rereview on haiku, five checks,
  the load-bearing ones being that the new test pins the NotAttested selector rather than any
  revert, and that no pre-existing test's call site was silently switched to WRONG_PK.
Task 3: complete (commits 9b9179c..acf6b33, fix round 1 re-review clean)
  All five scoped checks passed: the new test pins LeashAccount.NotAttested.selector rather
  than any revert, the blob is precomputed before the cheatcode, _sign still delegates to
  _signWith(SIGNER_PK, ...) with no existing call site switched to WRONG_PK, src/ diff empty,
  and the plan's embedded copy is byte-identical at 6829 bytes. 197 passed / 1 skipped.

  Pre-flight for Task 4, SERIOUS DEFECT FOUND and fixed. crosscheck.mjs's signature check
  was commented "prove a signature made here recovers to the expected signer, which catches
  the recovery-byte ordering" while the code only measured the blob's LENGTH. A blob with
  @noble's [recovery ‖ r ‖ s] mistakenly packed as r ‖ s ‖ v is still exactly 73 bytes, so
  the check could not detect the bug it was written for - and the recovery-byte ordering is
  one of the two silent-failure modes this whole script exists to catch. The comment promised
  a guarantee the code did not deliver, which is worse than no check: Step 5 would have
  printed "all cross-checks agree" over a broken blob and Task 5 would have deployed it.
  Fixed to eth_call verify(bytes32,bytes) and assert it returns true, which exercises the
  hash, the packing, the recovery byte and the signer match in one go. I validated my own
  hand-rolled ABI encoding rather than shipping it unchecked: selector 0x258ae582 and the
  full calldata are byte-identical to `cast calldata "verify(bytes32,bytes)" ...`. I also
  caught that my new code called `strip`, which attest.mjs keeps private and crosscheck.mjs
  never imported - it would have thrown ReferenceError - and defined it locally.
  Restructured Step 5 so it needs NO real secret: the anvil attester now deploys with anvil
  account #0 (0xf39Fd6e5...92266, verified to derive from the published test key) as SIGNER,
  and crosscheck reads SIGNER_PK rather than WORLD_RP_SIGNER_PK. server.mjs still uses
  WORLD_RP_SIGNER_PK for the real endpoint; the local cross-check must never touch it.
  Expected output updated from four ok lines to six. Cost if wrong: Step 5 fails loudly on a
  throwaway chain, which is the whole point of the step.

Task 4: dispatched (BASE 666bf17) — implementer t4-attest on sonnet.
  Model note: the brief carries complete code for all three files, but this task is
  multi-file with real crypto interop and a live cross-check to debug, so mid tier.
  The dispatch names the Task 1 carry-forward explicitly and at length: attest.mjs must
  compute the EIP-712 hash in JS and must never fetch it via eth_call, because every
  Solidity test signs whatever att.attestationHash() returned and so cannot catch a
  self-consistently wrong encoding. It is also in the plan now (9b9179c), so the constraint
  survives even if the dispatch prose is not read carefully.
  Also carried: node_modules pre-installed, the expected @noble/hashes 1.8/2.4 nesting split
  (do not unify the import styles), Step 5 needs no real secret, and hard prohibitions on
  touching World's live API and on echoing SEPOLIA_RPC.
Task 4: implementer reported DONE (0e8ad23, six ok lines, all cross-checks agree,
  197 passed / 1 skipped unchanged, forge fmt clean, no concerns on the code).

  I verified the carry-forward myself rather than trusting it: world/attest.mjs contains no
  eth_call, fetch, rpc, http or provider reference at all - the only match for any of those
  terms is the prohibition comment. It computes the hash from keccak, a locally built domain
  separator and 0x1901. The independence anchor is real.
  I also re-ran Step 5 end to end on a fresh anvil rather than accepting the pasted output:
  chain id 31337, four hash cases matching (including type(uint64).max), 73-byte blob, the
  contract accepting the signature, all cross-checks agree, exit 0.

  Then I proved the check I added in 666bf17 is not vacuous, by introducing the exact bug it
  exists for - reading @noble's recovered signature as r||s||v instead of recovery||r||s:
    all four hash cases      -> still ok  (packing does not affect the hash)
    "blob is 73 bytes"       -> still ok  (THE OLD LENGTH-ONLY CHECK WOULD HAVE PASSED THIS)
    "contract accepts"       -> FAIL, exit 1
  So the defect I fixed was real and load-bearing: the plan as originally written would have
  printed "all cross-checks agree" over a blob no chain would accept. Mutation reverted, tree
  verified clean.

  Ruling on the implementer's one concern (forge create's --constructor-args must be last):
  CONFIRMED, and the failure is nastier than reported. I ran the plan's own ordering: because
  --constructor-args is variadic it swallowed --rpc-url and every flag after it as further
  constructor arguments, and forge then fell back to the default RPC at localhost:8545 and
  failed to connect - so the symptom can be a connection error with no mention of arguments
  at all, not just the "expected 1 but got 6" the implementer saw. Fixed the plan's Step 5 to
  put --constructor-args last, with the reason. Task 5 deploys via forge script and is
  unaffected. Cost if wrong: none, measured on forge 1.7.1.

  SECURITY DEFECT found in Task 5's brief while checking that exposure, and fixed before it
  could ever be dispatched. Two steps ran `set -a && . /home/ubuntu/DEV/ETHOnline2026/.env`,
  sourcing the file WHOLESALE - which would have put WALLET_PK, AGENT_PK, WORLD_RP_SIGNER_PK,
  GRAPH_DEPLOY_KEY, LEASH_SECRET and the API-keyed SEPOLIA_RPC into a subagent's environment,
  none of which those steps need. This directly violates the standing constraint to extract
  single variables only. Replaced with a `get()` helper reading one key at a time, and the RPC
  is now substituted inline so its API key never sits in a shell variable a later command
  might print.
  Step 4 was restructured to need NO key at all: the four hash cases already cover everything
  chain-dependent, since chainId and verifyingContract both feed the domain separator, while
  signing and recovery order are chain-independent and were proven on anvil in Task 4. Added
  the one check only a Sepolia run can make and which also needs no key - `cast call
  SIGNER()(address)` must return 0x85b89D21DB13f220601430d48244B2AE06120969, catching a wrong
  constructor argument that would otherwise make every signed attestation fail onchain.
  Both new Step 4 commands validated against anvil: four ok lines plus
  "skip  signature checks (SIGNER_PK unset)" plus "all cross-checks agree", and the SIGNER
  call returning the expected address.

  Pre-flight for Task 5, TWO DEFECTS found and fixed while Task 4's review ran.
  (a) `cast call $LENS` - LENS is not in .env (verified: grep count 0), so the command would
      have run with an empty target and failed. Supplied the deployed LeashLens literal
      0xB6eB4C26AF866057920f7AB6fAFf69A914067B83. WORLD_ATTESTER is also absent, but that is
      correct: Step 3 tells the user to add it after deploying.
  (b) "The wallet's existing state survives" was ASSERTED with a sound ERC-7201 argument and
      never MEASURED. This is the demo's central claim - that redeploying the impl does not
      wipe the user's wallet - and if the layout had drifted or the slot constant had been
      recomputed from a different string, the wallet would come back blank and Step 6 would
      discover it live, in front of an audience. Step 5 now snapshots bindingOf and ruleOf
      before re-delegating and diffs them after, printing "state survived re-delegation" or
      "STATE CHANGED - stop and investigate". Both calls are view and need no key.
      I got the TokenRule tuple wrong on the first pass - guessed 8 fields
      (bool,uint256,uint256,uint64,uint64,uint64,uint256,uint64) when the struct has 7
      (bool,uint256,uint256,uint64,uint16,uint16,uint32) - which would have failed the cast
      call. Caught by reading src/LeashStorage.sol:28 rather than trusting the guess, then
      ran all three commands READ-ONLY against the live Sepolia deployment to prove they
      work: node 0x9b4cc576... matches namehash(vendors.leash.eth), binding returns
      (node, "vendors", false), rule returns (true, 500e6, 1000e6, 86400, 0, 0, 0).
  Cost if wrong: none, all three are view calls.

Task 4: review returned spec ✅ but task quality NOT APPROVED — 1 Critical.
  Critical CONFIRMED by me in the code, not accepted on report. world/server.mjs ~172:
    signal_hash: proof.signal_hash ?? hashSignal(digest),
  The comment at :148 promises "one face scan authorises one widening, and an intercepted
  proof cannot be moved to another". That line makes it movable. signal_hash IS the entire
  binding between a face scan and the policy change it authorises, so it can never come from
  the caller: an attacker holding one genuine proof P for digest D1 posts
  {digest: D2, proof: {...P, signal_hash: S_of_D1}}, World verifies P against the signal
  baked into it, returns 200, and the server signs an attestation for D2 - a widening no
  human's face approved. /api/attest is raw JSON with no trusted caller and world/index.html
  never calls it. This is a brief-level defect copied verbatim from the plan, so it is fixed
  in both places.

  Ruling: I ALSO scoped in `action: action ?? ACTION` on the adjacent line, which the reviewer
  did not flag. Same class - a field the security property depends on, taken from an untrusted
  caller. A proof is bound to its action, so a caller can present a face scan made for a
  different action of this same app to authorise a widening. Not hypothetical: max_verifications
  is 1 per action and cannot be raised, so this project creates a fresh action for every demo
  and recording, and expand-policy was consumed 2026-09-07 - without pinning, that retired
  action's face scan still buys a widening today, which quietly voids "every widening from here
  needs a real face scan". Pinned to the server-configured ACTION, still settable via
  WORLD_ACTION but not per-request. Cost if wrong: a caller can no longer choose the action,
  which nothing legitimate does - index.html only calls /api/verify.

  The fix cannot be verified against World's live API (single verification already consumed,
  needs a phone), so the dispatch requires the payload construction be extracted into a pure
  exported function and checked locally: build a payload from a proof carrying a HOSTILE
  signal_hash and action, assert the result uses hashSignal(digest) and the server's action,
  and prove the check fails when the ?? fallback is restored.
Task 4: fix round 1/5 dispatched to t4-attest.
  I then swept the whole defect class rather than stopping at the reported instance, since
  "untrusted caller controls a field the security property rests on" rarely appears once.
  Every ?? fallback and every proof.* / body.* read in world/server.mjs, both routes:
    signal_hash (:172)  -> THE Critical, dispatched.
    action (:167)       -> same class, dispatched (my addition).
    identifier (:171)   -> client-supplied but NOT exploitable: World verifies the proof
      against the named credential, so lying fails. And per world/README the proof cannot
      reveal Selfie Check either way - both credential_type and verification_level come back
      "device" - so this is the already-documented limitation of the World integration, not a
      new hole in our endpoint. No change.
    deadline (:192)     -> SERVER-computed, Date.now()/1000 + 900. Correctly not client
      controlled; a caller-chosen deadline would have let a stolen attestation stay valid
      indefinitely.
    chainId (:196)      -> hardcoded 11155111. Safer than reading it from the request, and
      correct for the only chain this is deployed to.
    nullifier echoed in the response (:204) -> not a leak; the caller supplied it.
    error handler (:211) -> String(err?.message) only, no secret reachable (reviewer also
      verified this independently).
  Lines 114-122 are /api/verify, which relays World's answer and signs nothing, so the same
  pattern there is harmless and stays.
  Conclusion: the class closes at two instances, both already in fix round 1.
Task 4: fix round 1/5 (1 addressed, 0 open; commit eae52c9). Verified by me, not on report:
  buildVerifyPayload computes signal_hash: hashSignal(digest) with no fallback and takes
  action only as a parameter; /api/attest passes ACTION and no longer reads action from the
  body; /api/verify untouched (correctly - it signs nothing). I re-ran the new
  check-payload-binding.mjs (all checks agree, exit 0) and then restored BOTH fallbacks to
  prove it is not vacuous: the hostile signal_hash 0xdede... and the hostile action
  "old-retired-action" flowed straight through, 2 MISMATCH, exit 1. Reverted, tree clean.
  The plan now carries the attack narrative for both fields, not just the rule, which matters
  because the defect was copied from the plan in the first place.
Task 4: scoped re-review dispatched over ded205b..eae52c9 — t4-rereview on sonnet (mid tier
  rather than cheap, because the fix is security-relevant), seven checks plus an independent
  read on my `identifier` ruling.

  OPEN ITEM I created, to apply once the re-review releases world/: pinning `action` turned
  world/server.mjs:19's `const ACTION = process.env.WORLD_ACTION || "expand-policy"` into a
  footgun. expand-policy was CONSUMED on 2026-09-07 and max_verifications cannot be raised.
  Before the fix a caller could pass a fresh action in the request body as a workaround;
  now, with WORLD_ACTION unset, /api/attest silently sends a dead action, World refuses, and
  the failure looks like World's fault rather than a missing env var. The plan warns about it
  at Task 5 Step 5 but the server does not guard. Ruling: /api/attest should refuse to
  proceed on the known-consumed default instead of sending it - a 500 naming WORLD_ACTION,
  in the same style as the existing WORLD_RP_SIGNER_PK and WORLD_ATTESTER guards. Cost if
  wrong: one extra required env var on an endpoint that already requires two.
  Re-review clean: finding ADDRESSED, all seven checks pass, nothing new. It confirmed
  /api/attest no longer reads `action` from the body at all (absent, not merely unused),
  /api/verify's identical ?? pattern is untouched, and check-payload-binding.mjs asserts
  against the hostile values too rather than only for the expected ones, so it is not vacuous.
  It independently reached my conclusion on `identifier`, with a better mechanism than I had:
  the proof is a SNARK bound to a specific credential-type merkle tree and `merkle_root`
  travels in the same payload, so a mismatched identifier fails against that pool - there is
  no way to launder a device-credential proof into a stronger claim.

  Ruling: DECLINED the re-review's optional hardening (hardcode identifier: "device" instead
  of trusting either proof field). Its own reasoning is that a mismatched identifier fails
  verification, so hardcoding buys nothing against an attack that cannot work - and it costs
  real fragility. docs/world-feedback.md asks World to expose a genuine selfie/face credential
  type, which is the outcome this project wants; if they ship it, a hardcoded "device" breaks
  us precisely when the thing we asked for arrives. Trading a non-risk for a silent future
  break is the wrong trade. Cost if wrong: nothing, the field is already proven unexploitable.

Task 4: fix round 2/5 dispatched to t4-attest — the WORLD_ACTION guard from the open item
  above. Scoped deliberately narrowly: the module-level default stays, because /api/config,
  /api/precheck and /api/verify are the verification harness and should keep working with
  defaults; only /api/attest, the one endpoint where a wrong action means no attestation at
  all, must demand an explicit current action.

  Pre-flight for Task 5, CLEAR and verified against the chain rather than against docs.
  The deploy script builds a new LeashAccount impl from three constants, and a wrong one
  would silently point the re-delegated wallet at the wrong registry or the wrong approvals
  list. I read the immutables off the CURRENTLY deployed impl 0x136b33c6... on Sepolia:
    ETH_REGISTRY()  0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2  == the plan's constant
    APPROVALS()     0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4  == the plan's constant
    ATTESTER()      0x268990a91B0727E80d38d5ED4Ab10d8889754124  == MockAttester, the one
                    thing Task 5 is meant to replace
  So the new impl preserves both non-attester immutables and swaps only the attester. Task 5
  changes exactly one thing, which is what makes the state-survival claim checkable at all.
  Task 5 Step 7's documentation targets also all exist as described: README.md:99-106 (the
  callout whose "nothing about World ID is enforced onchain yet" becomes false at Step 5),
  docs/deployments.md:64 and :329. Note the callout must become PARTLY true rather than be
  deleted - PolicyApprovals and LeashRegistry keep MockAttester, so it stays deployed and
  its row in the address table stays. The plan already says this.
Task 4: fix round 2/5 (1 addressed, 0 open; commit fa3bc48). Verified by me:
  checkAttestEnv guards all three of WORLD_RP_SIGNER_PK, WORLD_ATTESTER and WORLD_ACTION,
  and the WORLD_ACTION message names the date it was consumed, why it cannot be raised, and
  what to do. The implementer went one better than my brief: /api/attest reads
  process.env.WORLD_ACTION DIRECTLY rather than the module-level ACTION, so the consumed
  fallback stays unreachable even if the guard is later loosened. Harness routes at :72, :81
  and :96 still use defaulting ACTION, which is the scoping I asked for. I ran the check
  myself: 7 ok, all checks agree, exit 0. world/README.md:36-38 and the plan's new Step 4c
  both updated.

  Ruling: SKIPPED the scoped re-review for this round, as a deliberate deviation from the
  skill's fix loop rather than an oversight. The change is purely restrictive - the endpoint
  refuses more and never signs more - so its whole risk surface is "does it refuse when it
  should", and that is pinned by five new executable assertions I ran rather than by
  inspection. The implementer also mutation-tested it (guard removed -> 2 FAIL, exit 1). The
  whole-branch final review on the most capable model still covers this commit. Cost if
  wrong: a defensive guard that does not guard, on an endpoint that already refuses without
  two other env vars. Deadline pressure is real (2026-09-13 16:00 UTC) but was not the
  deciding factor - the executable pin was.
Task 4: complete (commits 666bf17..fa3bc48, fix rounds 1-2, re-review of round 1 clean)

Task 5: dispatched (BASE fa3bc48) — implementer t5-script on haiku, SCOPED TO STEP 1 ONLY.
  Model note: the brief carries the complete contract, so this is transcription - cheapest
  tier per the skill.
  Ruling on scope and on secret handling: Task 5's remaining steps are the four that stop.
  Step 3 broadcasts to Sepolia and Step 5 re-delegates a live EOA - both irreversible side
  effects outside this worktree, which the skill says to stop and ask about, and both need
  the user's explicit authorisation. Step 6 needs a fresh World action and a phone. So only
  Step 1 is dispatchable.
  I also pulled Step 2 (simulate) OUT of the subagent's scope and will run it myself, even
  though it broadcasts nothing. It needs ADMIN_PK, and there is no benefit to that key
  entering a subagent's context for a single command I am going to verify anyway. The
  dispatch forbids the subagent from opening .env at all. Cost if wrong: I run one command
  instead of delegating it.

  PLAN GAP found while checking Task 5 Step 6, and it is the demo-critical one.
  Step 6 is prose with no commands - "compute the digest, get an attestation from
  /api/attest, and send allowPayee" - which is exactly the placeholder failure the
  writing-plans skill forbids, in the one step the user runs LIVE with a phone in hand.
  Worse, the flow it describes has no client. Task 4 built /api/attest; nothing calls it.
  world/index.html:35 does have a free-text signal field and passes it to IDKit
  (index.html:88), so a scan CAN be bound to a digest - but handleVerify posts the result to
  /api/verify (index.html:74), which relays World's answer and signs nothing. Grepped the
  whole file: /api/attest appears nowhere. The reviewer noticed this too, from the other
  direction, when it confirmed /api/attest has no trusted caller.
  So Step 6 as written requires the user to capture the proof JSON from the page and curl it
  to /api/attest by hand, BETWEEN the face scan and the attestation.

  Ruling: that manual gap must be closed in the page before the demo, not documented as a
  procedure. The reason is max_verifications: it is 1 per action, cannot be raised, and a
  consumed action cannot be reset - so the flow gets exactly ONE attempt per action created.
  A copy-paste-curl step wedged between the scan and the signature is the single
  highest-risk possible design: a malformed body, a stale digest or a typo burns the scan,
  and recovering means creating a brand new action in the Portal and scanning again. Routing
  it inside handleVerify, which already holds the proof, makes it one round trip with no
  human in the middle. Sizing: ~15 lines - if the signal parses as 0x + 64 hex, POST
  { digest, proof } to /api/attest and render the attestation and deadline.
  Deferred only until t5-script reports, to avoid two agents committing to this worktree at
  once - I have already been bitten by that ordering once today.
Task 5 Step 1: complete (commit fb03954). Script read in full by me: WALLET_PK appears twice
  and both are inert - one in the @dev comment, one inside a console.log string - never used
  as a value. It also carries require(block.chainid == SEPOLIA), which is a real guard, not
  decoration. The three constants match what I read off the live impl earlier.

Task 5 Step 2: SIMULATION COMPLETE, run by me rather than delegated so ADMIN_PK never
  entered a subagent's context. No revert. Printed SIGNER = 0x85b89D21DB13f220601430d48244B2AE06120969,
  which is exactly the check the step asks for. Chain 11155111. Estimated cost
  0.008280684991843208 ETH at 1.87 gwei; the new addresses in the dry run were
  WorldAttester 0xa4E208dA... and LeashAccount 0x55528C70..., though the real deploy will
  differ since they depend on ADMIN's nonce at broadcast time.
  Checked funding before asking the user to authorise anything: ADMIN holds 0.0713 ETH
  against a ~0.0083 estimate (8.6x headroom), WALLET holds 0.0396 ETH for the 7702
  authorization and allowPayee. Neither is a blocker.
  Investigated forge's "Sensitive values saved to: cache/.../run-latest.json" warning rather
  than leaving it alarming in the log: the file is 130 bytes, contains no 64-hex string and
  only a "transactions" key, so nothing was written for a dry run - the label is generic
  boilerplate. Both cache/ and broadcast/ are gitignored (.gitignore:11-12), so neither can
  reach a commit even on a real broadcast.

Task 5: STOPPED at Step 3 as designed. Steps 3 and 5 are irreversible side effects outside
  this worktree (a Sepolia broadcast, and re-delegating a live EOA) and need the user's
  explicit authorisation; Step 6 additionally needs a fresh World action and a phone.
  Dispatched t5-demopath on sonnet meanwhile - the pre-stop work from the Step 6 gap ruling.

Task 5 demo path: complete (commit 45177b4). Verified by me: exactly one of /api/attest or
  /api/verify is called, chosen from the signal before any network call; the digest regex
  matches the server's; 197 passed / 1 skipped unchanged; only world/index.html, the plan and
  world/README.md touched.
  Ruling: ACCEPTED both of the implementer's judgement calls, and its reasoning on the second
  is better than my brief's. One button, because the signal field's contents already
  determine the path and a second button would let "which button I pressed" drift out of sync
  with "what is in the field" - a new failure mode for an operator under time pressure. And
  never call both endpoints, because /api/attest performs its own full World verification, so
  also calling /api/verify would verify the same proof against the same action twice: with
  max_verifications at 1 that is at best a wasted call and at worst burns the single use
  before the signing route gets it, with no ordering guarantee between them. There is no
  safety upside since /api/attest's own 200-gate is the sole authority for signing.
  The client-side regex duplicates the server's with a "kept in sync by eye" comment. Left
  as is: drift can only cause the client to route a non-digest to /api/attest, which the
  server rejects with 400, so the failure is fail-safe and visible.

  Its one flagged concern - nothing confirms the signal before IDKit.open(), so an operator
  could scan against a STALE digest - is real but not UI-fixable: no dialog can distinguish a
  stale digest from a fresh one by eye, and the failure only surfaces onchain as NotAttested
  after the scan is already spent. So I closed it procedurally in Step 6 instead, plus a
  second trap the implementer did not raise:
    - NODE is now recomputed inside Step 6 rather than carried from Step 5, so the step
      stands alone in a fresh shell instead of depending on a variable set minutes ago in
      another terminal.
    - Added the deadline window: server.mjs signs deadline = now + 900, so the copy-then-
      cast-send tail has 15 minutes. Past it allowPayee reverts NotAttested with the scan
      already spent AND the action consumed - the single worst outcome available in this
      plan. Step 6 now says to have the cast send line typed out and ready, everything but
      the attestation filled in, BEFORE scanning.
  Cost if wrong: two paragraphs of operational advice.

FINAL whole-branch review dispatched over fee6fce..42930f6 (22 commits) — final-review on
  opus, the most capable tier, as the skill requires for this one.
  Ruling on timing: dispatched NOW rather than after Task 5 completes. Every line of code on
  this branch exists; what remains is the deployment itself and the documentation that
  describes it, both gated on the user's authorisation for irreversible onchain actions. So
  the review has the whole code surface available and the gate time is otherwise idle. Step 7
  will add doc-only commits afterwards, which I will diff separately rather than re-running
  the whole review. Cost if wrong: one later doc commit outside the reviewed range.
  The dispatch tells it explicitly NOT to report the missing deployment as a defect, and not
  to flag the MockAttester caveats in README/deployments.md as stale - they are still TRUE
  today, because the deploy has not happened - while asking it to flag any claim that IS
  already false. It also gets the ledger, so it can push back on any ruling I made.

  Checked a Step 5 risk nobody had raised: does INDEXING survive re-delegation, not just
  storage? It does, and for a reason worth writing down. subgraph/subgraph.yaml:97 indexes
  the wallet as a STATIC dataSource keyed on the EOA address 0x46C09255... (startBlock
  11664742), and EIP-7702 executes in the EOA's own storage, so events are emitted from that
  same address whichever impl is delegated. Re-delegation therefore needs no subgraph change
  and cannot orphan the wallet's history. I also confirmed the branch adds NO event
  declarations at all - `git diff fee6fce..HEAD -- src/` has no +/- lines matching "event ",
  and src/ changes are only +42 in LeashAccount.sol (the two view getters) and +98 for the
  new WorldAttester.sol - so the indexed ABI surface is unchanged and the deployed subgraph
  needs no redeploy for Task 5. This matters because the agent decision loop reads the
  subgraph, so a break here would have surfaced mid-demo as an agent that cannot see its own
  budget.
  Live subgraph re-checked at the same time: hasIndexingErrors false, indexed to block
  11667406, and the agents entity is keyed <wallet>-<agent>, confirming the entity-id
  collision fix from before this plan is deployed and working.

FINAL REVIEW returned. Verdict pending (report was truncated mid-I1; remainder requested and
  also being written to final-review-report.md). Two findings so far, BOTH CONFIRMED BY ME
  independently rather than accepted on report. This review earned its keep.

  C1 (Critical) - /api/attest could NEVER have succeeded on the digest path.
  world/attest.mjs:92-95 hashSignal does keccak_256(signal) with signal as a JS STRING, so
  @noble UTF-8-encodes it and we hash 66 ASCII characters. IDKit hashes the same signal as 32
  DECODED bytes. Measured for digest 0x9b4cc576...e121:
    ours  (utf8 of 66-char string): 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
    IDKit (keccak of 32 raw bytes): 0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
  I did not stop at the reviewer's word on IDKit's rule, since the whole fix depends on it -
  I fetched @worldcoin/idkit-standalone@2.2.5, the exact bundle world/index.html loads, and
  read it:
    function hashToField(input) {
      if (Bytes.validate(input) || Hex.validate(input)) return hashEncodedBytes(input);
      return hashString(input);
    }
    function hashString(input)       { return hashEncodedBytes(Buffer.from(input)); }
    function hashEncodedBytes(input) { BigInt(keccak256(input)) >> 8n }
    function validate(value, options = {}) { const { strict = false } = options; ... }
  validate defaults to NON-strict, so any 0x-prefixed string takes the hex-decode branch.
  Confirmed exactly as reported. signal_hash is a public input to the proof, so World would
  refuse our payload, /api/attest would return non-200, sign nothing - and the action's single
  verification would be SPENT. Act three of the demo could not have completed.
  Why every existing check missed it, which is the lesson: check-payload-binding.mjs asserts
  signal_hash === hashSignal(digest), pinning the server against ITSELF, so it agrees however
  wrong hashSignal is. crosscheck.mjs never touches hashSignal. And the 2026-09-07 end-to-end
  run used the non-hex default signal widen:vendors.acme.eth:5000, where both branches
  coincide - I verified hashSignal("") still equals the world/README baseline
  0x00c5d246...85a4, so the string path is right and must not move. The digest path, the only
  path /api/attest ever takes, had never been exercised once.
  Dispatched to t4-attest with the fix (mirror hashToField) and, as importantly, a
  requirement that the new assertions compute expected values INDEPENDENTLY - hardcoded
  measured IDKit outputs and inline keccak of raw bytes - so the check pins against IDKit's
  rule instead of against us.

  I1 (Important) - restoring a revoked agent does not actually require an attestation.
  Proved with my own forge test, both probes passing: restoreAgent with a junk blob reverts
  NotAttested (the gate works), AND revoke -> unbind -> bind returns the agent to
  (node, "vendors", revoked=false) with no attestation anywhere. So README.md:86's
  "Restore a revoked agent | self ✅ | attestation ✅" is false today.
  bindAgent:219-223 names this exact attack in its own comment - the AlreadyBound guard
  exists so "rebind for free after a revocation" cannot sidestep the face scan - and then
  sanctions unbindAgent-then-bindAgent as the free remedy. That remedy is right for a
  MIS-BINDING and is a bypass for a REVOCATION, because unbindAgent deletes the very
  `revoked` flag the guard reads.
  Scope note: the bypass needs the WALLET key, since bindAgent is onlySelf, so it is not
  agent privilege escalation. It still matters, because the reason widenings are attested at
  all is that the wallet key alone is NOT sufficient - the face scan is the second factor
  against a compromised wallet key.

  Ruling: FIX THE CONTRACT, not the README, and fix it now. Three reasons. The branch's
  entire purpose is making the attestation half real, so shipping it with a free bypass for
  one of the three attested operations undermines the deliverable itself. We are about to
  deploy a new impl anyway, so this rides along at zero marginal cost, whereas fixing it
  later costs a second deploy AND a second manual re-delegation. And this project has
  already been burned once by asserting a guarantee it had not earned (the README
  MockAttester episode), where the reviewer's words were "the gap reads as concealment
  rather than oversight" - documenting a known bypass instead of closing it would be that
  same mistake, chosen deliberately.
  Ruling on the FIX ITSELF: one guard, no storage change. unbindAgent refuses when the
  binding is currently revoked; the only route out of revoked is then restoreAgent, which is
  attested, and bindAgent on a revoked agent still hits AlreadyBound because revokeAgent
  keeps node non-zero. I considered and REJECTED an `everRevoked` mapping: revokeAgent
  already retains the binding, so the deciding state is present, and LeashStorage carries an
  explicit do-not-reorder warning plus a test pinning `paused` at SLOT+5 - no reason to touch
  the layout on the eve of a deployment.
  Verified before dispatching that this breaks nothing: NO existing test revokes then
  unbinds, and the legitimate remedy test test_a_mis_binding_is_correctable_for_free
  (test/LeashAccountBinding.t.sol:325) binds then unbinds WITHOUT revoking, so it is
  untouched. Refusing also forfeits no capability - a revoked agent is already powerless,
  blocked at spend step 2b with SpendBlocked(AGENT_REVOKED) - only storage cleanup.
  Dispatched as t6-revokegate on sonnet.

  Final review's full report is at .superpowers/sdd/.../final-review-report.md (217 lines).
  Verdict: NOT READY TO FINISH, C1 the hard blocker. Findings beyond C1 and I1:
    I2 - world/index.html:151 hands IDKit the UNTRIMMED signal while :115 sends the server
      the trimmed one, and isDigest trims too. Step 6 has the operator paste $DIGEST out of a
      shell, so a trailing newline routes to /api/attest on the trimmed test while IDKit binds
      the proof to the untrimmed string - the binding diverges silently and the scan is spent.
      Routed to t4-attest, since C1's fix is what makes this the REMAINING way to break the
      same binding.
    I3 - checkAttestEnv only checks WORLD_ATTESTER is present. buf() is
      Buffer.from(hex,"hex"), which TRUNCATES instead of throwing, so a malformed value
      silently mis-encodes the domain separator; the reviewer measured three different hashes
      from a valid address, that address one character short, and the string "nope", with no
      error raised. Worse, a stale-but-valid address passes plan Step 4 entirely - crosscheck
      prints four ok lines and SIGNER() matches, because an older WorldAttester carries the
      same signer - so the mismatch first appears as NotAttested at allowPayee, after the scan
      is spent. Routed to t4-attest, plus the keyless Step 4 assertion
      cast call "$W" 'ATTESTER()(address)' == WORLD_ATTESTER.
    Minors routed to t4-attest: crosscheck.mjs:55's deadline hardcoded to 1800000900
      (2027-01-15), a time bomb that would report FAIL for a reason unrelated to encoding; and
      the already-false "wiring AttesterGate / signal is a test string" claims in
      world/README.md:120-129 and world/server.mjs:10,:36-40,:122-123, which name a contract
      that does not exist.
    Minor routed to t6-revokegate: restoreDigest (src/LeashAccount.sol:525-535) omits the
      node == nodeFor(label) check that restoreAgent:282-283 has, so it hands back a digest
      that can NEVER be consumed - and discovering that costs a face scan and therefore an
      action.
    Handled by me, since no agent owned those files: .env.example was missing WORLD_ATTESTER
      and WORLD_ACTION, both now hard requirements; and spec :288 claimed once-per-person is
      "a backend property" when nothing records a nullifier - the real mechanism is World's
      max_verifications: 1. Committed.
    Deferred, agreeing with the reviewer: describe()'s hardcoded rp_id.

  ACCEPTED CORRECTION from the reviewer, recorded because it corrects MY ledger. My round-1
  entry and server.mjs:130-132 both say "one face scan authorises exactly one widening" is now
  real. The PINNING of signal_hash is real and was the right fix; the PROPERTY is not live
  until C1 lands, because the pinned value is computed in the wrong domain and no proof can
  verify against it at all. I overstated it. The property arrives with C1's fix, not before.

  What the review verified as sound, worth recording so it is not re-litigated: the JS and
  Solidity EIP-712 implementations agree BY CONSTRUCTION, not by four lucky cases - it read
  them field by field and then measured 233 (digest, deadline) pairs including every uint64
  edge with 0 mismatches; verify never reverts across 20,000 fuzz runs per test, and
  IAttester.verify being `view` makes the call a STATICCALL so nothing can reenter the window
  between the attestationUsed read and its write; all six replay surfaces are closed; the
  reduction side of the asymmetry is intact; and no key material is in the diff - the three
  64-hex strings are anvil's published key, secp256k1's n, and a public namehash.
  It also confirmed .gitignore's !broadcast/*/*/run-latest.json negation is INERT because the
  parent broadcast/ is excluded, verified with git check-ignore on the real post-broadcast
  path - so no run artifact can reach a commit after the deploy.
  It reported NO substantive disagreement with any ledger ruling.

C1: FIXED and verified by me (commit 249aa91). hashSignal now mirrors IDKit's hashToField -
  0x-prefixed goes through buf() to raw bytes, everything else stays UTF-8. I re-measured both
  baselines rather than accepting the report: the real digest now yields
  0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3, matching what I read out
  of IDKit's own bundle, and hashSignal("") is still 0x00c5d246...85a4, so the string path did
  not move. The implementer's mutation reproduced my exact wrong value (0x007cd569...) on the
  two digest assertions while both string assertions stayed green - which is the proof the new
  assertions would have caught this, and the proof that they are no longer self-referential.
  It also added docs/world-feedback.md §7.7 as a measured correction extending §7.3. Right
  call: a second undocumented hashing branch in IDKit is exactly what that document is for,
  and the prize asks for it.

  Process note: my second message (I2, I3, two minors) arrived AFTER t4-attest had committed
  C1 and gone idle, so none of it was done. I verified each of the four independently at
  249aa91 rather than assuming either way - index.html:151 still raw, checkAttestEnv:187 still
  presence-only, crosscheck.mjs:55 still pinned, AttesterGate still claimed 3x in each of
  world/README.md and world/server.mjs - and re-sent. Lesson for the rest of this session:
  a follow-up sent to an agent already mid-task is not guaranteed to be picked up; check the
  files, not the reply.

  Correction of MY OWN instruction, caught while re-sending: I had told it to replace
  crosscheck's pinned deadline 1800000900 with a Date.now() value AND to keep the four hash
  cases deterministic. Those conflict, because the signature-acceptance check reuses cases[3],
  which IS that line. Resolved: leave the cases array untouched so the hash comparisons stay
  reproducible and type(uint64).max keeps its coverage, and give the signature-acceptance
  check its own fresh Math.floor(Date.now()/1000) + 900 deadline while still using cases[3][0]
  as its digest. Had the implementer followed my first wording literally it would have
  silently weakened the uint64 edge coverage.

I1: FIXED and verified by me (commit 5f498b4). unbindAgent at src/LeashAccount.sol:270-276
  now reverts RevokedNeedsRestore() when the binding is currently revoked, reusing the
  existing `revoked` flag with NO storage change, exactly as ruled. Suite 200 passed /
  1 skipped / 0 failed, fmt clean. Its mutation evidence is the right kind: with the guard
  removed, BOTH bypass tests went RED with "next call did not revert as expected" - so the
  new tests genuinely pin the hole rather than describing it.
  It also correctly declined to change README.md:86: that row is about restoreAgent, which
  was always properly gated, and the bypass ran through unbindAgent instead - so it added a
  paragraph on the one exception to "unbind is free" rather than rewriting a row that was
  literally true. Better judgement than my dispatch implied, which had assumed the row itself
  was false. It checked docs/architecture.md and docs/deployments.md and found neither
  mentions unbindAgent at all, so it left them alone rather than inventing a change.
  restoreDigest also picked up the nodeFor(label) check from my follow-up and is still
  uncommitted, so that agent is mid-work; I let it finish rather than interrupting.

  Sent three loose ends into the same files rather than opening another round: the now-stale
  comment at test/LeashAccountBinding.t.sol:303 claiming "LeashAccount exposes no public
  restoreDigest()" (untrue since Task 2, and the local _restoreDigest helper should STAY -
  an independent reconstruction is a better test than calling the getter, which would compare
  it to itself, so only the comment's reason needs correcting); the still-missing README
  nuance that binding a FRESH address to the same node remains free by design, so the guard
  protects re-activating that same agent address rather than agent authority in general; and
  my unanswered question about whether ruleDigest and payeeDigest omit analogous
  consumer-side checks - to be reported, not fixed, so I can rule on it separately.

  restoreDigest fix landed (4283570) with test_restoreDigest_rejects_a_node_label_mismatch;
  201 passed / 1 skipped / 0 failed.
  ACCEPTED its ruling on ruleDigest and payeeDigest, having verified it myself rather than
  taking the negative result on trust: both setRule and allowPayee go STRAIGHT to
  _consumeAttestation with no validation before it, so there is no consumer-side check for
  either getter to mirror and no analogous gap. restoreAgent was the only one of the three
  with a pre-attestation check (node == nodeFor(label)), which is exactly why restoreDigest
  was the only getter that could hand back an unconsumable digest. Useful negative result -
  recorded so nobody re-opens it.
  It also stepped slightly outside its brief by ruling rather than reporting, as I had asked
  it to just report. Letting that stand: the ruling is correct, it is backed by the reading I
  independently confirmed, and pushing it back for form's sake would cost a round trip and
  change nothing.
  README nuance landed too: it now distinguishes re-activating THAT SAME revoked agent
  address (attested) from binding a FRESH address to the same node (free by design, because
  bindAgent grants authority from zero and the content comes from ENS plus the approval
  list). That is the honest narrow claim.
  The stale comment at test/LeashAccountBinding.t.sol:303 is mid-edit as I write this, and
  the replacement gives the RIGHT reason - that calling restoreDigest() there would compare
  the getter to itself and prove nothing, so the independent reconstruction is deliberate.
  That is the point I most wanted preserved.
  Stale comment fixed too (4b8d9bf). t6-revokegate's work is complete: 5f498b4, 4283570,
  4b8d9bf.

  I WAS WRONG and it pushed back correctly. I reported the README nuance as still missing,
  based on a grep run against the tree BEFORE 4283570 landed - the "What this does and does
  not claim" paragraph was already there at README.md:105-112, and it is exactly the narrow
  honest claim: re-activating THAT revoked address needs an attestation, while binding a
  fresh address to the same node stays free by design because bindAgent grants authority
  from zero and the content comes from ENS plus the approval list. It also cites bindAgent's
  own note on why binding points in the reducing direction. Correct on the substance and
  correct to challenge me on it.
  Process lesson, and it is the mirror of the one two entries above: there I learned not to
  trust an agent's reply over the files, and here I trusted a file read that was already
  stale by the time I interpreted it. In a worktree with concurrent agents, neither the reply
  nor a snapshot is authoritative on its own - the check has to be `git show <sha> -- <path>`
  against a named commit, not a working-tree grep whose timing I cannot see.

  t4-attest's four items are all present in the working tree, verified by me before its
  commit: I2 threads a single trimmed `signal` into both IDKit.init and handleVerify - and it
  went further than my brief by passing it as a PARAMETER to handleVerify rather than
  re-reading the input, so the two consumers cannot diverge structurally instead of merely
  happening to agree today; I3 validates /^0x[0-9a-fA-F]{40}$/ at attest.mjs:197; crosscheck
  keeps the `cases` array untouched at line 55 (so the type(uint64).max hash coverage
  survives) and gives the signature check its own Math.floor(Date.now()/1000)+900 at :77 with
  a comment saying why it is deliberately not cases[3][1] - exactly my corrected instruction;
  and AttesterGate is down to 0 occurrences in both world/README.md and world/server.mjs.

ALL final-review findings fixed. Fix range 42930f6..642738b, 6 commits. Verified by me at the
  named commit rather than by working-tree grep, given the lesson above:
    I2  world/index.html          one trimmed value, threaded into IDKit.init AND handleVerify
    I3  world/attest.mjs:197      /^0x[0-9a-fA-F]{40}$/ enforced
    minor crosscheck.mjs          own Date.now() deadline at :77, cases[] intact at :55 so the
                                  type(uint64).max hash case still runs
    minor AttesterGate            0 occurrences in world/README.md and world/server.mjs
    restoreDigest                 NodeLabelMismatch check present
    I1  RevokedNeedsRestore       present
  201 passed / 1 skipped / 0 failed, forge fmt clean, tree clean.
  I re-ran both check suites end to end against a fresh anvil myself, not on report:
    crosscheck.mjs           6 ok, "all cross-checks agree"
    check-payload-binding    13 ok, "all checks agree", including the four hashSignal
                             assertions that now pin against IDKit's rule independently -
                             two computed inline from raw bytes, two hardcoded from
                             measurement - which is the specific property whose absence let
                             C1 survive two earlier review rounds.

  Ruling on I3's fix quality: t4-attest volunteered a mutation for it without being asked
  this round (guard removed -> both new cases FAIL, exit 1, then reverted). Accepted and
  noted approvingly - that is the habit I had to demand explicitly in earlier rounds, now
  applied unprompted.

SCOPED RE-REVIEW dispatched over 42930f6..642738b — final-rereview on opus. Deliberately the
  top tier again rather than a cheap scoped pass, because this is the last gate before an
  irreversible Sepolia deployment and one of the fixes is for a Critical that two prior
  review rounds missed. It is asked to be adversarial about whether each fix is actually
  CORRECT rather than merely present; to independently verify the negative result on
  ruleDigest/payeeDigest, since a second opinion on "there is no bug here" is worth more than
  on a fix; to check whether any fix weakened an existing check, naming crosscheck.mjs as the
  one I would look at hardest because my own first draft instruction would have destroyed the
  uint64 edge coverage; and to find any comment or doc still carrying the overstatement I
  already corrected in this ledger.

  Re-review found ONE genuine gap, and it is mine. I routed two closures for I3 in the same
  message - the WORLD_ATTESTER shape check AND plan Step 4's keyless
  cast call "$W" 'ATTESTER()(address)' assertion - then verified only the shape half and
  reported I3 done. ATTESTER() had 0 occurrences in both the plan and the deploy script.
  This is the exact failure mode I recorded a lesson about earlier: I checked the file for
  the item I remembered and not for the item I had actually asked for.
  Fixed myself rather than dispatching, since both files were free. Step 4 now reads
  ATTESTER() through the 7702 wallet and compares it against the configured WORLD_ATTESTER,
  and says to run it again after Step 5 - noting that BEFORE re-delegation it correctly
  reports the old MockAttester, so that is not a failure. Proven against the live wallet
  read-only: it returns 0x268990a9...54124, the MockAttester still delegated today.
  Why this check is not redundant with SIGNER(): a stale-but-valid WORLD_ATTESTER carries the
  SAME signer, so SIGNER() matches and all four hash cases match and Step 4 passes clean -
  the mismatch then surfaces as NotAttested at allowPayee, scan spent, action consumed. This
  is the only check in the plan that catches it beforehand.
  Also added the linkage to the deploy script's own log, so it is captured at deployment
  rather than only by a later check. Confirmed in simulation: "impl ATTESTER" prints the same
  address as the WorldAttester just deployed, and SIGNER prints the expected RP signer.
  201 passed / 1 skipped / 0 failed, fmt clean.

  Re-review's confirmations worth keeping: it re-derived BOTH hardcoded hashSignal values
  with `cast keccak` independently of this repo and both check out, so the C1 assertions are
  genuinely anchored outside our own code; it enumerated every writer that can produce an
  active binding and found only bindAgent (guarded) and restoreAgent (attested), and showed
  the one state that would defeat the guard - node == 0 with revoked == true - is now
  unreachable because the only delete sits behind the new guard and _requireSelfOrAgent
  reverts NotBoundAgent on a never-bound agent; and it independently confirmed the negative
  result on ruleDigest/payeeDigest by checking that every line AFTER setRule's consume has no
  revert path at all, which is a stronger argument than the one I made from reading the
  function heads.

FINAL RE-REVIEW VERDICT: **safe to deploy to Sepolia.** All six findings ADDRESSED, each
  correct on the merits rather than merely present. No Critical, no Important. It confirmed
  no fix weakened an existing check, and that crosscheck.mjs is strictly STRONGER than what
  it replaced - the failure mode I feared from my own first-draft instruction did not happen.

  Its three new Minors, all verified by me and all now fixed:
    - plan Step 4's missing ATTESTER() assertion - mine, fixed in 778edfb before it reported.
    - world/attest.mjs claimed being stricter than IDKit's Hex.validate "only ever fails
      safe". False, and I measured it: hashSignal("0xabc") returns keccak(<0xab>) >> 8 - the
      regex matches odd-length hex and buf() silently drops the trailing nibble, where ox
      throws. No live path reaches it because /api/attest anchors {64} first. Comment now
      names the divergence and says the upstream anchor is what makes it moot and therefore
      what must stay, so nobody "fixes" it by widening the regex.
    - test/LeashAccountBinding.t.sol:324 still said unbindAgent is "entirely free", which my
      own I1 fix made false as written. Qualified.
    - src/IPolicyApprovals.sol:6 named AttesterGate; it was the last such reference in src/,
      now zero.
  201 passed / 1 skipped / 0 failed, fmt clean.

  THE RESIDUAL IT NAMED, and it is the right thing to carry to the user rather than bury:
  the digest path has still never been exercised against World's LIVE API, deliberately,
  because the action's single verification is spent. So "one face scan authorises exactly one
  widening is real" rests on code correctness plus one hardcoded measurement against IDKit's
  own bundle - not on a live end-to-end run. The first live proof of the property will be the
  demo itself. That is the correct call given max_verifications cannot be raised, but it must
  be said out loud, not implied away.

=== DEPLOYED. Task 5 Steps 3-5 executed with the user's explicit authorisation. ===

Step B (precheck of the fresh action, consumes nothing) — expand-policy-demo1 PASSED all four
  gates: status active, max_verifications 1 (fresh and unconsumed), enable_face_check TRUE,
  can_user_verify yes. is_staging false, so it is the production RP.
  action id action_1f91e0b88227d9c86c276c28d30c3324,
  external_nullifier 0x001f91e0b88227d9c86c276c28d30c3324eeae57b1a61b9b7bfef36eeec15018.

Step 3 (deploy, ONCHAIN EXECUTION COMPLETE & SUCCESSFUL, gas 3442671):
  WorldAttester       0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26
                      tx 0xec9a06d398d51868fa5b576bdc54f424d9826acfd461be3226dc2d3720368cfa
  LeashAccount impl   0x55528C707Bff43175CC7d7fCe6D9767060C67f23
                      tx 0xdf3ed24ccf91f304d1e78432f46865bee4fded45b91405c806bea749067abc51
  Verified by reading the immutables back OFF CHAIN rather than trusting the deploy log:
  SIGNER 0x85b89D21...20969 as expected; impl.ATTESTER() equals the attester just deployed;
  and crucially impl.APPROVALS() 0x7CB9d4Ac...925B4 and impl.ETH_REGISTRY()
  0xBDC85dD5...4F0E2 are UNCHANGED from the old impl, so the deployment moved exactly one
  thing, which is what the pre-flight said it should.

Step 5 (re-delegation, run by me at the user's explicit request - "D: 你也幫我做"):
  tx 0xfe8cb0fd6096fca1e5da9563fbec91b1dadcd066ed6f87f67520708fac458008
  type 4, status 1, block 11667630, gas 36844. WALLET signed its own authorization; the key
  was passed inline from .env and never echoed, and never entered a script.
  delegateOf -> (true, 0x55528C70...67f23).

  STATE SURVIVED, measured rather than asserted - the whole reason Step 5 got a snapshot:
    binding  (0x9b4cc576...e121, "vendors", false)   identical before and after
    rule     (true, 500e6, 1000e6, 86400, 0, 0, 0)   identical before and after
  LINKAGE OK: wallet ATTESTER() == WORLD_ATTESTER == 0xa4E208dA...65F26.

THE ASYMMETRY IS NOW LIVE ON SEPOLIA, proved with free static calls:
  allowPayee + 73 junk bytes  -> reverts 0x99efb890 = NotAttested() (confirmed via cast sig)
  allowPayee + empty bytes    -> reverts NotAttested()
  removePayee, no attestation -> 0x, succeeds
  Under MockAttester the first two would have been ACCEPTED. This is the first moment in the
  project's history that the attestation half of "widening needs a live human" is actually
  guarding, and the reduction half is demonstrably still free.
  .env now carries WORLD_ATTESTER and WORLD_ACTION=expand-policy-demo1.

REMAINING: Step 6 needs the user, their phone and the one face scan. Step 7 is the
  documentation, which is now the honesty-critical piece: README.md:118-126 and
  docs/deployments.md:64,:329 still say the system is wired to MockAttester and that nothing
  about World ID is enforced onchain. Those were TRUE until 11667630 and are FALSE now.

Step 7 (documentation): complete (380a79ae) plus my own d7bd4c2.
  Spot-checked its work rather than accepting the report, because this is the honesty-
  critical piece and the project's one prior failure was in exactly this file. All four
  "still not true" points survived at the strength I specified:
    README.md:135    MockAttester still deployed and still used by PolicyApprovals.approve
                     and LeashRegistry.register, named as a deliberate scoping decision
    README.md:142-147 the digest path has never been exercised against World's live API, and
                     "the first live proof of the full chain will be the demo itself"
    README.md:245-247 credential_type comes back "device"; the guarantee lives in
                     enable_face_check, not in the proof
    README.md:149+   what verify actually proves, stated exactly: the RP signer signed this
                     precise digest before its deadline, NOT "a human approved this"
  It also opens by separating the two claims explicitly rather than blurring them. It left
  the asymmetry table and the unbindAgent scope paragraph untouched after checking every row.

  It flagged one already-false claim it deliberately kept out of scope, and was right to
  flag it and right not to expand unilaterally: README's Tests section still claimed "170
  unit and fuzz tests" and a printed "170 passed ... (171 total)". Actual is 201/1/0 -
  WorldAttester added 16, the digest getters 4, the integration file 7, the revoke fix 4.
  I fixed it (d7bd4c2). It matters more than a stale number usually would, because a reader
  reaches it immediately after the attestation claims that were just corrected, so a wrong
  count there undercuts the ones that are now right.

REMAINING: Step 6 only - the live demo beat, which needs the user, their phone, and the
  single face scan on expand-policy-demo1. Everything else on this plan is done.
  Not started: finishing-a-development-branch. That merges into main, which is a side effect
  outside this worktree, so it waits for the user.
