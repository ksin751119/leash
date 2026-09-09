// Leash · Selfie Check verification harness
//
// Two routes only: a static page, and a backend that forwards the proof to World for
// verification. No dependencies to speak of — node's built-in http and fetch are enough,
// and this is throwaway code.
//
// Why verification has to happen on the backend: a proof "looking successful" in the
// frontend means nothing, because the frontend can be modified. What counts is World's
// server saying yes, and only then does /api/attest (below) sign the EIP-712 attestation
// that WorldAttester verifies onchain.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { signAttestation, buildVerifyPayload, hashSignal, checkAttestEnv } from "./attest.mjs";

const PORT = Number(process.env.PORT || 8787);
const APP_ID = process.env.WORLD_APP_ID || "app_452654c9c277c08df71fec3315501c00";
const ACTION = process.env.WORLD_ACTION || "expand-policy";
const RP_ID = process.env.WORLD_RP_ID || "rp_ef35d4e2d4f1a031";

// Selfie Check produces a World ID **3.0**-format proof (their words: "Currently uses
// World ID 3.0 technology, with World ID 4.0 support not yet available"), but
// verification has to go to the **v4** endpoint. That was established on 2026-09-07 with
// a real proof; it is not what the documentation says.
//
// v2 (`/api/v2/verify/{app_id}`) **always** answers this app with
// `invalid_action: Action not found.` — a real action, a fake action and an empty string
// all behave identically, and so does sending a real proof. It cannot see our action,
// because this app was created as a 4.0 RP.
//
// v4's documentation says it "Verifies World ID 4.0 proofs **and legacy 3.0 proofs**" and
// takes an `rp_id`. A 3.0 proof has to be wrapped as a `VerifyV4LegacyProofRequest`.
const VERIFY_URL = `https://developer.worldcoin.org/api/v4/verify/${RP_ID}`;

// hashSignal is imported from attest.mjs (shared with buildVerifyPayload's own use of it
// for /api/attest); the comment there documents the shift, the 2026-09-07 measurement,
// and the two-branch domain rule it has to match. The signal is the digest of the
// widening in question, and WorldAttester's EIP-712 struct binds to it — so one face scan
// can only loosen that one rule, and an intercepted proof cannot be replayed anywhere
// else.

const json = (res, code, body) => {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body, null, 2));
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (c) => {
      raw += c;
      if (raw.length > 1e6) reject(new Error("body too large"));
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(raw || "{}"));
      } catch (e) {
        reject(e);
      }
    });
  });

const server = createServer(async (req, res) => {
  try {
    if (req.method === "GET" && (req.url === "/" || req.url.startsWith("/?"))) {
      const html = await readFile(new URL("./index.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (req.method === "GET" && req.url === "/api/config") {
      return json(res, 200, { app_id: APP_ID, action: ACTION });
    }

    // The Portal has no surface anywhere that shows credential enablement status;
    // precheck is the only place it can be asked.
    if (req.method === "GET" && req.url === "/api/precheck") {
      const r = await fetch(`https://developer.worldcoin.org/api/v1/precheck/${APP_ID}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: ACTION }),
      });
      return json(res, r.status, await r.json());
    }

    if (req.method === "POST" && req.url === "/api/verify") {
      const { proof, action, signal } = await readBody(req);
      if (!proof) return json(res, 400, { error: "missing proof" });

      // A 3.0 proof wrapped as a v4 legacy request. **Field names have to change**:
      //   nullifier_hash → responses[].nullifier
      // and credential_type / verification_level **must not be sent** — v4 rejects both.
      const payload = {
        protocol_version: "3.0",
        nonce: "0x" + randomBytes(16).toString("hex"),
        action: action ?? ACTION,
        environment: "production", // the app is is_staging: false
        responses: [
          {
            identifier: proof.credential_type ?? proof.verification_level,
            signal_hash: proof.signal_hash ?? hashSignal(signal ?? ""),
            merkle_root: proof.merkle_root,
            nullifier: proof.nullifier_hash,
            proof: proof.proof,
          },
        ],
      };

      console.log("\n← the complete proof IDKit returned:");
      console.log(JSON.stringify(proof, null, 2));
      console.log("\n→ POST", VERIFY_URL);
      console.log(JSON.stringify(payload, null, 2));

      const r = await fetch(VERIFY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const body = await r.json().catch(() => ({ error: "non-JSON response" }));
      console.log("← HTTP", r.status, JSON.stringify(body));

      // nullifier_hash is the anonymous identity of "this person" for this action.
      // Neither this harness nor WorldAttester records it — WorldAttester only checks a
      // signature. Anything that wants to detect the same person reusing a scan across
      // separate widenings would have to persist this itself; nothing does yet.
      return json(res, r.status, { http_status: r.status, ...body });
    }

    // Sprint item 11: verify a Selfie Check proof, then sign an attestation for exactly
    // the digest that proof was bound to.
    //
    // `signal = digest` is the security property, not a convenience: one face scan
    // authorises one widening, and an intercepted proof cannot be moved to another. That
    // was the documented intention in IAttester from day one; here it becomes real.
    //
    // `/api/attest` is raw JSON with no trusted caller, so `proof` (and the rest of the
    // body) is attacker-controlled. `signal_hash` and `action` are therefore pinned inside
    // buildVerifyPayload — from `digest` and `process.env.WORLD_ACTION`, never from the
    // request body — rather than trusted from the caller. See buildVerifyPayload's
    // docstring in attest.mjs for the two attacks that closes, and checkAttestEnv's for
    // why WORLD_ACTION has no fallback here even though ACTION (used by the other
    // routes) does.
    if (req.method === "POST" && req.url === "/api/attest") {
      const { digest, proof } = await readBody(req);
      if (!digest || !/^0x[0-9a-fA-F]{64}$/.test(digest)) {
        return json(res, 400, { error: "digest must be 0x + 64 hex chars" });
      }
      if (!proof) return json(res, 400, { error: "missing proof" });

      // checkAttestEnv (attest.mjs) also refuses to run without WORLD_ACTION set — the
      // module-level ACTION above falls back to "expand-policy" for the other routes,
      // but that default was consumed on 2026-09-07 and must never reach World from
      // here. Use process.env.WORLD_ACTION directly below, not ACTION, so the fallback
      // stays unreachable even if this guard is ever loosened.
      const attestEnvErr = checkAttestEnv(process.env);
      if (attestEnvErr) return json(res, 500, { error: attestEnvErr });

      const payload = buildVerifyPayload({ digest, proof, action: process.env.WORLD_ACTION });

      const r = await fetch(VERIFY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const body = await r.json().catch(() => ({ error: "non-JSON response" }));
      console.log("← HTTP", r.status, JSON.stringify(body));

      // Sign nothing unless World said yes. This is the only gate between a proof and a
      // signature the chain will accept.
      if (r.status !== 200) return json(res, r.status, { http_status: r.status, ...body });

      const deadline = Math.floor(Date.now() / 1000) + 900; // 15 minutes
      const { attestation } = signAttestation({
        digest,
        deadline,
        chainId: 11155111,
        verifyingContract: process.env.WORLD_ATTESTER,
        privKeyHex: process.env.WORLD_RP_SIGNER_PK,
      });

      return json(res, 200, {
        attestation,
        deadline,
        nullifier: proof.nullifier_hash,
      });
    }

    json(res, 404, { error: "not found" });
  } catch (err) {
    console.error(err);
    json(res, 500, { error: String(err?.message ?? err) });
  }
});

// Bound to loopback only. This machine has a public IP, so binding *:8787 would stand up
// an open proxy — no secret would leak (precheck is public anyway and verify only
// forwards), but there is no reason to. An SSH tunnel lands on localhost, so this costs
// nothing in practice.
server.listen(PORT, "127.0.0.1", () => {
  console.log(`\n  Leash · Selfie Check verification harness`);
  console.log(`  http://localhost:${PORT}\n`);
  console.log(`  app_id  ${APP_ID}`);
  console.log(`  action  ${ACTION}`);
  console.log(`  rp_id   ${RP_ID}`);
  console.log(`  verify  ${VERIFY_URL}\n`);
  console.log(`  config check: curl -s localhost:${PORT}/api/precheck\n`);
});
