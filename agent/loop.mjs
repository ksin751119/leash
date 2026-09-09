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

export const initialState = () => ({ tick: 0, at: null, source: null, snapshot: null, intents: {} });

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
      const d = decide(snapshot, intent, nowSec);
      rec.verdict = d.verdict;
      rec.reason = d.reason;
      rec.reasonName = d.reasonName;
      rec.explain = d.explain;
      if (d.verdict === "will-pass") toSend.push(intent);
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

function publicState() {
  const s = state;
  return {
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
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
      wallet: process.env.WALLET_ADDR,
      node: process.env.LEASH_NODE,
      agent: process.env.AGENT_ADDR,
      token: intents[0]?.token,
    };
    let chainBlock;
    try {
      const pc = createPublicClient({ chain: sepolia, transport: viemHttp(process.env.SEPOLIA_RPC) });
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
        rpcUrl: process.env.SEPOLIA_RPC,
        privKey: process.env.AGENT_PK,
        wallet: process.env.WALLET_ADDR,
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
  for (const v of ["AGENT_PK", "SEPOLIA_RPC", "WALLET_ADDR", "AGENT_ADDR", "LEASH_NODE"]) {
    if (!process.env[v]) {
      console.error(`${v} is not set. Extract single variables; never source .env wholesale.`);
      process.exit(1);
    }
  }
  intents = JSON.parse(await readFile(new URL("./intents.json", import.meta.url), "utf8"));

  createServer(async (req, res) => {
    const json = (code, body) => {
      res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify(body, null, 2));
    };
    if (req.method === "GET" && req.url === "/api/agent/state") return json(200, publicState());
    if (req.method === "POST" && req.url === "/api/agent/tick") {
      await tick();
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
