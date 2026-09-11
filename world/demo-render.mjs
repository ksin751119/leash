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
  let hasSpent = false;
  try {
    hasSpent = spent != null && BigInt(spent) > 0n;
    if (limit != null && BigInt(limit) > 0n) {
      // Tenths, then divide. Computing straight into whole percent truncates: 5 USDC of a
      // 1000 limit came out as 0%, the same reading as having spent nothing at all — which
      // is precisely the claim this panel exists to disprove. `hasSpent` is carried
      // separately so the bar can stay visible for an amount too small to round to 0.1%,
      // without the number having to overstate it.
      pct = Number((BigInt(spent ?? 0) * 1000n) / BigInt(limit)) / 10;
    }
  } catch {
    pct = 0;
    hasSpent = false;
  }
  return {
    policy: s.policy?.address ?? null,
    policyShort: shortHex(s.policy?.address ?? null),
    approved: s.policy?.approved === true,
    // The name the rule is resolved through, and the sentence a human approved it as.
    // Both come from the index rather than from configuration: the point of the panel is
    // that nothing here is written down on our side.
    ensName: s.subname?.label ? `${s.subname.label}.leash.eth` : null,
    ensLive: s.subname?.live === true,
    policyDesc: s.policy?.description ?? null,
    spent: formatUsdc(spent),
    limit: formatUsdc(limit),
    pct,
    hasSpent,
    payees: Object.entries(s.payees ?? {}).map(([addr, v]) => ({
      addr,
      short: shortHex(addr),
      allowed: v?.allowed === true,
      // Four states, not three. Until PolicySet, `allowed === false` on a row that exists
      // could only mean "revoked", because a spend to a payee that was never allow-listed
      // was impossible - StandardPolicy ANDs payeeAllowed into every verdict. Under
      // `(MicroPaymentPolicy) OR (StandardPolicy)` it is possible, it is the point, and
      // labelling it "revoked" tells the audience the opposite of what happened.
      everAllowed: v?.everAllowed === true,
      paid: Boolean(v?.lastToken),
    })),
  };
}
