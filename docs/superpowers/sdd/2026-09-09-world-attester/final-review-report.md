# Final whole-branch review — `world-attester` (fee6fce..42930f6)

**Verified green:** `forge test` → 197 passed / 1 skipped / 0 failed. `forge fmt --check` → clean.
`node --check` clean on all four `.mjs`. Worktree left unmodified (`git status` clean at 42930f6);
all probing was done in an isolated forge project under the scratchpad, and the local anvil was killed.

---

## Critical

### C1 — `/api/attest` can never succeed: the signal hash is computed in the wrong domain

`world/attest.mjs:92-95` (`hashSignal`), consumed at `attest.mjs:130` inside `buildVerifyPayload`.

`hashSignal(digest)` does `keccak_256(signal)` where `signal` is the JavaScript **string**
`"0x9b4c…"`. `@noble/hashes` converts a string argument to UTF-8, so the server hashes 66 ASCII
characters. IDKit hashes the same signal as **32 decoded bytes**. From the bundle the page loads
(`@worldcoin/idkit-standalone@2.2.5`, `build/index.global.js:14576`):

```js
function hashToField(input) {
  if (Bytes.validate(input) || Hex.validate(input)) return hashEncodedBytes(input);  // ← 0x… goes here
  return hashString(input);                                                          // ← plain text
}
```

`Hex.validate` (non-strict, `index.global.js:12783`) accepts any string starting with `0x`, and
`hashEncodedBytes` → `ox`'s `Hash.keccak256(hex)` hex-decodes first. Measured, for
`digest = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121`:

```
server  hashSignal(digest string) : 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
IDKit   keccak(32 raw bytes) >> 8 : 0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
```

`signal_hash` is a public input to the proof, so the payload the server sends will not match the
proof and World will refuse it. `/api/attest` returns non-200, signs nothing, and **the action's
single verification is spent** — recovery means creating a fresh Portal action and scanning again.
Act three of the demo cannot complete.

Why every existing check missed it: `check-payload-binding.mjs` asserts
`signal_hash === hashSignal(digest)`, i.e. it pins the server against itself; `crosscheck.mjs` never
touches `hashSignal`; and the 2026-09-07 end-to-end run used the default non-hex signal
`widen:vendors.acme.eth:5000`, where both code paths coincide (confirmed: the string case still
matches). The digest path — the only one `/api/attest` ever takes — has never been exercised.

Fix — mirror `hashToField` rather than approximating it:

```js
export function hashSignal(signal) {
  const bytes = /^0x[0-9a-fA-F]*$/.test(signal) ? buf(signal) : Buffer.from(signal, "utf8");
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
}
```

Both callers stay correct: `/api/verify`'s string signals keep the old value (the `signal_hash("")`
baseline in `world/README.md:94-95` still holds), and the digest path becomes the one IDKit
produced. Add the paired assertion to `check-payload-binding.mjs` — `hashSignal("0x"+"00".repeat(32))`
must equal `keccak(32 zero bytes) >> 8`, not `keccak("0x000…")` — so it pins against IDKit's rule
instead of against itself.

---

## Important

### I1 — Restoring a revoked agent does not actually require an attestation

`src/LeashAccount.sol:215-224` (`bindAgent`), `:253-257` (`unbindAgent`), `:275-300`
(`restoreAgent`). `README.md:86` states "Restore a revoked agent → self ✅ **and** attestation ✅".

`revokeAgent(A)` → `unbindAgent(A)` → `bindAgent(A, node, label)` returns agent A to a fully active
binding with `revoked == false`, passing no attestation anywhere. Proved in an isolated forge
project (worktree untouched); both probes passed:

- `restoreAgent` with a junk blob reverts `NotAttested` ✓ (the gate works when used)
- `revoke → unbind → bind` leaves `bindingOf(A) == (node, "vendors", false)` ✓ (the gate is routed around)

`bindAgent:221-223` names this exact attack — "otherwise 'rebind for free after a revocation' would
sidestep… restoring requires a face scan" — and then sanctions the bypass one line later as the
remedy for a mis-bind. `AlreadyBound` only blocks the direct rebind; clearing the binding first
defeats it. Separately, binding a *fresh* address to the same node is free by design (`bindAgent`'s
own doc argues this points in the reducing direction), so even with the unbind path closed, "restore"
is only protected for that one specific address.

This is pre-existing code, not a regression from this branch — but this branch is what turns the
attestation half from a no-op into a real cost, which is exactly what makes the claim falsifiable.
Two honest options:

- **Code:** `if (b.revoked) revert AlreadyBound();` (or a dedicated error) in `unbindAgent`, forcing
  a revoked binding through `restoreAgent`. No existing test unbinds a revoked agent —
  `test_a_mis_binding_is_correctable_for_free` (`test/LeashAccountBinding.t.sol:325`) unbinds a
  *non-revoked* one — so the suite stays green. Add a test for the composed path.
- **Docs:** restate the README row as what is enforced ("re-activating that same agent address"), and
  say plainly that the wallet key alone can bind a new agent under an already-attested rule.

### I2 — The page hands IDKit an untrimmed signal and the server a trimmed one

`world/index.html:151` (`signal: $("signal").value`) vs `:115` (`digest: signal.trim()`); `isDigest`
also trims (`:71`).

Step 6 has the operator paste `$DIGEST` from a shell into the field, so trailing whitespace or a
newline is a live possibility. It routes to `/api/attest` (trimmed test), IDKit binds the proof to
the untrimmed string, and the server hashes the trimmed one — the binding silently diverges (or `ox`
throws inside IDKit), and the scan is spent either way. One-word fix: pass
`$("signal").value.trim()` to `IDKit.init`. Worth fixing in the same pass as C1, since C1's fix is
what makes this the *remaining* way to break the binding.

### I3 — Nothing checks that `WORLD_ATTESTER` is the attester the wallet actually trusts, or even that it is an address

`world/server.mjs:175`, `world/attest.mjs:53` (`word(buf(verifyingContract))`), `world/attest.mjs:155-166`
(`checkAttestEnv`), plan Step 4.

`checkAttestEnv` only checks presence. `buf()` is `Buffer.from(hex, "hex")`, which truncates instead
of throwing, so a malformed value silently mis-encodes the domain separator. Measured — three
different hashes, no error, for the same digest:

```
0x8Ba1f109551bD432803012645Ac136ddd64DBA72  → 0x797af25d…   (correct)
0x8Ba1f109551bD432803012645Ac136ddd64DBA7   → 0x6e3814b2…   (39 hex chars, one slip)
"nope"                                      → 0xe0d5597b…
```

A stale-but-valid address behaves worse: `crosscheck.mjs` would print four `ok` lines and `SIGNER()`
would match (an older `WorldAttester` carries the same signer), so plan Step 4 passes and the
mismatch first appears as `NotAttested` at `allowPayee` — after the scan is spent. Two cheap
closures:

- `checkAttestEnv`: `if (!/^0x[0-9a-fA-F]{40}$/.test(env.WORLD_ATTESTER)) return "WORLD_ATTESTER is not an address"`.
- Plan Step 4, key-free and view-only: `cast call "$W" 'ATTESTER()(address)'` (the immutable lives in
  the delegate's code, so this reads through the 7702 wallet) and assert it equals
  `$(get WORLD_ATTESTER)`. Optionally `console.log("  ATTESTER      ", impl.ATTESTER())` in
  `script/DeployWorldAttester.s.sol:39` so the linkage is on the deploy log.

---

## Minor

- **`world/README.md:120-129`** — "## The one thing to change when wiring `AttesterGate` / Right now
  `signal` is a test string" is false as of `45177b4` and contradicts the section this branch added
  at `:40`. Same future tense in `world/server.mjs:10`, `:36-40`, `:122-123`, all naming
  `AttesterGate`, a contract that does not exist (`WorldAttester` does). These are the only
  already-false claims found; the `MockAttester` caveats in `README.md:99-106` are correctly still
  true.
- **Spec `:288`** — "'One person may only do this once' is therefore a backend property." No code
  records nullifiers; `server.mjs:182` only echoes one back. The real mechanism is World's
  `max_verifications: 1`. Worth saying that instead, since it is a stronger claim than an unwritten
  backend property.
- **`world/crosscheck.mjs:55`** — the signature-acceptance case is pinned to `deadline = 1800000900`
  (2027-01-15). After that date the script reports `FAIL the contract accepts this signature` for a
  reason that has nothing to do with the encoding. `Math.floor(Date.now()/1000) + 900` removes the
  time bomb.
- **`.env.example`** — has no `WORLD_ATTESTER` or `WORLD_ACTION`, both now hard requirements of
  `/api/attest`.
- **`src/LeashAccount.sol:525-535`** (`restoreDigest`) — unlike `restoreAgent:282-283` it does not
  check `node == nodeFor(label)`, so it will hand back a digest that can never be consumed. Cheap to
  mirror the check; costs one face scan if it bites.
- **`src/WorldAttester.sol:96`** — `describe()` hardcodes `rp_ef35d4e2d4f1a031` with nothing binding
  it to `SIGNER`. Agree with the ledger's decision to defer this.

---

## What was verified as sound

- **JS↔Solidity agreement (seam 2) holds by construction, not by four lucky cases.** Field-by-field
  read agrees: 5-word domain, 3-word struct hash, `deadline` left-padded to a full word, `0x1901` as
  two raw bytes. Then measured against a `WorldAttester` deployed to a local anvil: `crosscheck.mjs`
  all `ok` including *the contract accepts this signature* (so the `[recovery ‖ r ‖ s]` → `r ‖ s ‖ v`
  repacking is right), plus **233 `(digest, deadline)` pairs — random digests and every `uint64`
  edge (0, 1, 255, 2^32±1, 2^63, 2^64−1) — 0 mismatches.**
- **`verify` never reverts (seam 4).** 20,000 runs on each fuzz test. `IAttester.verify` is `view`
  (`src/IAttester.sol:22`), so the call in `_consumeAttestation` is a STATICCALL — no reentrancy into
  the window between the `attestationUsed` read and the write.
- **Replay surfaces (seam 3) are all closed.** Same attestation twice → `attestationUsed[d]` set
  permanently, checked *before* `verify` (`LeashAccount.sol:544-550`), tested. Another wallet →
  `domainSeparator()` binds `address(this)` = the EOA, tested. Another policy change → every field
  plus `nonce` inside the struct hash. Another impl → `SELF`. Another attester deployment →
  `verifyingContract` in `WorldAttester`'s own domain, tested. Cross-chain → `chainid` in both
  domains.
- **The asymmetry survives on the reduction side.** `test_every_reduction_is_still_free_with_a_real_attester`
  passes no attestation to `removePayee`/`tightenRule`/`revokeAgent`/`pause`/`unpause`. I1 is a
  *widening* that is too cheap, not a reduction that became expensive.
- **Secrets.** No key material in the diff — the three 64-hex strings are anvil's published account
  #0 key (labelled as such at plan `:1359`), secp256k1's `n`, and a public namehash. Error paths do
  not leak: a malformed key yields only `Field.fromBytes: expected 32 bytes, got 31` / `invalid
  private key`, never the value. `.gitignore`'s `!broadcast/*/*/run-latest.json` negation is inert
  because the parent `broadcast/` is excluded (verified with `git check-ignore` on the real
  post-broadcast path), so the ledger's claim holds. Nothing references `docs/info.md`.

---

## Disagreements with the ledger

None substantive — the rulings are well-reasoned, and the two most likely to be argued with (the
coarse-mutation split, and skipping the round-2 re-review) would have been ruled the same way.

One correction of confidence rather than judgement: the round-1 Critical fix ledger entry, and
`server.mjs:130-132`, both state that "one face scan authorises exactly one widening" is now real.
The *pinning* of `signal_hash` is real and correct; the property is not live yet, because C1 means
the pinned value is computed in the wrong domain and no proof will verify against it at all. The fix
was right; the property arrives with C1's fix.

---

## Verdict

**Not ready to finish.** C1 is a hard blocker: it makes `/api/attest` fail 100% of the time on the
only path it is built for, it is invisible to every check on the branch, and its natural discovery
point is a live demo where finding it costs a Portal action and a rescan. It is a five-line fix plus
one assertion. I2 should ride along with it (same failure mode, same file pair), and I3 is the cheap
insurance that Step 4 catches a wrong attester before the scan rather than after. I1 needs a
decision — code or README — because the branch's headline table currently claims something the
contracts do not enforce.

Everything else is in good shape: the contract itself is careful, the never-revert property is
genuinely pinned, the two EIP-712 implementations agree well beyond the tested cases, and the
reduction side of the asymmetry is demonstrably intact.
