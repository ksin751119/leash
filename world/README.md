# Selfie Check verification harness

One IDKit page plus a dependency-light node server. **Its only purpose is to prove Selfie
Check really completes a verification end to end.** This is not the demo frontend; that is
sprint item 12.

```bash
node server.mjs          # → http://localhost:8787
curl -s localhost:8787/api/precheck | jq   # config check; consumes no verification
```

`app_id` and `action` have hardcoded defaults (the app_id appears in the frontend anyway
and is not a secret). Override them with `WORLD_APP_ID` / `WORLD_ACTION`.

---

## 🔴 Read this before running it

**Every action has `max_verifications: 1`, and there is no way to change it.**

The default is `1` — each person can verify once, ever. **The first attempt succeeds, so
nothing looks wrong at the time.** Scan once to record a video and again for a live demo,
and the second one simply fails: the nullifier is burned and cannot be reset.

Running this harness once uses up that single verification.

The Portal has **no setting for this** — an earlier version of this file told you to change
it to 0 (unlimited), and that instruction was wrong; no such control exists anywhere in the
product. What does work is that `max_verifications` binds to the **action**, not to the
person, so **creating a fresh action resets it**. Do that before recording a video or
running a live demo.

`precheck`'s `can_user_verify` cannot answer "has this person already used theirs?" — it is
an unauthenticated endpoint and does not know who is asking.

`/api/attest` requires `WORLD_ACTION` to be set to a fresh action, and will refuse to run
(500) without it — it does not fall back to the built-in default above, because that
default (`expand-policy`) is itself a consumed action.

**`index.html`'s Signal field is also the switch between the two backend routes.** Paste a
`0x` + 64 hex-char digest in and the page calls `/api/attest`, verifying the proof and — only
on World's HTTP 200 — returning a signed EIP-712 attestation ready to paste into
`cast send allowPayee` / `setRule` / `restoreAgent`. Anything else (including the default
`widen:vendors.acme.eth:5000`) calls `/api/verify`, the plain relay this harness was built
to prove out; it signs nothing. The page never calls both for one scan — `/api/attest`
performs its own World verification of the same proof, and `max_verifications: 1` means a
second verify attempt against an already-consumed proof would only burn the action's one
shot, not add safety.

---

## ✅ Verified end to end (2026-09-07)

```
face scan → World App produces a proof → backend POSTs v4 → HTTP 200
"Proof verified successfully"
```

**Four official sources say four different things about the same app, and only measurement
can tell which is right:**

| Source | What it says | Correct? |
|---|---|---|
| The documentation | Selfie Check runs 3.0 only, "4.0 support not yet available" | Half right — **the proof is 3.0-format, but verification goes to v4** |
| `precheck` (v1) | `enable_face_check: true` | ✅ correct |
| v2 verify | `invalid_action: Action not found.` | ❌ **a real proof gets the same answer**. This app is a 4.0 RP, and v2 cannot see its actions |
| v4 verify | "Verifies World ID 4.0 proofs **and legacy 3.0 proofs**" | ✅ this is the one that holds |

### What actually works

`POST https://developer.worldcoin.org/api/v4/verify/{rp_id}`, wrapped as a
`VerifyV4LegacyProofRequest`. **The fields IDKit returns cannot be forwarded as they are**
— three changes are required:

| Do this | To these fields |
|---|---|
| Rename | `nullifier_hash` → `responses[].nullifier` |
| **Remove** | `credential_type`, `verification_level` (v4 rejects both) |
| Add | `protocol_version: "3.0"`, `nonce`, `environment` |

> The irony is that v4's own documentation says "Forward the complete IDKit result
> **without remapping response identifiers**" — while in practice the rename is mandatory:
> send `nullifier_hash` through untouched and it is refused.

The signposting only points one way, too: v4 tells you when you should have used v2, while
v2 never tells you to try v4.

### Two more measured conclusions

**IDKit does not send `signal_hash`; the backend has to compute it, and the rule has two
branches, not one.** `keccak256(bytes) >> 8` (the shift keeps the value inside the SNARK's
field) — but **which bytes** depends on the signal's shape, mirroring `hashToField` in
`@worldcoin/idkit-standalone@2.2.5`: a `0x`-prefixed hex string (a digest, always) is
**decoded to raw bytes** first; anything else is **UTF-8-encoded** first. Hashing a hex
string's *characters* as UTF-8 instead of its decoded bytes — the obvious one-branch
implementation — produces a `signal_hash` that can never match the one baked into the
proof, so World refuses every call on that path and each failed attempt spends the
action's single verification for nothing. This is silent the same way the missing
`signal_hash` itself is: a plain-string signal (e.g. `"widen:vendors.acme.eth:5000"`, used
in the 2026-09-07 end-to-end run below) takes the UTF-8 branch either way and never
reveals the bug.

**Do not use node's built-in `crypto.createHash("sha3-256")`** — SHA3 and keccak256 pad
differently, produce different values, and World refuses the result.

Baselines to check against — one per branch:
- UTF-8 branch: `signal_hash("")` must equal
  `0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4`.
- Hex/bytes branch: `signal_hash("0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121")`
  must equal `0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3` — measured
  directly against IDKit's own bundle, not derived from our own implementation.

**The nullifier is deterministic.** The same person plus the same action gives the same
`nullifier_hash`, identical across attempts (measured twice, `0x04a2cce3…` both times).
That is the anonymous identity `AttesterGate` records.

**A 500 from this backend surfaces in World App as "Verification Declined."** It looks like
World rejecting you; it is your own server crashing. The phone can show success while the
browser shows failure. Read your own stack trace first.

### ⚠️ The proof does not reveal that this was Selfie Check

Both `credential_type` and `verification_level` come back as `"device"` — **there is no
`selfie` and no `face`.**

Which means the guarantee "a real human's face produced this" is **not in the proof**. It
lives in the app's `enable_face_check: true` setting. Handed a proof, the backend **cannot
distinguish** "a face check just completed" from "an old, deprecated device credential".

For Leash this has to be said plainly: our claim is that privilege expansion is bound to a
real human, and the strength of that binding comes from an app setting, not from a
cryptographic credential type.

---

## The one thing to change when wiring `AttesterGate`

Right now `signal` is a test string. In production it becomes **the EIP-712 payload hash of
the widening in question** — so one face scan can only loosen that one rule, and an
intercepted proof cannot be replayed anywhere else. The `nullifier_hash` in the response is
that person's anonymous identity, and `AttesterGate` has to remember it to block reuse.

The full account, with every suggested fix, is in
[`../docs/world-feedback.md`](../docs/world-feedback.md) — the feedback document the prize
asks for, and 25% of the World track's score.
