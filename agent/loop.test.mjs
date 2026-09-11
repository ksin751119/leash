import { test } from "node:test";
import assert from "node:assert/strict";
import { advance, initialState, sendAndRecord, validateIntents, validateEnvVar, routePath, publicState } from "./loop.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200;
// The StandardPolicy whose rules decide() encodes, and the address okSnap() reports as
// installed. advance() takes it as an argument rather than reading module state, so these
// tests can say which policy is installed without starting the loop.
const KNOWN = "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b";

const intents = [{ id: "a", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" }];

const okSnap = () => ({
  ok: true,
  block: { subgraph: 11667861, chain: 11667863, lag: 2 },
  agent: { address: "0xaa", revoked: false },
  subname: { label: "vendors", live: true },
  policy: { address: KNOWN, approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "0", periodEnd: 0 },
  payees: { [PAYEE]: { allowed: true, lastToken: TOKEN } },
});

test("an eligible intent is queued to send", () => {
  const { toSend } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["a"]);
});

test("an in-flight intent is not queued again - this is what stops duplicate payments", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.inFlight = true;
  const next = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "in-flight");
});

test("an executed intent is terminal and never sent again", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "executed", tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "done");
});

test("a blocked intent stays eligible, so the agent retries after a widening", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

test("a failed read sends nothing and says so", () => {
  const { state, toSend } = advance(initialState(), { ok: false, error: "boom" }, intents, NOW, KNOWN);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.verdict, "unknown-read-failed");
});

test("a predicted block is not sent", () => {
  const s = okSnap();
  s.payees[PAYEE].allowed = false;
  const { toSend, state } = advance(initialState(), s, intents, NOW, KNOWN);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.reason, 6);
});

test("the tick counter and the source block land in the state", () => {
  // subgraph, chain and lag are all distinct here so a swap between subgraphBlock and
  // chainBlock in advance() cannot hide behind equal fixture values.
  const { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  assert.equal(state.tick, 1);
  assert.equal(state.source.subgraphBlock, 11667861);
  assert.equal(state.source.chainBlock, 11667863);
  assert.equal(state.source.lagBlocks, 2);
});

// A timed-out send obtains a transaction hash but never gets a classified outcome (send.mjs's
// 120s wait on waitForTransactionReceipt threw). That hash reaching state, and the intent NOT
// being queued again, is the second duplicate-payment path: without it, the next tick would
// send the same payment a second time on top of one that might still land.
test("a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", tx: "0xdeadbeef", outcome: null, error: "timeout" };
  const next = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "unconfirmed");
  assert.match(next.state.intents.a.explain, /0xdeadbeef/);
  assert.equal(next.state.intents.a.lastAction.tx, "0xdeadbeef");
});

// The counterpart: a failure with no hash at all means nothing was ever submitted, so the
// intent must stay eligible - otherwise the fix for the timeout case would over-correct into
// never retrying a genuine pre-send failure (bad nonce, insufficient gas, RPC down).
test("a pre-send failure with no hash stays eligible, since nothing was sent", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "error", tx: null, outcome: null, error: "insufficient funds for gas" };
  const next = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

// sendAndRecord clears `inFlight` in a `finally`, so the guard holds even if `sendImpl`
// throws instead of returning - which the real sendSpend never does today, but nothing in
// loop.mjs enforced that until now. Without the finally, a throwing send would leave the
// intent stuck reporting "in-flight" forever, indistinguishable on stage from index lag.
test("inFlight is cleared even when the send throws, via a finally", async () => {
  const rec = { id: "a", inFlight: false, lastAction: null };
  const throwingSend = async () => {
    throw new Error("network exploded");
  };
  await assert.rejects(() => sendAndRecord(rec, intents[0], { rpcUrl: "", privKey: "", wallet: "" }, throwingSend));
  assert.equal(rec.inFlight, false);
});

// C1: a duplicate id (copy an intent block for the demo, change the amount, forget the id)
// must never reach toSend twice. Two sends for the same id would call sendAndRecord on the
// same record object twice, and the second write to lastAction silently overwrites the
// first transaction's hash - no error, no warning, and the first payment becomes untraceable.
test("a duplicate intent id is never queued twice, even if one slipped past validateIntents", () => {
  const dupIntents = [
    { id: "retainer", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" },
    { id: "retainer", token: TOKEN, payee: PAYEE, amount: "9000000", note: "" },
  ];
  const { toSend } = advance(initialState(), okSnap(), dupIntents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["retainer"]);
});

// I2: decide()'s BigInt(intent.amount) throws on a malformed amount. Load-time validation
// (validateIntents) refuses to start on this for intents.json, but advance() must still
// contain the throw per-intent - otherwise one bad record would stop the loop from
// evaluating every OTHER intent in the same tick, and the whole tick body would need its own
// try/catch to avoid killing the process.
test("a malformed amount does not crash advance, and the error reaches that intent's state", () => {
  const badIntents = [
    { id: "good", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" },
    { id: "bad", token: TOKEN, payee: PAYEE, amount: "5.5", note: "" },
  ];
  const { state, toSend } = advance(initialState(), okSnap(), badIntents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["good"], "the good intent must still be evaluated and sent");
  assert.equal(state.intents.bad.verdict, "invalid");
  assert.match(state.intents.bad.explain, /malformed/);
});

// The "" amount is worse than a crash: BigInt("") === 0n, so decide() does not throw and
// instead silently returns will-pass - the headline intent would degrade to a reverting
// call every tick, which reads as a policy failure rather than a typo. validateIntents'
// /^[0-9]+$/ requires at least one digit, so this is caught at load instead.
test("an empty-string amount is rejected at load, not silently treated as zero", () => {
  const errors = validateIntents([{ id: "a", token: TOKEN, payee: PAYEE, amount: "" }]);
  assert.ok(errors.some((e) => e.includes("amount")), "an empty amount must be flagged");
});

test("validateIntents rejects a duplicate id", () => {
  const errors = validateIntents([
    { id: "a", token: TOKEN, payee: PAYEE, amount: "1" },
    { id: "a", token: TOKEN, payee: PAYEE, amount: "2" },
  ]);
  assert.ok(errors.some((e) => e.includes("duplicate")), "a duplicate id must be flagged");
});

test("validateIntents rejects a malformed token or payee address", () => {
  const errors = validateIntents([{ id: "a", token: "not-an-address", payee: PAYEE, amount: "1" }]);
  assert.ok(errors.some((e) => e.includes("token")), "a malformed token address must be flagged");
});

test("validateIntents accepts a well-formed, unique list", () => {
  assert.deepEqual(validateIntents(intents), []);
});

// I7: presence alone let a quoted or CR-suffixed value from a naive `.env` extraction flow
// through unchanged, producing entity ids that match nothing - fetchSnapshot then returns
// ok:true with everything null/empty, and the demo shows NO_POLICY/PAYEE_NOT_ALLOWED for
// every intent. A plausible-looking wrong screen, not an error.
test("a quoted address value is rejected, not silently accepted", () => {
  const result = validateEnvVar("WALLET_ADDR", '"0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6"', /^0x[0-9a-fA-F]{40}$/, "an address");
  assert.ok(result.error, "a value with literal quote characters must be rejected");
  assert.match(result.error, /WALLET_ADDR/);
});

test("a trailing CR is trimmed away, so a value that would otherwise be silently wrong is healed and accepted", () => {
  const result = validateEnvVar("WALLET_ADDR", "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6\r", /^0x[0-9a-fA-F]{40}$/, "an address");
  assert.equal(result.error, undefined, "trimming must heal a trailing CR from a naive .env extraction");
  assert.equal(result.value, "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6");
});

test("a missing value is rejected by name", () => {
  const result = validateEnvVar("LEASH_NODE", "", /^0x[0-9a-fA-F]{64}$/, "a hash");
  assert.ok(result.error && result.error.includes("LEASH_NODE"));
});

test("a wrong-length hash is rejected", () => {
  const result = validateEnvVar("LEASH_NODE", "0xdead", /^0x[0-9a-fA-F]{64}$/, "a 32-byte hash");
  assert.ok(result.error, "a value of the wrong length must be rejected");
});

// A scheme-less RPC URL is a real key leak, not tidying: send.mjs's redactUrls matches
// /https?:\/\/\S+/, so it catches "https://host/KEY" but not a bare "host/KEY" - and an RPC
// URL commonly carries an API key in its path. Requiring the scheme closes the hole at the
// source. The custom hint (validateEnvVar's fifth argument) must reach the caller, so
// someone who pastes a scheme-less URL learns why it was refused, not just that it was -
// and the rejected value itself must NOT be echoed back (the sixth argument, showValue:
// false), or the very error explaining the leak risk would leak the key.
test("a scheme-less RPC URL is rejected, explains why, and does not echo the key back", () => {
  const hint = "A scheme-less URL cannot be safely redacted if it ever reaches an error message or log line, and an RPC URL commonly carries an API key in its path.";
  const result = validateEnvVar(
    "SEPOLIA_RPC",
    "eth-sepolia.g.example.com/v2/SUPERSECRETKEY123",
    /^https:\/\//,
    "an https:// RPC URL",
    hint,
    false,
  );
  assert.ok(result.error, "a scheme-less URL must be rejected");
  assert.match(result.error, /redacted/, "the error must explain the redaction risk, not just refuse silently");
  assert.ok(!result.error.includes("SUPERSECRETKEY123"), "the rejected value must not be echoed into its own rejection message");
});

test("an https:// RPC URL is accepted", () => {
  const result = validateEnvVar("SEPOLIA_RPC", "https://eth-sepolia.example.com/v2/KEY", /^https:\/\//, "an https:// RPC URL");
  assert.equal(result.error, undefined);
  assert.equal(result.value, "https://eth-sepolia.example.com/v2/KEY");
});

// A non-string id defeats both C1 guards: validateIntents' `seen` Set and advance()'s
// `queued` Set key on the raw id (SameValueZero), while the record store keys on its string
// coercion. [{id: 1}, {id: "1"}] would otherwise pass duplicate-checking here (1 !== "1" to
// a Set) yet collide in the store, reproducing C1's exact mechanism through a door C1's own
// fix does not cover.
test("a non-string intent id is rejected at load", () => {
  const errors = validateIntents([{ id: 1, token: TOKEN, payee: PAYEE, amount: "1" }]);
  assert.ok(errors.some((e) => e.includes("must be a string")), "a numeric id must be flagged");
});

// __proto__ is worse than a duplicate: `next.intents["__proto__"] = rec` hits
// Object.prototype's setter instead of creating an own property, so the record is invisible
// to Object.keys/Object.values (and so to GET /api/agent/state and the console log) while
// every guard resets each tick - an unbounded repeat payment nothing shows.
test('an intent id of "__proto__" is rejected at load', () => {
  const errors = validateIntents([{ id: "__proto__", token: TOKEN, payee: PAYEE, amount: "1" }]);
  assert.ok(errors.some((e) => e.includes("__proto__")), "__proto__ as an id must be flagged");
});

// Belt and braces alongside the load-time rejection above: even if a "__proto__"-id intent
// reached advance() directly (bypassing validateIntents), the null-prototype store must not
// let it silently vanish into Object.prototype and reappear as an invisible repeat payment.
test('a "__proto__" id does not pollute the intents store or vanish from state', () => {
  const protoIntents = [{ id: "__proto__", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" }];
  const { state } = advance(initialState(), okSnap(), protoIntents, NOW, KNOWN);
  assert.ok(Object.prototype.hasOwnProperty.call(state.intents, "__proto__"), "the record must be its own visible property");
  assert.deepEqual(Object.keys(state.intents), ["__proto__"], "the record must be enumerable, not lost");
  assert.equal({}.verdict, undefined, "Object.prototype itself must not have gained a verdict property");
});

// I6/GET //: new URL(req.url, "http://x") throws "Invalid URL" for "//" and "/\", and that
// throw used to sit in an async request handler node:http does not await - an unhandled
// rejection that kills the whole process. routePath must never throw, for any input.
test("routePath never throws, including on // and /\\", () => {
  for (const bad of ["//", "/\\", "", "?", "///", "/\\/\\"]) {
    assert.doesNotThrow(() => routePath(bad), `routePath(${JSON.stringify(bad)}) must not throw`);
  }
});

test("routePath strips a cache-busting query string", () => {
  assert.equal(routePath("/api/agent/state?t=1699999999"), "/api/agent/state");
});

test("routePath collapses a leading double slash, so base + \"/path\" joins still resolve", () => {
  assert.equal(routePath("//api/agent/state"), "/api/agent/state");
});

test("a record carries the intent's payee, token and amount", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  const rec = state.intents.a;
  assert.equal(rec.payee, PAYEE);
  assert.equal(rec.token, TOKEN);
  assert.equal(rec.amount, "5000000");
});

test("those three survive a second tick without being recomputed away", () => {
  const first = advance(initialState(), okSnap(), intents, NOW, KNOWN).state;
  const second = advance(first, okSnap(), intents, NOW + 5, KNOWN).state;
  assert.equal(second.intents.a.payee, PAYEE);
  assert.equal(second.intents.a.amount, "5000000");
});

test("publicState forwards the payee allow-list", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  const pub = publicState(state);
  assert.equal(pub.payees[PAYEE].allowed, true);
});

test("publicState publishes the three new intent fields", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  const i = publicState(state).intents[0];
  assert.equal(i.payee, PAYEE);
  assert.equal(i.token, TOKEN);
  assert.equal(i.amount, "5000000");
});

test("payees is an empty object when the read failed, never stale", () => {
  const good = advance(initialState(), okSnap(), intents, NOW, KNOWN).state;
  const bad = advance(good, { ok: false, error: "boom" }, intents, NOW + 5, KNOWN).state;
  assert.deepEqual(publicState(bad).payees, {});
  assert.equal(publicState(bad).readError, "boom");
});

test("an intent with no payee publishes null rather than undefined", () => {
  const bare = [{ id: "z", token: TOKEN, payee: PAYEE, amount: "1", note: "" }];
  delete bare[0].payee;
  const { state } = advance(initialState(), okSnap(), bare, NOW, KNOWN);
  assert.equal(publicState(state).intents[0].payee, null);
});

// The test that actually pins the finding. The verdict-string assertions in decide.test.mjs
// would all still pass if the fallback returned `unknown` instead of `will-pass` - and
// `unknown` is exactly as unsent as a block, because the queue below takes only `will-pass`.
// So assert the intent reaches toSend: that is the observable the operator's money rides on.
test("under a policy this pre-flight does not know, a payment to a stranger is still sent", () => {
  const s = okSnap();
  s.policy.address = "0x1234567890abcdef1234567890abcdef12345678"; // the PolicySet
  s.payees = {}; // nobody has allow-listed this payee, and under the OR nobody needs to
  const { toSend, state } = advance(initialState(), s, intents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["a"], "the intent the composition exists to allow must be sent");
  assert.equal(state.intents.a.verdict, "will-pass");
});

// The counterpart, so the test above cannot pass by advance() having stopped checking
// anything: with the known policy installed, the same unknown payee is still refused.
test("under the known policy the same payment is still predicted blocked and not sent", () => {
  const s = okSnap();
  s.payees = {};
  const { toSend, state } = advance(initialState(), s, intents, NOW, KNOWN);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.reason, 6);
});

// A missing STANDARD_POLICY must not silently fall back to predicting with rules that may
// not apply. decide() throws, advance()'s per-intent catch turns that into `invalid`, and
// `invalid` is not `will-pass`, so nothing is sent: the misconfiguration fails closed.
test("a missing knownPolicy sends nothing rather than guessing which rules apply", () => {
  const { toSend, state } = advance(initialState(), okSnap(), intents, NOW, undefined);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.verdict, "invalid");
  assert.match(state.intents.a.explain, /knownPolicy/);
});
