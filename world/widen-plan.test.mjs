import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkWidenEnv, encodePayeeDigestCall, encodeAllowPayeeCall, encodePayeeFaceDigestCall,
  encodeAllowPayeeByFaceCall, buildCommand, redact, widenPlan,
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

test("a malformed nonce is 400 and makes no rpc call, for every bad shape", async () => {
  for (const badNonce of ["abc", undefined, null, 1.5, -1, "-1"]) {
    let called = false;
    const r = await widenPlan({
      payee: PAYEE, token: TOKEN, env, nonce: badNonce,
      fetchImpl: async () => { called = true; },
    });
    assert.equal(r.status, 400, `nonce ${JSON.stringify(badNonce)} should be 400`);
    assert.equal(called, false, `nonce ${JSON.stringify(badNonce)} should not call rpc`);
  }
});

test("a numeric-string nonce is accepted, same as a number", async () => {
  const r = await widenPlan({ payee: PAYEE, token: TOKEN, env, nonce: "7", fetchImpl: okFetch });
  assert.equal(r.status, 200);
  assert.equal(r.body.nonce, "7");
});

test("encodePayeeDigestCall rejects an oversized word", () => {
  const tooWide = "0x" + "ab".repeat(33); // 33 bytes, one too many
  assert.throws(
    () => encodePayeeDigestCall({ node: tooWide, token: TOKEN, payee: PAYEE, nonce: 7 }),
    /word too wide/,
  );
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

// --- encodeAllowPayeeCall ---
//
// This calldata is what a browser wallet signs, so a mis-encoding is not a failed request:
// it is a transaction the node accepts and the contract reads as something else. The
// vectors below were cross-checked with `cast decode-calldata`, which round-tripped all
// five arguments, so these tests pin the layout against an independent encoder rather than
// against my own arithmetic.
const AP = { node: "0x" + "11".repeat(32), token: "0x" + "22".repeat(20), payee: "0x" + "33".repeat(20) };
const headWord = (cd, i) => cd.slice(10 + i * 64, 10 + (i + 1) * 64);

test("encodeAllowPayeeCall puts the selector and the four static args where cast finds them", () => {
  const cd = encodeAllowPayeeCall({ ...AP, nonce: 7, attestation: "0x" + "ab".repeat(73) });
  assert.equal(cd.slice(0, 10), "0xc5bb4cb7", "cast sig allowPayee(bytes32,address,address,uint256,bytes)");
  assert.equal(headWord(cd, 0), "11".repeat(32));
  assert.equal(headWord(cd, 1), "0".repeat(24) + "22".repeat(20));
  assert.equal(headWord(cd, 2), "0".repeat(24) + "33".repeat(20));
  assert.equal(headWord(cd, 3), "0".repeat(63) + "7");
});

// The one an eye cannot check and a round-trip test would not isolate.
test("the bytes offset is 0xa0 - five head words, counted from the args and not the selector", () => {
  const cd = encodeAllowPayeeCall({ ...AP, nonce: 1, attestation: "0x" + "ab".repeat(73) });
  assert.equal(BigInt("0x" + headWord(cd, 4)), 160n, "0xa0. 0xc0 would be counting the selector in");
});

test("the length word is the real byte count, and the tail pads to a whole word", () => {
  const cd = encodeAllowPayeeCall({ ...AP, nonce: 1, attestation: "0x" + "ab".repeat(73) });
  assert.equal(BigInt("0x" + headWord(cd, 5)), 73n);
  const tail = cd.slice(10 + 6 * 64);
  assert.equal(tail.length, 96 * 2, "73 bytes rounds up to 3 words");
  assert.equal(tail.slice(0, 146), "ab".repeat(73), "the blob is intact");
  assert.match(tail.slice(146), /^0+$/, "and the remainder is zero padding, not truncation");
});

test("an attestation that is exactly one word is not over-padded", () => {
  const cd = encodeAllowPayeeCall({ ...AP, nonce: 1, attestation: "0x" + "cd".repeat(32) });
  assert.equal(cd.slice(10 + 6 * 64).length, 32 * 2, "one word in, one word out");
});

test("an attestation that is not whole bytes is refused rather than silently padded", () => {
  assert.throws(
    () => encodeAllowPayeeCall({ ...AP, nonce: 1, attestation: "0xabc" }),
    /not whole bytes/,
  );
});

// --- the face path ---
//
// `widenPlan` makes TWO eth_calls now: who governs this wallet, then the digest that names
// them. A mock that answers both identically - which is what `okFetch` above does - cannot
// tell the difference, so these drive the calls apart deliberately.
const OWNER = "0x180f9ee15bedaa3c1912ea178de159e0997ecaea8751f1b3f9f880601b49e881";
const ZERO32 = "0x" + "00".repeat(32);

/// Answers by selector, so a test can prove which call got which answer.
const byCall = (ownerResult, digestResult) => {
  const calls = [];
  const impl = async (_url, init) => {
    const data = JSON.parse(init.body).params[0].data;
    calls.push(data.slice(0, 10));
    // ownerNullifier() takes no arguments, so it is exactly the 4-byte selector.
    const isOwner = data.length === 10;
    return { ok: true, json: async () => ({ result: isOwner ? ownerResult : digestResult }) };
  };
  impl.calls = calls;
  return impl;
};

test("the plan reads who governs the wallet and binds the digest to them", async () => {
  const impl = byCall(OWNER, DIGEST);
  const r = await widenPlan({ payee: PAYEE, token: TOKEN, env, nonce: 7, fetchImpl: impl });
  assert.equal(r.status, 200);
  assert.equal(r.body.nullifier, OWNER, "the plan must report whose face this binds to");
  assert.equal(r.body.digest, DIGEST);
  assert.equal(impl.calls.length, 2, "one call for the owner, one for the digest");
});

// Without this the page would show a digest, spend a real face scan against it, and only
// then discover the account refuses every face - with nothing on screen explaining why.
test("a wallet with no registered face is refused before any scan is offered", async () => {
  const impl = byCall(ZERO32, DIGEST);
  const r = await widenPlan({ payee: PAYEE, token: TOKEN, env, nonce: 7, fetchImpl: impl });
  assert.equal(r.status, 409);
  assert.match(r.body.error, /no registered face/);
  assert.equal(impl.calls.length, 1, "and it does not go on to ask for a digest");
});

test("a short answer from ownerNullifier fails closed rather than becoming a signal", async () => {
  const impl = byCall("0x1234", DIGEST);
  const r = await widenPlan({ payee: PAYEE, token: TOKEN, env, nonce: 7, fetchImpl: impl });
  assert.equal(r.status, 502);
  assert.match(r.body.error, /ownerNullifier/);
});

test("encodePayeeFaceDigestCall carries the nullifier as its fifth word", () => {
  const cd = encodePayeeFaceDigestCall({
    node: "0x" + "11".repeat(32), token: "0x" + "22".repeat(20),
    payee: "0x" + "33".repeat(20), nonce: 7, nullifier: OWNER,
  });
  assert.equal(cd.length, 10 + 5 * 64, "selector plus five static words");
  assert.equal(cd.slice(10 + 4 * 64), OWNER.slice(2));
});

test("encodeAllowPayeeByFaceCall offsets to 0xc0 - six head words, not five", () => {
  const cd = encodeAllowPayeeByFaceCall({
    node: "0x" + "11".repeat(32), token: "0x" + "22".repeat(20),
    payee: "0x" + "33".repeat(20), nonce: 7, nullifier: OWNER,
    attestation: "0x" + "ab".repeat(73),
  });
  assert.equal(cd.slice(0, 10), "0xf9e0d27d", "cast sig allowPayeeByFace(...)");
  assert.equal(BigInt("0x" + cd.slice(10 + 5 * 64, 10 + 6 * 64)), 192n, "0xc0, one word past the other path's 0xa0");
  assert.equal(BigInt("0x" + cd.slice(10 + 6 * 64, 10 + 7 * 64)), 73n);
});
