// Guards the property fixed in Task 4 fix round 1: buildVerifyPayload must never let a
// caller-supplied `proof.signal_hash` or `proof.action` leak into the payload /api/attest
// sends to World. Pure — no network, no chain, no anvil — because the bug it guards is a
// property of buildVerifyPayload's own code, not of anything onchain.
//
// Usage: node check-payload-binding.mjs

import { buildVerifyPayload, hashSignal } from "./attest.mjs";

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

console.log(bad === 0 ? "\nall checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
