# Demo Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One page, served on :8787, that renders the agent's live reasoning beside the current rules and hosts the face scan, so the demo's central beat happens without cutting away.

**Architecture:** The agent's state endpoint widens by three fields per intent plus the payee allow-list. A new pure module builds the EIP-712 digest and a paste-ready `cast send` command via one `eth_call`. A second pure module turns `publicState()` into display strings. `world/demo.html` is markup, CSS, a 1-second poll and IDKit wiring — no framework, no build step.

**Tech Stack:** Node 24 ESM (`.mjs`), `node --test` (no test framework), `@noble/hashes` for keccak (already a `world/` dependency), plain `fetch` for JSON-RPC. **No new dependency in any package.**

**Spec:** [`docs/superpowers/specs/2026-09-10-demo-frontend-design.md`](../specs/2026-09-10-demo-frontend-design.md)

## Global Constraints

- **The page computes nothing.** No verdict is derived in the browser. Every value on screen traces to a field of `publicState()`. String formatting and substitution are fine; judgement is not.
- **`WALLET_PK` never enters this code.** The generated command contains the literal characters `$WALLET_PK`. A test asserts the command does not contain the value of `process.env.WALLET_PK`.
- **No branch in `advance()` changes.** Task 1 adds fields to a record. The four duplicate-payment guards (`executed` / `unconfirmed` / `inFlight` / `decide`) and their order are untouched.
- **No existing test is edited.** `agent/loop.test.mjs` currently has 28 tests and `cd agent && node --test` reports **72 passing**. That number may only rise.
- **No RPC or subgraph URL may appear in any error body.** Redact the full URL *and* its hostname, the way `agent/subgraph.mjs:63-76` does.
- **No new dependency.** `world/package.json` keeps exactly `@noble/curves` and `@noble/hashes`. Do not add `viem`.
- **`world/index.html` is not edited.** It only changes route.
- Env names already in use, reused verbatim: `SEPOLIA_RPC`, `WALLET_ADDR`, `LEASH_NODE`.
- There is **no Chrome on this machine**. No test may require a browser.

---

### Task 1: Widen the agent's state payload

**Files:**
- Modify: `agent/loop.mjs:143` (the record), `agent/loop.mjs:253-275` (`publicState`), and its one call site
- Test: `agent/loop.test.mjs` (append only)

**Interfaces:**
- Consumes: nothing
- Produces: `publicState(state)` — now an **exported function taking state as a parameter**, returning the object below. Tasks 4 and 5 render exactly this shape.

```
{ tick, at, source, readError, tickError,
  agent, subname, policy, budget,
  payees: { "<lowercase addr>": { allowed: boolean, lastToken: string|null } },
  intents: [{ id, note, payee, token, amount,
              verdict, reason, reasonName, explain, lastAction }] }
```

- [ ] **Step 1: Write the failing tests**

Append to `agent/loop.test.mjs`:

```js
import { publicState } from "./loop.mjs";

test("a record carries the intent's payee, token and amount", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const rec = state.intents.a;
  assert.equal(rec.payee, PAYEE);
  assert.equal(rec.token, TOKEN);
  assert.equal(rec.amount, "5000000");
});

test("those three survive a second tick without being recomputed away", () => {
  const first = advance(initialState(), okSnap(), intents, NOW).state;
  const second = advance(first, okSnap(), intents, NOW + 5).state;
  assert.equal(second.intents.a.payee, PAYEE);
  assert.equal(second.intents.a.amount, "5000000");
});

test("publicState forwards the payee allow-list", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const pub = publicState(state);
  assert.equal(pub.payees[PAYEE].allowed, true);
});

test("publicState publishes the three new intent fields", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const i = publicState(state).intents[0];
  assert.equal(i.payee, PAYEE);
  assert.equal(i.token, TOKEN);
  assert.equal(i.amount, "5000000");
});

test("payees is an empty object when the read failed, never stale", () => {
  const good = advance(initialState(), okSnap(), intents, NOW).state;
  const bad = advance(good, { ok: false, error: "boom" }, intents, NOW + 5).state;
  assert.deepEqual(publicState(bad).payees, {});
  assert.equal(publicState(bad).readError, "boom");
});

test("an intent with no payee publishes null rather than undefined", () => {
  const bare = [{ id: "z", token: TOKEN, payee: PAYEE, amount: "1", note: "" }];
  delete bare[0].payee;
  const { state } = advance(initialState(), okSnap(), bare, NOW);
  assert.equal(publicState(state).intents[0].payee, null);
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd agent && node --test loop.test.mjs`
Expected: FAIL — `publicState` is not exported (`SyntaxError: The requested module './loop.mjs' does not provide an export named 'publicState'`).

- [ ] **Step 3: Widen the record**

`agent/loop.mjs:143`, replace:

```js
    const rec = { ...prev, id: intent.id, note: intent.note ?? "" };
```

with:

```js
    // payee/token/amount are copied onto the record so the state endpoint can say who an
    // intent pays and how much. They are inputs, not decisions: nothing below reads them,
    // and no branch in this function changes because they exist.
    const rec = {
      ...prev,
      id: intent.id,
      note: intent.note ?? "",
      payee: intent.payee ?? null,
      token: intent.token ?? null,
      amount: intent.amount ?? null,
    };
```

- [ ] **Step 4: Make `publicState` a pure function of state, and export it**

`agent/loop.mjs:253`, replace the whole function:

```js
export function publicState(s) {
  return {
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
    tickError: s.tickError ?? null,
    agent: s.snapshot?.agent ?? null,
    subname: s.snapshot?.subname ?? null,
    policy: s.snapshot?.policy ?? null,
    budget: s.snapshot?.budget ?? null,
    // Forwarded from the snapshot, so it is absent exactly when the read failed. Falling
    // back to `{}` rather than the previous tick's map matters: a stale allow-list on a
    // failed read would show the page a permission that may no longer exist.
    payees: s.snapshot?.payees ?? {},
    intents: Object.values(s.intents).map((i) => ({
      id: i.id,
      note: i.note,
      payee: i.payee ?? null,
      token: i.token ?? null,
      amount: i.amount ?? null,
      verdict: i.verdict ?? null,
      reason: i.reason ?? null,
      reasonName: i.reasonName ?? null,
      explain: i.explain ?? null,
      lastAction: i.lastAction ?? null,
    })),
  };
}
```

Then fix the single call site (`agent/loop.mjs:405`):

```js
      if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState(state));
```

- [ ] **Step 5: Run the whole agent suite**

Run: `cd agent && node --test`
Expected: PASS — **78 tests, 0 fail** (72 before, 6 added). If any pre-existing test fails, a branch was changed; revert and redo Step 3 as a pure addition.

- [ ] **Step 6: Commit**

```bash
git add agent/loop.mjs agent/loop.test.mjs
git commit -m "feat: publish the payee, amount and allow-list the demo page needs"
```

---

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

### Task 3: Wire the routes into `world/server.mjs`

**Files:**
- Modify: `world/server.mjs`

**Interfaces:**
- Consumes: `checkWidenEnv`, `widenPlan` from Task 2
- Produces: `GET /` (demo), `GET /harness` (old page), `GET /demo-render.mjs`, `GET /api/widen-plan`

- [ ] **Step 1: Add the import**

At the top of `world/server.mjs`, beside the existing `attest.mjs` import:

```js
import { widenPlan, checkWidenEnv } from "./widen-plan.mjs";
```

- [ ] **Step 2: Move the harness and serve the demo**

Replace the existing `GET /` handler:

```js
    // The demo page is the front door: during judging this is what is on screen. The
    // harness stays reachable at /harness because it is the tool you reach for when the
    // demo misbehaves, and losing it would cost the fallback.
    if (req.method === "GET" && (req.url === "/" || req.url.startsWith("/?"))) {
      const html = await readFile(new URL("./demo.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (req.method === "GET" && (req.url === "/harness" || req.url.startsWith("/harness?"))) {
      const html = await readFile(new URL("./index.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    // demo.html imports this as an ES module, so it needs a JavaScript content type.
    if (req.method === "GET" && req.url === "/demo-render.mjs") {
      const js = await readFile(new URL("./demo-render.mjs", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" });
      return res.end(js);
    }
```

- [ ] **Step 3: Add the widen-plan route**

Place it beside `/api/attest`:

```js
    if (req.method === "GET" && req.url.startsWith("/api/widen-plan")) {
      const q = new URL(req.url, "http://localhost").searchParams;
      const { status, body } = await widenPlan({
        payee: q.get("payee"),
        token: q.get("token"),
        env: process.env,
        nonce: Math.floor(Date.now() / 1000),
      });
      return json(res, status, body);
    }
```

- [ ] **Step 4: Warn at boot**

Inside the existing `server.listen(PORT, "127.0.0.1", () => { … })` callback, after the URLs it already prints:

```js
  // Not fatal: /api/config, /api/precheck and /harness still work without these, and
  // finding out mid-demo is worse than a line at boot. The route itself still refuses with
  // a 500, so it can never half-work.
  const widenErr = checkWidenEnv(process.env);
  if (widenErr) console.warn(`⚠ /api/widen-plan is unavailable: ${widenErr}`);
```

- [ ] **Step 5: Verify by hand**

```bash
cd world && node server.mjs &
sleep 1
curl -s -o /dev/null -w "%{http_code} harness\n" localhost:8787/harness
curl -s "localhost:8787/api/widen-plan?payee=0xnope&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39"
curl -s "localhost:8787/api/widen-plan?payee=0x00000000000000000000000000000000000cafe0&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39" | head -20
kill %1
```

Expected: `200 harness`; the malformed payee returns `{"error":"payee must be 0x + 40 hex chars"}`; the good call returns a `digest`, a `nonce` and a `command` (or a `500` naming the missing env var if `.env` is not loaded — that is the guard working).

`GET /` throws ENOENT on the missing `demo.html` until Task 5, which the outer try/catch turns into a 500. That is expected at this point.

- [ ] **Step 6: Commit**

```bash
git add world/server.mjs
git commit -m "feat: serve the demo at /, move the harness to /harness, add the widen-plan route"
```

---

### Task 4: `world/demo-render.mjs` — turning state into display strings

**Files:**
- Create: `world/demo-render.mjs`, `world/demo-render.test.mjs`

**Interfaces:**
- Consumes: the `publicState(state)` shape from Task 1
- Produces:
  - `shortHex(h) -> string`
  - `formatUsdc(raw) -> string`
  - `renderStatus(s) -> { tick, at, lag, blind, error }`
  - `renderIntent(intent, payees) -> { id, note, payee, payeeShort, payeeAllowed, amount, verdict, tone, reasonLabel, explain, tx }`
  - `renderRules(s) -> { policy, policyShort, approved, spent, limit, pct, payees: [{ addr, short, allowed }] }`

- [ ] **Step 1: Write the failing tests**

Create `world/demo-render.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { shortHex, formatUsdc, renderStatus, renderIntent, renderRules } from "./demo-render.mjs";

const PAYEE = "0x00000000000000000000000000000000000cafe0";
const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";

const state = () => ({
  tick: 47,
  at: "2026-09-10T12:00:00.000Z",
  source: { subgraphBlock: 11667861, chainBlock: 11667863, lagBlocks: 2 },
  readError: null,
  tickError: null,
  policy: { address: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "310000000", periodEnd: 0 },
  payees: { "0x000000000000000000000000000000000000beef": { allowed: true, lastToken: TOKEN } },
  intents: [],
});

test("shortHex keeps both ends", () => {
  assert.equal(shortHex(PAYEE), "0x0000…cafe0");
  assert.equal(shortHex(null), "—");
});

test("formatUsdc divides by 1e6 and keeps two places", () => {
  assert.equal(formatUsdc("5000000"), "5.00");
  assert.equal(formatUsdc("310000000"), "310.00");
  assert.equal(formatUsdc("1"), "0.00");
  assert.equal(formatUsdc(null), "—");
});

test("renderStatus reports the index lag", () => {
  const r = renderStatus(state());
  assert.equal(r.tick, 47);
  assert.equal(r.lag, "2 blocks behind");
  assert.equal(r.blind, false);
});

test("renderStatus says the agent is blind on a read error", () => {
  const r = renderStatus({ ...state(), readError: "subgraph unreachable: <redacted>" });
  assert.equal(r.blind, true);
  assert.match(r.error, /unreachable/);
});

test("a will-pass intent is toned positive", () => {
  const i = renderIntent(
    { id: "retainer", note: "n", payee: PAYEE, token: TOKEN, amount: "5000000",
      verdict: "will-pass", reason: null, reasonName: null, explain: "e", lastAction: null },
    {},
  );
  assert.equal(i.verdict, "will-pass");
  assert.equal(i.tone, "ok");
  assert.equal(i.amount, "5.00");
  assert.equal(i.reasonLabel, null);
});

test("a blocked intent carries its numbered reason", () => {
  const i = renderIntent(
    { id: "newvendor", note: "n", payee: PAYEE, token: TOKEN, amount: "5000000",
      verdict: "will-be-blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED",
      explain: "e", lastAction: null },
    {},
  );
  assert.equal(i.tone, "blocked");
  assert.equal(i.reasonLabel, "6 · PAYEE_NOT_ALLOWED");
});

test("an intent's payee is allowed only when the map says so", () => {
  const base = { id: "x", note: "", payee: PAYEE, token: TOKEN, amount: "1",
                 verdict: "will-pass", reason: null, reasonName: null, explain: "", lastAction: null };
  assert.equal(renderIntent(base, {}).payeeAllowed, false);
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: true } }).payeeAllowed, true);
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: false } }).payeeAllowed, false);
});

test("the map is matched case-insensitively", () => {
  const base = { id: "x", note: "", payee: PAYEE.toUpperCase().replace("0X", "0x"),
                 token: TOKEN, amount: "1", verdict: "will-pass", reason: null,
                 reasonName: null, explain: "", lastAction: null };
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: true } }).payeeAllowed, true);
});

test("a done intent shows its transaction", () => {
  const i = renderIntent(
    { id: "x", note: "", payee: PAYEE, token: TOKEN, amount: "5000000", verdict: "done",
      reason: null, reasonName: null, explain: "",
      lastAction: { kind: "sent", tx: "0x" + "12".repeat(32), outcome: "executed" } },
    {},
  );
  assert.equal(i.tone, "done");
  assert.equal(i.tx, "0x1212…21212");
});

test("renderRules computes the spent percentage", () => {
  const r = renderRules(state());
  assert.equal(r.spent, "310.00");
  assert.equal(r.limit, "1000.00");
  assert.equal(r.pct, 31);
  assert.equal(r.approved, true);
  assert.equal(r.payees.length, 1);
  assert.equal(r.payees[0].allowed, true);
});

test("renderRules survives a null budget and a null policy", () => {
  const r = renderRules({ ...state(), budget: null, policy: null, payees: {} });
  assert.equal(r.limit, "—");
  assert.equal(r.pct, 0);
  assert.equal(r.policyShort, "—");
  assert.equal(r.approved, false);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd world && node --test demo-render.test.mjs`
Expected: FAIL — `Cannot find module './demo-render.mjs'`.

- [ ] **Step 3: Write the module**

Create `world/demo-render.mjs`:

```js
// Pure functions from `publicState()` to the strings the page prints.
//
// They live in their own module for one reason: **there is no browser on the build
// machine**, so the layout's logic has to be testable without one. Nothing here decides
// anything — every verdict, reason and explanation is copied out of what the agent already
// published. If a judgement ever appears in this file, the demo has started faking the one
// thing it exists to show.

export const shortHex = (h) =>
  typeof h === "string" && h.length > 12 ? `${h.slice(0, 6)}…${h.slice(-5)}` : (h ?? "—");

// USDC is 6 decimals. Integer arithmetic on BigInt, because the amounts are strings from
// the chain and Number() would start rounding at ~9 billion units.
export function formatUsdc(raw) {
  if (raw == null) return "—";
  try {
    const units = BigInt(raw);
    const whole = units / 1000000n;
    const cents = (units % 1000000n) / 10000n;
    return `${whole}.${String(cents).padStart(2, "0")}`;
  } catch {
    return "—";
  }
}

export function renderStatus(s) {
  const lag = s.source?.lagBlocks;
  return {
    tick: s.tick,
    at: s.at,
    lag: lag == null ? "—" : lag === 0 ? "up to date" : `${lag} block${lag === 1 ? "" : "s"} behind`,
    blind: Boolean(s.readError),
    error: s.readError ?? s.tickError ?? null,
  };
}

const TONE = {
  "will-pass": "ok",
  "will-be-blocked": "blocked",
  done: "done",
  "in-flight": "pending",
  unconfirmed: "pending",
  unknown: "unknown",
  invalid: "blocked",
};

export function renderIntent(intent, payees) {
  const key = String(intent.payee ?? "").toLowerCase();
  return {
    id: intent.id,
    note: intent.note ?? "",
    payee: intent.payee ?? null,
    payeeShort: shortHex(intent.payee),
    // Absent from the map means never allow-listed — the subgraph writes no Payee entity
    // until one exists — which is also how decide() reads it.
    payeeAllowed: payees?.[key]?.allowed === true,
    amount: formatUsdc(intent.amount),
    verdict: intent.verdict ?? "unknown",
    tone: TONE[intent.verdict] ?? "unknown",
    reasonLabel: intent.reason == null ? null : `${intent.reason} · ${intent.reasonName ?? "?"}`,
    explain: intent.explain ?? "",
    tx: intent.lastAction?.tx ? shortHex(intent.lastAction.tx) : null,
  };
}

export function renderRules(s) {
  const limit = s.budget?.limit ?? null;
  const spent = s.budget?.spent ?? null;
  let pct = 0;
  try {
    if (limit != null && BigInt(limit) > 0n) {
      pct = Number((BigInt(spent ?? 0) * 100n) / BigInt(limit));
    }
  } catch {
    pct = 0;
  }
  return {
    policy: s.policy?.address ?? null,
    policyShort: shortHex(s.policy?.address ?? null),
    approved: s.policy?.approved === true,
    spent: formatUsdc(spent),
    limit: formatUsdc(limit),
    pct,
    payees: Object.entries(s.payees ?? {}).map(([addr, v]) => ({
      addr,
      short: shortHex(addr),
      allowed: v?.allowed === true,
    })),
  };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd world && node --test demo-render.test.mjs`
Expected: PASS — 11 tests, 0 fail.

Then run everything in `world/`: `cd world && node --test`
Expected: PASS — 24 tests (13 from Task 2 + 11 here), 0 fail.

- [ ] **Step 5: Commit**

```bash
git add world/demo-render.mjs world/demo-render.test.mjs
git commit -m "feat: pure render functions, so the layout is testable without a browser"
```

---

### Task 5: `world/demo.html` — the page

**Files:**
- Create: `world/demo.html`

**Interfaces:**
- Consumes: `demo-render.mjs` (Task 4), `GET /api/widen-plan` (Task 3), `GET /api/config` and `POST /api/attest` (existing), `GET http://localhost:8788/api/agent/state` (Task 1)
- Produces: nothing other tasks consume

**Read `world/index.html` first.** Its IDKit boot sequence (`/api/config` → `IDKit.init` → `IDKit.open`) is the working reference and must be copied in shape, not reinvented. In particular `handleVerify(proof, signal)` takes the signal as a parameter rather than re-reading it, so the proof cannot be bound to a different value than the one shown.

- [ ] **Step 1: Write the page**

Create `world/demo.html`. Requirements it must satisfy, all of them checked in Step 2:

1. Two fixed columns: AGENT on the left, RULES on the right. Neither scrolls at 1280×720.
2. Body text ≥ 16px at 1280×720; verdicts carried by a **word and** a colour, never colour alone.
3. Polls `http://localhost:8788/api/agent/state` every 1000 ms and renders via `demo-render.mjs`.
4. Shows tick, timestamp, and the index lag from `renderStatus`.
5. A `readError` paints a banner reading **"the agent is blind — it will propose nothing"**; the intent list dims.
6. Each intent shows: id, note, `payeeShort`, amount in USDC, the verdict word, and — when blocked — `reasonLabel`.
7. The RULES column shows `policyShort` with an approved/unapproved badge, the budget bar (`pct`), and the payee list.
8. The blocked intent is joined to the payee list by a visible connector.
9. A button, enabled only when some intent is `will-be-blocked` with `reason === 6`, that runs the widening flow.

The widening flow, in order:

```js
// 1. Ask the server what this widening's digest is.
const plan = await (await fetch(
  `/api/widen-plan?payee=${encodeURIComponent(intent.payee)}&token=${encodeURIComponent(intent.token)}`
)).json();

// 2. Bind the scan to that digest. `signal` is passed to handleVerify rather than re-read,
//    exactly as world/index.html does, so the proof cannot end up bound to another value.
const cfg = await (await fetch("/api/config")).json();
IDKit.init({
  app_id: cfg.app_id,
  action: cfg.action,
  signal: plan.digest,
  verification_level: "selfieCheckLegacy",
  handleVerify: (proof) => handleVerify(proof, plan.digest),
  onSuccess: () => {},
});
IDKit.open();

// 3. Exchange the proof for an attestation. The server signs only after World returns 200.
async function handleVerify(proof, digest) {
  const r = await fetch("/api/attest", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ digest, proof }),
  });
  const body = await r.json();
  if (!r.ok) throw new Error(body.error ?? `attest failed: HTTP ${r.status}`);
  // 4. Substitute the blob into the command. A string replace, not a decision.
  showCommand(plan.command.replace("$ATTESTATION", body.attestation), body.deadline);
}
```

10. After a successful scan the page shows the finished command with a copy button, and the countdown `signed · valid for 15 min · run the command`.
11. While the payee is still absent from `payees`, show `subgraph is N blocks behind` from `renderStatus().lag`, then `next tick in 3… 2… 1` derived from `tick` and `at`.
12. **The page never fetches an RPC and never asks for a transaction hash.**

- [ ] **Step 2: Verify what can be verified without a browser**

```bash
cd world && node server.mjs &
sleep 1
curl -s localhost:8787/ | grep -c "demo-render.mjs"          # 1 — the module is imported
curl -s -o /dev/null -w "%{http_code}\n" localhost:8787/demo-render.mjs   # 200
curl -s localhost:8787/demo-render.mjs | head -3              # real JS, not HTML
node --input-type=module -e 'await import("./demo-render.mjs")' # parses
kill %1
```

Expected: `1`, `200`, JavaScript source, no import error.

Then grep the page for the constraints that a human reviewer would otherwise have to eyeball:

```bash
grep -c "8788/api/agent/state" world/demo.html   # 1
grep -c "eth_call\|jsonrpc" world/demo.html      # 0 — the page never talks to an RPC
grep -c "WALLET_PK" world/demo.html              # 0 — no key, not even the name
grep -ci "selfieCheckLegacy" world/demo.html     # 1 — not proofOfHuman
```

- [ ] **Step 3: Commit**

```bash
git add world/demo.html
git commit -m "feat: the demo page — the agent's reasoning and the face scan on one screen"
```

- [ ] **Step 4: Hand back for visual review**

There is no Chrome here, so the layout has **not** been seen. Report that plainly and list what a human must check:

- readable at 1280×720 full screen
- nothing scrolls, nothing reflows when a verdict flips
- the connector actually lands on the payee row
- light and dark both legible

---

## Self-Review

**1. Spec coverage.**

| Spec requirement | Task |
|---|---|
| Page served at `:8787`, harness to `/harness` | 3 |
| Polls `:8788`, no CORS change | 1, 5 |
| `publicState()` gains `payees` + three intent fields | 1 |
| No branch in `advance()` changes | 1 (Step 5 asserts 72 pre-existing tests still pass) |
| `GET /api/widen-plan` contract | 2, 3 |
| Command carries `$WALLET_PK` as a name | 2 (Step 5 proves the test is non-vacuous) |
| RPC errors redact url and hostname | 2 |
| Env guard mirroring `checkAttestEnv` | 2, 3 |
| Two fixed columns, 720p legibility | 5 |
| The wait made legible | 5 (items 11) |
| Errors shown, never swallowed | 4 (`renderStatus.blind`), 5 (item 5) |
| Render functions testable without a browser | 4 |
| No new dependency | 2 (`@noble/hashes` only) |

**2. Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". Task 5's HTML is specified as numbered requirements plus the exact widening-flow code, because the markup and CSS are the part a fresh implementer should be free to write well; every behaviour that could be got wrong is either code here or a grep in Step 2.

**3. Type consistency.** `publicState(s)` (Task 1) → `renderStatus/renderIntent/renderRules(s, payees)` (Task 4) → consumed in Task 5. `widenPlan({payee, token, env, nonce, fetchImpl})` returns `{status, body}` in Task 2 and is destructured as `{status, body}` in Task 3. `buildCommand` emits `$ATTESTATION`; Task 5 replaces exactly that token. `payees` is keyed lowercase in `agent/subgraph.mjs` and `renderIntent` lowercases before lookup.
