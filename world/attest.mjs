// The EIP-712 half of WorldAttester, in JavaScript. Kept out of server.mjs so
// crosscheck.mjs can import exactly the code the server signs with — a cross-check that
// exercised a copy would prove nothing.
//
// ⚠️ Two things here fail silently if wrong, with the identical symptom ("the signature
// does not verify") and nothing pointing at the cause:
//   1. `deadline` is a uint64 in the type but a full 32-byte word inside abi.encode.
//   2. @noble/curves returns `format: "recovered"` as [recovery(1) ‖ r(32) ‖ s(32)] —
//      recovery FIRST, valued 0 or 1 — while the blob wants r ‖ s ‖ v with v = 27 + recovery.
// crosscheck.mjs exists for exactly these.
//
// 🚫 This file computes the EIP-712 hash in JavaScript and must keep doing so. Do NOT
// "simplify" it by fetching the hash from the chain — not via eth_call to
// attestationHash(), not from a cached response, not for one field. Every Solidity test
// signs whatever att.attestationHash() returned, so no test in this repo can catch an
// encoding that is wrong the same way on both sides. This independent reimplementation is
// the only thing that can, and it stops being able to the moment it asks the contract.

import { keccak_256 } from "@noble/hashes/sha3.js";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { randomBytes } from "node:crypto";

const strip = (h) => h.replace(/^0x/, "");
const buf = (h) => Buffer.from(strip(h), "hex");
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const keccak = (...parts) => keccak_256(Buffer.concat(parts.map((p) => Buffer.from(p))));

/// Left-pad to a 32-byte ABI word.
const word = (b) => {
  const x = Buffer.from(b);
  if (x.length > 32) throw new Error(`word too wide: ${x.length}`);
  return Buffer.concat([Buffer.alloc(32 - x.length), x]);
};

const u64be = (n) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
};

/// A uint256 as a 32-byte ABI word. `padStart(64, "0")` guarantees both an even number of
/// hex characters and exactly 32 bytes, so no odd-length special case is needed.
const u256 = (n) => Buffer.from(BigInt(n).toString(16).padStart(64, "0"), "hex");

const DOMAIN_TYPEHASH = keccak(
  Buffer.from("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
);
const ATTESTATION_TYPEHASH = keccak(Buffer.from("LeashAttestation(bytes32 digest,uint64 deadline)"));
const NAME_HASH = keccak(Buffer.from("Leash"));
const VERSION_HASH = keccak(Buffer.from("1"));

export function domainSeparator({ chainId, verifyingContract }) {
  return keccak(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, u256(chainId), word(buf(verifyingContract)));
}

export function attestationHash({ digest, deadline, chainId, verifyingContract }) {
  const d = buf(digest);
  if (d.length !== 32) throw new Error(`digest must be 32 bytes, got ${d.length}`);
  const structHash = keccak(ATTESTATION_TYPEHASH, d, word(u64be(deadline)));
  return hex(
    keccak(Buffer.from([0x19, 0x01]), domainSeparator({ chainId, verifyingContract }), structHash)
  );
}

export function signAttestation({ digest, deadline, chainId, verifyingContract, privKeyHex }) {
  const hash = attestationHash({ digest, deadline, chainId, verifyingContract });
  const rec = secp256k1.sign(buf(hash), buf(privKeyHex), { format: "recovered", prehash: false });
  const recovery = rec[0]; // 0 or 1
  const r = rec.slice(1, 33);
  const s = rec.slice(33, 65);
  const v = 27 + recovery;
  return {
    hash,
    attestation: hex(Buffer.concat([u64be(deadline), r, s, Buffer.from([v])])), // 73 bytes
  };
}

/**
 * World ID's signal hash: keccak256 of the signal's ENCODED BYTES, shifted right by 8
 * bits. The shift is because a proof has to land inside the field in the SNARK system,
 * and keccak's 256 bits would overflow it.
 *
 * @dev **Measured on 2026-09-07: the proof IDKit returns contains no `signal_hash`.**
 *      So this is not a fallback path, it is the only path — the backend has to compute
 *      it. That is exactly where the first run fell over: `@noble/hashes` was not
 *      installed → 500 → World App displayed "Verification Declined", which looks like
 *      World rejecting you when in fact your own backend has crashed.
 *
 *      Note you cannot use node's built-in `crypto.createHash("sha3-256")` — SHA3 and
 *      keccak256 pad differently, produce different values, and World will refuse it.
 *
 * @dev 🔴 **"encoded bytes" is two branches, not one, and this is not our choice to
 *      make** — it mirrors `hashToField` in `@worldcoin/idkit-standalone@2.2.5`, the
 *      bundle the page actually loads:
 *      ```js
 *      function hashToField(input) {
 *        if (Bytes_exports.validate(input) || Hex_exports.validate(input)) return hashEncodedBytes(input);
 *        return hashString(input);
 *      }
 *      function hashString(input) { return hashEncodedBytes(Buffer.from(input)); }
 *      ```
 *      A `0x`-prefixed hex string (digests, always) is **decoded to raw bytes** before
 *      hashing; anything else is **UTF-8-encoded** first. Getting this wrong — hashing
 *      the 66-character digest *string* as UTF-8, as an earlier version of this function
 *      did — produces a `signal_hash` that can never match the one baked into the proof.
 *      World then refuses `/api/attest` on every call on the digest path, silently
 *      spending the action's one verification for nothing. Measured, for
 *      `digest = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121`:
 *        wrong (utf8 of the 66-char string): 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
 *        right (keccak of 32 raw bytes):     0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
 *
 *      The regex below is deliberately *stricter* than IDKit's `Hex.validate`, which
 *      (non-strict by default) would also accept malformed hex like `0xnothex`. For every
 *      real digest the two agree; being stricter here only ever fails safe.
 *
 *      The string branch must not move: `world/README.md` documents
 *      `hashSignal("") == 0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4`,
 *      and `/api/verify`'s plain-string signals (e.g. `"widen:vendors.acme.eth:5000"`,
 *      used on 2026-09-07's end-to-end run) rely on it.
 */
export function hashSignal(signal) {
  const bytes = /^0x[0-9a-fA-F]*$/.test(signal) ? buf(signal) : Buffer.from(signal, "utf8");
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
}

/// Builds the v4-legacy verify payload that `/api/attest` sends to World, and signs only
/// if World answers 200.
///
/// `signal_hash` and `action` are computed here from `digest` and the caller-supplied
/// `action`, and **never** read from `proof` — even though a real IDKit proof has no
/// `signal_hash` or `action` field of its own. This is load-bearing, not defensive
/// overkill: `/api/attest` is raw JSON with no trusted caller, so `proof` is
/// attacker-controlled.
///
/// **Attack this closes, #1 (signal_hash):** one face scan is supposed to authorise
/// exactly one widening, because World binds the proof to `signal_hash = hash(digest)`.
/// If this function read `proof.signal_hash` instead of recomputing it, an attacker who
/// captured one genuine proof P — a real scan that approved digest D1, carrying its own
/// signal_hash S — could POST `{ digest: D2, proof: { ...P, signal_hash: S } }`. World
/// verifies P happily, because S is exactly what's baked into it, and the server would
/// then sign an attestation for D2, a widening no human's face ever approved.
///
/// **Attack this closes, #2 (action):** a proof is bound to the action it was generated
/// for, and this app mints a fresh action per demo because `max_verifications` is 1 per
/// action and cannot be raised (`expand-policy` itself was already consumed on
/// 2026-09-07). If `action` came from the request body, a face scan made for an
/// already-retired action would still buy a widening today — quietly breaking "every
/// widening needs a real, current face scan." Pinning `action` to the value the server
/// passes in (its own configured `ACTION`, never the request body's) closes that path the
/// same way `signal_hash` does.
export function buildVerifyPayload({ digest, proof, action }) {
  return {
    protocol_version: "3.0",
    nonce: "0x" + randomBytes(16).toString("hex"),
    action,
    environment: "production",
    responses: [
      {
        identifier: proof.credential_type ?? proof.verification_level,
        signal_hash: hashSignal(digest),
        merkle_root: proof.merkle_root,
        nullifier: proof.nullifier_hash,
        proof: proof.proof,
      },
    ],
  };
}

/// The environment /api/attest needs before it can do anything, checked as a pure
/// function of an env-like object so it can be tested without starting the server or
/// touching the network.
///
/// `WORLD_ACTION` gets its own named failure rather than folding into a generic
/// "misconfigured" error, because its failure mode is worse than the other two: `ACTION`
/// in server.mjs falls back to `"expand-policy"` for the verification harness's other
/// routes (`/api/config`, `/api/precheck`, `/api/verify`), which is fine for those — but
/// that default was already consumed on 2026-09-07, and `max_verifications` cannot be
/// raised for a consumed action. If `/api/attest` reused that fallback, an unset
/// `WORLD_ACTION` would make it silently send a dead action to World on every call — a
/// failure that looks like "World is being weird" during a live demo, when it is really
/// a missing environment variable. Returning `null` here is what lets the caller use the
/// fallback-free `process.env.WORLD_ACTION` (never the module-level `ACTION` constant)
/// once this passes.
///
/// `WORLD_ATTESTER`'s shape is checked too, not just its presence, because `buf()` (this
/// file's `Buffer.from(hex, "hex")` helper, used in `domainSeparator`) truncates a
/// malformed hex string rather than throwing. A value that is the right shape but the
/// wrong contract still passes this check — that failure mode is deploy-tracking, not
/// something a format check can catch — but a value that is *not even a 20-byte address*
/// (too short, mixed in non-hex characters, a copy-paste of the wrong env var) would
/// otherwise silently mis-encode the EIP-712 domain separator and produce a `signal_hash`-
/// shaped wrong answer with no error anywhere.
export function checkAttestEnv(env) {
  if (!env.WORLD_RP_SIGNER_PK) return "WORLD_RP_SIGNER_PK not set";
  if (!env.WORLD_ATTESTER) return "WORLD_ATTESTER not set";
  if (!/^0x[0-9a-fA-F]{40}$/.test(env.WORLD_ATTESTER)) {
    return `WORLD_ATTESTER is not a 20-byte address (0x + 40 hex chars): ${env.WORLD_ATTESTER}`;
  }
  if (!env.WORLD_ACTION) {
    return (
      'WORLD_ACTION not set: the built-in default ("expand-policy") was already consumed ' +
      "on 2026-09-07 and max_verifications cannot be raised for a consumed action. " +
      "Create a fresh action in the Portal and set WORLD_ACTION to it before running " +
      "/api/attest."
    );
  }
  return null;
}
