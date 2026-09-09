// The block reason codes, frozen in docs/events.md and defined in src/Reason.sol.
//
// This is the THIRD copy of this table - src/Reason.sol is the authority and
// subgraph/src/reason.ts is the second. src/Reason.sol says so out loud: "The numbers must
// never be renumbered: the subgraph, the frontend and the agent all depend on them."
// `check-reason-table.mjs` reads the Solidity and asserts this file matches, so a
// renumbering fails loudly instead of silently mislabelling what the agent reports.
export const REASON = Object.freeze({
  OK: 0,
  AGENT_NOT_BOUND: 1,
  AGENT_REVOKED: 2,
  NO_POLICY: 3,
  POLICY_NOT_APPROVED: 4,
  TOKEN_NOT_ALLOWED: 5,
  PAYEE_NOT_ALLOWED: 6,
  OVER_TX_LIMIT: 7,
  OVER_PERIOD_LIMIT: 8,
  OUTSIDE_TIME_WINDOW: 9,
  PAUSED: 10,
  OVER_SHARED_LIMIT: 11,
  POLICY_FAILED: 12,
});

export function buildNames(map) {
  const names = [];
  for (const [name, code] of Object.entries(map)) names[code] = name;
  return Object.freeze(names);
}

export const REASON_NAMES = buildNames(REASON);

export function reasonName(code) {
  return REASON_NAMES[code] ?? "UNKNOWN";
}
