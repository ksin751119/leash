import { test } from "node:test";
import assert from "node:assert/strict";
import {
  advance, initialState, sendAndRecord, validateIntents, validateEnvVar, routePath, publicState,
  inputFingerprint,
} from "./loop.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200;
// The StandardPolicy whose rules decide() encodes, and the address okSnap() reports as
// installed. advance() takes it as an argument rather than reading module state, so these
// tests can say which policy is installed without starting the loop.
const KNOWN = "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b";
// Any other policy - in production the PolicySet, `(MicroPaymentPolicy) OR (StandardPolicy)`.
const POLICYSET = "0x1234567890abcdef1234567890abcdef12345678";

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

// This test used to be called "a blocked intent stays eligible, so the agent retries after a
// widening" and asserted that the same blocked intent was queued again on the very next tick.
// The first half of that was pinning the defect, not a feature: nothing had changed between
// the two ticks, so "retries" meant a real Sepolia transaction every TICK_MS forever. The
// widening half is the part worth keeping, and it now has a test of its own below.
test("a blocked intent is not sent again while nothing it depends on has changed", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(state.intents.a.sentFingerprint, inputFingerprint(okSnap(), intents[0], NOW),
    "the first tick sent it, so it must have recorded what it sent under");
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", tx: "0x1" };

  const second = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(second.toSend, [], "one block is enough; the same request buys the same refusal");

  // And it stays latched - a latch that only holds for one tick is a latch that pays twelve
  // times a minute instead of thirteen.
  const third = advance(second.state, okSnap(), intents, NOW + 5, KNOWN);
  assert.deepEqual(third.toSend, []);
});

// The other half of the latch, and the demo's face-scan beat, in the exact shape it happens:
// under a PolicySet the pre-flight no longer applies the payee allow-list, so the intent is
// sent, the chain refuses it with 6, and a human scans their face a few ticks later. The
// agent has to notice by itself. Asserted on toSend, because toSend is what spends money - a
// verdict-string assertion here would pass even with the intent still latched.
test("a widening re-arms a latched intent, which is the whole point of keying on the inputs", () => {
  const composed = okSnap();
  composed.policy.address = POLICYSET;
  composed.payees = {}; // nobody has allow-listed this payee yet

  let { state, toSend } = advance(initialState(), composed, intents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["a"], "under the composition the pre-flight sends it");
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", tx: "0x1" };
  assert.deepEqual(advance(state, composed, intents, NOW, KNOWN).toSend, [], "latched until something moves");

  const widened = okSnap();
  widened.policy.address = POLICYSET;
  widened.payees = { [PAYEE]: { allowed: true, lastToken: TOKEN } }; // the face scan lands
  const next = advance(state, widened, intents, NOW + 5, KNOWN);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"], "the intent must actually be queued to send");
});

// The demo's finale: ADMIN points the name at the PolicySet. An intent blocked under the old
// policy has to be reconsidered under the new one without anyone restarting the agent.
test("a new policy address re-arms a latched intent", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", tx: "0x1" };

  const composed = okSnap();
  composed.policy.address = POLICYSET;
  const next = advance(state, composed, intents, NOW, KNOWN);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

// A budget that moves is the other thing that can turn a refusal into a payment - someone
// raises the limit, or an earlier spend falls out of the period.
test("a changed budget re-arms a latched intent", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 8, reasonName: "OVER_PERIOD_LIMIT", tx: "0x1" };

  const moved = okSnap();
  moved.budget.spent = "1";
  const next = advance(state, moved, intents, NOW, KNOWN);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

// The latch must not invent a verdict: world/demo.html styles verdicts by value and an
// unrecognised one renders unstyled on stage. The last decided verdict and reason survive,
// and only the explanation changes - to one a person can read out.
test("the latch leaves the verdict and reason alone and explains itself in words", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  const decided = state.intents.a.verdict;
  state.intents.a.reason = 6;
  state.intents.a.reasonName = "PAYEE_NOT_ALLOWED";
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 7, reasonName: "OVER_TX_LIMIT", tx: "0x1" };

  const rec = advance(state, okSnap(), intents, NOW, KNOWN).state.intents.a;
  assert.equal(rec.verdict, decided, "no new verdict string");
  assert.equal(rec.reason, 6);
  assert.equal(rec.reasonName, "PAYEE_NOT_ALLOWED");
  assert.match(rec.explain, /7 OVER_TX_LIMIT/, "the chain's own reason belongs in the sentence");
  assert.match(rec.explain, /restarting the agent/i, "an operator has to be told the latch is in memory only");
});

// Every record is rebuilt from scratch each tick. `sentFingerprint` survives only through the
// `...prev` spread: list it among the fields that are overwritten and it is zeroed before the
// comparison runs, the latch never engages, and the intent goes back to being resubmitted
// every five seconds - a mutation that looks exactly like a working fix from the outside.
test("the latch survives the per-tick record rebuild", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", tx: "0x1" };

  // Two ticks of nothing changing: the second one can only stay latched if the fingerprint
  // written at send time is still on the record after a rebuild.
  const second = advance(state, okSnap(), intents, NOW, KNOWN);
  const third = advance(second.state, okSnap(), intents, NOW + 5, KNOWN);
  assert.equal(third.state.intents.a.sentFingerprint, inputFingerprint(okSnap(), intents[0], NOW + 5));
  assert.deepEqual(third.toSend, []);
});

// --- the fingerprint itself ---

test("the fingerprint is stable across snapshots that differ only in key order or address case", () => {
  const a = okSnap();
  const b = {
    // The payee key stays lower-cased: the index reports it that way and `decide` looks it up
    // that way. What varies here is key order and the case of the two addresses that are
    // values rather than keys.
    payees: { [PAYEE]: { lastToken: TOKEN, allowed: true } },
    budget: { periodEnd: 0, spent: "0", limit: "1000000000", token: TOKEN.toUpperCase() },
    policy: { approved: true, address: KNOWN.toUpperCase() },
    ok: true,
    block: { subgraph: 1, chain: 1, lag: 0 },
  };
  assert.equal(inputFingerprint(a, intents[0], NOW), inputFingerprint(b, intents[0], NOW));
});

test("the fingerprint moves when any fact decide reads moves", () => {
  const baseline = inputFingerprint(okSnap(), intents[0], NOW);
  const vary = (f) => {
    const s = okSnap();
    f(s);
    return inputFingerprint(s, intents[0], NOW);
  };
  assert.notEqual(vary((s) => (s.policy.address = POLICYSET)), baseline);
  assert.notEqual(vary((s) => (s.payees[PAYEE].allowed = false)), baseline);
  assert.notEqual(vary((s) => delete s.payees[PAYEE]), baseline);
  assert.notEqual(vary((s) => (s.budget.token = "0x1111111111111111111111111111111111111111")), baseline);
  assert.notEqual(vary((s) => (s.budget.limit = "1")), baseline);
  assert.notEqual(vary((s) => (s.budget.spent = "1")), baseline);
  assert.notEqual(vary((s) => (s.budget.periodEnd = 1)), baseline);
});

// The clock is an input `decide` reads - `rolledOver = periodEnd > 0 && periodEnd <= nowSec` -
// and it is the only one that changes without the index changing. It goes in as the derived
// boolean, not as the time: a fingerprint carrying `nowSec` itself would differ on every tick
// and the latch would never hold at all.
test("the fingerprint ignores the clock ticking but not the period ending", () => {
  const s = okSnap();
  s.budget.periodEnd = NOW + 60;
  assert.equal(inputFingerprint(s, intents[0], NOW), inputFingerprint(s, intents[0], NOW + 30),
    "a later tick inside the same period is the same inputs");
  assert.notEqual(inputFingerprint(s, intents[0], NOW), inputFingerprint(s, intents[0], NOW + 61),
    "the period ending is a change decide can act on");
});

// The hole the seventh field closes, end to end. The chain refused this payment for being
// over the period budget; the period then ends. The chain has reset the budget, but the index
// reports the same `spent` and the same `periodEnd` until some spend is indexed - so if the
// fingerprint were built from index fields alone, NOTHING would move at the moment the answer
// changes and the intent would stay latched until someone restarted the agent.
test("a latched over-budget intent re-arms when its period ends, with the index unchanged", () => {
  const snap = okSnap();
  snap.budget.periodEnd = NOW + 60; // the period is still running when it is sent

  let { state, toSend } = advance(initialState(), snap, intents, NOW, KNOWN);
  assert.deepEqual(toSend.map((i) => i.id), ["a"], "the index showed room, so it was sent");
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 8, reasonName: "OVER_PERIOD_LIMIT", tx: "0x1" };

  // Still inside the period: latched, and the clock moving on its own must not re-arm it.
  assert.deepEqual(advance(state, snap, intents, NOW + 30, KNOWN).toSend, [],
    "a later tick in the same period is not a change");

  // Past periodEnd, and the snapshot is the same object - not merely equal - so the only
  // thing that has moved is the clock crossing the boundary.
  const after = advance(state, snap, intents, NOW + 61, KNOWN);
  assert.deepEqual(after.toSend.map((i) => i.id), ["a"],
    "the chain has reset the budget; the agent must be willing to ask again");
});

// --- an empty receipt is latched too, and says something different ---

// `no-event` is a status-1 receipt carrying neither SpendExecuted nor SpendBlocked. It reaches
// none of the three older terminal branches, so before this it was resubmitted every tick
// forever, showing the operator nothing. It is a designed-for state, not a hypothesis: `spend`
// calldata sent to an account whose EIP-7702 delegation is gone succeeds and emits nothing,
// which is the condition LeashLens exists to detect.
test("a send that came back with an empty receipt is not repeated either", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "no-event", reason: null, reasonName: null, tx: "0xfeed" };

  const second = advance(state, okSnap(), intents, NOW, KNOWN);
  assert.deepEqual(second.toSend, [], "the outcome is unknown; resending risks paying twice");
  const third = advance(second.state, okSnap(), intents, NOW + 5, KNOWN);
  assert.deepEqual(third.toSend, []);
});

// The operator's next move differs between the two latched cases - a refusal is something to
// fix, an empty receipt is something to look up - so the sentence has to differ too.
test("an empty receipt explains itself differently from a refusal", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "no-event", reason: null, reasonName: null, tx: "0xfeed" };

  const rec = advance(state, okSnap(), intents, NOW, KNOWN).state.intents.a;
  assert.match(rec.explain, /0xfeed/, "the hash is the thing to look up");
  assert.match(rec.explain, /neither paid nor refused/i);
  assert.match(rec.explain, /delegates to LeashAccount/i, "the missing-leash case has to be named");
  assert.doesNotMatch(rec.explain, /refused this payment/, "this is not the blocked sentence");
});

// And an empty receipt re-arms on the same signal as a refusal: something that could change
// the answer actually moved.
test("a re-delegated wallet re-arms an intent latched on an empty receipt", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "no-event", reason: null, reasonName: null, tx: "0xfeed" };

  const restored = okSnap();
  restored.policy.address = POLICYSET; // the name is repointed as part of putting it right
  assert.deepEqual(advance(state, restored, intents, NOW, KNOWN).toSend.map((i) => i.id), ["a"]);
});

// A failed read must not look like a changed input that re-arms everything: it produces one
// fingerprint of empty fields, which matches nothing recorded at send time, so the latch is
// bypassed - but decide() answers `unknown-read-failed` on that same snapshot and nothing is
// sent. The next successful read restores the match.
test("a failed read neither sends a latched intent nor loses the fingerprint", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW, KNOWN);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED", tx: "0x1" };

  const down = advance(state, { ok: false, error: "boom" }, intents, NOW, KNOWN);
  assert.deepEqual(down.toSend, []);

  const back = advance(down.state, okSnap(), intents, NOW + 5, KNOWN);
  assert.deepEqual(back.toSend, [], "the latch must still hold once the index answers again");
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
