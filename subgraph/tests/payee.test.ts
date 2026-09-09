import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  assert,
  beforeEach,
  clearStore,
  describe,
  newMockEvent,
  test,
} from "matchstick-as/assembly/index";

import {
  handlePayeeAllowed,
  handlePayeeRemoved,
  handleSpendBlocked,
  handleSpendExecuted,
} from "../src/account";
import { PayeeAllowed, PayeeRemoved, SpendBlocked, SpendExecuted } from "../generated/LeashAccount-wallet1/LeashAccount";

// The real values from the 2026-09-08 deployment, so a failure here reads against
// something recognisable rather than against invented addresses.
const NODE = "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121";
const AGENT = "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0";
const PAYEE = "0x000000000000000000000000000000000000beef";
const USDC = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
// A second token, which is the whole point of several tests below: the account's
// allow-list is per-(node, token, payee) while this entity is per-(node, payee).
const DAI = "0x0000000000000000000000000000000000000da1";
const POLICY = "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b";

// The wallet each mock event is emitted from. In a LeashAccount data source `event.address`
// IS the delegated EOA, because delegated code emits from the EOA's own context.
const WALLET = "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6";
const WALLET2 = "0x00000000000000000000000000000000000000a2";

/// `<wallet>-<node>-<payee>`, spelled out rather than importing the helper so that
/// re-keying the entity breaks this test loudly instead of silently agreeing with itself.
const PAYEE_ID = WALLET + "-" + NODE + "-" + PAYEE;
const PAYEE_ID_W2 = WALLET2 + "-" + NODE + "-" + PAYEE;

function b32(hex: string): Bytes {
  return Bytes.fromHexString(hex);
}

function payeeAllowed(node: string, payee: string, block: i32, wallet: string = WALLET): PayeeAllowed {
  const e = changetype<PayeeAllowed>(newMockEvent());
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(b32(node))));
  e.parameters.push(
    new ethereum.EventParam("payee", ethereum.Value.fromAddress(Address.fromString(payee)))
  );
  e.parameters.push(
    new ethereum.EventParam("attestationHash", ethereum.Value.fromFixedBytes(b32(NODE)))
  );
  e.address = Address.fromString(wallet);
  e.block.number = BigInt.fromI32(block);
  e.block.timestamp = BigInt.fromI32(block * 12);
  return e;
}

function payeeRemoved(node: string, payee: string, block: i32, wallet: string = WALLET): PayeeRemoved {
  const e = changetype<PayeeRemoved>(newMockEvent());
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(b32(node))));
  e.parameters.push(
    new ethereum.EventParam("payee", ethereum.Value.fromAddress(Address.fromString(payee)))
  );
  e.parameters.push(
    new ethereum.EventParam("by", ethereum.Value.fromAddress(Address.fromString(AGENT)))
  );
  e.address = Address.fromString(wallet);
  e.block.number = BigInt.fromI32(block);
  e.block.timestamp = BigInt.fromI32(block * 12);
  return e;
}

function spendExecuted(payee: string, token: string, amount: i32, block: i32, wallet: string = WALLET): SpendExecuted {
  const e = changetype<SpendExecuted>(newMockEvent());
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(b32(NODE))));
  e.parameters.push(
    new ethereum.EventParam("agent", ethereum.Value.fromAddress(Address.fromString(AGENT)))
  );
  e.parameters.push(
    new ethereum.EventParam("payee", ethereum.Value.fromAddress(Address.fromString(payee)))
  );
  e.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(Address.fromString(token)))
  );
  e.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(amount)))
  );
  e.parameters.push(
    new ethereum.EventParam("policy", ethereum.Value.fromAddress(Address.fromString(POLICY)))
  );
  e.parameters.push(
    new ethereum.EventParam("spentAfter", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(amount)))
  );
  e.parameters.push(
    new ethereum.EventParam("limit", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1000)))
  );
  e.parameters.push(
    new ethereum.EventParam("periodEnd", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(86400)))
  );
  e.address = Address.fromString(wallet);
  e.block.number = BigInt.fromI32(block);
  e.block.timestamp = BigInt.fromI32(block * 12);
  return e;
}

function spendBlocked(payee: string, token: string, amount: i32, reason: i32, block: i32, wallet: string = WALLET): SpendBlocked {
  const e = changetype<SpendBlocked>(newMockEvent());
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(b32(NODE))));
  e.parameters.push(
    new ethereum.EventParam("agent", ethereum.Value.fromAddress(Address.fromString(AGENT)))
  );
  e.parameters.push(
    new ethereum.EventParam("payee", ethereum.Value.fromAddress(Address.fromString(payee)))
  );
  e.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(Address.fromString(token)))
  );
  e.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(amount)))
  );
  e.parameters.push(
    new ethereum.EventParam("reason", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(reason)))
  );
  e.parameters.push(
    new ethereum.EventParam("policy", ethereum.Value.fromAddress(Address.fromString(POLICY)))
  );
  e.parameters.push(
    new ethereum.EventParam("spentSoFar", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(0)))
  );
  e.parameters.push(
    new ethereum.EventParam("limit", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1000)))
  );
  e.address = Address.fromString(wallet);
  e.block.number = BigInt.fromI32(block);
  e.block.timestamp = BigInt.fromI32(block * 12);
  return e;
}

describe("Payee — the defect the deployment found, now pinned", () => {
  beforeEach(() => {
    clearStore();
  });

  /// 🔴 **The regression.** Before the fix, `Payee` was keyed by (node, token, payee) and
  /// the allow/remove handlers used `token = 0x0` as a placeholder while the spend handler
  /// used the real token. That produced two rows: the placeholder row tracked `allowed`,
  /// the real-token row tracked payments with `allowed` hardcoded true at creation. So
  /// after a removal, the row an agent would naturally read still said `allowed: true`.
  ///
  /// This test is the direct check that would have caught it, and the one the README now
  /// says did not exist.
  test("removal wins over an earlier payment, in one row", () => {
    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 100));
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 200, 101));
    handlePayeeRemoved(payeeRemoved(NODE, PAYEE, 102));

    assert.entityCount("Payee", 1);
    assert.fieldEquals("Payee", PAYEE_ID, "allowed", "false");
    // The payment history survives the removal - it is history, not permission.
    assert.fieldEquals("Payee", PAYEE_ID, "paidCount", "1");
    assert.fieldEquals("Payee", PAYEE_ID, "paidTotal", "200");
  });

  /// The reverse order, because event ordering is not something to assume: a spend
  /// arriving before its `PayeeAllowed` must still leave one row, allowed.
  test("a spend arriving first creates the row, and a later allow keeps it allowed", () => {
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 200, 100));
    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 101));

    assert.entityCount("Payee", 1);
    assert.fieldEquals("Payee", PAYEE_ID, "allowed", "true");
    assert.fieldEquals("Payee", PAYEE_ID, "paidCount", "1");
  });

  /// 🔴 **The reason the fix does not touch `allowed` on an existing row**, and the reason
  /// code review corrected: `removePayee` is per-(node, token, payee) onchain while this
  /// entity is per-(node, payee). A payee removed for USDC can still be allowed for DAI
  /// and produce an executed DAI spend. That spend must not flip `allowed` back to true,
  /// because the entity cannot say "allowed for DAI but not USDC" - so it stays false,
  /// which is wrong in the restrictive direction, the safe one.
  ///
  /// Delete the `p.allowed` guard in `handleSpendExecuted` and this test fails.
  test("a later spend on a second token does not resurrect a removed payee", () => {
    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 100));
    handlePayeeRemoved(payeeRemoved(NODE, PAYEE, 101));
    handleSpendExecuted(spendExecuted(PAYEE, DAI, 50, 102));

    assert.entityCount("Payee", 1);
    assert.fieldEquals("Payee", PAYEE_ID, "allowed", "false");
    assert.fieldEquals("Payee", PAYEE_ID, "lastToken", DAI);
  });

  /// Two tokens paid to one payee aggregate into one row, and `lastToken` is the latest.
  /// This is the imprecision the schema states rather than hides.
  test("payments across tokens aggregate, and lastToken is the most recent", () => {
    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 100));
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 200, 101));
    handleSpendExecuted(spendExecuted(PAYEE, DAI, 50, 102));

    assert.entityCount("Payee", 1);
    assert.fieldEquals("Payee", PAYEE_ID, "paidCount", "2");
    assert.fieldEquals("Payee", PAYEE_ID, "paidTotal", "250");
    assert.fieldEquals("Payee", PAYEE_ID, "lastToken", DAI);
  });

  /// The justification for `allowed = true` on creation is "a spend that executed proves
  /// the payee was allowed at that moment". That is only sound if no *blocked* spend can
  /// create a row. Pin it.
  test("a blocked spend creates no Payee row at all", () => {
    handleSpendBlocked(spendBlocked(PAYEE, USDC, 600, 6, 100));

    assert.entityCount("Payee", 0);
    // It is still recorded as a Spend - a block has to leave a record.
    assert.entityCount("Spend", 1);
  });

  /// `removePayee` on a payee never seen: the handler returns early rather than creating a
  /// row that says "allowed: false", which would invent a relationship that never existed.
  test("removing an unknown payee creates nothing", () => {
    handlePayeeRemoved(payeeRemoved(NODE, PAYEE, 100));
    assert.entityCount("Payee", 0);
  });

  /// 🔴 **Two wallets, the same ENS node, and they must not share a row.**
  ///
  /// `payees` and `spent` live in the delegated EOA's own storage, so two wallets that
  /// bind an agent to the same node have entirely separate allow-lists and ledgers
  /// onchain. Keying by node alone merged them — invisible today because the demo has one
  /// wallet, and silently wrong the moment there are two. Code review flagged it as a
  /// note; it is a defect of the same shape as the one above, so it is fixed and pinned.
  ///
  /// Drop the wallet from `payeeId` and this test fails with 1 row instead of 2.
  test("two wallets under the same node keep separate rows", () => {
    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 100, WALLET));
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 200, 101, WALLET));

    handlePayeeAllowed(payeeAllowed(NODE, PAYEE, 102, WALLET2));
    handlePayeeRemoved(payeeRemoved(NODE, PAYEE, 103, WALLET2));

    assert.entityCount("Payee", 2);
    // Wallet 1 is unaffected by wallet 2's removal, and keeps its own history.
    assert.fieldEquals("Payee", PAYEE_ID, "allowed", "true");
    assert.fieldEquals("Payee", PAYEE_ID, "paidTotal", "200");
    // Wallet 2 removed the payee and never paid it.
    assert.fieldEquals("Payee", PAYEE_ID_W2, "allowed", "false");
    assert.fieldEquals("Payee", PAYEE_ID_W2, "paidTotal", "0");
  });

  /// The same collision, on the number the agent trusts most: question 1's budget.
  /// `spent` is per-EOA storage, so two wallets must not aggregate into one budget row.
  test("two wallets under the same node keep separate budgets", () => {
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 200, 100, WALLET));
    handleSpendExecuted(spendExecuted(PAYEE, USDC, 700, 101, WALLET2));

    assert.entityCount("AgentBudget", 2);
    assert.fieldEquals("AgentBudget", WALLET + "-" + NODE + "-" + USDC, "spent", "200");
    assert.fieldEquals("AgentBudget", WALLET2 + "-" + NODE + "-" + USDC, "spent", "700");
  });
});
