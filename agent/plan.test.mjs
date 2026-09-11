// The boundary between a language model and this wallet.
//
// Everything here asks one question: **what can the model make happen that it should not
// be able to?** The answer has to be "nothing beyond proposing a payment from a fixed
// directory", and the tests are the places that could give more away.
import test from "node:test";
import assert from "node:assert/strict";
import { toBaseUnits, buildPrompt, parsePlan, resolvePlan, planPayments } from "./plan.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const VENDORS = [
  { id: "acme-retainer", name: "Acme Studio", note: "on retainer", address: "0x000000000000000000000000000000000000bEEF" },
  { id: "bluefin", name: "Bluefin Design", note: "new", address: "0x00000000000000000000000000000000000CafE0" },
];

// --- amounts ---

test("dollars become base units without touching a float", () => {
  assert.equal(toBaseUnits("5"), "5000000");
  assert.equal(toBaseUnits("5.00"), "5000000");
  assert.equal(toBaseUnits("0.50"), "500000");
  assert.equal(toBaseUnits("0.000001"), "1");
  // The one every money bug starts with. 0.1 + 0.2 must not be anywhere near this.
  assert.equal(toBaseUnits("0.3"), "300000");
});

test("a large amount keeps every digit", () => {
  assert.equal(toBaseUnits("123456789.123456"), "123456789123456");
});

test("anything that is not a plain decimal is refused, not coerced", () => {
  for (const bad of ["$5", "5 USDC", "1,000", "1e3", "-5", "", null, undefined, "abc", "5.", ".5"]) {
    assert.throws(() => toBaseUnits(bad), /plain decimal/, `should refuse ${JSON.stringify(bad)}`);
  }
});

test("more precision than the token has is refused rather than silently truncated", () => {
  assert.throws(() => toBaseUnits("0.1234567"), /decimal places/);
});

// --- the prompt ---

test("the prompt offers ids and never asks for an address", () => {
  const p = buildPrompt({ instruction: "pay the retainer", vendors: VENDORS });
  assert.match(p, /acme-retainer/);
  assert.match(p, /bluefin/);
  assert.equal(/0x[0-9a-fA-F]{40}/.test(p), false, "no address may appear in the prompt");
  assert.match(p, /Use only the ids listed above/);
});

// --- parsing ---

test("a fenced answer is unwrapped, because a fence is formatting and not content", () => {
  assert.deepEqual(parsePlan('```json\n[{"vendor":"bluefin","amount":"5"}]\n```'), [
    { vendor: "bluefin", amount: "5" },
  ]);
  assert.deepEqual(parsePlan('```\n[]\n```'), []);
});

test("prose around the JSON is an error, not something to salvage", () => {
  assert.throws(() => parsePlan('Sure! Here you go: [{"vendor":"bluefin"}]'), /did not return JSON/);
});

test("an object is refused - a plan is a list of payments or it is nothing", () => {
  assert.throws(() => parsePlan('{"vendor":"bluefin","amount":"5"}'), /not an array/);
});

// --- resolution: the security boundary ---

// 🔴 The model has no field in which to put an address. This is what makes a hallucinated
// payee impossible rather than unlikely.
test("a vendor id the directory does not contain is refused", () => {
  assert.throws(
    () => resolvePlan({ plan: [{ vendor: "attacker", amount: "5" }], vendors: VENDORS, token: TOKEN }),
    /not in the directory/,
  );
});

test("an address supplied by the model is ignored entirely", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "5", payee: "0x" + "99".repeat(20), address: "0x" + "99".repeat(20) }],
    vendors: VENDORS,
    token: TOKEN,
  });
  assert.equal(out[0].payee, "0x00000000000000000000000000000000000CafE0", "the directory's address, not the model's");
});

test("the token comes from the caller, never from the model", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "1", token: "0x" + "99".repeat(20) }],
    vendors: VENDORS,
    token: TOKEN,
  });
  assert.equal(out[0].token, TOKEN);
});

test("a resolved plan is exactly the shape intents.json has", () => {
  const out = resolvePlan({
    plan: [{ vendor: "acme-retainer", amount: "5.00", why: "monthly retainer" }],
    vendors: VENDORS,
    token: TOKEN,
  });
  assert.deepEqual(Object.keys(out[0]).sort(), ["amount", "id", "note", "payee", "token"]);
  assert.equal(out[0].amount, "5000000");
  assert.equal(out[0].note, "monthly retainer");
});

test("a note is bounded, because it is rendered on a page", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "1", why: "x".repeat(500) }],
    vendors: VENDORS,
    token: TOKEN,
  });
  assert.equal(out[0].note.length, 80);
});

// --- end to end, with the model stubbed ---

const stubRun = (text) => async () => ({ text, durationMs: 1 });

test("an instruction becomes intents", async () => {
  const { intents } = await planPayments({
    instruction: "pay the retainer",
    token: TOKEN,
    vendorsPath: new URL("./vendors.json", import.meta.url),
    runImpl: stubRun('[{"vendor":"acme-retainer","amount":"5","why":"monthly retainer"}]'),
  });
  assert.equal(intents.length, 1);
  assert.equal(intents[0].payee.toLowerCase(), "0x000000000000000000000000000000000000beef");
  assert.equal(intents[0].amount, "5000000");
});

test("an instruction that asks for no payment yields no intents", async () => {
  const { intents } = await planPayments({
    instruction: "what is our budget?",
    token: TOKEN,
    vendorsPath: new URL("./vendors.json", import.meta.url),
    runImpl: stubRun("[]"),
  });
  assert.deepEqual(intents, []);
});

// The demo's second beat, stated as a test: the model proposing a payment the chain will
// refuse is not a failure of this module. It is the thing being demonstrated.
test("a payment to a payee nobody allow-listed is planned, not filtered out here", async () => {
  const { intents } = await planPayments({
    instruction: "we hired Bluefin, pay them 5 dollars",
    token: TOKEN,
    vendorsPath: new URL("./vendors.json", import.meta.url),
    runImpl: stubRun('[{"vendor":"bluefin","amount":"5","why":"first invoice"}]'),
  });
  assert.equal(intents.length, 1, "this module does not second-guess the chain");
  assert.equal(intents[0].payee.toLowerCase(), "0x00000000000000000000000000000000000cafe0");
});
