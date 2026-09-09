// 🔴 The single link between the two halves of this feature.
//
// A one-byte disagreement between the JS hash and the contract's produces exactly one
// symptom: the signature does not verify. Nothing says whether the encoding, the key, the
// deadline or v was at fault. That is a half-day bug, and this script is what turns it
// into a one-line failure.
//
// Usage: WORLD_ATTESTER=0x… SEPOLIA_RPC=… node crosscheck.mjs

import { keccak_256 } from "@noble/hashes/sha3.js";
import { attestationHash, signAttestation } from "./attest.mjs";

// attest.mjs keeps its own `strip` private, so this file defines its own.
const strip = (h) => h.replace(/^0x/, "");

const RPC = process.env.SEPOLIA_RPC;
const ATTESTER = process.env.WORLD_ATTESTER;
if (!RPC || !ATTESTER) {
  console.error("need SEPOLIA_RPC and WORLD_ATTESTER");
  process.exit(1);
}

/// Read the chain id from the RPC rather than hardcoding Sepolia's. The EIP-712 domain
/// binds it, so a hardcoded value would make this script compare a Sepolia-domain hash
/// against an anvil-domain one and always mismatch — and the local check in Task 4 Step 5
/// is exactly where it runs against anvil first.
async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
}
const CHAIN_ID = Number(await rpc("eth_chainId", []));
console.log(`chain id ${CHAIN_ID}, attester ${ATTESTER}`);

// attestationHash(bytes32,uint64) — selector computed rather than pasted.
const selector =
  "0x" +
  Buffer.from(keccak_256(Buffer.from("attestationHash(bytes32,uint64)"))).toString("hex").slice(0, 8);

async function onchain(digest, deadline) {
  const data =
    selector + digest.replace(/^0x/, "") + BigInt(deadline).toString(16).padStart(64, "0");
  return rpc("eth_call", [{ to: ATTESTER, data }, "latest"]);
}

const cases = [
  ["0x" + "00".repeat(32), 0],
  ["0x" + "00".repeat(32), 1],
  ["0x" + "ff".repeat(32), "18446744073709551615"], // type(uint64).max
  ["0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121", 1800000900],
];

let bad = 0;
for (const [digest, deadline] of cases) {
  const js = attestationHash({ digest, deadline, chainId: CHAIN_ID, verifyingContract: ATTESTER });
  const chain = await onchain(digest, deadline);
  const ok = js.toLowerCase() === chain.toLowerCase();
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"}  deadline=${deadline}\n      js    ${js}\n      chain ${chain}`);
}

// And prove a signature made here is one the CONTRACT accepts. This is the check that
// catches the recovery-byte ordering, and it has to go through `verify` to do it: a blob
// with @noble's [recovery ‖ r ‖ s] mistakenly packed as r ‖ s ‖ v is still exactly 73
// bytes, so a length check cannot see the bug at all. Only ecrecover can.
if (process.env.SIGNER_PK) {
  const { attestation } = signAttestation({
    digest: cases[3][0],
    deadline: cases[3][1],
    chainId: CHAIN_ID,
    verifyingContract: ATTESTER,
    privKeyHex: process.env.SIGNER_PK,
  });
  const len = (attestation.length - 2) / 2;
  console.log(`${len === 73 ? "ok  " : "FAIL"}  blob is ${len} bytes (want 73)`);
  if (len !== 73) bad++;

  // verify(bytes32,bytes) — one static arg, then offset/length/data for the dynamic one.
  const vsel =
    "0x" +
    Buffer.from(keccak_256(Buffer.from("verify(bytes32,bytes)"))).toString("hex").slice(0, 8);
  const body = strip(attestation);
  const padded = body + "0".repeat((64 - (body.length % 64)) % 64);
  const data =
    vsel +
    strip(cases[3][0]) +
    (64).toString(16).padStart(64, "0") +
    len.toString(16).padStart(64, "0") +
    padded;
  const accepted = BigInt(await rpc("eth_call", [{ to: ATTESTER, data }, "latest"])) === 1n;
  console.log(`${accepted ? "ok  " : "FAIL"}  the contract accepts this signature`);
  if (!accepted) bad++;
} else {
  console.log("skip  signature checks (SIGNER_PK unset)");
}

console.log(bad === 0 ? "\nall cross-checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
