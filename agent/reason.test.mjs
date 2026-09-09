import { test } from "node:test";
import assert from "node:assert/strict";
import { REASON, reasonName, buildNames } from "./reason.mjs";

test("the codes match src/Reason.sol exactly", () => {
  assert.equal(REASON.OK, 0);
  assert.equal(REASON.AGENT_NOT_BOUND, 1);
  assert.equal(REASON.AGENT_REVOKED, 2);
  assert.equal(REASON.NO_POLICY, 3);
  assert.equal(REASON.POLICY_NOT_APPROVED, 4);
  assert.equal(REASON.TOKEN_NOT_ALLOWED, 5);
  assert.equal(REASON.PAYEE_NOT_ALLOWED, 6);
  assert.equal(REASON.OVER_TX_LIMIT, 7);
  assert.equal(REASON.OVER_PERIOD_LIMIT, 8);
  assert.equal(REASON.OUTSIDE_TIME_WINDOW, 9);
  assert.equal(REASON.PAUSED, 10);
  assert.equal(REASON.OVER_SHARED_LIMIT, 11);
  assert.equal(REASON.POLICY_FAILED, 12);
});

test("reasonName round-trips every code", () => {
  for (const [name, code] of Object.entries(REASON)) {
    assert.equal(reasonName(code), name, `code ${code}`);
  }
});

test("an unknown code does not throw", () => {
  assert.equal(reasonName(99), "UNKNOWN");
  assert.equal(reasonName(-1), "UNKNOWN");
});

test("buildNames preserves gaps in the code sequence", () => {
  const gapped = buildNames({ A: 0, B: 1, D: 3 });
  assert.equal(gapped[0], "A");
  assert.equal(gapped[1], "B");
  assert.equal(gapped[2], undefined, "gap at index 2");
  assert.equal(gapped[3], "D");
});
