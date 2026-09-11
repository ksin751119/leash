import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./decide.mjs";
import { REASON } from "./reason.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200; // 2026-09-09T12:00:00Z
// The StandardPolicy whose rules decide() encodes - the address base() reports as installed.
const KNOWN = "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b";
// Any other policy. In production this is the PolicySet: `(MicroPaymentPolicy) OR
// (StandardPolicy)`, whose verdict decide() cannot reproduce.
const OTHER = "0x1234567890abcdef1234567890abcdef12345678";

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
  const d = decide(base(), intent(), NOW, KNOWN);
  assert.equal(d.verdict, "will-pass");
  assert.equal(d.reason, null);
});

// I5: `explain: null` on a pass reads as "nothing to say", which is exactly the silent
// optimism the three-valued verdict was built to avoid - the five unindexed reasons must
// stay visible somewhere the endpoint actually shows.
test("a pass says what pre-flight cannot see, so it never reads as a silent guarantee", () => {
  const d = decide(base(), intent(), NOW, KNOWN);
  assert.equal(d.verdict, "will-pass");
  assert.ok(d.explain && d.explain.length > 10, "will-pass must not carry a null explain");
  assert.match(d.explain, /not indexed|only the chain/i);
});

test("a revoked agent is blocked with AGENT_REVOKED", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW, KNOWN);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.AGENT_REVOKED);
});

test("no policy pointer is blocked with NO_POLICY", () => {
  const s = base();
  s.policy = null;
  assert.equal(decide(s, intent(), NOW, KNOWN).reason, REASON.NO_POLICY);
});

test("an unapproved policy is blocked with POLICY_NOT_APPROVED", () => {
  const s = base();
  s.policy.approved = false;
  assert.equal(decide(s, intent(), NOW, KNOWN).reason, REASON.POLICY_NOT_APPROVED);
});

test("a payee absent from the index is blocked with PAYEE_NOT_ALLOWED", () => {
  const d = decide(base(), intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW, KNOWN);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.PAYEE_NOT_ALLOWED);
});

test("a payee explicitly not allowed is blocked with PAYEE_NOT_ALLOWED", () => {
  const s = base();
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW, KNOWN).reason, REASON.PAYEE_NOT_ALLOWED);
});

test("exceeding the remaining period budget is blocked with OVER_PERIOD_LIMIT", () => {
  // limit 1000, spent 300 => 700 remaining; 800 must not fit
  const d = decide(base(), intent({ amount: "800000000" }), NOW, KNOWN);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.OVER_PERIOD_LIMIT);
});

test("exactly the remaining budget still passes", () => {
  assert.equal(decide(base(), intent({ amount: "700000000" }), NOW, KNOWN).verdict, "will-pass");
});

test("a rolled-over period frees the whole limit again", () => {
  // periodEnd 1788998400 is 2026-09-10T00:00:00Z; decide one second after it
  const d = decide(base(), intent({ amount: "900000000" }), 1788998401, KNOWN);
  assert.equal(d.verdict, "will-pass", "spent must be treated as 0 once the period has reset");
});

test("periodEnd 0 means a lifetime budget and never rolls over", () => {
  const s = base();
  s.budget.periodEnd = 0;
  assert.equal(decide(s, intent({ amount: "800000000" }), NOW, KNOWN).reason, REASON.OVER_PERIOD_LIMIT);
});

test("limit 0 means unlimited", () => {
  const s = base();
  s.budget.limit = "0";
  assert.equal(decide(s, intent({ amount: "999999999999" }), NOW, KNOWN).verdict, "will-pass");
});

test("a missing budget row is unknown, not a block", () => {
  const s = base();
  s.budget = null;
  const d = decide(s, intent(), NOW, KNOWN);
  assert.equal(d.verdict, "unknown");
  assert.equal(d.reason, null);
});

test("a token other than the budget's token is unknown, because the index cannot say", () => {
  const d = decide(base(), intent({ token: "0x1111111111111111111111111111111111111111" }), NOW, KNOWN);
  assert.equal(d.verdict, "unknown");
});

test("a failed read blocks nothing and sends nothing", () => {
  const d = decide({ ok: false, error: "boom" }, intent(), NOW, KNOWN);
  assert.equal(d.verdict, "unknown-read-failed");
  assert.equal(d.reason, null);
});

test("the account layer is checked before the policy layer, as the contract does", () => {
  // revoked (2, account) AND payee not allowed (6, policy) - the contract reports 2
  const s = base();
  s.agent.revoked = true;
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW, KNOWN).reason, REASON.AGENT_REVOKED);
});

test("every verdict carries a reasonName and an explain when it blocks", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW, KNOWN);
  assert.equal(d.reasonName, "AGENT_REVOKED");
  assert.ok(d.explain && d.explain.length > 10);
});

// --- the installed policy decides whether the policy layer applies at all ---

// The finding, in one test: under `(MicroPaymentPolicy) OR (StandardPolicy)` a sub-cap
// payment to a payee nobody allow-listed is exactly what the composition was built to allow.
// A pre-flight still applying StandardPolicy's allow-list refuses it, and the agent never
// even attempts the payment the chain would have made.
test("an unrecognised policy skips the payee allow-list, because it is not that policy's rule", () => {
  const s = base();
  s.policy.address = OTHER;
  const d = decide(s, intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW, KNOWN);
  assert.equal(d.verdict, "will-pass");
  assert.equal(d.reason, null);
  assert.match(d.explain, /not the StandardPolicy|only the chain/i);
});

// Both policy-layer rules are gated, not just the first one. The budget block sits below the
// payee check, so gating only the payee check would leave this one still firing.
test("an unrecognised policy skips the period budget too", () => {
  const s = base();
  s.policy.address = OTHER;
  // limit 1000, spent 300 => 700 remaining; 800 would be blocked under StandardPolicy
  assert.equal(decide(s, intent({ amount: "800000000" }), NOW, KNOWN).verdict, "will-pass");
});

// The gate must not weaken the case it was always right about: with StandardPolicy itself
// installed, its rules are this pre-flight's rules and still block.
test("the known policy still blocks a payee that is not allow-listed", () => {
  const d = decide(base(), intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW, KNOWN);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.PAYEE_NOT_ALLOWED);
});

// The subgraph reports addresses lower-cased; .env.example carries the checksummed form.
// A case-sensitive comparison would gate the rules off for the one configuration that is
// actually deployed, and every test above would still pass.
test("the comparison ignores address case, since the index and the env differ in it", () => {
  const d = decide(base(), intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW,
    "0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b");
  assert.equal(d.reason, REASON.PAYEE_NOT_ALLOWED, "the checksummed address must still be recognised");
});

// No default: a pre-flight that does not know whose rules it holds must not predict. loop.mjs
// turns the throw into verdict `invalid`, which is never sent, so this fails closed.
test("decide refuses to run without being told which policy its rules belong to", () => {
  assert.throws(() => decide(base(), intent(), NOW), /knownPolicy/);
  assert.throws(() => decide(base(), intent(), NOW, "0xnothex"), /knownPolicy/);
  assert.throws(() => decide(base(), intent(), NOW, null), /knownPolicy/);
});
