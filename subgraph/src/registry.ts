import { SubnameRegistered, SubnameRevoked } from "../generated/LeashRegistry/LeashRegistry";
import { Subname } from "../generated/schema";
import { BigInt } from "@graphprotocol/graph-ts";

/// Whether a subname is alive. It also lapses when `expiry` passes, **and that needs no
/// transaction at all** — so `live` reflects only "has it been revoked". Expiry must be
/// judged by the caller, comparing `expiry` against the current time.
///
/// This is deliberate: a subgraph has no "run again when the clock passes a threshold"
/// mechanism. Simulating one would produce a field that looks correct but is actually
/// frozen at the last event.
export function handleSubnameRegistered(event: SubnameRegistered): void {
  const id = event.params.node.toHexString();
  let s = Subname.load(id);
  if (s == null) {
    s = new Subname(id);
    s.node = event.params.node;
  }
  s.label = event.params.label;
  s.owner = event.params.owner;
  s.expiry = event.params.expiry;
  s.live = true;
  s.revokedAt = null;
  s.revokedBy = null;
  s.save();
}

/// Evidence for demo act four: one transaction halts this agent without ever touching
/// its account.
export function handleSubnameRevoked(event: SubnameRevoked): void {
  const s = Subname.load(event.params.node.toHexString());
  if (s == null) return;
  s.live = false;
  s.expiry = BigInt.fromI32(0);
  s.revokedAt = event.block.timestamp;
  s.revokedBy = event.params.by;
  s.save();
}
