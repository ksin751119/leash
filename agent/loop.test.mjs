import { test } from "node:test";
import assert from "node:assert/strict";
import { advance, initialState, sendAndRecord } from "./loop.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200;

const intents = [{ id: "a", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" }];

const okSnap = () => ({
  ok: true,
  block: { subgraph: 11667861, chain: 11667863, lag: 2 },
  agent: { address: "0xaa", revoked: false },
  subname: { label: "vendors", live: true },
  policy: { address: "0xbb", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "0", periodEnd: 0 },
  payees: { [PAYEE]: { allowed: true, lastToken: TOKEN } },
});

test("an eligible intent is queued to send", () => {
  const { toSend } = advance(initialState(), okSnap(), intents, NOW);
  assert.deepEqual(toSend.map((i) => i.id), ["a"]);
});

test("an in-flight intent is not queued again - this is what stops duplicate payments", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.inFlight = true;
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "in-flight");
});

test("an executed intent is terminal and never sent again", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", outcome: "executed", tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "done");
});

test("a blocked intent stays eligible, so the agent retries after a widening", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

test("a failed read sends nothing and says so", () => {
  const { state, toSend } = advance(initialState(), { ok: false, error: "boom" }, intents, NOW);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.verdict, "unknown-read-failed");
});

test("a predicted block is not sent", () => {
  const s = okSnap();
  s.payees[PAYEE].allowed = false;
  const { toSend, state } = advance(initialState(), s, intents, NOW);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.reason, 6);
});

test("the tick counter and the source block land in the state", () => {
  // subgraph, chain and lag are all distinct here so a swap between subgraphBlock and
  // chainBlock in advance() cannot hide behind equal fixture values.
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  assert.equal(state.tick, 1);
  assert.equal(state.source.subgraphBlock, 11667861);
  assert.equal(state.source.chainBlock, 11667863);
  assert.equal(state.source.lagBlocks, 2);
});

// A timed-out send obtains a transaction hash but never gets a classified outcome (send.mjs's
// 120s wait on waitForTransactionReceipt threw). That hash reaching state, and the intent NOT
// being queued again, is the second duplicate-payment path: without it, the next tick would
// send the same payment a second time on top of one that might still land.
test("a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", tx: "0xdeadbeef", outcome: null, error: "timeout" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "unconfirmed");
  assert.match(next.state.intents.a.explain, /0xdeadbeef/);
  assert.equal(next.state.intents.a.lastAction.tx, "0xdeadbeef");
});

// The counterpart: a failure with no hash at all means nothing was ever submitted, so the
// intent must stay eligible - otherwise the fix for the timeout case would over-correct into
// never retrying a genuine pre-send failure (bad nonce, insufficient gas, RPC down).
test("a pre-send failure with no hash stays eligible, since nothing was sent", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "error", tx: null, outcome: null, error: "insufficient funds for gas" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

// sendAndRecord clears `inFlight` in a `finally`, so the guard holds even if `sendImpl`
// throws instead of returning - which the real sendSpend never does today, but nothing in
// loop.mjs enforced that until now. Without the finally, a throwing send would leave the
// intent stuck reporting "in-flight" forever, indistinguishable on stage from index lag.
test("inFlight is cleared even when the send throws, via a finally", async () => {
  const rec = { id: "a", inFlight: false, lastAction: null };
  const throwingSend = async () => {
    throw new Error("network exploded");
  };
  await assert.rejects(() => sendAndRecord(rec, intents[0], { rpcUrl: "", privKey: "", wallet: "" }, throwingSend));
  assert.equal(rec.inFlight, false);
});
