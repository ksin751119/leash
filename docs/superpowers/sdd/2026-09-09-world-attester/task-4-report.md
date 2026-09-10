# Task 4 report: the attestation endpoint and cross-check

## Status: DONE (fix rounds 1, 2, 3, and 4 applied)

## Fix round 4 (2026-09-09) — I2, I3, and doc-hygiene minors from the final review

**Commit:** `642738bda44ace11db53d0f4b8a186992525c61c` on branch `world-attester`. Folded
into one commit rather than split, per the team lead's "your call, just say which commits
contain what" — all four findings are in `world/`, none depend on each other, and none
warranted separate mutation-test ceremony the way C1 (round 3) did.

### I2 — index.html trimmed the signal inconsistently

`index.html:151` passed `$("signal").value` (untrimmed) to `IDKit.init`, while `:115`
sent `signal.trim()` to `/api/attest`, and `isDigest` (`:71`) also trims internally. Step
6 of the plan has the operator paste `$DIGEST` out of a shell into that field, making a
trailing newline or space a live possibility — which would route to `/api/attest` on the
trimmed test, bind IDKit's proof to the *untrimmed* string, and have the server hash the
*trimmed* one: the exact binding round 3's `hashSignal` fix depends on would diverge
again (or IDKit would throw first).

Fixed by trimming once, in the click handler, and threading that single trimmed value
into both `IDKit.init`'s `signal` and `handleVerify` (now a parameter,
`handleVerify(proof, signal)`, instead of a second, independent read of the input
field). No other consumer re-reads or re-trims.

### I3 — checkAttestEnv didn't validate WORLD_ATTESTER's shape

`buf()` (`attest.mjs`'s `Buffer.from(hex, "hex")` helper, used in `domainSeparator`)
truncates malformed hex rather than throwing — a too-short or non-hex `WORLD_ATTESTER`
would silently mis-encode the EIP-712 domain separator with no error anywhere.
`checkAttestEnv` only checked presence, not shape.

Added, in the same style as the existing two guards:
```js
if (!/^0x[0-9a-fA-F]{40}$/.test(env.WORLD_ATTESTER)) {
  return `WORLD_ATTESTER is not a 20-byte address (0x + 40 hex chars): ${env.WORLD_ATTESTER}`;
}
```
Extended `check-payload-binding.mjs`'s `envCases` with `"0x1234"` (too short) and
`"nope"` (non-hex), both expecting an error.

**Mutation test** (done for thoroughness, though not explicitly required this round):
backed up `attest.mjs`, removed the new format-check line, ran
`node check-payload-binding.mjs`:
```
ok    checkAttestEnv: all three vars set
ok    checkAttestEnv: WORLD_RP_SIGNER_PK missing -> WORLD_RP_SIGNER_PK not set
ok    checkAttestEnv: WORLD_ATTESTER missing -> WORLD_ATTESTER not set
FAIL  checkAttestEnv: WORLD_ATTESTER too short
FAIL  checkAttestEnv: WORLD_ATTESTER not hex
ok    the WORLD_ACTION error names the variable
...
2 MISMATCH
exit code: 1
```
Reverted `attest.mjs` from the backup (byte-for-byte diff confirmed clean), re-ran,
confirmed all 13 lines `ok` and `all checks agree` again before committing.

### Minor — crosscheck.mjs's signature-acceptance deadline was a time bomb

The signature-acceptance case reused the fourth hash case's deadline, `1800000900`
(2027-01-15). After that date, the contract's `verify` (`block.timestamp > deadline`)
starts rejecting for a reason unrelated to the encoding, and whoever hits it would go
hunting in the EIP-712 code for nothing. Changed only the signature check to compute
`Math.floor(Date.now() / 1000) + 900` fresh; the four hash-agreement cases (`cases`) are
untouched and stay exactly as deterministic as before — `type(uint64).max` is still one
of them, per instruction.

### Minor — stale future-tense docs naming a nonexistent contract

`world/server.mjs` (three spots: the file header, the `hashSignal` import comment, and
the `/api/verify` nullifier comment) and `world/README.md` (the nullifier-determinism
paragraph and the "one thing to change when wiring `AttesterGate`" section) all described
`/api/attest` and the EIP-712 attestation as future work, and all named a contract called
`AttesterGate` that was never real — the actual contract, live since Task 1, is
`WorldAttester`. Commit `45177b4` (routing digest signals to `/api/attest`, not mine)
already made the feature real, so these were stale by the time of this review. Rewrote
all five spots to state what's true now, and — per the team lead's separate correction —
made sure none of them claim anything *records* `nullifier_hash`: neither this harness
nor `WorldAttester` does; `WorldAttester` only checks a signature. Left the
already-correct `world/server.mjs:130-135` comment (the "one face scan authorises one
widening" claim) untouched, since round 3's `hashSignal` fix is exactly what makes that
claim true now, for the right reason.

Did **not** touch the top-level `README.md` or anything in `src/`, `test/`, `script/` —
per instruction, another agent was editing the top-level `README.md` concurrently, and
its `MockAttester` caveats are still accurate (the deploy hasn't happened).

### Plan updated

`docs/superpowers/plans/2026-09-09-world-attester.md`: `checkAttestEnv`'s code block
(Step 2) gains the `WORLD_ATTESTER` format check and its docstring paragraph; Step 4c's
`envCases` gains the two new cases; Step 3's `crosscheck.mjs` code block computes the
signature-check deadline fresh instead of reusing the fourth hash case's, with the same
"time bomb" reasoning inline. `index.html` isn't embedded in the plan (it's produced by
a different, later task), so I2 needed no plan update.

### Regression checks (post-fix)

- `node --check` on `server.mjs`, `attest.mjs`, `check-payload-binding.mjs`,
  `crosscheck.mjs`: clean.
- `forge test`: `201 tests passed, 0 failed, 1 skipped (202 total tests)`. Note this is
  up from the 197/1/0 baseline in earlier rounds — not a regression. Concurrent,
  legitimate work on another task (`src/LeashAccount.sol` / `test/LeashAccountBinding.t.sol`,
  a revoke-bypass fix, commits `5f498b4`/`4283570`/`4b8d9bf`) landed on this shared branch
  between round 3 and round 4 and added 4 passing tests. I did not touch either file at
  any point — confirmed via `git status --porcelain` throughout, which showed them as
  modified-but-unstaged (someone else's in-progress work) during round 3, and fully
  committed and clean by the time I ran this round's checks.
- `forge fmt --check`: exit 0, clean.
- `git status --porcelain` after this round's commit: clean working tree.

### Constraints honored

No requests to `developer.worldcoin.org`; `SEPOLIA_RPC`, `WORLD_RP_SIGNER_PK`, `ADMIN_PK`,
and `WALLET_PK` were never read, echoed, or set; `.env` was never opened; `src/`, `test/`,
`script/`, and the top-level `README.md` were not touched; no subagents dispatched; no
push.

### Concerns

None.

## Fix round 3 (2026-09-09) — CRITICAL: hashSignal hashed a digest in the wrong domain

**Commit:** `249aa91d39a20c0508deded876c8ea2882e80be1` on branch `world-attester`.

### The bug

`hashSignal` did `keccak_256(signal)` with `signal` as a JavaScript string. `@noble/hashes`
UTF-8-encodes a string argument, so for a digest it hashed 66 ASCII characters. IDKit's own
`hashToField` (in the actual bundle, `@worldcoin/idkit-standalone@2.2.5`) takes the
opposite branch for any `0x`-prefixed string: it decodes to 32 raw bytes first. The two
implementations could never agree on the digest path — the only path `/api/attest` ever
takes — so every real call would fail World's `signal_hash` check, return non-200, sign
nothing, and spend the action's single face scan for nothing. This is the highest-stakes
defect found across all three rounds: everything else in this task could be exercised and
verified; this one meant the endpoint could never succeed on its actual input, and nothing
in rounds 1 or 2 could have caught it (see below).

Team lead's measurement, reproduced independently after the fix:
```
digest = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121
wrong (utf8 of the 66-char string): 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
right (keccak of 32 raw bytes):     0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
```

### The fix

`hashSignal` now mirrors `hashToField`'s two branches:
```js
export function hashSignal(signal) {
  const bytes = /^0x[0-9a-fA-F]*$/.test(signal) ? buf(signal) : Buffer.from(signal, "utf8");
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
}
```
The regex is deliberately stricter than IDKit's own non-strict `Hex.validate` (which would
also accept malformed hex like `0xnothex`) — for every real digest the two agree, and being
stricter here only ever fails safe. Confirmed by direct measurement that this changes
nothing for the two paths that must not move:
- `hashSignal("")` still equals the `world/README.md` baseline
  `0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4`.
- `hashSignal("widen:vendors.acme.eth:5000")` (the 2026-09-07 end-to-end run's signal)
  still takes the UTF-8 branch.
- `hashSignal(<the digest above>)` now equals the IDKit-measured value
  `0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3`.

### Why nothing in rounds 1 or 2 caught this

Both existing checks assert properties of `buildVerifyPayload` and `checkAttestEnv`
*against `hashSignal`'s own output* — they pin that the payload uses `hashSignal(digest)`
rather than a caller-supplied value, which is a real and correctly-guarded property, but
says nothing about whether `hashSignal` itself computes the right value. Such a check
agrees with `hashSignal` no matter how wrong its hashing domain is. `crosscheck.mjs` never
touches `hashSignal` at all (it only cross-checks the Solidity-side EIP-712 hash). And the
2026-09-07 end-to-end run used a plain-string signal, which coincidentally takes the same
branch as the buggy always-UTF-8 code — so the digest path had never once been exercised
before this review.

### The new checks, and the mutation result

Extended `world/check-payload-binding.mjs` with four `hashSignal` assertions whose expected
values are computed **without calling `hashSignal`** — the fix for the exact blind spot
above:
- A zero digest (`0x` + 32 zero bytes) — expected value computed inline from raw bytes via
  a local `toSignalHash` helper.
- The real digest from the team lead's measurement — expected value **hardcoded** to
  `0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3`.
- The empty string — expected value **hardcoded** to the `README.md` baseline.
- The plain string `"widen:vendors.acme.eth:5000"` — expected value computed inline via
  `keccak_256(Buffer.from(str, "utf8")) >> 8`.

Ran against the fixed code — all 11 checks (7 from rounds 1/2, 4 new) pass:
```
ok    signal_hash is hashSignal(digest), not proof.signal_hash
ok    action is the server's configured action, not proof.action
ok    checkAttestEnv: all three vars set
ok    checkAttestEnv: WORLD_RP_SIGNER_PK missing -> WORLD_RP_SIGNER_PK not set
ok    checkAttestEnv: WORLD_ATTESTER missing -> WORLD_ATTESTER not set
ok    checkAttestEnv: WORLD_ACTION missing -> WORLD_ACTION not set: ...
ok    the WORLD_ACTION error names the variable
ok    hashSignal: a zero digest is decoded as 32 raw bytes, not UTF-8
ok    hashSignal: a real digest is decoded as 32 raw bytes (measured against IDKit's own bundle)
ok    hashSignal: the empty string still takes the UTF-8 branch (world/README.md baseline)
ok    hashSignal: a plain (non-hex) string still takes the UTF-8 branch

all checks agree
```

**Mutation test.** Backed up `world/attest.mjs`, reverted `hashSignal` to the old
always-UTF-8 form (`keccak_256(signal)` on the raw string, no branch). Ran
`node check-payload-binding.mjs` — the two digest cases failed, reproducing the exact wrong
value from the team lead's report, while the two string cases stayed green:
```
FAIL  hashSignal: a zero digest is decoded as 32 raw bytes, not UTF-8
      want 0x00290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e5
      got  0x004f64fe1ce613546d34d666d8258c13c6296820fd13114d784203feb91276e8
FAIL  hashSignal: a real digest is decoded as 32 raw bytes (measured against IDKit's own bundle)
      want 0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
      got  0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
ok    hashSignal: the empty string still takes the UTF-8 branch (world/README.md baseline)
ok    hashSignal: a plain (non-hex) string still takes the UTF-8 branch

2 MISMATCH
exit code: 1
```
The mutated "got" value for the real digest (`0x007cd569...`) matches the team lead's
reported "wrong" value exactly. Reverted `attest.mjs` from the backup (byte-for-byte diff
confirmed clean), re-ran the check, confirmed all 11 lines `ok` and `all checks agree`
again before committing.

### Plan, README, and world-feedback.md updated

- `docs/superpowers/plans/2026-09-09-world-attester.md`: Step 2's `attest.mjs` code block
  for `hashSignal` gained the two-branch rule and its docstring (mirroring the real code's
  `@dev 🔴` comment); new Step 4d documents the extended check and explicitly flags its
  mutation test as "the one a reader must not skip."
- `world/README.md`: the signal_hash section now states both branches explicitly (was:
  "`keccak256(signal) >> 8`", stated as if single-branch — the same simplification that
  caused the bug) and gives a known-answer baseline for **each** branch, not only the
  empty-string one.
- `docs/world-feedback.md`: added §7.7, documenting that §7.3's existing entry described
  only the UTF-8 branch (the one our first, plain-string signal happened to take), and that
  the missing hex/bytes branch is exactly the class of undocumented, silently-wrong,
  high-consequence finding this document exists to capture. Also touched the Summary
  section's item 5 to reference §7.7.

### Decision on docs/world-feedback.md: yes, added an entry

Chosen to add §7.7 rather than leave this internal-only. Reasoning: `world-feedback.md` is
explicitly a running log of measured, dated integration findings for the World Selfie
Check prize track, and its existing §7.3 already covers `signal_hash` — this finding is a
direct, material correction/extension of that entry (a second hashing branch the original
entry never disclosed, discovered by reading IDKit's own bundle), not speculation. It meets
the document's own bar: measured directly, dated, distinguishes what was confirmed from
what wasn't. Framed it as building on §7.3 rather than replacing it, per the document's own
practice of keeping earlier entries visible and correcting forward (see its Summary
preamble, which does exactly this for an earlier access-gate finding).

### Regression checks (post-fix)

- `node --check` on `server.mjs`, `attest.mjs`, `check-payload-binding.mjs`: clean.
- `forge test`: `197 tests passed, 0 failed, 1 skipped (198 total tests)`.
- `forge fmt --check`: exit 0, clean.

**Important caveat on the above two forge results:** this worktree is shared with
concurrent work on another task. At the time of this fix, `git status` showed uncommitted,
in-progress changes to `src/LeashAccount.sol` and `test/LeashAccountBinding.t.sol` that I
did not make (a `RevokedNeedsRestore` guard on `unbindAgent`/`bindAgent`, unrelated to World
attestation) alongside three commits from other work already on the branch
(`fb03954`, `45177b4`, `42930f6` — a deploy script and Selfie Check harness routing, not
mine). `forge test` necessarily runs against the full working tree, so the 197/1/0 result
reflects that combined state, not my changes in isolation — though my changes are
JS-only and cannot affect Solidity test outcomes either way. I did not stage, commit, run
`forge fmt` (only the read-only `--check`), or otherwise touch either file: confirmed via
`git status --porcelain` immediately after my commit, which shows only those two files
still modified and unstaged.

### Constraints honored

No requests to `developer.worldcoin.org`; `SEPOLIA_RPC`, `WORLD_RP_SIGNER_PK`, `ADMIN_PK`,
and `WALLET_PK` were never read, echoed, or set; `.env` was never opened; `src/`, `test/`,
and `script/` were not modified by me (see caveat above re: pre-existing concurrent
changes I left untouched); no subagents dispatched; no push.

### Concerns

None regarding my own changes. Flagging for visibility, not as a defect I'm asking to be
assigned: the concurrent uncommitted `src/LeashAccount.sol` / `test/LeashAccountBinding.t.sol`
changes in this shared worktree belong to different, unrelated work and were left exactly
as found.

## Fix round 1 (2026-09-09) — Critical: signal_hash and action pinning

**Commit:** `eae52c94668f1b04da81b91fedca6bf809e07945` on branch `world-attester`.

### The defect

`/api/attest`'s handler built its verify payload as:
```js
signal_hash: proof.signal_hash ?? hashSignal(digest),
action: action ?? ACTION,
```
`/api/attest` is raw JSON with no trusted caller (`world/index.html` never calls it), so
`proof` and the rest of the body are attacker-controlled. `signal_hash` is the entire
binding between a face scan and the digest it approved — if a caller could supply it, an
attacker who captured one genuine proof P (a real scan that approved digest D1, carrying
its own `signal_hash` S) could POST `{ digest: D2, proof: { ...P, signal_hash: S } }`.
World verifies P happily, since S is exactly what's baked into it, and the server would
then sign an attestation for D2, a widening no human's face ever approved. `action` had
the identical shape: a proof is bound to the action it was generated for, and this app
mints a fresh action per demo (`max_verifications` is 1 and cannot be raised —
`expand-policy` itself was already consumed on 2026-09-07); without pinning, a scan from
an already-retired action would still buy a widening today.

### The fix

- Extracted payload construction into `buildVerifyPayload({ digest, proof, action })` in
  `world/attest.mjs`. It computes `signal_hash` unconditionally from `digest` (never
  `proof.signal_hash`) and uses `action` only as a trusted parameter with no fallback to
  anything inside `proof`.
- Moved `hashSignal` from `server.mjs` into `attest.mjs` too (pure crypto helper, now
  shared by `buildVerifyPayload` and `/api/verify`'s own inline payload).
- `server.mjs`'s `/api/attest` handler now destructures only `{ digest, proof }` from the
  body — `action` is never read from the request at all — and calls
  `buildVerifyPayload({ digest, proof, action: ACTION })`, where `ACTION` is the server's
  own env-configured constant.
- Left `/api/verify` untouched, per instruction — it only relays World's answer and signs
  nothing, so its identical-looking `proof.signal_hash ?? hashSignal(signal ?? "")` is not
  the same risk.

### The new check, and its mutation result

Added `world/check-payload-binding.mjs` — a pure, no-network, no-chain check. It calls
`buildVerifyPayload` with a `digest`, a trusted `serverAction` ("expand-policy"), and a
hostile `proof` object carrying both a fake `signal_hash` and a fake `action`, then asserts
the returned payload's `signal_hash` equals `hashSignal(digest)` (not the hostile value)
and its `action` equals `serverAction` (not the hostile value).

Ran it against the fixed code first:
```
ok    signal_hash is hashSignal(digest), not proof.signal_hash
      want 0x007bfbd480b491516897eb64ee7435a1bc07bd3e4eba95bae6f3b5600fef304d
      got  0x007bfbd480b491516897eb64ee7435a1bc07bd3e4eba95bae6f3b5600fef304d
ok    action is the server's configured action, not proof.action
      want expand-policy
      got  expand-policy

all checks agree
```

**Mutation test.** Backed up `world/attest.mjs`, then edited `buildVerifyPayload` in place
to reintroduce both fallbacks:
```js
action: proof.action ?? action, // MUTATION: reintroduced the fixed bug for testing
...
signal_hash: proof.signal_hash ?? hashSignal(digest), // MUTATION: same class
```
Ran `node check-payload-binding.mjs` against the mutated file. Result — both lines failed,
exit code 1:
```
FAIL  signal_hash is hashSignal(digest), not proof.signal_hash
      want 0x007bfbd480b491516897eb64ee7435a1bc07bd3e4eba95bae6f3b5600fef304d
      got  0xdededededededededededededededededededededededededededededededede
FAIL  action is the server's configured action, not proof.action
      want expand-policy
      got  old-retired-action

2 MISMATCH
exit code: 1
```
Reverted `attest.mjs` from the backup (byte-for-byte diff confirmed clean), re-ran the
check, confirmed `all checks agree` again before committing.

### Plan updated

`docs/superpowers/plans/2026-09-09-world-attester.md`, Task 4:
- Interfaces section: `attest.mjs`'s produced interface now lists `hashSignal` and
  `buildVerifyPayload`; `POST /api/attest` documented as accepting `{ digest, proof }`
  (not `action`).
- Step 2's `attest.mjs` code block: added `hashSignal` and `buildVerifyPayload`, each with
  a docstring explaining why `signal_hash`/`action` cannot come from the caller (the two
  attacks above), plus the `randomBytes` import needed for the nonce.
- Step 4's `server.mjs` code block: handler now calls `buildVerifyPayload`, destructures
  only `{ digest, proof }`, and the import line adds `buildVerifyPayload`/`hashSignal`.
- Added Step 4b documenting `check-payload-binding.mjs` and its mutation-check procedure,
  so a future reader rebuilding from the plan gets the fixed shape and knows how to verify
  it.

### Regression checks (post-fix)

- `node --check` on `server.mjs`, `attest.mjs`, `check-payload-binding.mjs`: clean.
- `forge test`: `197 tests passed, 0 failed, 1 skipped (198 total tests)` — unchanged from
  before the fix; no `src/` or `test/` file was touched (confirmed via
  `git status --porcelain` before commit — only `docs/`, `world/attest.mjs`,
  `world/server.mjs`, and the new `world/check-payload-binding.mjs` changed).
- `forge fmt --check`: exit 0, clean.

### Constraints honored

Same as the original task: no requests to World's live API at any point (the new check is
pure JS with no network calls); `SEPOLIA_RPC` and `WORLD_RP_SIGNER_PK` were never read,
echoed, or set; `src/` and `test/` untouched; no subagents dispatched; no push.

## Fix round 2 (2026-09-09) — guard: require a fresh WORLD_ACTION for /api/attest

**Commit:** `fa3bc4883ce873e4b4b6f53200234f798a32d423` on branch `world-attester`.

### The problem

`server.mjs`'s module-level `ACTION` falls back to `"expand-policy"` — a default that was
already consumed on 2026-09-07, with `max_verifications` unable to be raised for it. That
fallback is fine for `/api/config`, `/api/precheck`, and `/api/verify` (the verification
harness's other routes), but round 1's fix made `/api/attest` use the server's configured
action exclusively (correctly — that closed the action-pinning defect). The side effect:
an unset `WORLD_ACTION` env var would make `/api/attest` silently send the dead
`"expand-policy"` action to World on every call, and the failure would look like "World is
being weird" during a live demo rather than "an environment variable is missing."

### The fix

- Added `checkAttestEnv(env)` to `world/attest.mjs`: a pure function of an env-like object,
  checked alongside the existing `WORLD_RP_SIGNER_PK` / `WORLD_ATTESTER` checks. It returns
  `null` if all three are set, or a specific error string otherwise. The `WORLD_ACTION`
  case names the variable and the reason (consumed default, `max_verifications` cannot be
  raised) rather than a bare "not set" — so someone debugging this at 2am before a demo
  doesn't have to read the source.
- `world/server.mjs`'s `/api/attest` handler now calls `checkAttestEnv(process.env)` before
  building the payload, and — once it passes — uses `process.env.WORLD_ACTION` directly
  (never the module-level `ACTION` constant) so the consumed-default fallback can never
  reach World from this endpoint even if the guard itself is ever loosened.
- The other three routes (`/api/config`, `/api/precheck`, `/api/verify`) are untouched and
  keep the `ACTION` default — scoped deliberately narrowly, per the ask.
- Added a line to `world/README.md`'s existing `max_verifications` section: `/api/attest`
  requires `WORLD_ACTION` set to a fresh action and refuses (500) without it.

### Why the guard had to be a pure function, not tested via the live handler

Testing the guard by driving the actual HTTP handler would require either (a) letting a
request past a broken guard reach `fetch(VERIFY_URL)` — a live call to
`developer.worldcoin.org`, which is prohibited — or (b) mocking `fetch`, which adds
complexity without adding confidence over testing `checkAttestEnv` directly. Extracting it
as a pure function of an env-like object sidesteps this entirely: the check never starts a
server, opens a socket, or touches the network.

### The check, and its mutation result

Extended `world/check-payload-binding.mjs` (chose to extend the same file rather than add a
sibling: both this and round 1's check are "does /api/attest trust something it must not"
checks over `attest.mjs`'s exported functions, and keeping them together means one command,
`node check-payload-binding.mjs`, tells the whole story for this endpoint's trust
boundary). Added:
- Four `checkAttestEnv` cases: all three vars set (expect `null`), and each of
  `WORLD_RP_SIGNER_PK`, `WORLD_ATTESTER`, `WORLD_ACTION` missing individually (expect a
  non-empty error string).
- One assertion that the `WORLD_ACTION`-missing error string actually contains
  `"WORLD_ACTION"`.

Ran against the fixed code — all 7 checks (2 from round 1, 5 new) pass:
```
ok    signal_hash is hashSignal(digest), not proof.signal_hash
ok    action is the server's configured action, not proof.action
ok    checkAttestEnv: all three vars set
ok    checkAttestEnv: WORLD_RP_SIGNER_PK missing -> WORLD_RP_SIGNER_PK not set
ok    checkAttestEnv: WORLD_ATTESTER missing -> WORLD_ATTESTER not set
ok    checkAttestEnv: WORLD_ACTION missing -> WORLD_ACTION not set: the built-in default ("expand-policy") was already consumed on 2026-09-07 and max_verifications cannot be raised for a consumed action. Create a fresh action in the Portal and set WORLD_ACTION to it before running /api/attest.
ok    the WORLD_ACTION error names the variable

all checks agree
```

**Mutation test.** Backed up `world/attest.mjs`, removed the `if (!env.WORLD_ACTION) {...}`
branch from `checkAttestEnv` (replaced with a comment marker), leaving only the
`WORLD_RP_SIGNER_PK` / `WORLD_ATTESTER` checks. Ran `node check-payload-binding.mjs` —
both `WORLD_ACTION`-related lines failed, exit code 1:
```
ok    checkAttestEnv: all three vars set
ok    checkAttestEnv: WORLD_RP_SIGNER_PK missing -> WORLD_RP_SIGNER_PK not set
ok    checkAttestEnv: WORLD_ATTESTER missing -> WORLD_ATTESTER not set
FAIL  checkAttestEnv: WORLD_ACTION missing
FAIL  the WORLD_ACTION error names the variable

2 MISMATCH
exit code: 1
```
Reverted `attest.mjs` from the backup (byte-for-byte diff confirmed clean), re-ran the
check, confirmed all 7 lines `ok` and `all checks agree` again before committing.

### Plan and README updated

- `docs/superpowers/plans/2026-09-09-world-attester.md`: Step 2's `attest.mjs` code block
  gained `checkAttestEnv` (with the same reasoning docstring as the real code); Step 4's
  `server.mjs` code block gained the guard call and switched the payload's `action` to
  `process.env.WORLD_ACTION`; the import line gained `checkAttestEnv`; a new Step 4c
  documents the extended check and its mutation-test procedure.
- `world/README.md`: added a line under the existing `max_verifications` section noting
  `/api/attest` requires `WORLD_ACTION` and refuses to run without it.

### Regression checks (post-fix)

- `node --check` on `server.mjs`, `attest.mjs`, `check-payload-binding.mjs`: clean.
- `forge test`: `197 tests passed, 0 failed, 1 skipped (198 total tests)` — unchanged; no
  `src/` or `test/` file touched (confirmed via `git status --porcelain` before commit —
  only `docs/`, `world/README.md`, `world/attest.mjs`, `world/server.mjs`, and
  `world/check-payload-binding.mjs` changed).
- `forge fmt --check`: exit 0, clean.

### Constraints honored

No requests to `developer.worldcoin.org` at any point; `SEPOLIA_RPC` and
`WORLD_RP_SIGNER_PK` were never read, echoed, or set; `src/` and `test/` untouched; no
subagents dispatched; no push.

### Concerns

None.

## What was done

- **Step 1** — `cd world && npm i @noble/curves@2`. `world/package.json` now lists
  `"@noble/curves": "^2.4.0"` in `dependencies`. Verified both import styles resolve:
  `node -e "import('@noble/hashes/sha3.js').then(()=>console.log('ok'))"` → `ok`, and the
  same for `@noble/curves/secp256k1.js` → `ok2`. `world/node_modules` was already present
  from the team lead's `npm ci`, so this only added the new dependency.
- **Step 2** — Created `world/attest.mjs` verbatim from the brief: `domainSeparator`,
  `attestationHash({ digest, deadline, chainId, verifyingContract })`, and
  `signAttestation({ digest, deadline, chainId, verifyingContract, privKeyHex })`. Kept the
  ⚠️/🚫 header comments exactly as given, including the prohibition on fetching the hash
  from the chain — this file computes the EIP-712 hash independently in JS and does not
  call the contract anywhere.
- **Step 3** — Created `world/crosscheck.mjs` verbatim from the brief: reads `SEPOLIA_RPC`
  and `WORLD_ATTESTER` from env, reads chain id live from the RPC rather than hardcoding
  it, compares `attestationHash` across 4 digest/deadline cases against
  `attestationHash(bytes32,uint64)` on the deployed contract, and — when `SIGNER_PK` is
  set — signs a blob, checks it's 73 bytes, and calls `verify(bytes32,bytes)` on the
  contract to confirm it accepts the signature (the only check that can catch the
  recovery-byte-ordering bug, since a mis-packed blob is still 73 bytes).
- **Step 4** — Added `import { signAttestation } from "./attest.mjs";` to `world/server.mjs`
  beside the existing `@noble/hashes` import, and inserted the `POST /api/attest` block
  immediately after the `/api/verify` block closes, before the `json(res, 404, …)`
  fallthrough. Verbatim from the brief: validates `digest` format, requires `proof`,
  requires `WORLD_RP_SIGNER_PK` and `WORLD_ATTESTER` env vars, builds the same
  v4-legacy-wrapped payload as `/api/verify` (with `signal_hash` derived from `digest` via
  `hashSignal`), POSTs to `VERIFY_URL`, and only calls `signAttestation` (chainId
  `11155111`, i.e. Sepolia) if World's response is HTTP 200. Returns
  `{ attestation, deadline, nullifier }`. Did not touch `WORLD_RP_SIGNER_PK` at any point —
  never read, echoed, printed, or set it.
- **Step 5** — Ran the cross-check locally against anvil, from this worktree's own
  checkout (not `~/DEV/leash`), per the note about `src/WorldAttester.sol` existing only on
  this branch.

## Cross-check output (Step 5)

Anvil started on `127.0.0.1:8545` (chain id confirmed `0x7a69` = 31337 via `eth_chainId`
before deploying).

Deploy:
```
forge create src/WorldAttester.sol:WorldAttester --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast --constructor-args 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```
(Note: `--constructor-args` had to be the **last** flag on this forge 1.7.1 build — placing
it before `--rpc-url`/`--private-key`/`--broadcast` produced
`Error: Constructor argument count mismatch: expected 1 but got 6` even though the value
itself was a single, valid 40-hex-char address. Moving it to the end of the command line
fixed it; this looks like a forge CLI arg-parsing quirk on this version, not anything
wrong with the constructor or the address.)

Deployed to: `0x5FbDB2315678afecb367f032d93F642f64180aa3`

Cross-check run:
```
cd world && SEPOLIA_RPC=http://127.0.0.1:8545 WORLD_ATTESTER=0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  SIGNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 node crosscheck.mjs
```

Output:
```
chain id 31337, attester 0x5FbDB2315678afecb367f032d93F642f64180aa3
ok    deadline=0
      js    0x2bded8af8c072dcdfe3684033d14a76149bdae9a7e5e3b3edd09cf6d110117fc
      chain 0x2bded8af8c072dcdfe3684033d14a76149bdae9a7e5e3b3edd09cf6d110117fc
ok    deadline=1
      js    0xec1f992baa2f2b6e0544673964d390e1113fc9d0bf7972b8a713d34b967a9968
      chain 0xec1f992baa2f2b6e0544673964d390e1113fc9d0bf7972b8a713d34b967a9968
ok    deadline=18446744073709551615
      js    0x5e3868676b3ef5d6204ebd0ce82da8ad86e1bbec603f90276ab4a942a6d5700f
      chain 0x5e3868676b3ef5d6204ebd0ce82da8ad86e1bbec603f90276ab4a942a6d5700f
ok    deadline=1800000900
      js    0xcbb8b0750fc23889ecfd4aba13727a1f1c8a5faabce3aa6c83ccce6fa0c9f840
      chain 0xcbb8b0750fc23889ecfd4aba13727a1f1c8a5faabce3aa6c83ccce6fa0c9f840
ok    blob is 73 bytes (want 73)
ok    the contract accepts this signature

all cross-checks agree
```

Six `ok` lines, `chain id 31337`, `all cross-checks agree` — matches the expected result
exactly. Anvil was killed afterward (`pkill -f "anvil --port 8545"`).

## Regression checks

- `forge test`: `Ran 13 test suites in 61.25ms: 197 tests passed, 0 failed, 1 skipped (198
  total tests)` — matches the required baseline of 197 passed / 1 skipped / 0 failed both
  before and after this task's changes. No `src/` or `test/` files were touched (confirmed
  via `git status --porcelain` — only files under `world/` changed).
- `forge fmt --check`: exit 0, no output — clean.

## Commit

`0e8ad23aff89bb84b58e0292d30fb9c0dcd726da` on branch `world-attester`, authored as
`albertlin <ksin751119@gmail.com>`, containing:
- `world/attest.mjs` (new)
- `world/crosscheck.mjs` (new)
- `world/server.mjs` (modified — import + `/api/attest` route)
- `world/package.json`, `world/package-lock.json` (modified — `@noble/curves` dependency)

## Prohibitions honored

- Never sent any request to World's live API (`developer.worldcoin.org`) — the endpoint
  was written but never exercised against a real or fake proof.
- Never echoed `SEPOLIA_RPC` — Step 5 only ever used the local anvil URL
  `http://127.0.0.1:8545`, which carries no secret, so there was nothing to redact.
- Never read, echoed, printed, or set `WORLD_RP_SIGNER_PK`.
- Did not modify anything under `src/` or `test/`, did not touch `docs/info.md`, did not
  push or merge, did not dispatch any subagents.

## Concerns

None. One minor observation worth flagging: forge 1.7.1's `--constructor-args` flag
appears to require being the last argument on the command line in this environment
(placing it mid-command triggered a spurious "expected 1 but got 6" parse error even
though the ABI and the argument were both correct). This is a CLI usage note for whoever
runs Task 5's Sepolia deploy, not a code defect — I did not modify anything in `src/` to
work around it.
