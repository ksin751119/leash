// Leash · Selfie Check verification harness
//
// Two routes only: a static page, and a backend that forwards the proof to World for
// verification. No dependencies to speak of — node's built-in http and fetch are enough,
// and this is throwaway code.
//
// Why verification has to happen on the backend: a proof "looking successful" in the
// frontend means nothing, because the frontend can be modified. What counts is World's
// server saying yes, and that response is what will later become the EIP-712 content
// AttesterGate signs.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { keccak_256 } from "@noble/hashes/sha3";
import { randomBytes } from "node:crypto";

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

/**
 * World ID's signal hash: keccak256(signal) shifted right by 8 bits.
 * The shift is because a proof has to land inside the field in the SNARK system, and
 * keccak's 256 bits would overflow it.
 *
 * @dev **Measured on 2026-09-07: the proof IDKit returns contains no `signal_hash`.**
 *      So this is not a fallback path, it is the only path — the backend has to compute
 *      it. That is exactly where the first run fell over: `@noble/hashes` was not
 *      installed → 500 → World App displayed "Verification Declined", which looks like
 *      World rejecting you when in fact your own backend has crashed.
 *
 *      Note you cannot use node's built-in `crypto.createHash("sha3-256")` — SHA3 and
 *      keccak256 pad differently, produce different values, and World will refuse it.
 *
 *      When this is wired to AttesterGate, the signal becomes the EIP-712 payload hash of
 *      the widening in question — so one face scan can only loosen that one rule, and an
 *      intercepted proof cannot be replayed anywhere else.
 */
function hashSignal(signal) {
  const h = BigInt("0x" + Buffer.from(keccak_256(signal)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
}

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

      // nullifier_hash is the anonymous identity of "this person". AttesterGate will need
      // to remember it, so it can tell whether the same person is reusing one face scan.
      return json(res, r.status, { http_status: r.status, ...body });
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
