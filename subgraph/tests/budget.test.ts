import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import { assert, beforeEach, clearStore, describe, newMockEvent, test } from "matchstick-as/assembly/index";

import { handleLimitLowered, handleLimitRaised } from "../src/account";
import { LimitLowered, LimitRaised } from "../generated/LeashAccount-wallet1/LeashAccount";

// The real values from the 2026-09-08 deployment, so a failure reads against something
// recognisable rather than against invented addresses.
const NODE = "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121";
const USDC = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const WALLET = "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6";
const BY = "0x36b3f5364a0de03dc8ebaf0162c516e22d6bf959";

// `<wallet>-<node>-<token>`, spelled out rather than importing the helper so that re-keying
// the entity breaks this test loudly instead of silently agreeing with itself.
const BUDGET_ID = WALLET + "-" + NODE + "-" + USDC;

const ONE_K = "1000000000"; // 1000 USDC, 6 decimals
const FIFTY = "50000000"; //    50 USDC

function raised(newLimit: string): LimitRaised {
  const e = changetype<LimitRaised>(newMockEvent());
  e.address = Address.fromString(WALLET);
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))));
  e.parameters.push(new ethereum.EventParam("token", ethereum.Value.fromAddress(Address.fromString(USDC))));
  e.parameters.push(new ethereum.EventParam("oldLimit", ethereum.Value.fromUnsignedBigInt(BigInt.zero())));
  e.parameters.push(new ethereum.EventParam("newLimit", ethereum.Value.fromUnsignedBigInt(BigInt.fromString(newLimit))));
  e.parameters.push(new ethereum.EventParam("period", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(86400))));
  e.parameters.push(new ethereum.EventParam("attestationHash", ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))));
  return e;
}

function lowered(oldLimit: string, newLimit: string): LimitLowered {
  const e = changetype<LimitLowered>(newMockEvent());
  e.address = Address.fromString(WALLET);
  e.parameters = new Array();
  e.parameters.push(new ethereum.EventParam("node", ethereum.Value.fromFixedBytes(Bytes.fromHexString(NODE))));
  e.parameters.push(new ethereum.EventParam("token", ethereum.Value.fromAddress(Address.fromString(USDC))));
  e.parameters.push(new ethereum.EventParam("oldLimit", ethereum.Value.fromUnsignedBigInt(BigInt.fromString(oldLimit))));
  e.parameters.push(new ethereum.EventParam("newLimit", ethereum.Value.fromUnsignedBigInt(BigInt.fromString(newLimit))));
  e.parameters.push(new ethereum.EventParam("by", ethereum.Value.fromAddress(Address.fromString(BY))));
  return e;
}

describe("LimitLowered", () => {
  beforeEach(() => {
    clearStore();
  });

  test("a tightened limit reaches the index", () => {
    handleLimitRaised(raised(ONE_K));
    assert.fieldEquals("AgentBudget", BUDGET_ID, "limit", ONE_K);

    handleLimitLowered(lowered(ONE_K, FIFTY));
    assert.fieldEquals("AgentBudget", BUDGET_ID, "limit", FIFTY);
  });

  test("remaining is recomputed against the new limit, not the old one", () => {
    handleLimitRaised(raised(ONE_K));
    handleLimitLowered(lowered(ONE_K, FIFTY));
    // spent is 0 here, so remaining is the whole new limit — the point is that it tracks
    // the tightened figure rather than keeping 1000's answer.
    assert.fieldEquals("AgentBudget", BUDGET_ID, "remaining", FIFTY);
  });

  test("lowering a budget that does not exist creates nothing", () => {
    handleLimitLowered(lowered(ONE_K, FIFTY));
    assert.notInStore("AgentBudget", BUDGET_ID);
  });
});
