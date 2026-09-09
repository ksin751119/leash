import { PolicyPointerSet } from "../generated/LeashResolver/LeashResolver";
import { PolicyPointer } from "../generated/schema";

/// Half of question 3: where the pointer points. **Controlled by ADMIN.**
///
/// The other half — whether a human approved that policy — lives in `approvals.ts`, and
/// comes from a *different contract*. Separating the two is the point: with a stolen
/// ADMIN key an attacker can move the pointer, but cannot make an unapproved policy
/// count as approved on the existing list.
export function handlePolicyPointerSet(event: PolicyPointerSet): void {
  const id = event.params.node.toHexString();
  let p = PolicyPointer.load(id);
  if (p == null) {
    p = new PolicyPointer(id);
    p.node = event.params.node;
  }
  p.policy = event.params.policy;
  // The event carries the approval state *at the moment the pointer was set*. If the
  // approval list changes later, `ApprovedPolicy` in approvals.ts is the authoritative
  // record — which is exactly why the account re-checks `isApproved` on every spend
  // instead of trusting a snapshot like this one.
  p.approved = event.params.approved;
  p.setBy = event.params.setBy;
  p.updatedAt = event.block.timestamp;
  p.save();
}
