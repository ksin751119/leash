# Scoped re-review — fix range `42930f6..642738b` (6 commits)

Adversarial re-review of the fixes made in response to `final-review-report.md`. Scope is the
fix diff only. Nothing in the worktree was modified by this review; `git status` clean at
`642738b`.

## Verified green (my own runs)

- `forge test` → **201 passed / 1 skipped / 0 failed**
- `forge fmt --check` → clean
- `node --check` → clean on all four `world/*.mjs`
- `node world/check-payload-binding.mjs` → 13 `ok`, `all checks agree`, exit 0
- `world/crosscheck.mjs` against a local anvil on port 8548 (fresh `WorldAttester`, anvil
  account #0 as signer) → 4 hash `ok` **including `deadline=18446744073709551615`**,
  `blob is 73 bytes`, `the contract accepts this signature`, `all cross-checks agree`.
  Anvil killed afterwards; no request was sent to `developer.worldcoin.org`; nothing
  broadcast to Sepolia.

---

## 1. C1 — ADDRESSED, and the new assertions are genuinely independent

`world/attest.mjs:118-119` mirrors IDKit's `hashToField`: a `0x`-prefixed hex signal goes
through `buf()` (decoded to raw bytes), anything else through `Buffer.from(signal, "utf8")`.

The critical part — the new assertions do **not** pin the code against itself. The four
`hashCases` in `world/check-payload-binding.mjs:104-125` never call `hashSignal` to build a
`want`: two are computed by a locally re-implemented `toSignalHash` over raw bytes, two are
hardcoded from measurement. I re-derived both hardcoded values with `cast keccak`,
independently of anything in this repo:

```
keccak(32 raw bytes of 0x9b4c…e121) = 0x1387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf376
                               >> 8 = 0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3  ✓ hardcoded value
keccak(0x)                          = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
                               >> 8 = 0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4  ✓ README baseline
keccak(utf8 of the 66-char string)  >> 8 = 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260  ✓ the documented wrong value
```

The UTF-8 branch is unchanged and `hashSignal("")` still equals the documented baseline.
Bonus: the pre-existing (necessarily self-referential) round-1 `signal_hash` assertion's
value `0x001874b9…3e93` equals `keccak(32×0x42) >> 8`, so even that one now sits on the
correct branch.

## 2. I1 — ADDRESSED, and no other route reopens it

Only two writers can produce an active binding:

- `bindAgent` (`src/LeashAccount.sol:229`), guarded by `b.node != bytes32(0)` → `AlreadyBound`
- `restoreAgent` (`src/LeashAccount.sol:294`), `onlySelf` **and** `_consumeAttestation`

The one state that would defeat that guard is `node == 0 && revoked == true` — `bindAgent`
never clears `revoked`, so such a binding could be re-activated silently. It is now
unreachable: the only `delete` of a binding is `src/LeashAccount.sol:274`, behind the new
`RevokedNeedsRestore` guard, and `revokeAgent` cannot mark a never-bound agent because
`_requireSelfOrAgent` (`:346-348`) reverts `NotBoundAgent` when `node == 0`.

Legitimate remedy intact: `test_a_mis_binding_is_correctable_for_free`
(`test/LeashAccountBinding.t.sol:328`) unbinds a never-revoked binding and still passes.

Accepted costs, correctly documented in the fix: a revoked binding's storage can never be
freed, and an agent that revokes itself can only be cleared through an attested
`restoreAgent`. `restoreAgent` can restore under a *different* node/label, but that is still
attested, so the widening/reduction asymmetry holds.

## 3. I2 — ADDRESSED

`world/index.html:156` is the single `.trim()`, threaded into both consumers: `IDKit.init`'s
`signal` (`:160`) and `handleVerify(proof, signal)` (`:162`). The only other read of the raw
field is the UI hint at `:76` (and `isDigest` trims internally anyway). Passing the value as
a parameter rather than re-trimming in each consumer makes divergence structurally
impossible, not merely coincidentally absent.

## 4. I3 — ADDRESSED (shape half); the linkage half was not implemented

`world/attest.mjs:197` enforces `/^0x[0-9a-fA-F]{40}$/` and the error names the variable and
prints the offending value. Both new negative cases pass:

```
ok    checkAttestEnv: WORLD_ATTESTER too short -> WORLD_ATTESTER is not a 20-byte address (0x + 40 hex chars): 0x1234
ok    checkAttestEnv: WORLD_ATTESTER not hex   -> WORLD_ATTESTER is not a 20-byte address (0x + 40 hex chars): nope
```

The ledger routed a second closure in the same message — plan Step 4's keyless
`cast call "$W" 'ATTESTER()(address)' == WORLD_ATTESTER` — which was not implemented:
`ATTESTER()` has 0 occurrences in `docs/superpowers/plans/2026-09-09-world-attester.md` and
in `script/DeployWorldAttester.s.sol`. Recorded under Findings; the team lead has taken it.

## 5. `restoreDigest` — ADDRESSED, and the negative result independently confirmed

`src/LeashAccount.sol:555-556` mirrors `restoreAgent:301-302`, with
`test_restoreDigest_rejects_a_node_label_mismatch` in `test/LeashAccountDigests.t.sol`.

Verifying the "there is no analogous gap" claim myself rather than on report:

- `allowPayee` (`src/LeashAccount.sol:351-363`) calls `_consumeAttestation` as its **first**
  statement, with no validation of any kind before it.
- `setRule` (`src/LeashAccount.sol:400-470`) also consumes first, and every line after the
  consume is storage writes plus event logic with **no revert path** — the `epoch` bump
  cannot revert, and `_isTighterIgnoringEpoch` is used only to decide whether to emit
  `LimitRaised`.

So no digest obtainable from `ruleDigest` or `payeeDigest` can be unconsumable. The negative
result holds. (`tightenRule`'s `NotTighter` is not a counterexample: it is on the reduction
path and has no digest getter.)

## 6. Minors — ADDRESSED

- **`world/crosscheck.mjs`**: the `cases` array is untouched — `type(uint64).max` is still
  `cases[2]` and I watched `deadline=18446744073709551615` pass against a real deployment.
  Only the signature-acceptance case got its own `Math.floor(Date.now()/1000) + 900`
  (`:73`), with a comment stating why it is deliberately not `cases[3][1]`. The four
  hash-agreement cases remain fully deterministic. Nothing was made non-deterministic and no
  coverage was dropped — this change is strictly stronger than what it replaced.
- **`AttesterGate`**: 0 occurrences in `world/README.md` and `world/server.mjs`. The
  rewritten text in both is accurate — `world/README.md:114-117` and `world/server.mjs:125-128`
  now say plainly that neither the harness nor `WorldAttester` records a nullifier.
- **`.env.example`**: `WORLD_ATTESTER` and `WORLD_ACTION` both present, with the
  `max_verifications` warning on the latter.
- **Spec `:286-291`**: once-per-person is now attributed to World's `max_verifications: 1`,
  with an explicit statement that nothing in `server.mjs` records a nullifier. Accurate
  against the code.

---

## New findings

### Minor — plan Step 4 never asserts the attester the wallet actually trusts

`docs/superpowers/plans/2026-09-09-world-attester.md:1596-1615`; `script/DeployWorldAttester.s.sol:27-43`.

I3's second half was silently dropped: Step 4 checks `SIGNER()` but nothing checks that
`WORLD_ATTESTER` is the attester the deployed `LeashAccount` impl points at. Exposure for
*this* deployment is small — `script/DeployWorldAttester.s.sol:32-34` constructs the impl
with `IAttester(address(att))` in the same script, so impl↔attester cannot drift, and there
is no prior Sepolia `WorldAttester` for a stale `.env` value to point at. A mis-paste of the
*LeashAccount* address into `WORLD_ATTESTER` would be caught, because `crosscheck.mjs`'s
`eth_call` to `attestationHash(bytes32,uint64)` would revert. It becomes a real,
scan-costing hole the moment Step 3 is ever re-run. Taken by the team lead.

### Minor — `hashSignal`'s docstring overstates the regex's safety

`world/attest.mjs:113-114`: "being stricter here only ever fails safe." Not true for
odd-length hex. Measured:

```
hashSignal("0xabc") = 0x00468fc9c005382579139846222b7b0aebc9182ba073b2455938a86d9753bfb0
keccak(<0xab>) >> 8 = 0x00468fc9c005382579139846222b7b0aebc9182ba073b2455938a86d9753bfb0   ← same: buf() truncated
utf8("0xabc")  >> 8 = 0x00851bb152e67e6c958ab7da1431fcaed09ce0efc598885f69a750b3b4b81fc1
```

`buf()` silently drops the odd nibble, where IDKit/`ox` throws on odd-length hex — so for
that input class our function is looser, not stricter. No practical exposure: `/api/attest`
anchors `/^0x[0-9a-fA-F]{64}$/` (`world/server.mjs:146-148`), and on `/api/verify` IDKit
throws before any proof exists. The comment claims more than the code does.

### Minor — stale comment introduced by the I1 fix

`test/LeashAccountBinding.t.sol:324-325`: "`unbindAgent` is entirely free (unbinding is a
reduction)", unqualified. The test body uses a never-revoked binding so it is still correct
in context, but the sentence is now false as written. `src/LeashAccount.sol:253-254` and
`README.md:95-111` were both updated; this one was missed.

### Minor (pre-existing, outside the fix scope) — last stale `AttesterGate` in `src/`

`src/IPolicyApprovals.sol:6` still says writing to the list "costs a face scan
(`AttesterGate`)". Every other surviving mention (`docs/events.md:225-227`, the 09-08 spec,
`docs/sprint.md`) is explicitly a struck-out or historical record and reads correctly.

### No Critical or Important findings.

---

## Did any fix weaken an existing check?

No.

- **`crosscheck.mjs`** — the one to look hardest at, and it came out strictly stronger. The
  `cases` array is byte-identical, so all four hash-agreement cases stay deterministic and
  the `type(uint64).max` edge still runs (confirmed live, not by reading). Only the
  signature-acceptance case moved to a fresh `Date.now()`-based deadline, which removes an
  expiry without removing a property. The feared outcome — non-deterministic hash cases and
  dropped `uint64` coverage — did not happen.
- **`check-payload-binding.mjs`** — gained 6 assertions (2 env-shape, 4 hashSignal), lost
  none. The round-1 and round-2 checks are unchanged.
- **`unbindAgent`** — the only capability removed is the bypass itself plus storage cleanup
  on a revoked binding. Every reduction remains free;
  `test_every_reduction_is_still_free_with_a_real_attester` still passes.
- **`restoreDigest`** — a `view` getter gained a precondition that its consumer already
  enforces. It cannot reject anything `restoreAgent` would have accepted.

## Is any documentation now false?

Only the one Minor above (`test/LeashAccountBinding.t.sol:324-325`). Everything else checks
out:

- `README.md:118-126` — the `MockAttester` caveats are intact and still correct. The
  deployment has not happened; they must stay until it does.
- `README.md:88` + `:95-111` — the table row plus the new exception paragraph, including the
  "what this does and does not claim" qualifier about binding a fresh address, is an accurate
  description of the contracts as they now stand.
- `world/README.md:114-117`, `world/server.mjs:125-128`, spec `:286-291` — the nullifier and
  once-per-person rewrites all match the code.

## Does the "one face scan authorises exactly one widening" overstatement survive anywhere?

No. With C1 fixed the claim is accurate in code, so `world/server.mjs:135` ("here it becomes
real"), `world/README.md:140` ("real today") and plan `:7` are no longer overstatements.

One residual worth saying out loud rather than a false claim: the digest path has still never
been exercised against World's live API — deliberately, since the action's single
verification is spent. So "real today" rests on code correctness plus one hardcoded
measurement against IDKit's bundle, not on a live end-to-end run. That is the right call
given the constraint, but it means the first live proof of the property will be the demo
itself.

---

## Verdict

**Yes — safe to deploy to Sepolia.**

All six findings are fixed, and each fix is correct on the merits rather than merely present.
The two highest-stakes ones I verified from first principles instead of against the
implementer's account: C1's new assertions are independent of `hashSignal` (both hardcoded
values re-derived with `cast keccak`), and I1 is closed across every route into an active
binding, including the `node == 0 && revoked == true` state that would have defeated
`AlreadyBound`. No fix weakened an existing check; `crosscheck.mjs` in particular is stronger
than what it replaced. Nothing I found rises above Minor, and none of the Minors can cost a
face scan on this run.

The one line I would still spend before Step 6 is the `ATTESTER()` linkage assertion — cheap
insurance against a Step 3 re-run — which the team lead has taken.
