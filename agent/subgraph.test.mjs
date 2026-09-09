import { test } from "node:test";
import assert from "node:assert/strict";
import { buildIds, fetchSnapshot } from "./subgraph.mjs";

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
