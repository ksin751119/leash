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
    // `bluefin.leash.eth → 0x0000…cafe0` says where the address came from. The address
    // alone does not, and "we use ENS" on a page that shows only addresses is a claim
    // rather than a demonstration.
    ens: intent.ens ?? null,
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

export function renderRules(s, nowSec = Math.floor(Date.now() / 1000)) {
  const limit = s.budget?.limit ?? null;

  // The index only moves `spent` when a spend is indexed, so once `periodEnd` has passed
  // the chain has already zeroed the budget while the index still reports the last
  // period's total. `agent/decide.mjs` has applied this rule since it was written; this
  // panel did not, and the gap is not cosmetic — at 09/12 08:00 the period rolled over
  // with 47.00 of 50.00 showing, so the page said "94% used" about a budget the chain had
  // just emptied. A panel that overstates how little room is left is a panel that will
  // explain the wrong reason for the next refusal.
  //
  // Read with the meaning the schema gives the field. That is not re-deriving policy logic,
  // and it is the same sentence decide.mjs carries.
  // Which payees the payments currently on screen are about.
  const inPlay = new Set(
    (s.intents ?? []).map((i) => String(i.payee ?? "").toLowerCase()).filter(Boolean),
  );

  const periodEnd = Number(s.budget?.periodEnd ?? 0);
  const rolledOver = periodEnd > 0 && periodEnd <= nowSec;
  const spent = s.budget == null ? null : rolledOver ? "0" : s.budget.spent;
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
    // Marked `live` by comparison rather than by a flag from the index: the pointer and the
    // approval list are separate facts, and a policy can be approved without being live -
    // which is exactly the state the OR demo starts from.
    policies: (s.approvedPolicies ?? []).map((a) => ({
      addr: a.address,
      short: shortHex(a.address),
      description: a.description,
      approved: a.approved,
      live: String(a.address).toLowerCase() === String(s.policy?.address ?? "").toLowerCase(),
    })),
    spent: formatUsdc(spent),
    limit: formatUsdc(limit),
    pct,
    hasSpent,
    // The panel is titled "payees this wallet allows", so it shows what is true NOW: every
    // payee currently on the list, plus any payee the payments on screen are about. A row
    // left over from an earlier run — approved and dropped, or paid months ago — is history,
    // and history in a panel that claims to describe the present is just noise a viewer has
    // to work out is irrelevant.
    payees: Object.entries(s.payees ?? {})
      .filter(([addr, v]) => v?.allowed === true || inPlay.has(addr))
      .map(([addr, v]) => ({
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
