import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./decide.mjs";
import { REASON } from "./reason.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200; // 2026-09-09T12:00:00Z

const base = () => ({
  ok: true,
  block: { subgraph: 11667861, chain: 11667861, lag: 0 },
  agent: { address: "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0", revoked: false },
  subname: { label: "vendors", live: true },
  policy: { address: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "300000000", periodEnd: 1788998400 },
  payees: { [PAYEE]: { allowed: true, lastToken: TOKEN } },
});

const intent = (over = {}) => ({
  id: "t", token: TOKEN, payee: PAYEE, amount: "100000000", note: "", ...over,
});

test("a payment inside every limit will pass", () => {
  const d = decide(base(), intent(), NOW);
  assert.equal(d.verdict, "will-pass");
  assert.equal(d.reason, null);
});

// I5: `explain: null` on a pass reads as "nothing to say", which is exactly the silent
// optimism the three-valued verdict was built to avoid - the five unindexed reasons must
// stay visible somewhere the endpoint actually shows.
test("a pass says what pre-flight cannot see, so it never reads as a silent guarantee", () => {
  const d = decide(base(), intent(), NOW);
  assert.equal(d.verdict, "will-pass");
  assert.ok(d.explain && d.explain.length > 10, "will-pass must not carry a null explain");
  assert.match(d.explain, /not indexed|only the chain/i);
});

test("a revoked agent is blocked with AGENT_REVOKED", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.AGENT_REVOKED);
});

test("no policy pointer is blocked with NO_POLICY", () => {
  const s = base();
  s.policy = null;
  assert.equal(decide(s, intent(), NOW).reason, REASON.NO_POLICY);
});

test("an unapproved policy is blocked with POLICY_NOT_APPROVED", () => {
  const s = base();
  s.policy.approved = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.POLICY_NOT_APPROVED);
});

test("a payee absent from the index is blocked with PAYEE_NOT_ALLOWED", () => {
  const d = decide(base(), intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.PAYEE_NOT_ALLOWED);
});

test("a payee explicitly not allowed is blocked with PAYEE_NOT_ALLOWED", () => {
  const s = base();
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.PAYEE_NOT_ALLOWED);
});

test("exceeding the remaining period budget is blocked with OVER_PERIOD_LIMIT", () => {
  // limit 1000, spent 300 => 700 remaining; 800 must not fit
  const d = decide(base(), intent({ amount: "800000000" }), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.OVER_PERIOD_LIMIT);
});

test("exactly the remaining budget still passes", () => {
  assert.equal(decide(base(), intent({ amount: "700000000" }), NOW).verdict, "will-pass");
});

test("a rolled-over period frees the whole limit again", () => {
  // periodEnd 1788998400 is 2026-09-10T00:00:00Z; decide one second after it
  const d = decide(base(), intent({ amount: "900000000" }), 1788998401);
  assert.equal(d.verdict, "will-pass", "spent must be treated as 0 once the period has reset");
});

test("periodEnd 0 means a lifetime budget and never rolls over", () => {
  const s = base();
  s.budget.periodEnd = 0;
  assert.equal(decide(s, intent({ amount: "800000000" }), NOW).reason, REASON.OVER_PERIOD_LIMIT);
});

test("limit 0 means unlimited", () => {
  const s = base();
  s.budget.limit = "0";
  assert.equal(decide(s, intent({ amount: "999999999999" }), NOW).verdict, "will-pass");
});

test("a missing budget row is unknown, not a block", () => {
  const s = base();
  s.budget = null;
  const d = decide(s, intent(), NOW);
  assert.equal(d.verdict, "unknown");
  assert.equal(d.reason, null);
});

test("a token other than the budget's token is unknown, because the index cannot say", () => {
  const d = decide(base(), intent({ token: "0x1111111111111111111111111111111111111111" }), NOW);
  assert.equal(d.verdict, "unknown");
});

test("a failed read blocks nothing and sends nothing", () => {
  const d = decide({ ok: false, error: "boom" }, intent(), NOW);
  assert.equal(d.verdict, "unknown-read-failed");
  assert.equal(d.reason, null);
});

test("the account layer is checked before the policy layer, as the contract does", () => {
  // revoked (2, account) AND payee not allowed (6, policy) - the contract reports 2
  const s = base();
  s.agent.revoked = true;
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.AGENT_REVOKED);
});

test("every verdict carries a reasonName and an explain when it blocks", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW);
  assert.equal(d.reasonName, "AGENT_REVOKED");
  assert.ok(d.explain && d.explain.length > 10);
});
