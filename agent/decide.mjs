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
import { REASON, reasonName } from "./reason.mjs";

const blocked = (reason, explain) => ({
  verdict: "will-be-blocked",
  reason,
  reasonName: reasonName(reason),
  explain,
});
const unknown = (verdict, explain) => ({ verdict, reason: null, reasonName: null, explain });
const pass = () => ({ verdict: "will-pass", reason: null, reasonName: null, explain: null });

const lower = (a) => String(a ?? "").toLowerCase();

export function decide(snapshot, intent, nowSec) {
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

  // Policy layer, for the two the index can answer.
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
        `this would exceed the period budget (${limit - spent} left of ${limit})`,
      );
    }
  }

  return pass();
}
