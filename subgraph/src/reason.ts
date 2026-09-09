/// Reason code -> name. One-to-one with `src/Reason.sol`; **the numbers must never be
/// renumbered.**
///
/// `LeashAccount` judges 1-4, 10 and 12 **before** it calls the policy; the policy
/// judges 5-9 and 11. That line is drawn deliberately: agent bindings, the policy
/// pointer, the approval list and the pause switch are security-critical and stay in
/// the account's own hands. Swapping the policy cannot reach the control plane.
export function reasonName(code: i32): string {
  if (code == 0) return "OK";
  if (code == 1) return "AGENT_NOT_BOUND";
  if (code == 2) return "AGENT_REVOKED";
  if (code == 3) return "NO_POLICY";
  if (code == 4) return "POLICY_NOT_APPROVED";
  if (code == 5) return "TOKEN_NOT_ALLOWED";
  if (code == 6) return "PAYEE_NOT_ALLOWED";
  if (code == 7) return "OVER_TX_LIMIT";
  if (code == 8) return "OVER_PERIOD_LIMIT";
  if (code == 9) return "OUTSIDE_TIME_WINDOW";
  if (code == 10) return "PAUSED";
  if (code == 11) return "OVER_SHARED_LIMIT";
  if (code == 12) return "POLICY_FAILED";
  return "UNKNOWN";
}
