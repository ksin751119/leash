// Guards two properties of /api/attest's trust boundary, both pure functions of
// attest.mjs's own code so they can be checked without starting the server, touching the
// network, or deploying anything:
//
//   1. (fix round 1) buildVerifyPayload must never let a caller-supplied
//      `proof.signal_hash` or `proof.action` leak into the payload sent to World.
//   2. (fix round 2) checkAttestEnv must refuse to run without WORLD_ACTION set, so the
//      module-level ACTION default (a consumed action, see server.mjs) can never reach
//      World from /api/attest silently.
//
// Kept in one file rather than split, since both are "does /api/attest trust something
// it must not" checks over the same two functions' worth of code, and a single `node
// check-payload-binding.mjs` is the whole story for this endpoint's config/trust boundary.
//
// Usage: node check-payload-binding.mjs

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

console.log(bad === 0 ? "\nall checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
