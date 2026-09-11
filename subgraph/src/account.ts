import { BigInt, Bytes, Address } from "@graphprotocol/graph-ts";
import {
  SpendExecuted,
  SpendBlocked,
  AgentBound,
  AgentRevoked,
  Leashed,
  PayeeAllowed,
  PayeeRemoved,
  LimitRaised,
  LimitLowered,
} from "../generated/LeashAccount-wallet1/LeashAccount";
import { AgentBudget, Payee, Spend, Agent, LeashedWallet } from "../generated/schema";
import { reasonName } from "./reason";

const ZERO = BigInt.fromI32(0);

/// **The wallet is part of every id that mirrors per-EOA storage.** `bindings`, `rules`,
/// `payees` and `spent` all live in the delegated EOA's own storage (see `LeashStorage`),
/// so two wallets binding an agent to the *same* ENS node have entirely separate budgets,
/// allow-lists and ledgers onchain. Keying these entities by node alone merged them into
/// one row — invisible with one wallet, silently wrong with two, which is the same shape
/// as the `Payee` defect the deployment found. In a LeashAccount data source
/// `event.address` **is** the wallet, because delegated code emits from the EOA.
function budgetId(wallet: Address, node: Bytes, token: Address): string {
  return wallet.toHexString() + "-" + node.toHexString() + "-" + token.toHexString();
}

/// Keyed by (node, payee) only — `PayeeAllowed` / `PayeeRemoved` carry no token, and they
/// are the only authority for `allowed`. See the note on `Payee` in schema.graphql.
function payeeId(wallet: Address, node: Bytes, payee: Address): string {
  return wallet.toHexString() + "-" + node.toHexString() + "-" + payee.toHexString();
}

function agentId(wallet: Address, agent: Address): string {
  return wallet.toHexString() + "-" + agent.toHexString();
}

/// Pre-computed remaining budget. **This is where "the arithmetic lives in the mapping,
/// not in the agent" actually happens.**
///
/// `limit == 0` means unlimited, and we return null for it. An agent that reads null
/// knows there is no cap. Returning 0 instead would be read as "no budget left" — the
/// exact opposite meaning.
function remainingOf(limit: BigInt, spent: BigInt): BigInt | null {
  if (limit.equals(ZERO)) return null;
  if (spent.ge(limit)) return ZERO;
  return limit.minus(spent);
}

export function handleSpendExecuted(event: SpendExecuted): void {
  const node = event.params.node;
  const token = event.params.token;

  // --- Question 1: budget snapshot ---
  const bid = budgetId(event.address, node, token);
  let b = AgentBudget.load(bid);
  if (b == null) {
    b = new AgentBudget(bid);
    b.wallet = event.address;
    b.node = node;
    b.token = token;
  }
  b.spent = event.params.spentAfter;
  b.limit = event.params.limit;
  b.remaining = remainingOf(event.params.limit, event.params.spentAfter);
  b.periodEnd = event.params.periodEnd;
  b.lastSpendAt = event.block.timestamp;
  b.lastSpendTx = event.transaction.hash;
  b.save();

  // --- Question 2: this payee's running total ---
  const pid = payeeId(event.address, node, event.params.payee);
  let p = Payee.load(pid);
  if (p == null) {
    // Create the record if it is missing, but `allowed = FALSE`.
    //
    // 🔴 This said `allowed = true` until 2026-09-11, on the reasoning that "a spend that
    // executed proves the payee was allowed at that moment". That was true while
    // `StandardPolicy` was the only policy, because it ANDs `payeeAllowed` into every
    // verdict. It is FALSE under `PolicySet`: `MicroPaymentPolicy` deliberately never reads
    // `payeeAllowed`, so a small payment executes for a payee nobody ever allow-listed, and
    // this line then invented an allow-list entry the chain does not have.
    //
    // It was caught in a live rehearsal, where the page reported `0x…f00d` as "allowed"
    // while `isPayeeAllowed(node, token, 0x…f00d)` returned false on chain — and that is
    // the one payee whose whole purpose is to be paid WITHOUT being on the list. The panel
    // was erasing the demonstration it existed to show.
    //
    // `PayeeAllowed` and `PayeeRemoved` are the only authority for this field, as the
    // schema says. There is no ordering hazard in reading it that strictly: graph-node
    // replays in ascending (block, logIndex) order, so a `PayeeAllowed` that happened
    // has already been processed by the time any later spend arrives. If no `PayeeAllowed`
    // has been seen, the payee genuinely is not on the list.
    p = new Payee(pid);
    p.wallet = event.address;
    p.node = node;
    p.payee = event.params.payee;
    p.allowed = false;
    p.paidCount = 0;
    p.paidTotal = ZERO;
    p.firstAllowedAt = event.block.timestamp;
  }
  // Deliberately NOT touching `p.allowed` on an existing row: PayeeAllowed and
  // PayeeRemoved own that field.
  //
  // The reason is *not* reindex safety - graph-node replays in ascending
  // (block, logIndex) order, identical to the first pass, so an older SpendExecuted can
  // never arrive after a later PayeeRemoved. (That was the reason this comment gave
  // until code review pointed out it was false.)
  //
  // The real reason is that `removePayee` is per-(node, token, payee) onchain while this
  // entity is per-(node, payee). A payee removed for USDC but still allowed for DAI can
  // still produce an executed DAI spend, and flipping `allowed` back to true here would
  // report it as allowed for USDC too. Leaving it false is wrong in the *restrictive*
  // direction, which is the safe one: the agent asks first and the account decides.
  p.lastToken = token;
  p.paidCount = p.paidCount + 1;
  p.paidTotal = p.paidTotal.plus(event.params.amount);
  p.lastPaidAt = event.block.timestamp;
  p.save();

  recordSpend(event.transaction.hash, event.logIndex, node, event.params.agent,
    event.params.payee, token, event.params.amount, true, 0, event.params.policy,
    event.params.spentAfter, event.params.limit, event.block.number, event.block.timestamp);

  bumpAgent(event.address, event.params.agent, true);
}

/// **A blocked attempt has to leave a record.** The whole design chose no-op + event
/// over revert precisely so this handler has something to index: the chain discards a
/// reverted transaction's logs, and the agent could then never answer "why was I
/// blocked last time?"
export function handleSpendBlocked(event: SpendBlocked): void {
  recordSpend(event.transaction.hash, event.logIndex, event.params.node, event.params.agent,
    event.params.payee, event.params.token, event.params.amount, false,
    event.params.reason, event.params.policy,
    event.params.spentSoFar, event.params.limit, event.block.number, event.block.timestamp);

  bumpAgent(event.address, event.params.agent, false);
}

function recordSpend(
  txHash: Bytes, logIndex: BigInt, node: Bytes, agent: Address, payee: Address,
  token: Address, amount: BigInt, executed: boolean, reason: i32, policy: Address,
  spentAfter: BigInt, limit: BigInt, blockNumber: BigInt, timestamp: BigInt
): void {
  const s = new Spend(txHash.toHexString() + "-" + logIndex.toString());
  s.node = node;
  s.agent = agent;
  s.payee = payee;
  s.token = token;
  s.amount = amount;
  s.executed = executed;
  s.reason = reason;
  s.reasonName = reasonName(reason);
  s.policy = policy;
  s.spentAfter = spentAfter;
  s.limit = limit;
  s.blockNumber = blockNumber;
  s.timestamp = timestamp;
  s.txHash = txHash;
  s.save();
}

function bumpAgent(wallet: Address, agent: Address, executed: boolean): void {
  const a = Agent.load(agentId(wallet, agent));
  if (a == null) return; // AgentBound was not indexed (bound before startBlock) — do not fabricate one
  if (executed) a.spendCount = a.spendCount + 1;
  else a.blockedCount = a.blockedCount + 1;
  a.save();
}

export function handleAgentBound(event: AgentBound): void {
  const id = agentId(event.address, event.params.agent);
  let a = Agent.load(id);
  if (a == null) {
    a = new Agent(id);
    a.agent = event.params.agent;
    a.spendCount = 0;
    a.blockedCount = 0;
  }
  a.node = event.params.node;
  a.wallet = event.address; // in delegate execution, address(this) *is* that EOA
  a.revoked = false;
  a.boundAt = event.block.timestamp;
  a.save();
}

export function handleAgentRevoked(event: AgentRevoked): void {
  const a = Agent.load(agentId(event.address, event.params.agent));
  if (a == null) return;
  a.revoked = true;
  a.save();
}

/// `Leashed` fires on the first `bindAgent`.
///
/// ⚠️ **It cannot serve as a subgraph template trigger**, even though the design doc
/// originally said it would. The EOA itself emits this event, and a template must be
/// triggered by a contract the subgraph is *already* watching — so the subgraph cannot
/// see it before it watches that EOA. Chicken and egg.
///
/// That is why the addresses in subgraph.yaml are hardcoded, and why this handler only
/// records the fact.
export function handleLeashed(event: Leashed): void {
  const id = event.params.wallet.toHexString();
  let w = LeashedWallet.load(id);
  if (w == null) {
    w = new LeashedWallet(id);
    w.leashedAt = event.block.timestamp;
  }
  w.wallet = event.params.wallet;
  w.impl = event.params.impl;
  w.node = event.params.node;
  w.save();
}

/// The authority for question 2's `allowed`. `PayeeAllowed` carries no token (the frozen
/// event is node/payee/hash only), which is why `Payee` is keyed by (node, payee) — see
/// the note on that entity in schema.graphql.
export function handlePayeeAllowed(event: PayeeAllowed): void {
  const pid = payeeId(event.address, event.params.node, event.params.payee);
  let p = Payee.load(pid);
  if (p == null) {
    p = new Payee(pid);
    p.wallet = event.address;
    p.node = event.params.node;
    p.payee = event.params.payee;
    p.paidCount = 0;
    p.paidTotal = ZERO;
    p.firstAllowedAt = event.block.timestamp;
  }
  p.allowed = true;
  p.save();
}

export function handlePayeeRemoved(event: PayeeRemoved): void {
  const p = Payee.load(payeeId(event.address, event.params.node, event.params.payee));
  if (p == null) return;
  p.allowed = false;
  p.save();
}

/// Create the AgentBudget when a limit is raised, so "has a budget but has not spent
/// yet" is queryable. Otherwise the agent's very first decision would read null and
/// have no idea how much it may spend.
/// Lowering is the one reduction this subgraph used to miss. Every other one — a payee
/// removed, an agent revoked, a policy revoked, a subname revoked — was already indexed,
/// so the index agreed with the chain about every way to take authority away except this
/// one. It mattered in practice: a limit tightened from 1000 to 50 left the index still
/// answering 1000 until the next spend happened to carry the real figure, and anything
/// reading the index — the agent's own pre-flight among them — believed the looser number.
///
/// Unlike a raise, this never creates the entity. A budget that does not exist has no
/// limit to lower, and inventing one here would assert a rule that was never set.
export function handleLimitLowered(event: LimitLowered): void {
  const bid = budgetId(event.address, event.params.node, event.params.token);
  const b = AgentBudget.load(bid);
  if (b == null) return;
  b.limit = event.params.newLimit;
  b.remaining = remainingOf(event.params.newLimit, b.spent);
  b.save();
}

export function handleLimitRaised(event: LimitRaised): void {
  const bid = budgetId(event.address, event.params.node, event.params.token);
  let b = AgentBudget.load(bid);
  if (b == null) {
    b = new AgentBudget(bid);
    b.wallet = event.address;
    b.node = event.params.node;
    b.token = event.params.token;
    b.spent = ZERO;
    b.periodEnd = ZERO;
    b.lastSpendAt = ZERO;
    b.lastSpendTx = Bytes.empty();
  }
  b.limit = event.params.newLimit;
  b.remaining = remainingOf(event.params.newLimit, b.spent);
  // periodEnd cannot be derived here: the event gives the period *length*, not the
  // alignment point. A newly created entity keeps 0, and the first SpendExecuted fills
  // in the real value. (Existing values are not overwritten — that would erase a
  // periodEnd we already know.)
  b.save();
}
