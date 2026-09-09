// Guards three properties of /api/attest's trust boundary, all pure functions of
// attest.mjs's own code so they can be checked without starting the server, touching the
// network, or deploying anything:
//
//   1. (fix round 1) buildVerifyPayload must never let a caller-supplied
//      `proof.signal_hash` or `proof.action` leak into the payload sent to World.
//   2. (fix round 2) checkAttestEnv must refuse to run without WORLD_ACTION set, so the
//      module-level ACTION default (a consumed action, see server.mjs) can never reach
//      World from /api/attest silently.
//
//   3. (fix round 3) hashSignal must hash a 0x-prefixed hex string as its DECODED BYTES,
//      not as a UTF-8 string — mirroring IDKit's own hashToField, which is not our
//      choice to make (see hashSignal's docstring in attest.mjs). Getting this backwards
//      is the highest-stakes bug this file guards: it means /api/attest can never
//      succeed on the digest path, and every failed attempt spends the action's single
//      face scan. Unlike the round 1/2 checks, this one's expected values are computed
//      independently of hashSignal — inline from raw bytes, or hardcoded from a value
//      measured directly against IDKit's bundle / the world/README.md baseline — because
//      a check that calls hashSignal to compute its own expected value would agree with
//      hashSignal no matter how wrong it is. That is exactly how this bug shipped past
//      round 1's check in the first place.
//
// Kept in one file rather than split, since all three are "does /api/attest trust or
// compute something it must not" checks over attest.mjs's exports, and a single `node
// check-payload-binding.mjs` is the whole story for this endpoint's config/trust/hashing
// boundary.
//
// Usage: node check-payload-binding.mjs

import { keccak_256 } from "@noble/hashes/sha3.js";
import { buildVerifyPayload, hashSignal, checkAttestEnv } from "./attest.mjs";

const digest = "0x" + "42".repeat(32);
const serverAction = "expand-policy"; // what server.mjs passes as its own ACTION

// A hostile proof: both fields an attacker controls, set to values that — if trusted —
// would let a genuine proof for one digest/action authorise a different one. Neither
// field exists on a real IDKit proof; a real attacker adds them by hand.
const hostileProof = {
  credential_type: "device",
  signal_hash: "0x" + "de".repeat(32), // baked into some other, already-approved proof
  action: "old-retired-action", // an action whose single verification is already spent
  merkle_root: "0x" + "11".repeat(32),
  nullifier_hash: "0x" + "22".repeat(32),
  proof: "0x" + "33".repeat(8),
};

const payload = buildVerifyPayload({ digest, proof: hostileProof, action: serverAction });

let bad = 0;

const wantSignalHash = hashSignal(digest);
const gotSignalHash = payload.responses[0].signal_hash;
const signalOk = gotSignalHash === wantSignalHash && gotSignalHash !== hostileProof.signal_hash;
console.log(`${signalOk ? "ok  " : "FAIL"}  signal_hash is hashSignal(digest), not proof.signal_hash`);
console.log(`      want ${wantSignalHash}`);
console.log(`      got  ${gotSignalHash}`);
if (!signalOk) bad++;

const actionOk = payload.action === serverAction && payload.action !== hostileProof.action;
console.log(`${actionOk ? "ok  " : "FAIL"}  action is the server's configured action, not proof.action`);
console.log(`      want ${serverAction}`);
console.log(`      got  ${payload.action}`);
if (!actionOk) bad++;

// --- checkAttestEnv (fix round 2) ---
//
// WORLD_ACTION gets its own case, not just "all three set / all three missing", because
// its failure mode is the one that matters: an unset WORLD_ACTION must refuse, never
// silently fall back to a consumed action.
const fullEnv = {
  WORLD_RP_SIGNER_PK: "0x" + "11".repeat(32),
  WORLD_ATTESTER: "0x" + "22".repeat(20),
  WORLD_ACTION: "demo-2026-09-09",
};

const envCases = [
  ["all three vars set", fullEnv, false],
  ["WORLD_RP_SIGNER_PK missing", { ...fullEnv, WORLD_RP_SIGNER_PK: undefined }, true],
  ["WORLD_ATTESTER missing", { ...fullEnv, WORLD_ATTESTER: undefined }, true],
  ["WORLD_ACTION missing", { ...fullEnv, WORLD_ACTION: undefined }, true],
  // fix round 4 (I3): a WORLD_ATTESTER that is present but not a real address. buf() in
  // attest.mjs truncates malformed hex rather than throwing, so without this check a
  // too-short or non-hex value would silently mis-encode the domain separator instead of
  // failing loudly here.
  ["WORLD_ATTESTER too short", { ...fullEnv, WORLD_ATTESTER: "0x1234" }, true],
  ["WORLD_ATTESTER not hex", { ...fullEnv, WORLD_ATTESTER: "nope" }, true],
];

for (const [label, env, wantError] of envCases) {
  const err = checkAttestEnv(env);
  const ok = wantError ? typeof err === "string" && err.length > 0 : err === null;
  console.log(`${ok ? "ok  " : "FAIL"}  checkAttestEnv: ${label}${err ? ` -> ${err}` : ""}`);
  if (!ok) bad++;
}

// The WORLD_ACTION error has to name WORLD_ACTION specifically — someone hitting this at
// 2am before a demo should not have to read the source to know what to set.
const actionErr = checkAttestEnv({ ...fullEnv, WORLD_ACTION: undefined });
const namesTheVar = typeof actionErr === "string" && actionErr.includes("WORLD_ACTION");
console.log(`${namesTheVar ? "ok  " : "FAIL"}  the WORLD_ACTION error names the variable`);
if (!namesTheVar) bad++;

// --- hashSignal domain correctness (fix round 3) ---
//
// Every "want" below is computed WITHOUT calling hashSignal, so this cannot pass merely
// by agreeing with itself the way the round-1 signal_hash check (necessarily) does when
// pinning buildVerifyPayload's *sourcing* rather than hashSignal's own correctness.
const toSignalHash = (bytes) => {
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
};

const hashCases = [
  [
    "a zero digest is decoded as 32 raw bytes, not UTF-8",
    "0x" + "00".repeat(32),
    toSignalHash(Buffer.alloc(32)), // computed inline from raw bytes
  ],
  [
    "a real digest is decoded as 32 raw bytes (measured against IDKit's own bundle)",
    "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
    "0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3", // hardcoded, measured
  ],
  [
    "the empty string still takes the UTF-8 branch (world/README.md baseline)",
    "",
    "0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4", // hardcoded baseline
  ],
  [
    "a plain (non-hex) string still takes the UTF-8 branch",
    "widen:vendors.acme.eth:5000",
    toSignalHash(Buffer.from("widen:vendors.acme.eth:5000", "utf8")), // computed inline
  ],
];

for (const [label, signal, want] of hashCases) {
  const got = hashSignal(signal);
  const ok = got === want;
  console.log(`${ok ? "ok  " : "FAIL"}  hashSignal: ${label}`);
  console.log(`      want ${want}`);
  console.log(`      got  ${got}`);
  if (!ok) bad++;
}

console.log(bad === 0 ? "\nall checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
