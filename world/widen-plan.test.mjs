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
