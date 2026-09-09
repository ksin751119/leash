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
import { decide } from "./decide.mjs";
import { sendSpend } from "./send.mjs";

const PORT = Number(process.env.PORT || 8788);
const TICK_MS = Number(process.env.AGENT_TICK_MS || 5000);
const SUBGRAPH_URL =
  process.env.SUBGRAPH_URL ||
  "https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4";

const AMOUNT_RE = /^[0-9]+$/;
const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;
const NODE_RE = /^0x[0-9a-fA-F]{64}$/;

export const initialState = () => ({ tick: 0, at: null, source: null, snapshot: null, intents: {} });

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
    if (seen.has(id)) errors.push(`duplicate intent id: ${JSON.stringify(id)}`);
    seen.add(id);
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
export function validateEnvVar(name, rawValue, pattern, label) {
  if (!rawValue) {
    return { error: `${name} is not set. Extract single variables; never source .env wholesale.` };
  }
  const trimmed = rawValue.trim();
  if (pattern && !pattern.test(trimmed)) {
    return {
      error: `${name} is not shaped like ${label} (got ${JSON.stringify(rawValue)}). Check for stray quotes or a trailing CR from .env extraction.`,
    };
  }
  return { value: trimmed };
}

// The pure half: given the state, a snapshot and the intents, work out each verdict and
// which intents to send. Kept separate from the IO so duplicate-payment prevention is
// testable without a chain.
export function advance(state, snapshot, intents, nowSec) {
  const next = { ...state, tick: state.tick + 1, at: new Date(nowSec * 1000).toISOString() };
  next.source = snapshot?.ok
    ? { subgraphBlock: snapshot.block.subgraph, chainBlock: snapshot.block.chain, lagBlocks: snapshot.block.lag }
    : { subgraphBlock: null, chainBlock: null, lagBlocks: null };
  next.snapshot = snapshot?.ok ? snapshot : null;
  next.readError = snapshot?.ok ? null : (snapshot?.error ?? "no snapshot");
  next.intents = { ...state.intents };

  const toSend = [];
  // C1, belt and braces: a duplicate id must never reach toSend twice even if one slipped
  // past validateIntents (a future caller that skips it, a bug in that function). Two sends
  // for the same id overwrite each other's lastAction, and the first tx hash is lost.
  const queued = new Set();
  for (const intent of intents) {
    const prev = next.intents[intent.id] ?? { inFlight: false, lastAction: null };
    const rec = { ...prev, id: intent.id, note: intent.note ?? "" };

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
    } else {
      let d;
      try {
        d = decide(snapshot, intent, nowSec);
      } catch (err) {
        // decide()'s BigInt(intent.amount) throws on a malformed amount (I2). validateIntents
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
let AGENT_PK, SEPOLIA_RPC, WALLET_ADDR, AGENT_ADDR, LEASH_NODE;

function publicState() {
  const s = state;
  return {
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
    tickError: s.tickError ?? null,
    agent: s.snapshot?.agent ?? null,
    subname: s.snapshot?.subname ?? null,
    policy: s.snapshot?.policy ?? null,
    budget: s.snapshot?.budget ?? null,
    intents: Object.values(s.intents).map((i) => ({
      id: i.id,
      note: i.note,
      verdict: i.verdict ?? null,
      reason: i.reason ?? null,
      reasonName: i.reasonName ?? null,
      explain: i.explain ?? null,
      lastAction: i.lastAction ?? null,
    })),
  };
}

async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    const cfg = {
      url: SUBGRAPH_URL,
      wallet: WALLET_ADDR,
      node: LEASH_NODE,
      agent: AGENT_ADDR,
      token: intents[0]?.token,
    };
    let chainBlock;
    try {
      const pc = createPublicClient({ chain: sepolia, transport: viemHttp(SEPOLIA_RPC) });
      chainBlock = Number(await pc.getBlockNumber());
    } catch {
      chainBlock = undefined; // lag becomes 0; the read itself still decides
    }
    const snapshot = await fetchSnapshot({ ...cfg, chainBlock });
    const nowSec = Math.floor(Date.now() / 1000);
    const advanced = advance(state, snapshot, intents, nowSec);
    state = advanced.state;

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
    ["SEPOLIA_RPC", null, null],
    ["WALLET_ADDR", ADDR_RE, "a 20-byte hex address (0x + 40 hex chars)"],
    ["AGENT_ADDR", ADDR_RE, "a 20-byte hex address (0x + 40 hex chars)"],
    ["LEASH_NODE", NODE_RE, "a 32-byte hex hash (0x + 64 hex chars)"],
  ];
  const envValues = {};
  for (const [name, pattern, label] of envChecks) {
    const result = validateEnvVar(name, process.env[name], pattern, label);
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

  intents = JSON.parse(await readFile(new URL("./intents.json", import.meta.url), "utf8"));
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
    // I6: route on the pathname, not the raw req.url - a cache-busting query string
    // (`?t=169...`) otherwise 404s on an exact string match.
    const pathname = new URL(req.url, "http://x").pathname;
    if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState());
    if (req.method === "POST" && pathname === "/api/agent/tick") {
      try {
        await tick();
      } catch (err) {
        // tick() already catches internally and records tickError (I2); this is a backstop
        // so the request cannot hang or 500 with no body if something still escapes.
        return json(500, { error: String(err?.message ?? err) });
      }
      return json(200, publicState());
    }
    json(404, { error: "not found" });
  }).listen(PORT, () => {
    console.log(`agent loop on http://localhost:${PORT}  (tick ${TICK_MS}ms)`);
    console.log(`  state: curl -s localhost:${PORT}/api/agent/state | jq`);
    tick();
    setInterval(tick, TICK_MS);
  });
}
