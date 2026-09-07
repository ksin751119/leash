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
import { createHash } from "node:crypto";

const PORT = Number(process.env.PORT || 8787);
const APP_ID = process.env.WORLD_APP_ID || "app_452654c9c277c08df71fec3315501c00";
const ACTION = process.env.WORLD_ACTION || "expand-policy";

// Selfie Check 目前跑 World ID **3.0**,官方原文:「Currently uses World ID 3.0
// technology, with World ID 4.0 support not yet available.」
// 所以驗證要走 v2 端點吃 app_id,不是 v4 吃 rp_id —— v4 會回
// 「This app has not been migrated to World ID 4.0. Please use the v2 verify endpoint」。
const VERIFY_URL = `https://developer.worldcoin.org/api/v2/verify/${APP_ID}`;

/**
 * World ID 的 signal hash:keccak256(signal) 右移 8 bits。
 * 右移是因為 proof 在 SNARK 體系裡要落在 field 之內,keccak 的 256 bits 會溢出。
 * @dev 之後接 AttesterGate 時,signal 要換成那筆擴權的 EIP-712 payload hash ——
 *      這樣一次刷臉只能放寬那一條規則,proof 被攔截也重放不到別的地方。
 */
function hashSignal(signal) {
  if (!keccak) throw new Error("IDKit 沒送 signal_hash,而 @noble/hashes 沒裝:npm i @noble/hashes");
  const { keccak_256 } = keccak;
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

      const payload = {
        nullifier_hash: proof.nullifier_hash,
        merkle_root: proof.merkle_root,
        proof: proof.proof,
        verification_level: proof.verification_level,
        action: action ?? ACTION,
        signal_hash: proof.signal_hash ?? hashSignal(signal ?? ""),
      };

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

// keccak 只在 hashSignal 用得到,而 IDKit 通常已經把 signal_hash 一起送來了。
// 動態載入:沒裝也不影響主路徑。
let keccak = null;
try {
  keccak = await import("@noble/hashes/sha3");
} catch {
  console.warn("⚠️  @noble/hashes 沒裝 —— 只有 IDKit 沒送 signal_hash 時才會用到");
}

server.listen(PORT, () => {
  console.log(`\n  Leash · Selfie Check 驗證測試`);
  console.log(`  http://localhost:${PORT}\n`);
  console.log(`  app_id  ${APP_ID}`);
  console.log(`  action  ${ACTION}`);
  console.log(`  verify  ${VERIFY_URL}\n`);
  console.log(`  設定檢查:curl -s localhost:${PORT}/api/precheck\n`);
});
