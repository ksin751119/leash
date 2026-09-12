// The boundary between a language model and this wallet.
//
// Everything here asks one question: **what can the model make happen that it should not
// be able to?** The answer has to be "nothing beyond proposing a payment from a fixed
// directory", and the tests are the places that could give more away.
import test from "node:test";
import assert from "node:assert/strict";
import {
  toBaseUnits, buildPrompt, buildOutcomePrompt, parsePlan, resolvePlan, planPayments,
  resolveEns, namehash,
} from "./plan.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const VENDORS = [
  { id: "acme-retainer", name: "Acme Studio", note: "on retainer", ens: "acme.leash.eth" },
  { id: "bluefin", name: "Bluefin Design", note: "new", ens: "bluefin.leash.eth" },
];
const BEEF = "0x000000000000000000000000000000000000beef";
const CAFE = "0x00000000000000000000000000000000000cafe0";
const RESOLVED = new Map([["acme.leash.eth", BEEF], ["bluefin.leash.eth", CAFE]]);

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
  assert.deepEqual(parsePlan('```json\n{"say":"ok","payments":[{"vendor":"bluefin","amount":"5"}]}\n```'), {
    say: "ok",
    payments: [{ vendor: "bluefin", amount: "5" }],
  });
  assert.deepEqual(parsePlan('```\n{"say":"nothing to do","payments":[]}\n```'), {
    say: "nothing to do",
    payments: [],
  });
});

// The shape this returned before the model was asked to speak. Still accepted: refusing it
// would turn a model that answered the older contract correctly into a failure.
test("a bare array is still accepted, with no sentence", () => {
  assert.deepEqual(parsePlan('[{"vendor":"bluefin","amount":"5"}]'), {
    say: null,
    payments: [{ vendor: "bluefin", amount: "5" }],
  });
});

test("an object with no payments array is refused", () => {
  assert.throws(() => parsePlan('{"say":"I will pay them"}'), /no payments array/);
});

test("a runaway sentence is bounded, because it is rendered on a page", () => {
  const long = JSON.stringify({ say: "x".repeat(900), payments: [] });
  assert.equal(parsePlan(long).say.length, 240);
});

test("prose around the JSON is an error, not something to salvage", () => {
  assert.throws(() => parsePlan('Sure! Here you go: [{"vendor":"bluefin"}]'), /did not return JSON/);
});

test("an object that is neither shape is refused", () => {
  assert.throws(() => parsePlan('{"vendor":"bluefin","amount":"5"}'), /no payments array/);
  assert.throws(() => parsePlan('"just a string"'), /neither an object nor an array/);
  assert.throws(() => parsePlan("42"), /neither an object nor an array/);
});

// --- resolution: the security boundary ---

// 🔴 The model has no field in which to put an address. This is what makes a hallucinated
// payee impossible rather than unlikely.
test("a vendor id the directory does not contain is refused", () => {
  assert.throws(
    () => resolvePlan({ plan: [{ vendor: "attacker", amount: "5" }], vendors: VENDORS, token: TOKEN, resolved: RESOLVED }),
    /not in the directory/,
  );
});

test("an address supplied by the model is ignored entirely", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "5", payee: "0x" + "99".repeat(20), address: "0x" + "99".repeat(20) }],
    vendors: VENDORS,
    token: TOKEN,
    resolved: RESOLVED,
  });
  assert.equal(out[0].payee, CAFE, "the address ENS gave, not the model's");
});

test("the token comes from the caller, never from the model", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "1", token: "0x" + "99".repeat(20) }],
    vendors: VENDORS,
    token: TOKEN,
    resolved: RESOLVED,
  });
  assert.equal(out[0].token, TOKEN);
});

test("a resolved plan is exactly the shape intents.json has", () => {
  const out = resolvePlan({
    plan: [{ vendor: "acme-retainer", amount: "5.00", why: "monthly retainer" }],
    vendors: VENDORS,
    token: TOKEN,
    resolved: RESOLVED,
  });
  assert.deepEqual(Object.keys(out[0]).sort(), ["amount", "ens", "id", "note", "payee", "token"]);
  assert.equal(out[0].amount, "5000000");
  assert.equal(out[0].note, "monthly retainer");
});

test("a note is bounded, because it is rendered on a page", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "1", why: "x".repeat(500) }],
    vendors: VENDORS,
    token: TOKEN,
    resolved: RESOLVED,
  });
  assert.equal(out[0].note.length, 80);
});

// --- end to end, with the model stubbed ---

const stubRun = (text) => async () => ({ text, durationMs: 1 });
const stubPlan = (payments, say = "on it") => stubRun(JSON.stringify({ say, payments }));
// Resolution is stubbed so these stay offline; `resolveEns` has its own tests below.
const stubResolve = async () => new Map([
  ["acme.leash.eth", BEEF], ["bluefin.leash.eth", CAFE], ["api.leash.eth", "0x000000000000000000000000000000000000f00d"],
]);
const plan = (opts) => planPayments({ token: TOKEN, vendorsPath: new URL("./vendors.json", import.meta.url), resolveImpl: stubResolve, ...opts });

test("an instruction becomes intents", async () => {
  const { intents } = await plan({
    instruction: "pay the retainer",
    runImpl: stubPlan([{ vendor: "acme-retainer", amount: "5", why: "monthly retainer" }]),
  });
  assert.equal(intents.length, 1);
  assert.equal(intents[0].payee.toLowerCase(), "0x000000000000000000000000000000000000beef");
  assert.equal(intents[0].amount, "5000000");
});

test("an instruction that asks for no payment yields no intents", async () => {
  const { intents } = await plan({
    instruction: "what is our budget?",
    runImpl: stubPlan([], "There is nothing to pay here."),
  });
  assert.deepEqual(intents, []);
});

// The demo's second beat, stated as a test: the model proposing a payment the chain will
// refuse is not a failure of this module. It is the thing being demonstrated.
test("a payment to a payee nobody allow-listed is planned, not filtered out here", async () => {
  const { intents } = await plan({
    instruction: "we hired Bluefin, pay them 5 dollars",
    runImpl: stubPlan([{ vendor: "bluefin", amount: "5", why: "first invoice" }]),
  });
  assert.equal(intents.length, 1, "this module does not second-guess the chain");
  assert.equal(intents[0].payee.toLowerCase(), "0x00000000000000000000000000000000000cafe0");
});

// --- what it says ---

test("the sentence the model addresses to the person is carried through", async () => {
  const { say } = await plan({
    instruction: "pay the retainer",
    runImpl: stubPlan([{ vendor: "acme-retainer", amount: "5" }], "Paying the studio retainer, 5.00 USDC."),
  });
  assert.equal(say, "Paying the studio retainer, 5.00 USDC.");
});

test("the planning prompt forbids promising success, because the agent does not decide that", () => {
  const p = buildPrompt({ instruction: "pay everyone", vendors: VENDORS });
  assert.match(p, /Do not promise the payments will succeed/);
});

// The sentence that matters. A canned "I was blocked" would prove nothing about whether the
// agent understood being overruled, which is why this is a second model call and not a
// template.
test("the outcome prompt states what happened and does not prescribe the remedy", () => {
  const p = buildOutcomePrompt({
    instruction: "pay Bluefin",
    outcomes: [
      { name: "bluefin", paid: false, reason: 6, reasonName: "PAYEE_NOT_ALLOWED", explain: "not on the allow-list" },
      { name: "acme-retainer", paid: true, amount: "5.00" },
    ],
  });
  assert.match(p, /REFUSED by the chain, reason 6 PAYEE_NOT_ALLOWED/);
  assert.match(p, /PAID 5\.00 USDC/);
  assert.match(p, /it can overrule you/);
  // The TEMPLATE carries no remedy. At runtime the remedy does reach the model, through
  // `explain` — decide.mjs's own sentence for reason 6 mentions a face scan — so an agent
  // that says "we'll need a face scan" is repeating the account, not deducing it. Worth
  // pinning the template's silence anyway: the day explain stops saying it, we want the
  // agent to go quiet about it too rather than keep asserting it from a hardcoded string.
  assert.equal(/face scan/i.test(p), false, "no remedy may be hardcoded into the template");
});

// --- ENS is where a payee address comes from ---
//
// vendors.json has no `address` field. Every one of these tests exists because that is the
// difference between ENS being load-bearing and ENS being a label on a screen.

test("a name that does not resolve stops the payment before a transaction exists", () => {
  assert.throws(
    () => resolvePlan({
      plan: [{ vendor: "bluefin", amount: "5" }],
      vendors: VENDORS, token: TOKEN,
      resolved: new Map(), // the record is gone
    }),
    /does not resolve to an address/,
  );
});

test("the ENS name is carried onto the intent, so the page can show the resolution", () => {
  const out = resolvePlan({
    plan: [{ vendor: "bluefin", amount: "5" }], vendors: VENDORS, token: TOKEN, resolved: RESOLVED,
  });
  assert.equal(out[0].ens, "bluefin.leash.eth");
  assert.equal(out[0].payee, CAFE);
});

test("namehash agrees with the value this project has used on chain since 09-08", () => {
  assert.equal(
    namehash("vendors.leash.eth"),
    "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
  );
  assert.equal(namehash(""), "0x" + "00".repeat(32));
});

// A name whose record was never set resolves to the zero address. Paying that is burning
// money, so it must be an error and not an answer.
test("resolveEns refuses the zero address rather than returning it", async () => {
  const zero = "0x" + "00".repeat(32) + "0".repeat(64) + "0".repeat(64);
  await assert.rejects(
    () => resolveEns({
      names: ["nobody.leash.eth"], rpcUrl: "http://x", resolver: "0x" + "11".repeat(20),
      fetchImpl: async () => ({ ok: true, json: async () => ({ result: "0x" + "00".repeat(96) }) }),
    }),
    /zero address/,
  );
});

test("resolveEns asks the resolver once per distinct name", async () => {
  let calls = 0;
  const beefWord = "0".repeat(24) + "beef".padStart(40, "0");
  const r = await resolveEns({
    names: ["acme.leash.eth", "acme.leash.eth", "bluefin.leash.eth"],
    rpcUrl: "http://x", resolver: "0x" + "11".repeat(20),
    fetchImpl: async () => {
      calls++;
      return { ok: true, json: async () => ({ result: "0x" + "00".repeat(32) + "00".repeat(32) + beefWord }) };
    },
  });
  assert.equal(calls, 2, "two distinct names, two calls");
  assert.equal(r.size, 2);
});

test("an rpc error naming the name is surfaced, not swallowed", async () => {
  await assert.rejects(
    () => resolveEns({
      names: ["acme.leash.eth"], rpcUrl: "http://x", resolver: "0x" + "11".repeat(20),
      fetchImpl: async () => ({ ok: true, json: async () => ({ error: { message: "execution reverted" } }) }),
    }),
    /acme\.leash\.eth did not resolve/,
  );
});
