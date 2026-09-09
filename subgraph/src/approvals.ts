import { PolicyApproved, PolicyRevoked } from "../generated/PolicyApprovals/PolicyApprovals";
import { ApprovedPolicy } from "../generated/schema";

/// The other half of question 3: has a human approved this policy? **Controlled by the
/// face scan, not by ADMIN.**
///
/// The approval list is **global** (keyed by policy address) while `PolicyPointer` is
/// per-node, so one approval or revocation would in principle touch every node pointing
/// at that policy. A subgraph has no store API for querying by a non-id field, so these
/// two handlers maintain a single global record and the join happens at query time.
///
/// (Trade-off: the agent makes two queries instead of one. Maintaining a policy -> node
///  reverse index in the mapping would mean appending to an unbounded array on every
///  PolicyPointerSet. Two queries are far cheaper, and "is this policy approved right
///  now" deserves a single authoritative source anyway.)

export function handlePolicyApproved(event: PolicyApproved): void {
  const id = event.params.policy.toHexString();
  let a = ApprovedPolicy.load(id);
  if (a == null) {
    a = new ApprovedPolicy(id);
    a.policy = event.params.policy;
    a.approvedAt = event.block.timestamp;
  }
  a.approved = true;
  a.description = event.params.description;
  a.nonce = event.params.nonce;
  a.attestationHash = event.params.attestationHash;
  a.revokedAt = null;
  a.revokedBy = null;
  a.save();
}

/// **Anyone may revoke, with no attestation** — reducing privilege must never be gated.
/// When something has gone wrong, nobody should have to find their phone and scan their
/// face before pulling the brake.
export function handlePolicyRevoked(event: PolicyRevoked): void {
  const a = ApprovedPolicy.load(event.params.policy.toHexString());
  if (a == null) return;
  a.approved = false;
  a.revokedAt = event.block.timestamp;
  a.revokedBy = event.params.by;
  a.save();
}
