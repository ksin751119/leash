// What `buildSelfieVerifyPayload` must refuse. Every test here is a way to get an
// attestation signed for a widening no face approved — the one thing this backend exists
// to prevent — so each asserts the exact refusal, not merely that something went wrong.
import test from "node:test";
import assert from "node:assert/strict";
import { buildSelfieVerifyPayload, hashSignal } from "./attest.mjs";

const DIGEST = "0x" + "ab".repeat(32);
const ACTION = "expand-policy-demo1";

// A real 4.0 SelfieCheckLegacy result, shape taken verbatim from a live scan on
// 2026-09-11 — the first one in this project's history that opened a camera.
const ok = (over = {}) => ({
  action: ACTION,
  environment: "production",
  nonce: "0x005767e69b39ee4a7ea9f51f2fdd63c4c9f626ddf90ba312096f27c702624098",
  protocol_version: "3.0",
  responses: [
    {
      identifier: "selfie",
      merkle_root: "0x15ed091141db63566353199fb104affa2564ab481385e6cf3f3deff05447c411",
      nullifier: "0x1218592f43ca8e5703acfe9ded3c9a4853280242d8b2d0de90dafce9b168144f",
      proof: "0x2048",
      signal_hash: hashSignal(DIGEST),
      ...over,
    },
  ],
});

test("a real Selfie Check result builds a payload", () => {
  const { payload, error } = buildSelfieVerifyPayload({ digest: DIGEST, result: ok(), action: ACTION });
  assert.equal(error, undefined);
  assert.equal(payload.responses[0].identifier, "selfie");
  assert.equal(payload.action, ACTION);
  assert.equal(payload.responses.length, 1);
});

// THE check. Before 2026-09-11 every proof this project saw said "device", and it believed
// a face had been checked anyway. It had not.
test("a device credential is refused, however well-formed", () => {
  const { payload, error } = buildSelfieVerifyPayload({
    digest: DIGEST,
    result: ok({ identifier: "device" }),
    action: ACTION,
  });
  assert.equal(payload, undefined);
  assert.match(error, /device credential is not a face/);
});

test("orb is refused too - only 'selfie' passes, not merely 'not device'", () => {
  const { error } = buildSelfieVerifyPayload({ digest: DIGEST, result: ok({ identifier: "orb" }), action: ACTION });
  assert.match(error, /needs a Selfie Check/);
});

// The tamper this backend can catch and World cannot: the proof is genuinely valid and
// genuinely bound to some other signal.
test("a proof bound to a different signal cannot be redirected at this digest", () => {
  const otherDigest = "0x" + "cd".repeat(32);
  const { payload, error } = buildSelfieVerifyPayload({
    digest: DIGEST,
    result: ok({ signal_hash: hashSignal(otherDigest) }),
    action: ACTION,
  });
  assert.equal(payload, undefined);
  assert.match(error, /bound to a different signal/);
});

test("the forwarded signal_hash is the one we computed, never the one we were handed", () => {
  // Same digest, but the caller supplies a differently-cased hex string. The payload must
  // carry our value verbatim so that a caller can never influence what World is asked.
  const mixed = hashSignal(DIGEST).toUpperCase().replace("0X", "0x");
  const { payload } = buildSelfieVerifyPayload({
    digest: DIGEST,
    result: ok({ signal_hash: mixed }),
    action: ACTION,
  });
  assert.equal(payload.responses[0].signal_hash, hashSignal(DIGEST));
});

test("more than one response is refused, because 'which one gated this' must have an answer", () => {
  const r = ok();
  r.responses.push({ ...r.responses[0] });
  const { error } = buildSelfieVerifyPayload({ digest: DIGEST, result: r, action: ACTION });
  assert.match(error, /exactly one response/);
});

test("an empty or missing result is refused rather than throwing", () => {
  assert.match(buildSelfieVerifyPayload({ digest: DIGEST, result: null, action: ACTION }).error, /missing result/);
  assert.match(
    buildSelfieVerifyPayload({ digest: DIGEST, result: {}, action: ACTION }).error,
    /exactly one response/,
  );
});

test("the action comes from the server, not from the result", () => {
  // A caller who could choose the action could spend a scan against an action with
  // verifications to spare, or one whose max_verifications was never reached.
  const { payload } = buildSelfieVerifyPayload({
    digest: DIGEST,
    result: { ...ok(), action: "some-other-action" },
    action: ACTION,
  });
  assert.equal(payload.action, ACTION);
});

// --- whose face ---
const OWNER = "0x180f9ee15bedaa3c1912ea178de159e0997ecaea8751f1b3f9f880601b49e881";

test("a real Selfie Check from the WRONG person is refused", () => {
  const r = ok({ nullifier: "0x" + "99".repeat(32) });
  const { payload, error } = buildSelfieVerifyPayload({
    digest: DIGEST, result: r, action: ACTION, expectedNullifier: OWNER,
  });
  assert.equal(payload, undefined);
  assert.match(error, /not the one registered to this wallet/);
});

test("the registered person passes", () => {
  const r = ok({ nullifier: OWNER });
  const { payload, error } = buildSelfieVerifyPayload({
    digest: DIGEST, result: r, action: ACTION, expectedNullifier: OWNER,
  });
  assert.equal(error, undefined);
  assert.equal(payload.responses[0].identifier, "selfie");
});

// Leading zeros, casing, and a 0x-less form are all the same number. Comparing the strings
// instead of the values would refuse the right person for a formatting difference.
test("the comparison is numeric, not textual", () => {
  const r = ok({ nullifier: OWNER });
  const { error } = buildSelfieVerifyPayload({
    digest: DIGEST, result: r, action: ACTION,
    expectedNullifier: BigInt(OWNER).toString(10),
  });
  assert.equal(error, undefined);
});
