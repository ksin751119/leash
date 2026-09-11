// The widening plan: what a human is about to approve, and the one command that applies it.
//
// The page needs the EIP-712 digest that `allowPayee` will consume, because IDKit binds the
// proof to it as the `signal`. Until now the operator pasted $DIGEST out of a shell
// (index.html:105 warns about that pattern) — one mistyped character binds the scan to
// nothing.
//
// **This module never sees a private key.** It emits `$WALLET_PK` and `$ATTESTATION` as
// literal shell variable names; the operator's own shell resolves them. A test asserts the
// command does not contain the value of WALLET_PK.

import { keccak_256 } from "@noble/hashes/sha3.js";

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const NODE_RE = /^0x[0-9a-fA-F]{64}$/;

const SIG = "payeeDigest(bytes32,address,address,uint256)";
const SELECTOR = Buffer.from(keccak_256(Buffer.from(SIG))).subarray(0, 4).toString("hex");

const strip = (h) => String(h).replace(/^0x/, "").toLowerCase();
const word = (h) => {
  const s = strip(h);
  if (s.length > 64) throw new Error(`word too wide: ${s.length / 2} bytes`);
  return s.padStart(64, "0");
};

// Accepts a non-negative integer as either a number or a numeric string — the digest API
// receives nonce as a route/query value, so "7" has to work exactly like 7. Anything else
// (a float, a sign, garbage, undefined) is rejected here, before encodePayeeDigestCall's
// BigInt(nonce) gets a chance to throw past widenPlan's try/catch and its {status, body}
// contract.
const isValidNonce = (n) => {
  if (typeof n === "number") return Number.isInteger(n) && n >= 0;
  if (typeof n === "string") return /^\d+$/.test(n);
  return false;
};

export function checkWidenEnv(env) {
  if (!env.SEPOLIA_RPC) return "SEPOLIA_RPC not set";
  if (!/^https?:\/\//.test(env.SEPOLIA_RPC)) {
    // Never echo the value: a scheme-less URL cannot be reliably redacted later, and an RPC
    // URL commonly carries an API key in its path.
    return "SEPOLIA_RPC must start with http:// or https://";
  }
  if (!env.WALLET_ADDR) return "WALLET_ADDR not set";
  if (!ADDR_RE.test(env.WALLET_ADDR)) return "WALLET_ADDR is not a 20-byte address (0x + 40 hex chars)";
  if (!env.LEASH_NODE) return "LEASH_NODE not set";
  if (!NODE_RE.test(env.LEASH_NODE)) return "LEASH_NODE is not a 32-byte hash (0x + 64 hex chars)";
  return null;
}

export function encodePayeeDigestCall({ node, token, payee, nonce }) {
  return (
    "0x" + SELECTOR + word(node) + word(token) + word(payee) + word(BigInt(nonce).toString(16))
  );
}

const ALLOW_SIG = "allowPayee(bytes32,address,address,uint256,bytes)";
const ALLOW_SELECTOR = Buffer.from(keccak_256(Buffer.from(ALLOW_SIG))).subarray(0, 4).toString("hex");

/// Calldata for `allowPayee`, so the browser wallet can send the widening itself and the
/// operator never touches a terminal.
///
/// Hand-encoded for the same reason `encodePayeeDigestCall` is: this file has no ABI
/// library and one function's calldata does not justify one. But `allowPayee` is the
/// harder shape — its last parameter is dynamic `bytes`, so the head holds an **offset**
/// where the other four hold values, and the tail holds a length followed by the data
/// padded up to a whole word.
///
/// The offset is `0xa0`: five head words at 32 bytes each, counted from the start of the
/// arguments and NOT from the start of the calldata — the selector is not part of the
/// encoding. Getting that wrong produces calldata a node accepts and a contract
/// misreads, which is why `widen-plan.test.mjs` pins the byte layout rather than only
/// the round trip.
export function encodeAllowPayeeCall({ node, token, payee, nonce, attestation }) {
  const blob = strip(attestation);
  if (blob.length % 2 !== 0) throw new Error("attestation is not whole bytes");
  const len = blob.length / 2;
  const padded = blob.padEnd(Math.ceil(len / 32) * 64, "0");
  return (
    "0x" +
    ALLOW_SELECTOR +
    word(node) +
    word(token) +
    word(payee) +
    word(BigInt(nonce).toString(16)) +
    word((5 * 32).toString(16)) + // offset to the bytes tail
    word(len.toString(16)) +
    padded
  );
}

export function buildCommand({ walletAddr, node, token, payee, nonce }) {
  return [
    `cast send ${walletAddr} \\`,
    `  "allowPayee(bytes32,address,address,uint256,bytes)" \\`,
    `  ${node} ${token} ${payee} ${nonce} $ATTESTATION \\`,
    `  --private-key $WALLET_PK --rpc-url $SEPOLIA_RPC`,
  ].join("\n");
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Same shape as agent/subgraph.mjs: remove the whole url, then the bare hostname, because a
// connection error reports only the host while a malformed-url error reports the path.
//
// Each pass also eats any trailing non-whitespace run, not just the literal match: an RPC
// url commonly carries an API key in its path or query, and a plain substring split would
// strip the host while leaving `/v2/<key>` sitting right next to it.
export function redact(text, rpcUrl) {
  let safe = String(text ?? "");
  if (!rpcUrl) return safe;
  safe = safe.replace(new RegExp(escapeRe(rpcUrl) + "\\S*", "g"), "<rpc>");
  try {
    const hostname = new URL(rpcUrl).hostname;
    safe = safe.replace(new RegExp(escapeRe(hostname) + "\\S*", "g"), "<rpc>");
  } catch {
    // An unparseable url still had its literal form removed above.
  }
  return safe;
}

export async function widenPlan({ payee, token, env, nonce, fetchImpl = fetch }) {
  if (!ADDR_RE.test(String(payee ?? ""))) {
    return { status: 400, body: { error: "payee must be 0x + 40 hex chars" } };
  }
  if (!ADDR_RE.test(String(token ?? ""))) {
    return { status: 400, body: { error: "token must be 0x + 40 hex chars" } };
  }
  if (!isValidNonce(nonce)) {
    return { status: 400, body: { error: "nonce must be a non-negative integer" } };
  }
  const envErr = checkWidenEnv(env);
  if (envErr) return { status: 500, body: { error: envErr } };

  const node = env.LEASH_NODE;
  const data = encodePayeeDigestCall({ node, token, payee, nonce });

  let body;
  try {
    const res = await fetchImpl(env.SEPOLIA_RPC, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to: env.WALLET_ADDR, data }, "latest"],
      }),
    });
    if (!res.ok) return { status: 502, body: { error: `rpc returned HTTP ${res.status}` } };
    body = await res.json();
  } catch (err) {
    const raw = String(err?.message ?? err) + (err?.cause?.message ? ` (${err.cause.message})` : "");
    return { status: 502, body: { error: `rpc unreachable: ${redact(raw, env.SEPOLIA_RPC)}` } };
  }

  if (body?.error) {
    return { status: 502, body: { error: `rpc error: ${redact(body.error.message ?? "unknown", env.SEPOLIA_RPC)}` } };
  }
  // Fail closed on anything that is not exactly one 32-byte word. A short or absent result
  // would otherwise become a signal IDKit happily binds a real face scan to.
  if (!NODE_RE.test(String(body?.result ?? ""))) {
    return { status: 502, body: { error: "payeeDigest did not return a 32-byte value" } };
  }

  return {
    status: 200,
    body: {
      digest: body.result,
      nonce: String(nonce),
      node,
      token,
      payee,
      command: buildCommand({ walletAddr: env.WALLET_ADDR, node, token, payee, nonce }),
    },
  };
}
