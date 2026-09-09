import { test } from "node:test";
import assert from "node:assert/strict";
import { advance, initialState } from "./loop.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200;

const intents = [{ id: "a", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" }];

const okSnap = () => ({
  ok: true,
  block: { subgraph: 1, chain: 1, lag: 0 },
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
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  assert.equal(state.tick, 1);
  assert.equal(state.source.subgraphBlock, 1);
  assert.equal(state.source.lagBlocks, 0);
});
