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
    "Reply with ONLY a JSON array, no prose and no code fence. Each element:",
    '  {"vendor": "<one of the ids above>", "amount": "<US dollars, e.g. 5 or 0.50>", "why": "<a short phrase>"}',
    "",
    "Rules:",
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
  if (!Array.isArray(parsed)) throw new Error("the model returned something that is not an array of payments");
  return parsed;
}

/// Resolves a plan against the directory. **This is where a proposal becomes an address**,
/// and the only place one can.
export function resolvePlan({ plan, vendors, token }) {
  const byId = new Map(vendors.map((v) => [v.id, v]));
  return plan.map((row, i) => {
    const vendor = byId.get(row?.vendor);
    if (!vendor) {
      throw new Error(
        `payment ${i + 1} names a vendor that is not in the directory: ${JSON.stringify(row?.vendor)}`,
      );
    }
    return {
      id: vendor.id,
      token,
      payee: vendor.address,
      amount: toBaseUnits(row?.amount),
      // Shown on the demo page under the intent. The model's own words for why it is about
      // to spend money, which is the thing a person actually wants to read.
      note: String(row?.why ?? vendor.name).slice(0, 80),
    };
  });
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
export async function planPayments({ instruction, token, vendorsPath, runImpl = runClaude }) {
  const vendors = JSON.parse(await readFile(vendorsPath, "utf8"));
  const prompt = buildPrompt({ instruction, vendors });
  const { text, durationMs } = await runImpl({ prompt });
  const plan = parsePlan(text);
  const intents = resolvePlan({ plan, vendors, token });
  return { intents, durationMs, raw: text };
}
