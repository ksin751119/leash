### Task 2: `world/widen-plan.mjs` — the digest and the command

**Files:**
- Create: `world/widen-plan.mjs`, `world/widen-plan.test.mjs`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `checkWidenEnv(env) -> string | null`
  - `encodePayeeDigestCall({ node, token, payee, nonce }) -> "0x…"`
  - `buildCommand({ walletAddr, node, token, payee, nonce }) -> string`
  - `redact(text, rpcUrl) -> string`
  - `async widenPlan({ payee, token, env, nonce, fetchImpl }) -> { status, body }`

- [ ] **Step 1: Write the failing tests**

Create `world/widen-plan.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkWidenEnv, encodePayeeDigestCall, buildCommand, redact, widenPlan,
} from "./widen-plan.mjs";

const NODE = "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121";
const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x00000000000000000000000000000000000cafe0";
const WALLET = "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6";
const RPC = "https://ethereum-sepolia-rpc.publicnode.com";
const DIGEST = "0x" + "ab".repeat(32);

const env = { SEPOLIA_RPC: RPC, WALLET_ADDR: WALLET, LEASH_NODE: NODE };
const okFetch = async () => ({ ok: true, json: async () => ({ jsonrpc: "2.0", id: 1, result: DIGEST }) });

test("checkWidenEnv names the first missing variable", () => {
  assert.match(checkWidenEnv({}), /SEPOLIA_RPC/);
  assert.match(checkWidenEnv({ SEPOLIA_RPC: RPC }), /WALLET_ADDR/);
  assert.match(checkWidenEnv({ SEPOLIA_RPC: RPC, WALLET_ADDR: WALLET }), /LEASH_NODE/);
  assert.equal(checkWidenEnv(env), null);
});

test("checkWidenEnv rejects a malformed address without echoing a secret", () => {
  const err = checkWidenEnv({ ...env, WALLET_ADDR: "0xnope" });
  assert.match(err, /WALLET_ADDR/);
});

test("the calldata is selector + four 32-byte words", () => {
  const data = encodePayeeDigestCall({ node: NODE, token: TOKEN, payee: PAYEE, nonce: 7 });
  assert.equal(data.length, 2 + 8 + 4 * 64);
  assert.ok(data.startsWith("0x"));
  // node occupies the first word verbatim
  assert.ok(data.slice(10, 74).endsWith(NODE.slice(-64)));
  // addresses are left-padded to 32 bytes
  assert.equal(data.slice(74, 138), "0".repeat(24) + TOKEN.slice(2).toLowerCase());
  assert.equal(data.slice(138, 202), "0".repeat(24) + PAYEE.slice(2).toLowerCase());
  assert.equal(data.slice(202, 266), "0".repeat(63) + "7");
});

test("the command carries $WALLET_PK as a name, never a value", () => {
  const cmd = buildCommand({ walletAddr: WALLET, node: NODE, token: TOKEN, payee: PAYEE, nonce: 7 });
  assert.ok(cmd.includes("$WALLET_PK"));
  assert.ok(cmd.includes("$ATTESTATION"));
  assert.ok(cmd.includes("allowPayee(bytes32,address,address,uint256,bytes)"));
  // The real key, whatever it is, must not be in there.
  const real = process.env.WALLET_PK;
  if (real) assert.ok(!cmd.includes(real) && !cmd.includes(real.replace(/^0x/, "")));
});

test("redact removes the url and its hostname", () => {
  const msg = `connect ECONNREFUSED ${RPC}/x and ethereum-sepolia-rpc.publicnode.com again`;
  const safe = redact(msg, RPC);
  assert.ok(!safe.includes("publicnode.com"));
  assert.ok(safe.includes("<rpc>"));
});

test("redact survives an unparseable url", () => {
  assert.doesNotThrow(() => redact("boom", "ht!tp://["));
});

test("a malformed payee is 400 and makes no rpc call", async () => {
  let called = false;
  const r = await widenPlan({
    payee: "0xnope", token: TOKEN, env, nonce: 7,
    fetchImpl: async () => { called = true; },
  });
  assert.equal(r.status, 400);
  assert.equal(called, false);
});

test("a malformed token is 400", async () => {
  const r = await widenPlan({ payee: PAYEE, token: "zzz", env, nonce: 7, fetchImpl: okFetch });
  assert.equal(r.status, 400);
});

test("missing env is 500 before any rpc call", async () => {
  let called = false;
  const r = await widenPlan({
    payee: PAYEE, token: TOKEN, env: {}, nonce: 7,
    fetchImpl: async () => { called = true; },
  });
  assert.equal(r.status, 500);
  assert.equal(called, false);
});

test("a good call returns the digest, the nonce and the command", async () => {
  const r = await widenPlan({ payee: PAYEE, token: TOKEN, env, nonce: 7, fetchImpl: okFetch });
  assert.equal(r.status, 200);
  assert.equal(r.body.digest, DIGEST);
  assert.equal(r.body.nonce, "7");
  assert.equal(r.body.payee, PAYEE);
  assert.ok(r.body.command.includes("$ATTESTATION"));
});

test("an rpc error is 502 with the url redacted", async () => {
  const r = await widenPlan({
    payee: PAYEE, token: TOKEN, env, nonce: 7,
    fetchImpl: async () => { throw new Error(`fetch failed for ${RPC}/v2/KEY`); },
  });
  assert.equal(r.status, 502);
  assert.ok(!JSON.stringify(r.body).includes("publicnode.com"));
  assert.ok(!JSON.stringify(r.body).includes("KEY"));
});

test("a JSON-RPC error object is 502, not a silent success", async () => {
  const r = await widenPlan({
    payee: PAYEE, token: TOKEN, env, nonce: 7,
    fetchImpl: async () => ({ ok: true, json: async () => ({ error: { message: "reverted" } }) }),
  });
  assert.equal(r.status, 502);
  assert.match(JSON.stringify(r.body), /reverted/);
});

test("a result that is not 32 bytes fails closed", async () => {
  const r = await widenPlan({
    payee: PAYEE, token: TOKEN, env, nonce: 7,
    fetchImpl: async () => ({ ok: true, json: async () => ({ result: "0x1234" }) }),
  });
  assert.equal(r.status, 502);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd world && node --test widen-plan.test.mjs`
Expected: FAIL — `Cannot find module './widen-plan.mjs'`.

- [ ] **Step 3: Write the module**

Create `world/widen-plan.mjs`:

```js
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

// Same shape as agent/subgraph.mjs: remove the whole url, then the bare hostname, because a
// connection error reports only the host while a malformed-url error reports the path.
export function redact(text, rpcUrl) {
  let safe = String(text ?? "");
  if (!rpcUrl) return safe;
  safe = safe.split(rpcUrl).join("<rpc>");
  try {
    safe = safe.split(new URL(rpcUrl).hostname).join("<rpc>");
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd world && node --test widen-plan.test.mjs`
Expected: PASS — 13 tests, 0 fail.

- [ ] **Step 5: Prove the key test is not vacuous**

Temporarily change `buildCommand` to interpolate `process.env.WALLET_PK` instead of the literal `$WALLET_PK`, and run with a value set:

```bash
cd world && WALLET_PK=0xdeadbeef node --test widen-plan.test.mjs
```

Expected: the `$WALLET_PK` test goes **RED**. Revert the change and confirm it goes green again. A guard that cannot fail is not a guard.

- [ ] **Step 6: Commit**

```bash
git add world/widen-plan.mjs world/widen-plan.test.mjs
git commit -m "feat: build the widening digest and its command without touching a key"
```

---

