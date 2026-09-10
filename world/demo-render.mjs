// Pure functions from `publicState()` to the strings the page prints.
//
// They live in their own module for one reason: **there is no browser on the build
// machine**, so the layout's logic has to be testable without one. Nothing here decides
// anything — every verdict, reason and explanation is copied out of what the agent already
// published. If a judgement ever appears in this file, the demo has started faking the one
// thing it exists to show.

export const shortHex = (h) =>
  typeof h === "string" && h.length > 12 ? `${h.slice(0, 6)}…${h.slice(-5)}` : (h ?? "—");

// USDC is 6 decimals. Integer arithmetic on BigInt, because the amounts are strings from
// the chain and Number() would start rounding at ~9 billion units.
export function formatUsdc(raw) {
  if (raw == null) return "—";
  try {
    const units = BigInt(raw);
    const whole = units / 1000000n;
    const cents = (units % 1000000n) / 10000n;
    return `${whole}.${String(cents).padStart(2, "0")}`;
  } catch {
    return "—";
  }
}

export function renderStatus(s) {
  const lag = s.source?.lagBlocks;
  return {
    tick: s.tick,
    at: s.at,
    lag: lag == null ? "—" : lag === 0 ? "up to date" : `${lag} block${lag === 1 ? "" : "s"} behind`,
    blind: Boolean(s.readError),
    error: s.readError ?? s.tickError ?? null,
  };
}

const TONE = {
  "will-pass": "ok",
  "will-be-blocked": "blocked",
  done: "done",
  "in-flight": "pending",
  unconfirmed: "pending",
  unknown: "unknown",
  invalid: "blocked",
};

export function renderIntent(intent, payees) {
  const key = String(intent.payee ?? "").toLowerCase();
  return {
    id: intent.id,
    note: intent.note ?? "",
    payee: intent.payee ?? null,
    payeeShort: shortHex(intent.payee),
    // Absent from the map means never allow-listed — the subgraph writes no Payee entity
    // until one exists — which is also how decide() reads it.
    payeeAllowed: payees?.[key]?.allowed === true,
    amount: formatUsdc(intent.amount),
    verdict: intent.verdict ?? "unknown",
    tone: TONE[intent.verdict] ?? "unknown",
    reasonLabel: intent.reason == null ? null : `${intent.reason} · ${intent.reasonName ?? "?"}`,
    explain: intent.explain ?? "",
    tx: intent.lastAction?.tx ? shortHex(intent.lastAction.tx) : null,
  };
}

export function renderRules(s) {
  const limit = s.budget?.limit ?? null;
  const spent = s.budget?.spent ?? null;
  let pct = 0;
  try {
    if (limit != null && BigInt(limit) > 0n) {
      pct = Number((BigInt(spent ?? 0) * 100n) / BigInt(limit));
    }
  } catch {
    pct = 0;
  }
  return {
    policy: s.policy?.address ?? null,
    policyShort: shortHex(s.policy?.address ?? null),
    approved: s.policy?.approved === true,
    spent: formatUsdc(spent),
    limit: formatUsdc(limit),
    pct,
    payees: Object.entries(s.payees ?? {}).map(([addr, v]) => ({
      addr,
      short: shortHex(addr),
      allowed: v?.allowed === true,
    })),
  };
}
