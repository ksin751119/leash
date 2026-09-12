import { test } from "node:test";
import assert from "node:assert/strict";
import { buildIds, buildCohort, fetchSnapshot } from "./subgraph.mjs";

const CFG = {
  url: "http://example.invalid/graphql",
  wallet: "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6", // checksummed on purpose
  node: "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
  agent: "0xf9248C78183E44b27AfAF6e0CdF5e3e2a3771De0", // checksummed on purpose
  token: "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
};

const okBody = {
  data: {
    _meta: { block: { number: 11667861 } },
    agent: { id: "x", revoked: false, node: "0x9B4CC5763F1C6DD5F80B1DD4D6D4C968B9971C25243467394F04E9AA1145E121" },
    subname: { label: "vendors", live: true },
    policyPointer: { policy: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
    agentBudget: {
      token: "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
      limit: "1000000000",
      spent: "300000000",
      remaining: "700000000",
      periodEnd: "1788998400",
    },
    payees: [
      { payee: "0x000000000000000000000000000000000000beef", allowed: true, lastToken: null },
    ],
  },
};

const stub = (body, status = 200) => async () => ({
  ok: status === 200,
  status,
  json: async () => body,
});

test("ids are lowercased, because the index stores them that way", () => {
  const ids = buildIds(CFG);
  assert.equal(ids.agent, "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6-0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0");
  assert.equal(
    ids.budget,
    "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6-0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121-0x768f42455a2d082e23ceef7d51e5787c82d67a39",
  );
  assert.equal(ids.wallet, "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6");
  assert.equal(ids.node, "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121");
  assert.ok(!/[A-F]/.test(ids.agent + ids.budget + ids.wallet), "no uppercase hex may survive");
});

test("a good response becomes a snapshot", async () => {
  const s = await fetchSnapshot({ ...CFG, chainBlock: 11667862 }, stub(okBody));
  assert.equal(s.ok, true);
  assert.equal(s.block.subgraph, 11667861);
  assert.equal(s.block.lag, 1);
  assert.equal(s.agent.revoked, false);
  assert.equal(s.policy.approved, true);
  assert.equal(s.budget.limit, "1000000000");
  assert.equal(s.budget.periodEnd, 1788998400, "periodEnd must be a number, not a string");
  assert.equal(s.payees["0x000000000000000000000000000000000000beef"].allowed, true);
});

// I3: the schema pre-computes `remaining` in the mapping precisely so the agent does not
// re-derive it in JavaScript. Publishing it (alongside decide()'s own figure, which handles
// the rollover case) means the endpoint stops silently dropping the index's own answer.
test("the index's own remaining figure is published, lowercased ids included", async () => {
  const s = await fetchSnapshot({ ...CFG, chainBlock: 11667862 }, stub(okBody));
  assert.equal(s.budget.remaining, "700000000");
  assert.equal(s.agent.node, "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121");
});

test("a null remaining (unlimited budget) is published as null, not the string \"null\"", async () => {
  const body = structuredClone(okBody);
  body.data.agentBudget.remaining = null;
  const s = await fetchSnapshot(CFG, stub(body));
  assert.equal(s.budget.remaining, null);
});

test("payee keys are lowercased so decide() can look them up", async () => {
  const body = structuredClone(okBody);
  body.data.payees[0].payee = "0x000000000000000000000000000000000000BEEF";
  const s = await fetchSnapshot(CFG, stub(body));
  assert.ok(s.payees["0x000000000000000000000000000000000000beef"]);
});

test("GraphQL errors fail closed", async () => {
  const s = await fetchSnapshot(CFG, stub({ errors: [{ message: "bad query" }] }));
  assert.equal(s.ok, false);
  assert.match(s.error, /bad query/);
});

test("a non-200 fails closed", async () => {
  const s = await fetchSnapshot(CFG, stub({}, 502));
  assert.equal(s.ok, false);
  assert.match(s.error, /502/);
});

test("a thrown fetch fails closed instead of propagating", async () => {
  const s = await fetchSnapshot(CFG, async () => {
    throw new Error("ECONNREFUSED");
  });
  assert.equal(s.ok, false);
  assert.match(s.error, /ECONNREFUSED/);
});

test("a missing _meta fails closed - we must never decide on an unknown block", async () => {
  const body = structuredClone(okBody);
  delete body.data._meta;
  const s = await fetchSnapshot(CFG, stub(body));
  assert.equal(s.ok, false);
});

test("absent optional rows are null, not an error", async () => {
  const body = structuredClone(okBody);
  body.data.agentBudget = null;
  body.data.policyPointer = null;
  const s = await fetchSnapshot(CFG, stub(body));
  assert.equal(s.ok, true);
  assert.equal(s.budget, null);
  assert.equal(s.policy, null);
});

test("the error sentence never contains the url on the non-200 path", async () => {
  const s = await fetchSnapshot({ ...CFG, url: "https://x/secret-key-abc" }, stub({}, 500));
  assert.ok(!s.error.includes("secret-key-abc"));
});

test("the error sentence never contains the url on the throw path (malformed URL)", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-abc123";
  const fetchWithUrlInError = async () => {
    throw new Error(`Failed to fetch from ${secretUrl}`);
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithUrlInError);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-abc123"), "the secret key must not appear");
  assert.ok(!s.error.includes(secretUrl), "the url must be redacted");
  assert.ok(s.error.includes("Failed to fetch"), "other error details must survive redaction");
});

test("real connection failures put the detail in err.cause, not err.message", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-xyz";
  const fetchWithCauseError = async () => {
    const err = new Error("fetch failed");
    err.cause = new Error("ECONNREFUSED");
    throw err;
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithCauseError);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-xyz"), "the secret key must not appear");
  assert.ok(s.error.includes("ECONNREFUSED"), "the real diagnostic from err.cause must be present");
  assert.ok(s.error.includes("fetch failed"), "the top-level message must also be present");
});

test("hostname in err.cause does not leak through redaction", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-abc";
  const fetchWithHostnameInCause = async () => {
    const err = new Error("fetch failed");
    err.cause = new Error("getaddrinfo ENOTFOUND api.example.com");
    throw err;
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithHostnameInCause);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-abc"), "the secret key must not appear");
  assert.ok(!s.error.includes("api.example.com"), "the hostname must not leak");
  assert.ok(s.error.includes("ENOTFOUND"), "the error reason must be present");
});

// A 429 must be distinguishable from every other failure, because it is the only one the
// agent can make worse by retrying. Studio rate-limits per deployment, so a loop that keeps
// asking while being told to stop keeps its own window from clearing.
const throttled = (retryAfter) => async () => ({
  ok: false,
  status: 429,
  headers: { get: (h) => (h.toLowerCase() === "retry-after" ? retryAfter : null) },
});

test("a 429 is reported as rate-limiting, not as a generic HTTP failure", async () => {
  const s = await fetchSnapshot(CFG, throttled(null));
  assert.equal(s.ok, false);
  assert.equal(s.rateLimited, true, "the caller must be able to tell this apart");
  assert.match(s.error, /rate-limit/i);
});

test("a Retry-After header is honoured and converted to milliseconds", async () => {
  const s = await fetchSnapshot(CFG, throttled("30"));
  assert.equal(s.retryAfterMs, 30_000);
});

test("a missing or nonsense Retry-After leaves the caller to choose", async () => {
  assert.equal((await fetchSnapshot(CFG, throttled(null))).retryAfterMs, null);
  assert.equal((await fetchSnapshot(CFG, throttled("soon"))).retryAfterMs, null);
  assert.equal((await fetchSnapshot(CFG, throttled("-5"))).retryAfterMs, null);
});

test("other HTTP failures stay generic and do not claim to be rate limits", async () => {
  const s = await fetchSnapshot(CFG, stub({}, 502));
  assert.equal(s.ok, false);
  assert.equal(s.rateLimited, undefined);
  assert.match(s.error, /502/);
});

/* ------------------------------------------------------------------ buildCohort */

const A1 = "0xf9248C78183E44b27AfAF6e0CdF5e3e2a3771De0"; // checksummed on purpose
const A2 = "0x2160562A1C07f854cA37F502fa34BE0887259F8a";
const AGENTS = [
  { agent: A1, revoked: false, spendCount: 2, blockedCount: 1, boundAt: 100 },
  { agent: A2, revoked: false, spendCount: 1, blockedCount: 0, boundAt: 200 },
];

// The whole point of the walk. Two different keys, one running total, and the figure each
// agent contributed is recoverable even though the chain stores no such figure.
test("attributes one shared total across two agents", () => {
  const spends = [
    { agent: A2, amount: "1000000", spentAfter: "21500000", executed: true, timestamp: 30 },
    { agent: A1, amount: "500000", spentAfter: "20500000", executed: true, timestamp: 20 },
    { agent: A1, amount: "20000000", spentAfter: "20000000", executed: true, timestamp: 10 },
  ];
  const rows = buildCohort(AGENTS, spends, { spent: "21500000" });
  assert.deepEqual(
    rows.map((r) => [r.address, r.spentThisPeriod]),
    [[A1.toLowerCase(), "20500000"], [A2.toLowerCase(), "1000000"]],
  );
});

// The period boundary is found by arithmetic, not by a clock. Yesterday's spends are in
// the fetched page and must not be counted: the running total reaches zero first.
test("stops at the period boundary without knowing the period", () => {
  const spends = [
    { agent: A2, amount: "1000000", spentAfter: "1000000", executed: true, timestamp: 99 }, // today, the only one
    { agent: A1, amount: "40000000", spentAfter: "45000000", executed: true, timestamp: 50 }, // yesterday
    { agent: A1, amount: "5000000", spentAfter: "5000000", executed: true, timestamp: 40 }, // yesterday
  ];
  const rows = buildCohort(AGENTS, spends, { spent: "1000000" });
  const byAddr = Object.fromEntries(rows.map((r) => [r.address, r.spentThisPeriod]));
  assert.equal(byAddr[A2.toLowerCase()], "1000000");
  assert.equal(byAddr[A1.toLowerCase()], "0", "yesterday's 45 USDC must not be attributed to today");
});

// A blocked spend never enters the ledger, so it must never enter the attribution either.
test("a refusal contributes nothing and does not break the walk", () => {
  const spends = [
    { agent: A2, amount: "1000000", spentAfter: "21500000", executed: true, timestamp: 30 },
    { agent: A1, amount: "20500000", spentAfter: "20500000", executed: true, timestamp: 10 },
  ];
  const rows = buildCohort(AGENTS, spends, { spent: "21500000" });
  assert.equal(rows.find((r) => r.address === A1.toLowerCase()).spentThisPeriod, "20500000");
  assert.equal(rows.find((r) => r.address === A2.toLowerCase()).spentThisPeriod, "1000000");
});

// The trap this guard exists for. `subgraph/src/account.ts:136` records a refusal's
// `spentSoFar` in the same `spentAfter` field an executed spend uses, so a refusal looks
// exactly like a valid link in the chain. Counting one hands an agent an amount nobody
// spent — here, A2's refused 40.00 would be subtracted from A1's real 20.50 and the parts
// would stop summing to the whole.
test("a refusal that looks like a valid link is still not followed", () => {
  const spends = [
    { agent: A2, amount: "40000000", spentAfter: "20500000", executed: false, timestamp: 40 },
    { agent: A1, amount: "20500000", spentAfter: "20500000", executed: true, timestamp: 10 },
  ];
  const rows = buildCohort(AGENTS, spends, { spent: "20500000" });
  assert.equal(rows.find((r) => r.address === A1.toLowerCase()).spentThisPeriod, "20500000");
  assert.equal(rows.find((r) => r.address === A2.toLowerCase()).spentThisPeriod, "0");
  const sum = rows.reduce((a, r) => a + BigInt(r.spentThisPeriod), 0n);
  assert.equal(sum, 20500000n, "the parts must still sum to the budget's total");
});

// Failing closed matters more than guessing: an incomplete page must under-report rather
// than invent an attribution, because the number goes on screen next to a claim.
test("a gap in the fetched page stops the walk rather than guessing", () => {
  const spends = [{ agent: A2, amount: "1000000", spentAfter: "21500000", executed: true, timestamp: 30 }];
  const rows = buildCohort(AGENTS, spends, { spent: "21500000" });
  assert.equal(rows.find((r) => r.address === A2.toLowerCase()).spentThisPeriod, "1000000");
  assert.equal(rows.find((r) => r.address === A1.toLowerCase()).spentThisPeriod, "0");
});

// A bound agent that has never spent still has to appear: "this budget has two agents on
// it" is the claim, and it is true before either of them spends anything.
test("lists a bound agent that has spent nothing", () => {
  const rows = buildCohort(AGENTS, [], { spent: "0" });
  assert.equal(rows.length, 2);
  assert.ok(rows.every((r) => r.spentThisPeriod === "0"));
});

test("orders by bind time so the list does not reshuffle as agents spend", () => {
  const rows = buildCohort([...AGENTS].reverse(), [], { spent: "0" });
  assert.deepEqual(rows.map((r) => r.address), [A1.toLowerCase(), A2.toLowerCase()]);
});

/* ------------------------------------------------------------------- refusals */

const withSpends = (spends) => ({
  data: {
    ...okBody.data,
    spends,
    agents: AGENTS,
  },
});

// The whole reason this field exists: a refused payment is a status-1 receipt carrying an
// event and no state change, so nothing on chain can be read back to find it. If the index
// does not surface it, it is not visible anywhere.
test("refusals are the blocked attempts, newest first, in reading order", async () => {
  const s = await fetchSnapshot(
    CFG,
    stub(
      withSpends([
        { agent: A2, payee: "0x000000000000000000000000000000000000B1eF", amount: "48000000", executed: false, reason: 8, reasonName: "OVER_PERIOD_LIMIT", spentAfter: "10000000", timestamp: 90, txHash: "0xAABB" },
        { agent: A1, payee: "0x000000000000000000000000000000000000bEEF", amount: "5000000", executed: true, reason: 0, reasonName: "OK", spentAfter: "10000000", timestamp: 80, txHash: "0xCCDD" },
        { agent: A1, payee: "0x000000000000000000000000000000000000B1eF", amount: "5000000", executed: false, reason: 6, reasonName: "PAYEE_NOT_ALLOWED", spentAfter: "5000000", timestamp: 70, txHash: "0xEEFF" },
      ]),
    ),
  );
  assert.equal(s.ok, true);
  assert.deepEqual(
    s.refusals.map((r) => [r.reason, r.reasonName, r.amount, r.agent, r.tx]),
    [
      [8, "OVER_PERIOD_LIMIT", "48000000", A2.toLowerCase(), "0xaabb"],
      [6, "PAYEE_NOT_ALLOWED", "5000000", A1.toLowerCase(), "0xeeff"],
    ],
  );
});

test("an executed spend is never a refusal", async () => {
  const s = await fetchSnapshot(
    CFG,
    stub(withSpends([{ agent: A1, payee: "0x0", amount: "1", executed: true, reason: 0, spentAfter: "1", timestamp: 1, txHash: "0x1" }])),
  );
  assert.deepEqual(s.refusals, []);
});

test("a snapshot with no spends at all has an empty refusal list rather than undefined", async () => {
  const s = await fetchSnapshot(CFG, stub(okBody));
  assert.deepEqual(s.refusals, []);
});
