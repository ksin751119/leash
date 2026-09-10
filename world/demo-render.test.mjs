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
