// The agent decision loop.
//
// Runs as its own process holding ONLY AGENT_PK. docs/architecture.md:68 says AGENT "holds
// nothing" and can only call spend; world/server.mjs holds WORLD_RP_SIGNER_PK, which can
// authorise any widening. Sharing one process would put those two keys together and invert
// the security model this project exists to demonstrate.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createPublicClient, http as viemHttp } from "viem";
import { sepolia } from "viem/chains";
import { fetchSnapshot } from "./subgraph.mjs";
import { planPayments, buildOutcomePrompt, runClaude } from "./plan.mjs";
import { decide } from "./decide.mjs";
import { sendSpend } from "./send.mjs";

const PORT = Number(process.env.PORT || 8788);
const TICK_MS = Number(process.env.AGENT_TICK_MS || 5000);
// What this process is FOR, in one word. Two of these run against one wallet in the demo
// ("payments" and "subscriptions"), and the page needs to name them apart — an address is
// a poor label for a colleague. It changes no behaviour: the chain has never heard of it.
const AGENT_NAME = (process.env.AGENT_NAME || "payments").trim();
const SUBGRAPH_URL =
  process.env.SUBGRAPH_URL ||
  "https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.12";

const AMOUNT_RE = /^[0-9]+$/;
const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const NODE_RE = /^0x[0-9a-fA-F]{64}$/;
const RPC_RE = /^https:\/\//;

// A null-prototype store, belt and braces alongside validateIntents' "__proto__" rejection:
// `next.intents["__proto__"] = rec` on an ordinary object hits Object.prototype's setter
// instead of creating an own property, silently discarding the write. Any caller of
// `advance` that skips validateIntents (a future refactor, a different loader) still gets
// this protection for free.
export const initialState = () => ({ tick: 0, at: null, source: null, snapshot: null, intents: Object.create(null) });

// Refuse to start on a malformed or duplicate-id intents.json rather than fail live (C1). A
// duplicate id is the most ordinary edit imaginable - copy an intent block for the demo,
// change the amount, forget the id - and it makes `advance` push the same id to `toSend`
// twice: `tick` then sends two spends against the same record, and the second write to
// `lastAction` silently overwrites the first transaction's hash. No error, no warning. Pure
// and side-effect-free so it is testable without a process to kill.
export function validateIntents(intents) {
  const errors = [];
  const seen = new Set();
  for (const intent of intents ?? []) {
    const id = intent?.id;
    // A non-string id defeats both C1 guards: this Set and advance()'s `queued` Set key on
    // the raw id (SameValueZero), while the record store keys on its string coercion - so
    // [{id: 1}, {id: "1"}] passes duplicate-checking here yet collides in the store, and
    // sendAndRecord runs twice on the same record object. "__proto__" is worse: it hits
    // Object.prototype's setter instead of creating an own property, so the record is
    // invisible to Object.keys/Object.values and every guard resets each tick - an
    // unbounded repeat payment that never appears at GET /api/agent/state.
    if (typeof id !== "string") {
      errors.push(`intent id must be a string, got ${JSON.stringify(id)} (${typeof id})`);
    } else if (id === "__proto__") {
      errors.push(`intent id "__proto__" is not allowed`);
    } else if (seen.has(id)) {
      errors.push(`duplicate intent id: ${JSON.stringify(id)}`);
    } else {
      seen.add(id);
    }
    if (!AMOUNT_RE.test(String(intent?.amount))) {
      errors.push(
        `intent ${JSON.stringify(id)}: amount must be a base-unit integer string, got ${JSON.stringify(intent?.amount)}`,
      );
    }
    if (!ADDR_RE.test(String(intent?.token))) {
      errors.push(`intent ${JSON.stringify(id)}: token is not a 20-byte hex address, got ${JSON.stringify(intent?.token)}`);
    }
    if (!ADDR_RE.test(String(intent?.payee))) {
      errors.push(`intent ${JSON.stringify(id)}: payee is not a 20-byte hex address, got ${JSON.stringify(intent?.payee)}`);
    }
  }
  return errors;
}

// Presence alone is not enough (I7): the README's own extraction
// (`grep -m1 "^$1=" "$ENV" | cut -d= -f2-`) preserves surrounding quotes and a trailing CR
// if the `.env` file has one. Either flows through buildIds into entity ids that match
// nothing, and fetchSnapshot returns `ok: true` with everything null/empty - a
// plausible-looking wrong demo, not an error. Trims first (healing a stray CR or leading/
// trailing whitespace) and then checks shape, so a genuinely malformed value (surrounding
// quotes, wrong length) is refused by name. Returns the trimmed value or an error string;
// never exits itself, so it is testable without a process to kill.
export function validateEnvVar(
  name,
  rawValue,
  pattern,
  label,
  hint = "Check for stray quotes or a trailing CR from .env extraction.",
  showValue = true,
) {
  if (!rawValue) {
    return { error: `${name} is not set. Extract single variables; never source .env wholesale.` };
  }
  const trimmed = rawValue.trim();
  if (pattern && !pattern.test(trimmed)) {
    // showValue is false for a value that can carry a secret (SEPOLIA_RPC): the point of
    // this whole check is that a scheme-less RPC URL cannot be safely redacted, so echoing
    // it back into the very error explaining that would defeat the purpose - even though
    // this only reaches the operator's own terminal, not an HTTP response.
    const got = showValue ? ` (got ${JSON.stringify(rawValue)})` : "";
    return {
      error: `${name} is not shaped like ${label}${got}. ${hint}`,
    };
  }
  return { value: trimmed };
}

// I6: route on the pathname, not the raw req.url - a cache-busting query string
// (`?t=169...`) otherwise 404s on an exact string match. Plain string splitting, not
// `new URL(req.url, ...)`: the URL constructor throws on `//` or `/\` (an ordinary typo, or
// - since this endpoint sends Access-Control-Allow-Origin: * - a page in the operator's own
// browser doing `fetch("http://localhost:8788//")`), and the request handler is an async
// callback node:http does not await, so an uncaught throw there is an unhandled rejection
// that kills the whole process mid-run. Collapsing a leading run of slashes also makes the
// ordinary `base + "/path"` join (`//api/agent/state`) resolve, instead of 404ing on what
// looks like a working URL. Pure and exported so the no-throw property is testable directly.
export function routePath(url) {
  return String(url ?? "").split("?")[0].replace(/^\/+/, "/");
}

// The pure half: given the state, a snapshot and the intents, work out each verdict and
// which intents to send. Kept separate from the IO so duplicate-payment prevention is
// testable without a chain.
// The facts `decide` reads about one intent, flattened into one comparable string. It is the
// latch's re-arm signal: a payment the chain refused will be refused again for as long as
// nothing it depends on has moved, so the agent resubmits only when one of these changes.
//
// Built field by field in a fixed order rather than with `JSON.stringify`, because the
// snapshot's key order comes from a GraphQL response nothing here controls, and a
// fingerprint that changed when two equal snapshots serialised differently would un-latch
// on its own - which is the failure the latch exists to prevent, wearing a different hat.
// Addresses are lower-cased for the same reason `decide` compares them that way: the index
// reports them lower-cased and the environment carries them checksummed.
//
// `nowSec` is read but never put in directly: it changes every tick, so including it would
// re-arm the latch continuously and the whole mechanism would be decorative. What goes in is
// the one thing `decide` derives from it - whether the budget period has rolled over - which
// flips once per period instead. Leaving it out would have been a hole with a date on it: an
// intent blocked with 8 OVER_PERIOD_LIMIT at 23:59 would stay latched past midnight, because
// the chain resets the budget at the boundary while the index keeps reporting the old `spent`
// until some spend is indexed, so nothing else in this string moves at the moment the answer
// changes.
export function inputFingerprint(snapshot, intent, nowSec) {
  const payee = String(intent?.payee ?? "").toLowerCase();
  const budget = snapshot?.budget;
  // Read exactly as `decide` reads it (agent/decide.mjs), so the two cannot disagree about
  // when a period has ended.
  const periodEnd = Number(budget?.periodEnd ?? 0);
  // The payee address itself is not a field: the allow-flag below is looked up with it, so
  // the string is already about this intent's payee, and fingerprints are only ever compared
  // with another fingerprint for the same intent.
  return [
    `policy=${String(snapshot?.policy?.address ?? "").toLowerCase()}`,
    `allowed=${String(snapshot?.payees?.[payee]?.allowed ?? "")}`,
    `token=${String(budget?.token ?? "").toLowerCase()}`,
    `limit=${String(budget?.limit ?? "")}`,
    `spent=${String(budget?.spent ?? "")}`,
    `periodEnd=${String(budget?.periodEnd ?? "")}`,
    `rolled=${periodEnd > 0 && periodEnd <= nowSec}`,
  ].join("|");
}

// `knownPolicy` is threaded in rather than read from the module-level `STANDARD_POLICY`
// below, so this half stays a total function of its arguments - the same reason
// `publicState` takes the state instead of closing over it.
export function advance(state, snapshot, intents, nowSec, knownPolicy) {
  const next = { ...state, tick: state.tick + 1, at: new Date(nowSec * 1000).toISOString() };
  next.source = snapshot?.ok
    ? { subgraphBlock: snapshot.block.subgraph, chainBlock: snapshot.block.chain, lagBlocks: snapshot.block.lag }
    : { subgraphBlock: null, chainBlock: null, lagBlocks: null };
  next.snapshot = snapshot?.ok ? snapshot : null;
  next.readError = snapshot?.ok ? null : (snapshot?.error ?? "no snapshot");
  // Object spread (`{ ...state.intents }`) always builds an ordinary object with
  // Object.prototype, which would undo the null-prototype store from initialState the
  // moment the second tick runs. Object.assign onto a fresh Object.create(null) preserves it.
  next.intents = Object.assign(Object.create(null), state.intents);

  const toSend = [];
  // C1, belt and braces: a duplicate id must never reach toSend twice even if one slipped
  // past validateIntents (a future caller that skips it, a bug in that function). Two sends
  // for the same id overwrite each other's lastAction, and the first tx hash is lost.
  const queued = new Set();
  for (const intent of intents) {
    const prev = next.intents[intent.id] ?? { inFlight: false, lastAction: null };
    const fingerprint = inputFingerprint(snapshot, intent, nowSec);
    // payee/token/amount are copied onto the record so the state endpoint can say who an
    // intent pays and how much. They are inputs, not decisions: nothing below reads them,
    // and no branch in this function changes because they exist.
    const rec = {
      ...prev,
      id: intent.id,
      note: intent.note ?? "",
      payee: intent.payee ?? null,
      ens: intent.ens ?? null,
      token: intent.token ?? null,
      amount: intent.amount ?? null,
      // `sentFingerprint` is deliberately NOT rebuilt here. It arrives through `...prev` and
      // must survive untouched: listing it above with a fresh value would zero it every tick,
      // the comparison in the blocked branch below would never match, and the latch would
      // silently never engage - the intent would go back to being resubmitted every 5
      // seconds, which is the defect this exists to fix and would look exactly like a fix
      // that works. `test the latch survives the per-tick record rebuild` pins that.
    };

    if (prev.lastAction?.outcome === "executed") {
      // One-shot. The tick is seconds and the budget is finite: an intent that stayed
      // eligible after succeeding would be paid twelve times a minute.
      rec.verdict = "done";
      rec.reason = null;
      rec.reasonName = null; // cleared with `reason`, or a previous block's name survives
      rec.explain = "already paid; intents are one-shot";
    } else if (prev.lastAction?.kind === "sent" && prev.lastAction?.tx && prev.lastAction?.outcome == null) {
      // A transaction hash was obtained but no receipt was ever classified into an outcome -
      // most likely send.mjs's 120s wait timed out. The payment may still land on chain, so
      // re-sending risks a second one on top of it. This is the duplicate-payment path a
      // lost hash used to open: the hash must stay visible (it does, via lastAction, spread
      // from `prev` below) so an operator can look it up instead of the agent guessing.
      rec.verdict = "unconfirmed";
      rec.reason = null;
      rec.reasonName = null;
      rec.explain = `sent but never confirmed (tx ${prev.lastAction.tx}); will not retry on its own`;
    } else if (prev.inFlight) {
      rec.verdict = "in-flight";
      rec.reason = null;
      rec.reasonName = null; // same reason as above
      rec.explain = "waiting for the receipt of the transaction just sent";
    } else if (
      (prev.lastAction?.outcome === "blocked" || prev.lastAction?.outcome === "no-event") &&
      prev.sentFingerprint === fingerprint
    ) {
      // The chain gave an answer - a refusal, or a receipt with nothing in it - and nothing
      // this payment depends on has moved since it was submitted. Asking again would buy the
      // same answer, once every TICK_MS, for as long as the agent runs. Five of the twelve
      // reason codes are not indexed at all, so `decide` cannot see most of the reasons a
      // send comes back blocked; the chain's own answer is the better evidence, and this is
      // where it is used.
      //
      // `no-event` is latched for a second reason: it means "sent, outcome unknown" - a
      // status-1 receipt carrying neither SpendExecuted nor SpendBlocked - so resending it
      // risks paying twice for one instruction. That is the same hazard the `unconfirmed`
      // branch above exists to avoid, arriving through a different door. It is also the
      // shape a missing EIP-7702 delegation makes: `spend` calldata sent to an account with
      // no code succeeds and emits nothing, which is precisely what `LeashLens` exists to
      // detect, so this is a designed-for state rather than a hypothetical.
      //
      // Compared against the fingerprint recorded at SEND time, not one taken when the block
      // was observed, so the latch engages after exactly one block rather than two.
      //
      // The verdict has to be rewritten here, and leaving it to `...prev` was a bug that
      // only a real `blocked-despite-green` could expose. `sendAndRecord` sets the record
      // to `in-flight` before sending and afterwards writes only `lastAction` — so the
      // executed case is corrected by the branch above (`verdict = "done"`), and the
      // refused case was corrected by nothing at all. A payment the chain turned down sat
      // at IN FLIGHT for as long as the agent ran.
      //
      // `blocked` is a distinct verdict from `will-be-blocked` on purpose: one is the
      // pre-flight expecting a refusal, the other is the chain having issued one, and the
      // second is the stronger claim. `demo-render.mjs` gives it the same tone so it still
      // paints red rather than rendering unstyled.
      rec.verdict = prev.lastAction.outcome === "blocked" ? "blocked" : "unconfirmed";
      rec.reason = prev.lastAction.reason ?? null;
      rec.reasonName = prev.lastAction.reasonName ?? null;
      // The two cases get different sentences because the operator's next move is different:
      // a refusal is something to fix, an empty receipt is something to look up.
      const willRetry =
        "It will try once more on its own as soon as the index shows something that could change the " +
        "answer: this payee allow-listed, the budget moved, or a different policy installed. " +
        "Restarting the agent also clears this, because it is remembered in memory and not on disk.";
      if (prev.lastAction.outcome === "blocked") {
        const code = prev.lastAction.reasonName
          ? `${prev.lastAction.reason} ${prev.lastAction.reasonName}`
          : "no reason code in the receipt";
        rec.explain =
          `the chain refused this payment (${code}), so the agent has stopped asking. ` +
          "Sending it again against the same rules would only be refused again, twelve times a minute. " +
          willRetry;
      } else {
        const where = prev.lastAction.tx ? `transaction ${prev.lastAction.tx}` : "the transaction";
        rec.explain =
          `this payment went through, but its receipt says neither paid nor refused, so the agent ` +
          `cannot tell whether the money moved and has stopped resending it rather than risk paying ` +
          `twice for one instruction. Look up ${where} to see what happened. An empty receipt is also ` +
          `what it looks like when the leash is no longer on this wallet at all - a spend sent to a ` +
          `plain account succeeds and does nothing - so it is worth checking that the wallet still ` +
          `delegates to LeashAccount. ` + willRetry;
      }
    } else {
      let d;
      try {
        d = decide(snapshot, intent, nowSec, knownPolicy);
      } catch (err) {
        // decide()'s BigInt(intent.amount) throws on a malformed amount (I2), and so does a
        // missing or malformed knownPolicy - deliberately, because a pre-flight that does not
        // know which policy's rules it encodes must not predict at all. validateIntents
        // refuses to start on this for intents.json, but catching it here too means one bad
        // record does not stop every OTHER intent in the same tick from being evaluated - a
        // single try/catch around the whole tick body would abort the rest of the loop.
        d = {
          verdict: "invalid",
          reason: null,
          reasonName: null,
          explain: `intent is malformed and cannot be evaluated: ${err?.message ?? err}`,
        };
      }
      rec.verdict = d.verdict;
      rec.reason = d.reason;
      rec.reasonName = d.reasonName;
      rec.explain = d.explain;
      if (d.verdict === "will-pass" && !queued.has(intent.id)) {
        queued.add(intent.id);
        // Recorded at send time, so that if this comes back blocked the branch above can tell
        // "nothing has changed since I asked" from "the inputs have moved, ask again".
        rec.sentFingerprint = fingerprint;
        toSend.push(intent);
      }
    }
    next.intents[intent.id] = rec;
  }
  return { state: next, toSend };
}

// Send one intent's spend and record what happened, clearing `inFlight` in a `finally` so
// that guard holds by construction rather than by every branch of `sendImpl` remembering to
// return normally. `sendSpend` today always returns an object literal and never throws past
// itself, so nothing currently exploits this - but that invariant living only in an audit of
// a different module is exactly the shape of gap this project keeps finding. `sendImpl` is
// injectable so this is testable without a chain: the real caller (`tick`, below) leaves it
// at the default.
export async function sendAndRecord(rec, intent, cfg, sendImpl = sendSpend) {
  rec.inFlight = true;
  rec.verdict = "in-flight";
  try {
    const res = await sendImpl({
      rpcUrl: cfg.rpcUrl,
      privKey: cfg.privKey,
      wallet: cfg.wallet,
      token: intent.token,
      payee: intent.payee,
      amount: intent.amount,
    });
    rec.lastAction = res.error
      ? {
          // A hash means the transaction was actually submitted - "sent, outcome unknown"
          // - and must be told apart from "never sent". Conflating them is what let a
          // timeout re-arm an intent whose transaction might still land, and pay it twice.
          kind: res.tx ? "sent" : "error",
          tx: res.tx ?? null,
          outcome: null,
          error: res.error,
        }
      : {
          kind: "sent",
          tx: res.tx,
          outcome: res.outcome,
          reason: res.reason ?? null,
          reasonName: res.reasonName ?? null,
          // The agent predicted this would pass. If the chain blocked it anyway, that is
          // the thesis in miniature: the agent's optimism is bounded by the contract.
          note: res.outcome === "blocked" ? "blocked-despite-green" : null,
        };
  } finally {
    rec.inFlight = false;
  }
  return rec;
}

// --- IO half ---

let state = initialState();
let intents = [];
let ticking = false;

// Populated by the startup validation below, after trimming. tick() reads these instead of
// process.env directly, so a healed value (a trailing CR stripped by validateEnvVar) is what
// actually gets used everywhere, not just at the startup check.
let AGENT_PK, SEPOLIA_RPC, WALLET_ADDR, AGENT_ADDR, LEASH_NODE, STANDARD_POLICY, MOCK_USDC,
  LEASH_RESOLVER;

// Rate-limit backoff. Module state rather than a parameter: `advance` is the pure half and
// has no business knowing the clock, and `tick` is the only caller that does.
let backoffMs = TICK_MS;
let backoffUntil = 0;
let reported = false;

// What a person last asked the agent to do, and what the model made of it. Kept so the page
// can show the instruction beside the payments it produced - without that pairing, an
// intent list is just as opaque as the JSON file it replaced.
let instruction = null;
let planning = false;

// The conversation. Kept as a list rather than a single "last reply" because the point is
// the SECOND thing the agent says: it proposed a payment, the chain refused it, and it
// comes back and says so. One slot would overwrite the interesting half.
let messages = [];
let reporting = false;
const MAX_MESSAGES = 12;

const speak = (role, text) => {
  messages = [...messages, { role, text, at: new Date().toISOString() }].slice(-MAX_MESSAGES);
};

/// True once every intent has an answer, whether that answer is payment or refusal.
/// `unknown` is not terminal: the chain has not spoken yet, and reporting on it would have
/// the agent narrating its own guess.
const settled = (s_) => {
  const rows = Object.values(s_.intents ?? {});
  if (!rows.length) return false;
  return rows.every((r) => r.verdict === "done" || r.verdict === "will-be-blocked" || r.verdict === "invalid");
};

/// Ask the model what it makes of the outcome. Fire-and-forget: a tick must never wait on
/// it, and a model that is slow or down costs a sentence rather than the demo.
async function reportOutcome() {
  if (reporting || !instruction?.text) return;
  reporting = true;
  try {
    const outcomes = Object.values(state.intents ?? {}).map((r) => ({
      name: r.id,
      paid: r.verdict === "done",
      amount: r.amount ? (Number(r.amount) / 1e6).toFixed(2) : null,
      reason: r.reason,
      reasonName: r.reasonName,
      explain: r.explain,
    }));
    const { text } = await runClaude({
      prompt: buildOutcomePrompt({ instruction: instruction.text, outcomes }),
    });
    const said = String(text ?? "").trim();
    if (said) speak("agent", said.slice(0, 400));
  } catch (err) {
    // Silence is the right failure here. A fabricated "everything went fine" would be the
    // one lie this page must not tell, and the intent cards already carry the truth.
    console.error("outcome report failed:", String(err?.message ?? err));
  } finally {
    reporting = false;
  }
}

export function publicState(s) {
  return {
    instruction,
    messages,
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
    tickError: s.tickError ?? null,
    // Whose money this is. Shown beside the agent's name so "the wallet" is a specific
    // address a viewer can look up rather than an abstraction — and it comes from the
    // validated env, not the snapshot, because it is true whether or not the read worked.
    wallet: WALLET_ADDR ?? null,
    // This process's own identity, from env rather than from the index — true even on a
    // tick whose read failed, which is exactly when a page most needs to say who it is
    // talking to.
    name: AGENT_NAME,
    agentAddr: AGENT_ADDR ?? null,
    agent: s.snapshot?.agent ?? null,
    subname: s.snapshot?.subname ?? null,
    policy: s.snapshot?.policy ?? null,
    budget: s.snapshot?.budget ?? null,
    // Forwarded from the snapshot, so it is absent exactly when the read failed. Falling
    // back to `{}` rather than the previous tick's map matters: a stale allow-list on a
    // failed read would show the page a permission that may no longer exist.
    payees: s.snapshot?.payees ?? {},
    // Same reasoning as `payees`: absent exactly when the read failed, rather than falling
    // back to the previous tick. A stale list here would show a rule as available after it
    // had been revoked.
    approvedPolicies: s.snapshot?.approvedPolicies ?? [],
    // Every agent bound to this name, with each one's share of the period's spending.
    // Published by BOTH processes and identical in both, because it is read from the chain
    // rather than from either process's own memory — which is the claim it exists to make.
    cohort: s.snapshot?.cohort ?? [],
    // What this wallet has turned away. Forwarded from the snapshot like `payees`, so it is
    // absent exactly when the read failed rather than falling back to the previous tick — a
    // stale refusal list is a page claiming something was refused that may since have been
    // allowed.
    refusals: s.snapshot?.refusals ?? [],
    intents: Object.values(s.intents).map((i) => ({
      id: i.id,
      note: i.note,
      payee: i.payee ?? null,
      // The name the address was resolved from. Shown beside it so the page reads
      // `bluefin.leash.eth → 0x0000…cafe0` rather than an address from nowhere.
      ens: i.ens ?? null,
      token: i.token ?? null,
      amount: i.amount ?? null,
      verdict: i.verdict ?? null,
      reason: i.reason ?? null,
      reasonName: i.reasonName ?? null,
      explain: i.explain ?? null,
      lastAction: i.lastAction ?? null,
    })),
  };
}

async function tick() {
  if (backoffUntil && Date.now() < backoffUntil) {
    // Say so, rather than skipping silently: a page showing a frozen tick counter with no
    // explanation is the thing this whole project is trying not to be.
    const left = Math.ceil((backoffUntil - Date.now()) / 1000);
    state.readError = `subgraph is rate-limiting us; retrying in ${left}s`;
    return;
  }
  if (ticking) return;
  ticking = true;
  try {
    const cfg = {
      url: SUBGRAPH_URL,
      wallet: WALLET_ADDR,
      node: LEASH_NODE,
      agent: AGENT_ADDR,
      // The token the budget is denominated in. Taken from the plan when there is one, and
      // otherwise from env: with two agents sharing one budget, the panel showing that
      // budget is part of the opening frame, and a page that can only say what the limit is
      // once somebody has proposed a payment makes the shared budget look like a
      // consequence of the payment rather than the constraint it was under all along.
      token: intents[0]?.token ?? MOCK_USDC,
    };
    let chainBlock;
    try {
      const pc = createPublicClient({ chain: sepolia, transport: viemHttp(SEPOLIA_RPC) });
      chainBlock = Number(await pc.getBlockNumber());
    } catch {
      chainBlock = undefined; // lag becomes 0; the read itself still decides
    }
    const snapshot = await fetchSnapshot({ ...cfg, chainBlock });

    // Back off when told to. Without this the loop answers a 429 by asking again TICK_MS
    // later, forever, which is how a rate-limit window stops clearing — and on a stage it
    // reads as "the demo is broken" rather than "we are being throttled". Doubles from one
    // tick up to two minutes, and any successful read resets it.
    if (snapshot?.rateLimited) {
      backoffMs = Math.min(Math.max(snapshot.retryAfterMs ?? backoffMs * 2, TICK_MS), 120_000);
      backoffUntil = Date.now() + backoffMs;
    } else if (snapshot?.ok) {
      backoffMs = TICK_MS;
      backoffUntil = 0;
    }
    const nowSec = Math.floor(Date.now() / 1000);
    const advanced = advance(state, snapshot, intents, nowSec, STANDARD_POLICY);
    state = advanced.state;

    // Once every intent has an answer, the agent says what it makes of it. Not awaited:
    // the tick's job is the chain, and a slow model must not hold it up.
    if (!reported && settled(state)) {
      reported = true;
      void reportOutcome();
    }

    for (const intent of advanced.toSend) {
      const rec = await sendAndRecord(state.intents[intent.id], intent, {
        rpcUrl: SEPOLIA_RPC,
        privKey: AGENT_PK,
        wallet: WALLET_ADDR,
      });
      const a = rec.lastAction;
      console.log(
        `tick ${state.tick}  ${intent.id}  ${
          a.error
            ? a.tx
              ? `unconfirmed (tx ${a.tx}): ${a.error}`
              : `error: ${a.error}`
            : `${a.outcome}${a.reason != null ? ` (${a.reasonName})` : ""} ${a.tx}`
        }`,
      );
    }

    for (const i of Object.values(state.intents)) {
      if (!advanced.toSend.some((t) => t.id === i.id)) {
        console.log(`tick ${state.tick}  ${i.id}  ${i.verdict}${i.reason != null ? ` (${i.reasonName})` : ""}`);
      }
    }
    state.tickError = null;
  } catch (err) {
    // Backstop (I2): advance() already contains a per-intent decide() throw (the "invalid"
    // verdict above), but this catches anything else unexpected - a subgraph payload shaped
    // differently than fetchSnapshot expects, a future change to this function - so a throw
    // here degrades to a visible tickError instead of an unhandled rejection from
    // `setInterval` killing the whole process on stage.
    state.tickError = String(err?.message ?? err);
    console.error(`tick ${state.tick}  error: ${state.tickError}`);
  } finally {
    ticking = false;
  }
}

// Everything below only runs when this file is executed directly (`node loop.mjs`), never
// on import. Without this guard, importing advance/initialState from loop.test.mjs would
// also run the env-var check (killing the test process via process.exit) and start the
// HTTP server - the pure half would no longer be testable without a chain, which is the
// whole reason it was split out.
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const envChecks = [
    ["AGENT_PK", null, null],
    // A scheme-less RPC URL is a real key leak, not tidying: redactUrls matches
    // /https?:\/\/\S+/, so it catches "https://host/KEY" but not "host/KEY" - and
    // send.mjs's err.cause/details/metaMessages surfacing (T4 Minor 2) means an RPC
    // failure's error text, which commonly repeats the request URL, can carry the API key
    // an RPC URL's path commonly holds straight into lastAction.error, the console, and the
    // JSON response. Requiring the scheme closes the hole at the source, rather than trying
    // to widen the redaction regex to guess at bare hostnames - that direction ends in
    // over-redacting ordinary text.
    [
      "SEPOLIA_RPC",
      RPC_RE,
      "an https:// RPC URL",
      "A scheme-less URL cannot be safely redacted if it ever reaches an error message or log line, and an RPC URL commonly carries an API key in its path.",
      false, // showValue: never echo the value being rejected for exactly that reason
    ],
    ["WALLET_ADDR", ADDR_RE, "a 20-byte hex address (0x + 40 hex chars)"],
    ["AGENT_ADDR", ADDR_RE, "a 20-byte hex address (0x + 40 hex chars)"],
    ["LEASH_NODE", NODE_RE, "a 32-byte hex hash (0x + 64 hex chars)"],
    // Which policy decide()'s payee and period-budget checks belong to. Required, and not
    // defaulted: with a PolicySet installed those two rules are no longer the whole story,
    // and a pre-flight that guesses wrong refuses payments the chain would have made.
    [
      "LEASH_RESOLVER",
      ADDR_RE,
      "a 20-byte hex address (0x + 40 hex chars)",
      "the ENSIP-10 resolver a vendor name is resolved through. vendors.json holds names and no addresses, so without this the agent cannot work out who to pay.",
    ],
    [
      "MOCK_USDC",
      ADDR_RE,
      "a 20-byte hex address (0x + 40 hex chars)",
      "the token the agent pays in. Only /api/agent/instruct needs it - a plan arrives as vendor ids and dollars, and the token is supplied here rather than by the model.",
    ],
    [
      "STANDARD_POLICY",
      ADDR_RE,
      "a 20-byte hex address (0x + 40 hex chars)",
      "decide() encodes StandardPolicy's payee allow-list and period budget. It needs to know which address those rules belong to, so that any other policy - a PolicySet, say - skips them and lets the chain decide instead.",
    ],
  ];
  const envValues = {};
  for (const [name, pattern, label, hint, showValue] of envChecks) {
    // hint/showValue are undefined for entries with fewer elements, which is exactly when
    // validateEnvVar's own default parameters should apply.
    const result = validateEnvVar(name, process.env[name], pattern, label, hint, showValue);
    if (result.error) {
      console.error(result.error);
      process.exit(1);
    }
    envValues[name] = result.value;
  }
  AGENT_PK = envValues.AGENT_PK;
  SEPOLIA_RPC = envValues.SEPOLIA_RPC;
  WALLET_ADDR = envValues.WALLET_ADDR;
  AGENT_ADDR = envValues.AGENT_ADDR;
  LEASH_NODE = envValues.LEASH_NODE;
  STANDARD_POLICY = envValues.STANDARD_POLICY;
  MOCK_USDC = envValues.MOCK_USDC;
  LEASH_RESOLVER = envValues.LEASH_RESOLVER;

  // AGENT_INTENTS points the loop at a different payment list. It exists because this loop
  // has no read-only mode — a tick is read, decide, SEND — so inspecting the HTTP endpoints
  // used to mean emptying the tracked intents.json and remembering to put it back. That cost
  // 5 test USDC twice. Pointing at an empty file touches nothing and cannot be forgotten.
  const intentsPath = process.env.AGENT_INTENTS
    ? new URL(process.env.AGENT_INTENTS, `file://${process.cwd()}/`)
    : new URL("./intents.json", import.meta.url);
  intents = JSON.parse(await readFile(intentsPath, "utf8"));
  const intentErrors = validateIntents(intents);
  if (intentErrors.length) {
    for (const e of intentErrors) console.error(e);
    process.exit(1);
  }

  createServer(async (req, res) => {
    // I6: sprint item 12 (the frontend) reads this endpoint from a different origin (a Vite
    // dev server, file://), which the browser blocks without this header.
    res.setHeader("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") {
      res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      res.setHeader("Access-Control-Allow-Headers", "Content-Type");
      res.writeHead(204);
      return res.end();
    }
    const json = (code, body) => {
      res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify(body, null, 2));
    };
    try {
      const pathname = routePath(req.url);
      if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState(state));
      // Give the agent an instruction in English. The model turns it into payments; the
      // chain decides whether any of them happen. Nothing here can widen anything - and the
      // model proposing something the chain refuses is the demo, not a bug.
      if (req.method === "POST" && pathname === "/api/agent/instruct") {
        if (planning) return json(409, { error: "already thinking about the last instruction" });
        let body = "";
        for await (const chunk of req) {
          body += chunk;
          if (body.length > 8192) return json(413, { error: "instruction too long" });
        }
        let text;
        try {
          text = String(JSON.parse(body || "{}").instruction ?? "").trim();
        } catch {
          return json(400, { error: "body must be JSON" });
        }
        if (!text) return json(400, { error: "say what you want the agent to do" });

        planning = true;
        instruction = { text, at: new Date().toISOString(), status: "thinking" };
        try {
          const { intents: planned, say, durationMs } = await planPayments({
            instruction: text,
            token: MOCK_USDC,
            vendorsPath: new URL("./vendors.json", import.meta.url),
            // Payee addresses come from ENS, not from the directory. Break the resolver and
            // this throws before a transaction exists — which is the same sentence the
            // README makes about the policy, now true of the payee too.
            rpcUrl: SEPOLIA_RPC,
            resolver: LEASH_RESOLVER,
          });
          const errs = validateIntents(planned);
          if (errs.length) throw new Error(errs.join("; "));

          // A new instruction replaces the old plan AND its history. Keeping records for
          // payments nobody asked for any more is how a page starts lying about what the
          // agent is doing.
          intents = planned;
          state = { ...initialState(), tick: state.tick };
          instruction = { text, at: instruction.at, status: "planned", tookMs: durationMs, count: planned.length };
          messages = [];
          speak("you", text);
          speak("agent", say ?? `Proposing ${planned.length} payment${planned.length === 1 ? "" : "s"}.`);
          reported = false;
        } catch (err) {
          // The model failing must not leave a stale plan running. An agent that keeps
          // paying from an instruction it could not re-read is worse than one that stops.
          intents = [];
          state = { ...initialState(), tick: state.tick };
          instruction = { text, at: instruction.at, status: "failed", error: String(err?.message ?? err) };
          messages = [];
          speak("you", text);
          speak("system", `the agent could not turn that into payments: ${instruction.error}`);
          return json(502, { error: instruction.error });
        } finally {
          planning = false;
        }

        // NOT awaited. A tick reads the index, decides, sends, and waits for a receipt —
        // about 22 seconds measured — and awaiting it here meant the whole round trip
        // returned at the end of that, so the page showed nothing at all until the money
        // had already moved. The model answers in four; the plan should appear then, and
        // the chain's part should be watched happening rather than waited out in silence.
        //
        // The page polls once a second, so it picks up the send and the receipt as they
        // land. `tick` guards its own re-entry, so a second instruction cannot overlap it.
        void tick();
        return json(200, publicState(state));
      }

      if (req.method === "POST" && pathname === "/api/agent/tick") {
        try {
          await tick();
        } catch (err) {
          // tick() already catches internally and records tickError (I2); this is a backstop
          // so the request cannot hang or 500 with no body if something still escapes.
          return json(500, { error: String(err?.message ?? err) });
        }
        return json(200, publicState(state));
      }
    } catch (err) {
      // Backstop for anything else unexpected in this handler - see the comment above on
      // why an uncaught throw here would otherwise kill the process, not just this request.
      return json(500, { error: String(err?.message ?? err) });
    }
    json(404, { error: "not found" });
  }).listen(PORT, () => {
    console.log(`agent loop on http://localhost:${PORT}  (tick ${TICK_MS}ms)`);
    console.log(`  state: curl -s localhost:${PORT}/api/agent/state | jq`);
    tick();
    setInterval(tick, TICK_MS);
  });
}
