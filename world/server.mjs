// Leash · Selfie Check 驗證測試伺服器
//
// 只有兩個路由:靜態頁面,和把 proof 轉給 World 驗證的後端。
// 沒有相依套件 —— node 內建的 http 和 fetch 就夠了,這支跑完就丟。
//
// 為什麼驗證一定要在後端:proof 在前端「看起來成功」不代表任何事,
// 前端可以被改。真正算數的是 World 的伺服器說 yes,而那個回應
// 之後會變成 AttesterGate 要簽的 EIP-712 內容。

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { keccak_256 } from "@noble/hashes/sha3";
import { randomBytes } from "node:crypto";

const PORT = Number(process.env.PORT || 8787);
const APP_ID = process.env.WORLD_APP_ID || "app_452654c9c277c08df71fec3315501c00";
const ACTION = process.env.WORLD_ACTION || "expand-policy";
const RP_ID = process.env.WORLD_RP_ID || "rp_ef35d4e2d4f1a031";

// Selfie Check 產出的是 World ID **3.0** 格式的 proof(官方原文:「Currently uses
// World ID 3.0 technology, with World ID 4.0 support not yet available」),
// 但驗證要送去 **v4** 端點 —— 這是 2026-09-07 拿真 proof 實測出來的,不是文件寫的。
//
// v2 (`/api/v2/verify/{app_id}`) 對這個 app **永遠**回
// `invalid_action: Action not found.` —— 真 action、假 action、空字串全都一樣,
// 拿真 proof 打也一樣。它看不到我們的 action,因為這個 app 是照 4.0 RP 開的。
//
// v4 的文件說它「Verifies World ID 4.0 proofs **and legacy 3.0 proofs**」,
// 並吃 `rp_id`。3.0 的 proof 要包成 `VerifyV4LegacyProofRequest` 送。
const VERIFY_URL = `https://developer.worldcoin.org/api/v4/verify/${RP_ID}`;

/**
 * World ID 的 signal hash:keccak256(signal) 右移 8 bits。
 * 右移是因為 proof 在 SNARK 體系裡要落在 field 之內,keccak 的 256 bits 會溢出。
 *
 * @dev **實測(2026-09-07):IDKit 回傳的 proof 裡沒有 `signal_hash`。**
 *      所以這不是備援路徑,是必經之路 —— 後端一定要自己算。第一次跑就是倒在這裡:
 *      `@noble/hashes` 沒裝 → 500 → World App 顯示「Verification Declined」,
 *      看起來像 World 拒絕了我們,其實是我們自己的後端掛掉。
 *
 *      注意不能用 node 內建的 `crypto.createHash("sha3-256")` —— SHA3 和 keccak256
 *      的 padding 不同,算出來的值不一樣,World 會拒絕。
 *
 *      之後接 AttesterGate 時,signal 要換成那筆擴權的 EIP-712 payload hash ——
 *      這樣一次刷臉只能放寬那一條規則,proof 被攔截也重放不到別的地方。
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

    // Portal 沒有任何介面顯示 credential 開通狀態,precheck 是唯一問得到的地方。
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

      // 3.0 的 proof 包成 v4 的 legacy 請求。**欄位名字要改**:
      //   nullifier_hash → responses[].nullifier
      // 而 credential_type / verification_level **不能送** —— v4 不收這兩個。
      const payload = {
        protocol_version: "3.0",
        nonce: "0x" + randomBytes(16).toString("hex"),
        action: action ?? ACTION,
        environment: "production", // app 是 is_staging: false
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

      console.log("\n← IDKit 回傳的完整 proof:");
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

      // nullifier_hash 就是「這個人」的匿名身分。之後 AttesterGate 要記住它,
      // 才知道同一個人有沒有重複用同一次刷臉。
      return json(res, r.status, { http_status: r.status, ...body });
    }

    json(res, 404, { error: "not found" });
  } catch (err) {
    console.error(err);
    json(res, 500, { error: String(err?.message ?? err) });
  }
});

// 只綁 loopback。這台有公網 IP,綁 *:8787 等於開一個公開代理 ——
// 沒有秘密會外洩(precheck 本來就公開,verify 只是轉發),但沒必要。
// SSH tunnel 打到的就是 localhost,所以完全不影響使用。
server.listen(PORT, "127.0.0.1", () => {
  console.log(`\n  Leash · Selfie Check 驗證測試`);
  console.log(`  http://localhost:${PORT}\n`);
  console.log(`  app_id  ${APP_ID}`);
  console.log(`  action  ${ACTION}`);
  console.log(`  rp_id   ${RP_ID}`);
  console.log(`  verify  ${VERIFY_URL}\n`);
  console.log(`  設定檢查:curl -s localhost:${PORT}/api/precheck\n`);
});
