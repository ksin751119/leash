// The pre-flight. Given a snapshot of what the index says and one intent, predict whether
// the chain will allow the spend.
//
// **This function is trustworthy when it refuses and not when it permits**, and that is by
// design, not a limitation to fix later:
//
//   - Payee.allowed is keyed by (node, payee) and NOT by token, because the frozen
//     PayeeAllowed event carries no token (see subgraph/schema.graphql). So `allowed: true`
//     may be optimistic for a second token.
//   - Five reason codes are not indexed at all: 5 TOKEN_NOT_ALLOWED, 7 OVER_TX_LIMIT,
//     9 OUTSIDE_TIME_WINDOW, 10 PAUSED, 11 OVER_SHARED_LIMIT. Plus 12 POLICY_FAILED, which
//     is unpredictable by nature.
//
// So "will-pass" means "I found nothing that forbids it", never "it will succeed". The
// caller must handle a send that gets blocked anyway - the loop records that as
// `blocked-despite-green`, which is the project's thesis in miniature: the agent's optimism
// is bounded by the contract.
//
// **What this function must never do is re-derive policy logic.** Completing the prediction
// would mean reimplementing StandardPolicy in JavaScript - per-transaction limits, time
// windows, period alignment. On 2026-09-09 this repo caught a Critical of exactly that
// shape: a JS reimplementation of a hashing rule diverged from the real one and no test
// could see it, because both sides were self-consistent. Read conclusions the index states;
// never recompute them.
//
// The two policy-layer rules below (payee allow-list, period budget) are `StandardPolicy`'s,
// not the account's, so they hold only while `StandardPolicy` is the policy actually
// installed. `PolicySet` makes that assumption false: `(MicroPaymentPolicy) OR
// (StandardPolicy)` allows a small payment to a payee nobody allow-listed, and a pre-flight
// still encoding the allow-list refuses what the chain would have paid - which inverts the
// direction of trust this module claims about itself two paragraphs up. So the caller must
// name the policy these rules belong to (`knownPolicy`); anything else skips them.
import { REASON, reasonName } from "./reason.mjs";

const blocked = (reason, explain) => ({
  verdict: "will-be-blocked",
  reason,
  reasonName: reasonName(reason),
  explain,
});
const unknown = (verdict, explain) => ({ verdict, reason: null, reasonName: null, explain });
// A silent null here is the one thing the three-valued verdict was designed not to be:
// found nothing forbidding it is not the same claim as it will succeed, and the five
// unindexed reasons (5, 7, 9, 10, 11) plus 12 stay invisible unless this says so.
const pass = () => ({
  verdict: "will-pass",
  reason: null,
  reasonName: null,
  explain:
    "found nothing that forbids it; the per-tx cap, token allow-list, time window and pause are not indexed, so only the chain can confirm",
});

const lower = (a) => String(a ?? "").toLowerCase();

// Base units are what the chain speaks and what every comparison above uses; they are not
// what a person reads. "23500000 left of 50000000" went on screen during a rehearsal and
// nobody in the room could tell at a glance whether it was 23 dollars or 23 million.
//
// The 6 is USDC's and is stated here rather than looked up: this module has no chain
// access, the demo pays in one token, and a decimals() call it cannot make would be a
// worse lie than a named assumption. Only the EXPLANATION is formatted — every decision
// above stays in base units.
const USDC_DECIMALS = 6n;
const usdc = (units) => {
  const n = BigInt(units);
  const scale = 10n ** USDC_DECIMALS;
  return `${n / scale}.${String(n % scale).padStart(Number(USDC_DECIMALS), "0").slice(0, 2)}`;
};
const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

// `knownPolicy` is the address of the `StandardPolicy` whose rules the policy layer below
// encodes. It is required and has no default: a default would be a silent guess about which
// rulebook applies, and `loop.mjs` turns this throw into verdict `invalid`, which is never
// sent - so a misconfigured deployment fails closed rather than predicting with the wrong one.
export function decide(snapshot, intent, nowSec, knownPolicy) {
  if (!ADDR_RE.test(String(knownPolicy ?? ""))) {
    throw new Error(
      `decide() needs knownPolicy: the address of the StandardPolicy whose rules it encodes (got ${JSON.stringify(knownPolicy)})`,
    );
  }

  if (!snapshot || snapshot.ok !== true) {
    return unknown(
      "unknown-read-failed",
      `could not read the index (${snapshot?.error ?? "no snapshot"}); sending nothing`,
    );
  }

  // Account layer first, in the contract's own order (src/Reason.sol: 1-4 and 10 are decided
  // by LeashAccount before it calls the policy). Reason 1 AGENT_NOT_BOUND reverts rather than
  // emitting, and reason 10 PAUSED is not indexed, so neither appears here.
  if (snapshot.agent?.revoked === true) {
    return blocked(REASON.AGENT_REVOKED, "this agent has been revoked; restoring it needs a face scan");
  }
  if (!snapshot.policy || !snapshot.policy.address) {
    return blocked(REASON.NO_POLICY, "this name points at no policy");
  }
  if (snapshot.policy.approved !== true) {
    return blocked(REASON.POLICY_NOT_APPROVED, "no human has approved the policy this name points at");
  }

  // Everything above is `LeashAccount`'s own (src/Reason.sol: 1-4), decided before it ever
  // calls the policy, so it holds whichever policy is installed. Everything below is
  // `StandardPolicy`'s, and holds only for `StandardPolicy` itself.
  if (lower(snapshot.policy.address) !== lower(knownPolicy)) {
    // `pass()`-shaped on purpose, and this is the whole point: `loop.mjs` sends only
    // `will-pass`, so returning an `unknown` verdict here would change the label and change
    // nothing an operator can observe - the payment the composition exists to allow would
    // still never be attempted. Declining to guess means letting the chain answer.
    return {
      ...pass(),
      explain:
        "the installed policy is not the StandardPolicy this pre-flight encodes, so the payee allow-list and period budget are not known to be its rules and were not checked; only the chain can decide",
    };
  }

  // Policy layer, for the two the index can answer - StandardPolicy's rules, reached only
  // once the installed policy has been confirmed to be it.
  const payee = snapshot.payees?.[lower(intent.payee)];
  if (!payee || payee.allowed !== true) {
    return blocked(
      REASON.PAYEE_NOT_ALLOWED,
      "this payee is not on the allow-list; adding it is a widening and needs a face scan",
    );
  }

  const budget = snapshot.budget;
  if (!budget) {
    return unknown("unknown", "the index has no budget row for this token yet; the chain will decide");
  }
  if (lower(budget.token) !== lower(intent.token)) {
    return unknown(
      "unknown",
      "the indexed budget is for a different token, and the index cannot answer per-token; the chain will decide",
    );
  }

  const limit = BigInt(budget.limit);
  if (limit !== 0n) {
    // periodEnd is when the period resets. The index only moves `spent` when a spend is
    // indexed, so once periodEnd has passed the chain has already reset the budget while the
    // index still reports the old figure. Reading the field with the meaning the schema gives
    // it is not re-deriving policy logic.
    const periodEnd = Number(budget.periodEnd ?? 0);
    const rolledOver = periodEnd > 0 && periodEnd <= nowSec;
    const spent = rolledOver ? 0n : BigInt(budget.spent);
    if (spent + BigInt(intent.amount) > limit) {
      return blocked(
        REASON.OVER_PERIOD_LIMIT,
        `this would exceed the period budget — ${usdc(limit - spent)} left of ${usdc(limit)} USDC, and this payment is ${usdc(intent.amount)}`,
      );
    }
  }

  return pass();
}
