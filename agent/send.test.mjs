import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyReceipt, redactUrls, TOPIC_EXECUTED, TOPIC_BLOCKED } from "./send.mjs";

const WALLET = "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6";
const OTHER = "0x1111111111111111111111111111111111111111";

// SpendBlocked's non-indexed args in order: node, amount, reason, policy, spentSoFar, limit.
// node is word 0, amount word 1, reason word 2. reason 6 in word 2:
const blockedData =
  "0x" +
  "00".repeat(32) + // node
  "00".repeat(32) + // amount
  "00".repeat(31) + "06" + // reason = 6
  "00".repeat(32) + // policy
  "00".repeat(32) + // spentSoFar
  "00".repeat(32); // limit

test("a SpendExecuted log is executed", () => {
  const r = classifyReceipt({ logs: [{ address: WALLET, topics: [TOPIC_EXECUTED], data: "0x" }] }, WALLET);
  assert.equal(r.outcome, "executed");
  assert.equal(r.reason, null);
});

test("a SpendBlocked log yields its reason code", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET, topics: [TOPIC_BLOCKED], data: blockedData }] },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
  assert.equal(r.reason, 6);
  assert.equal(r.reasonName, "PAYEE_NOT_ALLOWED");
});

test("logs from another address are ignored", () => {
  const r = classifyReceipt({ logs: [{ address: OTHER, topics: [TOPIC_EXECUTED], data: "0x" }] }, WALLET);
  assert.equal(r.outcome, "no-event");
});

test("address comparison is case-insensitive", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET.toLowerCase(), topics: [TOPIC_EXECUTED], data: "0x" }] },
    WALLET.toUpperCase().replace("0X", "0x"),
  );
  assert.equal(r.outcome, "executed");
});

test("no logs at all is no-event, not a crash", () => {
  assert.equal(classifyReceipt({ logs: [] }, WALLET).outcome, "no-event");
  assert.equal(classifyReceipt({}, WALLET).outcome, "no-event");
});

test("SpendBlocked wins if both appear, because a block is the safer reading", () => {
  const r = classifyReceipt(
    {
      logs: [
        { address: WALLET, topics: [TOPIC_EXECUTED], data: "0x" },
        { address: WALLET, topics: [TOPIC_BLOCKED], data: blockedData },
      ],
    },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
});

test("redactUrls removes an rpc url carrying an api key", () => {
  const msg = 'HTTP request failed. URL: https://eth-sepolia.g.alchemy.com/v2/SECRET-KEY-abc123';
  const out = redactUrls(msg);
  assert.ok(!out.includes("SECRET-KEY-abc123"), "the key must not survive");
  assert.ok(!out.includes("alchemy.com"), "the host must not survive either");
  assert.match(out, /<rpc>/);
});

test("redactUrls keeps the non-url detail, so it cannot regress to a generic message", () => {
  const out = redactUrls("connect ECONNREFUSED https://eth-sepolia.example/KEY-xyz 443");
  assert.match(out, /ECONNREFUSED/, "the diagnostic must survive");
  assert.ok(!out.includes("KEY-xyz"));
  assert.match(out, /443/, "detail after the url must survive too");
});

test("a truncated SpendBlocked data field does not throw", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET, topics: [TOPIC_BLOCKED], data: "0x1234" }] },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
  assert.equal(r.reason, null);
});
