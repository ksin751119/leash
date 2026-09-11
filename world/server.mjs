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
import QRCode from "qrcode";
import { signRequest } from "@worldcoin/idkit-server";
import { signAttestation, buildVerifyPayload, buildSelfieVerifyPayload, hashSignal, checkAttestEnv } from "./attest.mjs";
import { widenPlan, checkWidenEnv } from "./widen-plan.mjs";

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
    // The demo page is the front door: during judging this is what is on screen. The
    // harness stays reachable at /harness because it is the tool you reach for when the
    // demo misbehaves, and losing it would cost the fallback.
    if (req.method === "GET" && (req.url === "/" || req.url.startsWith("/?"))) {
      const html = await readFile(new URL("./demo.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    // The 4.0 Selfie Check probe. Separate from /harness, which speaks the older
    // `verification_level` vocabulary, so the two can be compared side by side.
    if (req.method === "GET" && (req.url === "/facetest" || req.url.startsWith("/facetest?"))) {
      const html = await readFile(new URL("./facetest.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (req.method === "GET" && (req.url === "/harness" || req.url.startsWith("/harness?"))) {
      const html = await readFile(new URL("./index.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    // `@worldcoin/idkit-core`'s browser build, served from OUR origin rather than a CDN.
    // It resolves `idkit_wasm_bg.wasm` relative to itself, and a CDN copy resolves that
    // against the CDN - which is one more thing to be wrong on a stage. Both files come
    // out of node_modules so the version is pinned by package-lock.
    if (req.method === "GET" && (req.url === "/idkit.global.js" || req.url === "/idkit_wasm_bg.wasm")) {
      const name = req.url.slice(1);
      const buf = await readFile(new URL(`./node_modules/@worldcoin/idkit-core/dist/${name}`, import.meta.url));
      res.writeHead(200, {
        "Content-Type": name.endsWith(".wasm") ? "application/wasm" : "text/javascript; charset=utf-8",
        "Content-Length": buf.length,
      });
      return res.end(buf);
    }

    // A QR rendered as SVG, server-side. The 4.0 flow hands us a `connectorURI` string and
    // expects the page to draw it - which is an improvement for the demo, because the code
    // then lives in our own layout instead of a third-party modal.
    if (req.method === "GET" && req.url.startsWith("/api/qr")) {
      const data = new URL(req.url, "http://x").searchParams.get("data");
      if (!data) return json(res, 400, { error: "missing data" });
      const svg = await QRCode.toString(data, { type: "svg", margin: 1, width: 320 });
      res.writeHead(200, { "Content-Type": "image/svg+xml; charset=utf-8" });
      return res.end(svg);
    }

    // demo.html imports this as an ES module, so it needs a JavaScript content type.
    if (req.method === "GET" && req.url === "/demo-render.mjs") {
      const js = await readFile(new URL("./demo-render.mjs", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" });
      return res.end(js);
    }

    if (req.method === "GET" && req.url === "/api/config") {
      return json(res, 200, { app_id: APP_ID, action: ACTION });
    }

    // The RP context a World ID **4.0** credential request needs. This is the route to
    // Selfie Check, and it exists because of what 2026-09-11 established: the older
    // `verification_level` vocabulary that `@worldcoin/idkit-standalone` speaks CANNOT
    // request a face check at all. Its bundle contains no Selfie Check of any kind - four
    // levels, `device` / `document` / `secure_document` / `orb`, and nothing else. A scan
    // against a brand-new action, with the app's `enable_face_check: true`, opened no
    // camera and came back `protocol_version: "3.0"`, `identifier: "device"`.
    //
    // Selfie Check is a 4.0 *credential request* - `{ type: "SelfieCheckLegacy" }` - and
    // reaching it means `@worldcoin/idkit-core`, which requires an RP context signed by
    // the relying party. `signRequest` is World's own helper for exactly that, so the
    // message format (version || nonce || createdAt || expiresAt || action) is theirs and
    // not ours to guess.
    //
    // **The signing key never leaves this process.** The browser gets the signature, the
    // nonce and the two timestamps - which is all a credential request needs, and none of
    // which lets anyone sign a different one.
    if (req.method === "GET" && req.url === "/api/rp-context") {
      const pk = process.env.WORLD_RP_SIGNER_PK;
      if (!pk) return json(res, 500, { error: "WORLD_RP_SIGNER_PK is not set" });
      try {
        // `action` is hashed into the signed message for a non-session proof, which binds
        // the context to this action. Omitting it would produce a signature World rejects.
        const r = signRequest({ signingKeyHex: pk, action: ACTION, ttl: 900 });
        return json(res, 200, {
          rp_id: RP_ID,
          nonce: r.nonce,
          created_at: r.createdAt,
          expires_at: r.expiresAt,
          signature: r.sig,
        });
      } catch (err) {
        return json(res, 500, { error: String(err?.message ?? err) });
      }
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
    // Takes a World ID **4.0** `SelfieCheckLegacy` result, and only that.
    //
    // It used to take a 3.0 `proof` from `@worldcoin/idkit-standalone`. That path is gone
    // rather than deprecated, because on 2026-09-11 it was measured to produce a **device
    // credential with no camera and no face** — the app's `enable_face_check: true` has no
    // effect on the 3.0 vocabulary, and that widget cannot request a face check at all.
    // Leaving the old path in place "for compatibility" would leave the exact hole this
    // endpoint exists to close: an attestation, signed by us and accepted by the chain,
    // for a widening no human face ever approved.
    if (req.method === "POST" && req.url === "/api/attest") {
      const { digest, result } = await readBody(req);
      if (!digest || !/^0x[0-9a-fA-F]{64}$/.test(digest)) {
        return json(res, 400, { error: "digest must be 0x + 64 hex chars" });
      }
      if (!result) return json(res, 400, { error: "missing result" });

      // checkAttestEnv (attest.mjs) also refuses to run without WORLD_ACTION set — the
      // module-level ACTION above falls back to "expand-policy" for the other routes,
      // but that default was consumed on 2026-09-07 and must never reach World from
      // here. Use process.env.WORLD_ACTION directly below, not ACTION, so the fallback
      // stays unreachable even if this guard is ever loosened.
      const attestEnvErr = checkAttestEnv(process.env);
      if (attestEnvErr) return json(res, 500, { error: attestEnvErr });

      // Refuses a non-selfie credential and a proof bound to another signal. See the
      // notes on buildSelfieVerifyPayload - both refusals are load-bearing, and both are
      // pinned by mutation-tested cases in attest.test.mjs.
      const { payload, error: refusal } = buildSelfieVerifyPayload({
        digest,
        result,
        action: process.env.WORLD_ACTION,
      });
      if (refusal) return json(res, 400, { error: refusal });

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
        nullifier: result.responses[0].nullifier,
        // Echoed so the page can show WHICH credential gated this widening. It is always
        // "selfie" by the time we get here - buildSelfieVerifyPayload refuses anything
        // else - but saying it out loud is the point: for two days this said "device" and
        // nobody was looking.
        credential: result.responses[0].identifier,
      });
    }

    if (req.method === "GET" && req.url.startsWith("/api/widen-plan")) {
      const q = new URL(req.url, "http://localhost").searchParams;
      const { status, body } = await widenPlan({
        payee: q.get("payee"),
        token: q.get("token"),
        env: process.env,
        nonce: Math.floor(Date.now() / 1000),
      });
      return json(res, status, body);
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

  // Not fatal: /api/config, /api/precheck and /harness still work without these, and
  // finding out mid-demo is worse than a line at boot. The route itself still refuses with
  // a 500, so it can never half-work.
  const widenErr = checkWidenEnv(process.env);
  if (widenErr) console.warn(`⚠ /api/widen-plan is unavailable: ${widenErr}`);
});
