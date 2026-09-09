import { PolicyPointerSet } from "../generated/LeashResolver/LeashResolver";
import { ApprovedPolicy, PolicyPointer } from "../generated/schema";

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
  // `description` was declared on this entity and never written by the first version - a
  // dead field, which is exactly the defect we fixed in `PolicyResolved.approved`. The
  // description lives on `ApprovedPolicy` (it comes from a different contract), so copy it
  // across if that policy has ever been approved. Null is the correct value when it has
  // not: there is no approval record to describe.
  const a = ApprovedPolicy.load(event.params.policy.toHexString());
  p.description = a == null ? null : a.description;
  p.setBy = event.params.setBy;
  p.updatedAt = event.block.timestamp;
  p.save();
}
