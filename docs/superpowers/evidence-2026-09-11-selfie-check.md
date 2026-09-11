# Measured evidence — 2026-09-11, the Selfie Check investigation

> **This file is the only source you may write claims from.** Every line below was
> produced by running something on 2026-09-11 and reading the output. If a statement you
> want to make is not derivable from this file, do not make it. This project has shipped
> three defects this week that were all the same shape — a confident claim with nothing
> behind it — and this document exists so the fourth does not come from a doc rewrite.

---

## E1 — `@worldcoin/idkit-standalone` cannot request a face check at all

`idkit-standalone@2.2.5` is the **latest** version (npm dist-tags: `latest: 2.2.5`).

Grepping its published bundle for any form of the word "selfie" returns **zero matches**.

Its only credential vocabulary is `verification_level`, and the function that maps it
accepts exactly four values before throwing:

```js
var verification_level_to_credential_types = (verification_level) => {
  switch (verification_level) {
    case "device":          return ["orb", "device"];
    case "document":        return ["document", "secure_document", "orb"];
    case "secure_document": return ["secure_document", "orb"];
    case "orb":             return ["orb"];
    default: throw new Error(`Unknown verification level: ${verification_level}`);
  }
};
```

## E2 — the failure mode when you pass the preset name, which is the discoverable one

The docs introduce Selfie Check as the React preset `selfieCheckLegacy()`. Passing that
string as a `verification_level` to the standalone widget produces:

```
Uncaught (in promise) Error: Unknown verification level: selfieCheckLegacy
    at verification_level_to_credential_types (index.global.js:14818)
    at createClient (index.global.js:14955)
```

**The throw happens after `IDKit.open()` has already mounted the widget and the Radix
dialog has rendered.** The host page's own state advances — our button flipped to
"Cancel" and the digest the scan was meant to bind to was painted on screen — and then an
unawaited promise rejects. No visible error, no `onError` callback. The observable symptom
is "the QR code did not appear", which sends a developer to inspect their layout.

## E3 — `enable_face_check: true` does nothing on the 3.0 path

Setup: app `app_452654c9c277c08df71fec3315501c00`, `enable_face_check: true`,
`is_staging: false`. Action `expand-policy-facetest-1`, **brand new, never verified**.
Request made with `idkit-standalone`, `verification_level: "device"`.

Result, observed by the human who scanned: **World App opened no camera.** It performed a
device verification only.

World's verify API returned:

```json
{"success":true,"action":"expand-policy-facetest-1",
 "protocol_version":"3.0",
 "results":[{"identifier":"device","success":true}],
 "message":"Proof verified successfully"}
```

## E4 — Selfie Check is a 4.0 credential request, and it lives in a different package

`@worldcoin/idkit-core` (v4.2.4) defines:

```js
function deviceLegacy(opts = {})      { return { type: "DeviceLegacy",      signal: opts.signal }; }
function selfieCheckLegacy(opts = {}) { return { type: "SelfieCheckLegacy", signal: opts.signal }; }
```

These are **credential requests**, a different vocabulary from `verification_level`.
`@worldcoin/idkit` (the React package, v4.2.3) re-exports them from `idkit-core`; the
standalone widget does not have them.

`idkit-core` ships a browser global build (`dist/idkit.global.js`, sets `globalThis.IDKit`)
exposing `request`, `createSession`, `proveSession`, `CredentialRequest`, `any`, `all`,
`orbLegacy`, `deviceLegacy`, `selfieCheckLegacy`, `proofOfHuman`, `passport`, `mnc`,
`identityCheck`. It loads `idkit_wasm_bg.wasm` **relative to itself**.

Its request API:

```js
const request = await IDKit.request({ app_id, action, rp_context, allow_legacy_proofs })
  .preset(IDKit.selfieCheckLegacy({ signal }))
// request.connectorURI      — a URI for the page to render as a QR itself
// request.pollUntilCompletion()
```

## E5 — with the 4.0 request, the camera opens and the proof says so

Same app, same `enable_face_check: true`, fresh action `expand-policy-facetest-2`,
`allow_legacy_proofs: false`.

Observed by the human who scanned: **the front camera opened, took a photo, and enrolled
a face record.** (First scan only; the enrollment is one-time.)

The 4.0 result:

```json
{ "success": true,
  "result": {
    "action": "expand-policy-facetest-1",
    "environment": "production",
    "nonce": "0x005767e69b39ee4a7ea9f51f2fdd63c4c9f626ddf90ba312096f27c702624098",
    "protocol_version": "3.0",
    "responses": [{
      "identifier": "selfie",
      "merkle_root": "0x15ed091141db63566353199fb104affa2564ab481385e6cf3f3deff05447c411",
      "nullifier": "0x1218592f43ca8e5703acfe9ded3c9a4853280242d8b2d0de90dafce9b168144f",
      "proof": "0x2048…",
      "signal_hash": "0x00c1d49ba85f98bb87aeaa6b62d12e78d4e0739d22a1c8a44a9a49005433254f"
    }]
  } }
```

And World's verify API returned:

```json
{"success":true,"action":"expand-policy-facetest-2",
 "protocol_version":"3.0",
 "results":[{"identifier":"selfie","success":true}],
 "message":"Proof verified successfully"}
```

**`identifier` is `"selfie"`, not `"device"`.** Note also that a 4.0 `SelfieCheckLegacy`
result still reports `protocol_version: "3.0"` and arrives in the same envelope shape the
v4 verify endpoint takes.

### What E3 + E5 together mean

The proof **does** say which credential was exercised. It said `device` because a device
credential is what was requested. The naming is confusing and the docs point at a preset
name that the standalone widget cannot accept — but World's API reported the truth at
every step.

## E6 — `precheck` mints actions on demand; the Portal is not required

`POST https://developer.worldcoin.org/api/v1/precheck/{app_id}` with a randomly generated
action string `zzz-b3d399cdd91670da` returned a **real, active action**:

```json
{"action": {"id": "action_cc653b71e1a6682826ac3b5e5c0f908b",
            "action": "zzz-b3d399cdd91670da",
            "external_nullifier": "0x00cc653b71e1a6682826ac3b5e5c0f908b014b30fa0a2c1850892f924a89b926",
            "max_verifications": 1, "max_accounts_per_user": 1, "status": "active"}}
```

## E7 — re-verifying a consumed action still succeeds

Scanning the **same** action a second time returned:

```
{"success":true, …, "message":"Proof verified successfully (nullifier reuse)"}
```

A fresh action returned the same `success: true` without the parenthetical.

So `max_verifications: 1` did **not** cause the second verification to fail. Whatever it
limits, it is not "can this person produce another valid proof for this action".

> ⚠️ E6 and E7 together mean the previously-written claim that `max_verifications: 1`
> "silently breaks the second demo run" is at best imprecise and at worst wrong. Say only
> what E6 and E7 show. Do not speculate about what `max_verifications` *does* limit —
> that was not measured.

## E8 — the RP context has an official helper

`@worldcoin/idkit-server` exports `signRequest({ signingKeyHex, action?, ttl? })`
returning `{ sig, nonce, createdAt, expiresAt }`, and `computeRpSignatureMessage`. Its own
doc comment gives the format:

```
version(1) || nonce(32) || createdAt_u64_be(8) || expiresAt_u64_be(8) || action?(32)
```

signed as an Ethereum EIP-191 message. Pure JS, no WASM. Session proofs omit `action`;
uniqueness proofs append it.

---

## Chain state produced by the first face-driven end-to-end run, 2026-09-11

| fact | value |
|---|---|
| `PolicySet` | `0xec45e967F4e907B92bb1A9a8b4fcF9F041792490` |
| `MicroPaymentPolicy` (CAP 1.00 USDC) | `0x0142BE4199942ff40F67c94aF181Cc9A0C9C19Df` |
| `retainer` paid | 5.00 USDC |
| `newvendor` blocked then paid after the face scan | tx `0x00a9080f…`, widening tx `0x53d31784…` |
| `apitopup` blocked under `StandardPolicy`, executed one tick after the pointer moved | tx `0x0335f905…`, `setPolicy` tx `0x53b16bbb…` |
| `isPayeeAllowed(node, USDC, 0x…f00d)` | **`false`** |
| `0x…f00d` USDC balance | **1.50** |
| `isPayeeAllowed(node, USDC, 0x…cafe0)` | `true` (the face scan bought this) |

The two attester wirings, read from chain:

| gate | attester | real? |
|---|---|---|
| `LeashAccount.ATTESTER` — widening a payee | `WorldAttester` `0xa4E208dA…` | **yes** |
| `PolicyApprovals.attester` — approving a policy | `MockAttester` `0x268990a9…`, `verify` returns `true` for any input | **no** |

## Backend refusals added the same day

`world/attest.mjs` `buildSelfieVerifyPayload` refuses, each pinned by a mutation-tested
case in `world/attest.test.mjs`:

1. `identifier !== "selfie"` — a device credential is not a face.
2. `signal_hash !== hashSignal(digest)` — the 4.0 result carries its own `signal_hash`,
   so a caller could present a proof genuinely bound to signal X and claim digest Y.
   World cannot catch that (the proof really does match its own `signal_hash`), so the
   binding is checked here and the forwarded value is the one we computed.
