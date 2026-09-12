// Turning an instruction in English into a list of payments the agent wants to make.
//
// This is the only place a language model touches this project, and the boundary is drawn
// deliberately tight. **The model proposes; it decides nothing.**
//
//   - It never writes an address. It picks a vendor `id` from a directory we hand it, and
//     this file looks the address up. A hallucinated address cannot exist, because there is
//     no field for the model to put one in.
//   - It never sees a key, an RPC url, or the chain. Its entire world is the prompt below.
//   - Its output goes through the same `validateIntents` as a hand-written intents.json.
//     Anything malformed is REFUSED, never repaired — a plan we had to fix is a plan we do
//     not understand.
//   - It cannot widen anything. Proposing a payment to a payee nobody allow-listed is
//     exactly what the chain is there to refuse, and refusing it is the demo.
//
// The security argument does not depend on the model behaving. That is the point: an agent
// that has to be well-behaved for your money to be safe is not safe. This one can propose
// whatever it likes.
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { keccak_256 } from "@noble/hashes/sha3.js";

const strip = (h) => String(h).replace(/^0x/, "").toLowerCase();
const word = (h) => strip(h).padStart(64, "0");
const sel = (sig) => Buffer.from(keccak_256(Buffer.from(sig))).subarray(0, 4).toString("hex");
const RESOLVE_SELECTOR = sel("resolve(bytes,bytes)");
const ADDR_SELECTOR = sel("addr(bytes32)");

/// ENS namehash. Recursive by definition, and short enough that importing one would be the
/// larger commitment.
export function namehash(name) {
  let node = Buffer.alloc(32);
  if (name) {
    for (const label of String(name).split(".").reverse()) {
      node = Buffer.from(keccak_256(Buffer.concat([node, Buffer.from(keccak_256(Buffer.from(label)))])));
    }
  }
  return "0x" + node.toString("hex");
}

/// USDC on Sepolia has 6 decimals. The model speaks in dollars because humans do; this is
/// the one conversion, done once, here.
const DECIMALS = 6;

/// Amounts arrive as text and must survive being a decimal string without float rounding:
/// `0.1 + 0.2` is the oldest bug in this profession and it has no place near money.
export function toBaseUnits(amount) {
  const s = String(amount ?? "").trim();
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`amount is not a plain decimal number: ${JSON.stringify(amount)}`);
  const [whole, frac = ""] = s.split(".");
  if (frac.length > DECIMALS) throw new Error(`amount has more than ${DECIMALS} decimal places: ${s}`);
  return (BigInt(whole) * 10n ** BigInt(DECIMALS) + BigInt((frac + "0".repeat(DECIMALS)).slice(0, DECIMALS)))
    .toString();
}

export function buildPrompt({ instruction, vendors }) {
  const directory = vendors
    .map((v) => `  - id: ${v.id}\n    who: ${v.name}\n    context: ${v.note}`)
    .join("\n");

  return [
    "You are the payments agent for a small company. You hold a wallet and you are asked",
    "to carry out instructions by proposing payments.",
    "",
    "The vendors you are able to pay:",
    directory,
    "",
    "The instruction:",
    `  ${instruction}`,
    "",
    "Reply with ONLY a JSON object, no prose and no code fence:",
    '  {"say": "<one sentence to the person, first person>",',
    '   "payments": [{"vendor": "<one of the ids above>", "amount": "<US dollars, e.g. 5 or 0.50>", "why": "<a short phrase>"}]}',
    "",
    "Rules:",
    '- "say" is what you tell the person you are about to do. Plain, brief, no hedging.',
    "  Do not promise the payments will succeed - you do not decide that.",
    "- Use only the ids listed above. You cannot pay anyone else.",
    "- Carry out EVERY payment the instruction asks for, not just the first.",
    "- When the instruction does not name an amount, use the one in that vendor's context.",
    "- If the instruction does not ask for a payment, reply with [].",
    "- Do not ask questions and do not explain. The array is the whole reply.",
    "- Amounts are plain decimal numbers. No currency symbols, no thousands separators.",
  ].join("\n");
}

/// Strips a fenced block if the model wrapped its answer in one, then parses.
///
/// Only ONE repair is performed and it is the fence, because a fence is a rendering
/// convention rather than a difference of opinion about the content. Everything else that
/// fails to parse is an error: a plan we had to guess at is a plan nobody checked.
export function parsePlan(raw) {
  let text = String(raw ?? "").trim();
  const fenced = text.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  if (fenced) text = fenced[1].trim();

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new Error(`the model did not return JSON: ${String(err.message).slice(0, 120)}`);
  }
  // An array is still accepted: it is what this returned before the model was asked to
  // speak, and refusing it would turn a model that answered the older shape correctly into
  // a failure. The `say` is the addition, not the contract.
  if (Array.isArray(parsed)) return { say: null, payments: parsed };
  if (!parsed || typeof parsed !== "object") {
    throw new Error("the model returned neither an object nor an array");
  }
  if (!Array.isArray(parsed.payments)) throw new Error("the model returned no payments array");
  return { say: typeof parsed.say === "string" ? parsed.say.slice(0, 240) : null, payments: parsed.payments };
}

/// Resolves a plan against the directory. **This is where a proposal becomes an address**,
/// and the only place one can.
///
/// The directory holds ENS names, not addresses — `agent/vendors.json` has no `address`
/// field at all. Every payee address comes from `resolveEns`, which reads it off the chain.
/// That is what makes "remove ENS and the agent cannot even find who to pay" a fact about
/// this file rather than a sentence in a README: delete the record and this throws, before
/// a transaction is ever built.
export function resolvePlan({ plan, vendors, token, resolved }) {
  const byId = new Map(vendors.map((v) => [v.id, v]));
  return plan.map((row, i) => {
    const vendor = byId.get(row?.vendor);
    if (!vendor) {
      throw new Error(
        `payment ${i + 1} names a vendor that is not in the directory: ${JSON.stringify(row?.vendor)}`,
      );
    }
    const payee = resolved?.get(vendor.ens);
    if (!payee) {
      throw new Error(
        `${vendor.ens} does not resolve to an address — the agent cannot pay a name the ` +
        `chain will not answer for`,
      );
    }
    return {
      id: vendor.id,
      token,
      payee,
      // Carried so the page can show the resolution rather than only its result: a card
      // reading `bluefin.leash.eth → 0x0000…cafe0` says where the address came from, and a
      // card reading only the address does not.
      ens: vendor.ens,
      amount: toBaseUnits(row?.amount),
      // Shown on the demo page under the intent. The model's own words for why it is about
      // to spend money, which is the thing a person actually wants to read.
      note: String(row?.why ?? vendor.name).slice(0, 80),
    };
  });
}

/// `addr(namehash(name))` through the resolver's ENSIP-10 `resolve(bytes,bytes)`.
///
/// Hand-encoded rather than pulled through a library, to match `world/widen-plan.mjs`: one
/// static call does not justify a dependency, and the shape is fixed.
export async function resolveEns({ names, rpcUrl, resolver, fetchImpl = fetch }) {
  const out = new Map();
  for (const name of new Set(names)) {
    const node = namehash(name);
    // resolve(bytes name, bytes data) with data = addr(bytes32 node)
    const inner = ADDR_SELECTOR + node.slice(2);
    const data =
      RESOLVE_SELECTOR +
      word((2 * 32).toString(16)) +          // offset to `name` (unused by this resolver)
      word((3 * 32).toString(16)) +          // offset to `data`
      word("0") +                            // name: zero length
      word((inner.length / 2).toString(16)) +
      inner.padEnd(Math.ceil(inner.length / 64) * 64, "0");

    const res = await fetchImpl(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "eth_call",
        params: [{ to: resolver, data: "0x" + data }, "latest"],
      }),
    });
    if (!res.ok) throw new Error(`rpc returned HTTP ${res.status} resolving ${name}`);
    const body = await res.json();
    if (body?.error) throw new Error(`${name} did not resolve: ${body.error.message ?? "rpc error"}`);

    // The returned `bytes` is an abi-encoded address: offset, length, then the word.
    const hex = String(body.result ?? "").slice(2);
    if (hex.length < 64 * 3) throw new Error(`${name} did not resolve to an address`);
    const addr = "0x" + hex.slice(64 * 2 + 24, 64 * 3);
    // A name whose record was never set resolves to the zero address, and paying that is
    // burning money. Fail rather than treat it as an answer.
    if (/^0x0{40}$/.test(addr)) throw new Error(`${name} resolves to the zero address`);
    out.set(name, addr);
  }
  return out;
}

/// What the agent says once the chain has answered.
///
/// A second call rather than a template, because the sentence that matters is the one
/// where it acknowledges being overruled — and a canned string saying "I was blocked"
/// proves nothing about whether the agent understood it. This one is written by the same
/// model that proposed the payment, looking at what happened to it.
///
/// It is told the reason code and the explanation the account gave, and nothing else. The
/// prompt template carries no remedy.
///
/// Be precise about what that does and does not show, because the output reads as more than
/// it is: when the agent says "we'll need a face scan", it is reading that from `explain`,
/// which is `decide.mjs`'s own sentence for reason 6. It is repeating the account's words,
/// not deducing the remedy. What IS its own is the acknowledgement — that it tried, that it
/// was refused, and that it cannot get around it.
export function buildOutcomePrompt({ instruction, outcomes }) {
  const lines = outcomes
    .map((o) =>
      o.paid
        ? `  - ${o.name}: PAID ${o.amount} USDC`
        : `  - ${o.name}: REFUSED by the chain, reason ${o.reason} ${o.reasonName}. ${o.explain ?? ""}`,
    )
    .join("\n");

  return [
    "You are the payments agent for a small company. You proposed some payments and the",
    "blockchain has now decided which of them happen. You do not decide that; the wallet's",
    "policy does, and it can overrule you.",
    "",
    `What you were asked to do: ${instruction}`,
    "",
    "What happened:",
    lines,
    "",
    "Reply with one or two short sentences to the person, in the first person, saying what",
    "happened. If something was refused, say plainly that you cannot get around it and what",
    "would have to change. No apology, no hedging, no markdown. Prose only - no JSON.",
  ].join("\n");
}

/// Runs `claude -p`. Separated from everything above so the rest of this file is pure and
/// testable without spawning anything.
export function runClaude({ prompt, model = "claude-haiku-4-5-20251001", timeoutMs = 60_000, spawnImpl = spawn }) {
  return new Promise((resolve, reject) => {
    const child = spawnImpl("claude", ["-p", prompt, "--output-format", "json", "--model", model], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`the model did not answer within ${Math.round(timeoutMs / 1000)}s`));
    }, timeoutMs);

    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(new Error(`could not run the claude CLI: ${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`claude exited ${code}: ${err.slice(0, 200)}`));
      let env;
      try {
        env = JSON.parse(out);
      } catch {
        return reject(new Error("the claude CLI did not return JSON"));
      }
      if (env.is_error) return reject(new Error(`the model reported an error: ${String(env.result).slice(0, 200)}`));
      resolve({ text: env.result, durationMs: env.duration_ms });
    });
  });
}

/// The whole path: an instruction in, intents out.
export async function planPayments({
  instruction, token, vendorsPath, rpcUrl, resolver, runImpl = runClaude, resolveImpl = resolveEns,
}) {
  const vendors = JSON.parse(await readFile(vendorsPath, "utf8"));
  const prompt = buildPrompt({ instruction, vendors });
  const { text, durationMs } = await runImpl({ prompt });
  const { say, payments } = parsePlan(text);

  // Resolved AFTER the model has spoken, and only for the names it actually named. A plan
  // nobody proposed costs no RPC calls.
  const wanted = payments
    .map((row) => vendors.find((v) => v.id === row?.vendor)?.ens)
    .filter(Boolean);
  const resolved = await resolveImpl({ names: wanted, rpcUrl, resolver });

  const intents = resolvePlan({ plan: payments, vendors, token, resolved });
  return { intents, say, durationMs, raw: text };
}
