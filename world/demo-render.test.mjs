import { test } from "node:test";
import assert from "node:assert/strict";
import { shortHex, formatUsdc, renderStatus, renderIntent, renderRules, renderRefusals, relativeTime } from "./demo-render.mjs";

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

test("a spend under one percent is not reported as zero", () => {
  // 5 of 1000 is 0.5%. Truncating integer division rendered it as 0% — indistinguishable
  // from having spent nothing, which is the one thing this panel exists to disprove.
  const r = renderRules({ ...state(), budget: { token: TOKEN, limit: "1000000000", spent: "5000000", periodEnd: 0 } });
  assert.equal(r.pct, 0.5);
  assert.equal(r.hasSpent, true);
});

test("any non-zero spend is distinguishable from none", () => {
  const at = (spent) => renderRules({ ...state(), budget: { token: TOKEN, limit: "1000000000", spent, periodEnd: 0 } });
  assert.equal(at("0").hasSpent, false);
  assert.equal(at("0").pct, 0);
  for (const s of ["1", "5000000", "10000000", "999000000"]) {
    assert.equal(at(s).hasSpent, true, `hasSpent for ${s}`);
  }
});

test("whole percentages stay whole", () => {
  const at = (spent) => renderRules({ ...state(), budget: { token: TOKEN, limit: "1000000000", spent, periodEnd: 0 } });
  assert.equal(at("310000000").pct, 31);
  assert.equal(at("1000000000").pct, 100);
});

test("a zero or absent limit reports no percentage and no spend", () => {
  assert.equal(renderRules({ ...state(), budget: { token: TOKEN, limit: "0", spent: "5000000", periodEnd: 0 } }).pct, 0);
  assert.equal(renderRules({ ...state(), budget: null }).hasSpent, false);
});

// The fourth payee state. Until 2026-09-11 there were three, and a payee that had been
// paid without ever being allow-listed rendered as "revoked" - which asserts that a human
// approved it and later changed their mind. Nobody ever approved it. That row is the
// evidence for the whole OR composition, and it was displaying its own opposite.
test("renderRules keeps 'never on the list' distinguishable from 'revoked'", () => {
  const out = renderRules({
    policy: { address: "0xabc", approved: true },
    budget: { limit: "50000000", spent: "0", token: "0xt" },
    // All four are in play, so the panel's "now" filter keeps every one and this test can
    // still be about the four states rather than about which rows survive.
    intents: [
      { payee: "0x0000000000000000000000000000000000000beef" },
      { payee: "0x000000000000000000000000000000000000f00d" },
      { payee: "0x00000000000000000000000000000000000cafe0" },
      { payee: "0x0000000000000000000000000000000000000dead" },
    ],
    payees: {
      "0x0000000000000000000000000000000000000beef": { allowed: true, everAllowed: true, lastToken: "0xt" },
      // paid under MicroPaymentPolicy; PayeeAllowed never fired for it
      "0x000000000000000000000000000000000000f00d": { allowed: false, everAllowed: false, lastToken: "0xt" },
      // a human allowed this one, then someone revoked it
      "0x00000000000000000000000000000000000cafe0": { allowed: false, everAllowed: true, lastToken: "0xt" },
      // never allowed, never paid
      "0x0000000000000000000000000000000000000dead": { allowed: false, everAllowed: false, lastToken: null },
    },
  });
  const by = Object.fromEntries(out.payees.map((p) => [p.addr.slice(-5), p]));

  assert.equal(by["0beef"].allowed, true);

  assert.equal(by["0f00d"].allowed, false);
  assert.equal(by["0f00d"].everAllowed, false, "nobody ever allow-listed it");
  assert.equal(by["0f00d"].paid, true, "but it was paid - that pair is the fourth state");

  assert.equal(by["cafe0"].everAllowed, true, "a real revocation must stay distinguishable");
  assert.equal(by["cafe0"].allowed, false);

  assert.equal(by["0dead"].everAllowed, false);
  assert.equal(by["0dead"].paid, false, "never allowed and never paid is not the same row");
});

// The index reports last period's total until a new spend is indexed, so a page that shows
// it verbatim overstates how little room is left. Found live: the period rolled over with
// 47.00 of 50.00 showing, and the panel said 94% used about a budget the chain had emptied.
test("renderRules zeroes a budget whose period has already ended", () => {
  const base = {
    policy: { address: "0xabc", approved: true },
    payees: {},
    budget: { limit: "50000000", spent: "47000000", token: "0xt", periodEnd: 1000 },
  };
  assert.equal(renderRules(base, 999).pct, 94, "before the boundary, the index is right");
  assert.equal(renderRules(base, 1000).pct, 0, "at the boundary the chain has reset");
  assert.equal(renderRules(base, 5000).pct, 0);
  assert.equal(renderRules(base, 5000).spent, "0.00");
  assert.equal(renderRules(base, 5000).hasSpent, false, "and the bar must not keep a sliver");
});

test("a budget with no periodEnd is left alone rather than guessed at", () => {
  const s = {
    policy: { address: "0xabc", approved: true },
    payees: {},
    budget: { limit: "50000000", spent: "47000000", token: "0xt" },
  };
  assert.equal(renderRules(s, 9_999_999_999).pct, 94);
});

// The third beat is a pointer swap, so the page has to show what the pointer could move TO.
// `live` is computed by comparison rather than read from a flag, because the pointer and
// the approval list are separate facts — a policy approved but not in use is exactly the
// state that demo starts from.
test("renderRules marks which approved policy is live and which is merely approved", () => {
  const out = renderRules({
    policy: { address: "0xEC45E967f4E907b92BB1a9A8b4Fcf9f041792490", approved: true },
    payees: {},
    budget: { limit: "1", spent: "0", token: "0xt" },
    approvedPolicies: [
      { address: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", description: "StandardPolicy/1: …", approved: true },
      { address: "0xec45e967f4e907b92bb1a9a8b4fcf9f041792490", description: "Under 1.00 USDC to any payee, or …", approved: true },
    ],
  });
  const [std, set] = out.policies;
  assert.equal(std.live, false, "approved, but the pointer is elsewhere");
  assert.equal(set.live, true, "case must not decide this - the pointer arrived checksummed");
  assert.equal(set.description, "Under 1.00 USDC to any payee, or …");
});

test("with no approved policies the list is empty rather than undefined", () => {
  const out = renderRules({ policy: null, payees: {}, budget: null });
  assert.deepEqual(out.policies, []);
});

// "Payees this wallet allows" is a claim about the present. A row left from an earlier run
// — approved and dropped, or paid weeks ago — is history, and history in a panel that
// claims to describe now is noise a viewer has to work out is irrelevant. It also spoils a
// demo: `paid, never listed` on screen before anything has been paid gives away the ending.
test("the payee panel shows what is allowed now, plus whoever the payments are about", () => {
  const out = renderRules({
    policy: { address: "0xa", approved: true },
    budget: { limit: "1", spent: "0", token: "0xt" },
    intents: [{ payee: "0x00000000000000000000000000000000000000b1" }],
    payees: {
      "0x00000000000000000000000000000000000000be": { allowed: true, everAllowed: true },
      // approved then dropped, and nothing on screen is about them
      "0x00000000000000000000000000000000000000ca": { allowed: false, everAllowed: true },
      // paid in some earlier run, and nothing on screen is about them
      "0x00000000000000000000000000000000000000f0": { allowed: false, everAllowed: false, lastToken: "0xt" },
      // not allowed, but a payment on screen is about them — must be shown
      "0x00000000000000000000000000000000000000b1": { allowed: false, everAllowed: false },
    },
  });
  assert.deepEqual(out.payees.map((p) => p.addr.slice(-2)), ["be", "b1"]);
});

test("a payee in play is still shown once it has been paid without ever being listed", () => {
  const addr = "0x00000000000000000000000000000000000000f0";
  const out = renderRules({
    policy: { address: "0xa", approved: true },
    budget: { limit: "1", spent: "0", token: "0xt" },
    intents: [{ payee: addr }],
    payees: { [addr]: { allowed: false, everAllowed: false, lastToken: "0xt" } },
  });
  assert.equal(out.payees.length, 1, "this row is the whole argument for the composition");
  assert.equal(out.payees[0].paid, true);
  assert.equal(out.payees[0].everAllowed, false);
});

/* ------------------------------------------------------- the shared budget's split */

const COHORT_STATE = {
  budget: { limit: "50000000", spent: "21500000", periodEnd: 4102444800 },
  cohort: [
    { address: "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0", spentThisPeriod: "20500000", revoked: false, spendCount: 23, blockedCount: 2 },
    { address: "0x2160562a1c07f854ca37f502fa34be0887259f8a", spentThisPeriod: "1000000", revoked: false, spendCount: 1, blockedCount: 0 },
  ],
};

test("splits one budget across the agents that spent it", () => {
  const r = renderRules(COHORT_STATE, 1000);
  assert.equal(r.spent, "21.50");
  assert.deepEqual(
    r.cohort.map((c) => [c.short, c.spent, c.pct]),
    [
      ["0xf924…71de0", "20.50", 41],
      ["0x2160…59f8a", "1.00", 2],
    ],
  );
});

// The bar and the breakdown read the same field. After the period rolls over the chain has
// zeroed the budget while the index still reports the last period's total — renderRules
// already corrects the bar, and a breakdown that did not would contradict it on screen.
test("zeroes the split on the same rollover that zeroes the bar", () => {
  const rolled = { ...COHORT_STATE, budget: { ...COHORT_STATE.budget, periodEnd: 500 } };
  const r = renderRules(rolled, 1000);
  assert.equal(r.spent, "0.00");
  assert.ok(r.cohort.every((c) => c.spent === "0.00" && c.pct === 0 && c.hasSpent === false));
});

// The claim the panel makes is "this is one budget". If the parts did not add up to the
// whole, the panel would be making it falsely.
test("the parts add up to the whole", () => {
  const r = renderRules(COHORT_STATE, 1000);
  const sum = r.cohort.reduce((a, c) => a + Number(c.spent), 0);
  assert.equal(sum.toFixed(2), r.spent);
});

test("an agent that has spent nothing still appears", () => {
  const r = renderRules(
    { ...COHORT_STATE, budget: { ...COHORT_STATE.budget, spent: "0" }, cohort: COHORT_STATE.cohort.map((c) => ({ ...c, spentThisPeriod: "0" })) },
    1000,
  );
  assert.equal(r.cohort.length, 2);
  assert.ok(r.cohort.every((c) => c.hasSpent === false));
});

test("a state with no cohort renders an empty split rather than throwing", () => {
  const r = renderRules({ budget: COHORT_STATE.budget }, 1000);
  assert.deepEqual(r.cohort, []);
});

/* ----------------------------------------------------------- what was turned away */

const REFUSAL_STATE = {
  refusals: [
    { agent: "0x2160562a1c07f854ca37f502fa34be0887259f8a", payee: "0x000000000000000000000000000000000000b1ef", amount: "48000000", reason: 8, reasonName: "OVER_PERIOD_LIMIT", at: 1000, tx: "0xaabbccddeeff00112233445566778899aabbccddeeff001122334455667788ff" },
    { agent: "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0", payee: "0x000000000000000000000000000000000000b1ef", amount: "5000000", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", at: 100, tx: null },
  ],
};

test("a refusal prints its amount, its reason and who was refused", () => {
  const rows = renderRefusals(REFUSAL_STATE, 1030);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].amount, "48.00");
  assert.equal(rows[0].reasonLabel, "8 · OVER_PERIOD_LIMIT");
  assert.equal(rows[0].payeeShort, "0x0000…0b1ef");
  assert.equal(rows[0].ago, "just now");
  assert.equal(rows[0].txShort, "0xaabb…788ff");
});

// The reason code is the whole content of a refusal. A row that lost it would be a page
// saying "something was refused" — which is the shape of a system that hides its refusals,
// dressed up as one that does not.
test("a refusal with no reason still says it was refused rather than printing nothing", () => {
  const rows = renderRefusals({ refusals: [{ agent: "0x1", payee: "0x2", amount: "1000000", reason: null, at: 0 }] }, 10);
  assert.equal(rows[0].reasonLabel, "refused");
  assert.equal(rows[0].ago, "");
  assert.equal(rows[0].txShort, null);
});

test("no refusals renders nothing rather than throwing", () => {
  assert.deepEqual(renderRefusals({}, 10), []);
});

test("relative time is coarse on purpose", () => {
  assert.equal(relativeTime(1000, 1030), "just now");
  assert.equal(relativeTime(1000, 1600), "10m ago");
  assert.equal(relativeTime(1000, 1000 + 7200), "2h ago");
  assert.equal(relativeTime(1000, 1000 + 86400 * 3), "3d ago");
  assert.equal(relativeTime(0, 1000), "", "no timestamp must print nothing, not '1970'");
});
