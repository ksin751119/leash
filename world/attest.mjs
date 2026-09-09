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
