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
const word = (h) => strip(h).padStart(64, "0");

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
