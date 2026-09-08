# Selfie Check 驗證測試

一頁 IDKit + 一支無相依的 node 伺服器。**唯一目的是證明 Selfie Check 真的跑得完一次。**
不是 demo 前端,demo 前端是 sprint 項目 12。

```bash
node server.mjs          # → http://localhost:8787
curl -s localhost:8787/api/precheck | jq   # 設定檢查,不消耗驗證次數
```

`app_id` / `action` 有寫死的預設值(app_id 本來就會出現在前端,不是秘密),
要覆寫就設 `WORLD_APP_ID` / `WORLD_ACTION`。

---

## 🔴 跑之前一定要先做的事

Portal → `expand-policy` → **max verifications 改成 0(unlimited)**。

預設是 `1` —— 每個人一輩子只能驗一次。**第一次會成功,所以當下看不出問題**;
等你錄影片刷一次、live demo 再刷一次,第二次直接失敗,nullifier 已經燒掉,不能重置。

現在只要跑一次這個測試,那唯一的一次就沒了。

---

## ✅ 實測走通了(2026-09-07)

```
刷臉 → World App 產出 proof → 後端 POST v4 → HTTP 200 "Proof verified successfully"
```

**四個官方來源對同一個 app 講四種話,只有實測分得出誰對:**

| 來源 | 說什麼 | 對嗎 |
|---|---|---|
| 官方文件 | Selfie Check 只跑 3.0,「4.0 support not yet available」 | 半對 —— **proof 是 3.0 格式,但驗證要送 v4** |
| `precheck` (v1) | `enable_face_check: true` | ✅ 對 |
| v2 verify | `invalid_action: Action not found.` | ❌ **拿真 proof 打也一樣**。這個 app 是 4.0 RP,v2 看不到它的 action |
| v4 verify | 「Verifies World ID 4.0 proofs **and legacy 3.0 proofs**」 | ✅ **這條才對** |

### 正確的做法

`POST https://developer.worldcoin.org/api/v4/verify/{rp_id}`,包成 `VerifyV4LegacyProofRequest`。
**IDKit 回傳的欄位不能照原樣送**,三處要動:

| 動作 | 欄位 |
|---|---|
| 改名 | `nullifier_hash` → `responses[].nullifier` |
| **拿掉** | `credential_type`、`verification_level`(v4 不收) |
| 補上 | `protocol_version: "3.0"`、`nonce`、`environment` |

> 諷刺的是 v4 文件寫「Forward the complete IDKit result **without remapping response
> identifiers**」—— 但實際上非改名不可,`nullifier_hash` 直接送會被拒。

### 另外兩個實測結論

**IDKit 不會送 `signal_hash`,後端一定要自己算。** `keccak256(signal) >> 8`
(右移是為了讓值落在 SNARK 的 field 內)。
**不能用 node 內建的 `crypto.createHash("sha3-256")`** —— SHA3 和 keccak256 的
padding 不同,算出來的值不一樣,World 會拒絕。驗算基準:
`signal_hash("")` 必須等於 `0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4`。

**nullifier 是決定性的。** 同一個人 + 同一個 action = 同一個 `nullifier_hash`,
跨次數完全相同(實測兩次都是 `0x04a2cce3…`)。這就是 `AttesterGate` 要記的匿名身分。

### ⚠️ proof 裡看不出這是 Selfie Check

`credential_type` 和 `verification_level` 都是 `"device"` —— **沒有 `selfie`,沒有 `face`。**

也就是說:「這是一張真人的臉做的」這個保證**不在 proof 裡**,而在 app 設定的
`enable_face_check: true` 上。後端拿到 proof **分不出**「剛做完臉部檢查」和
「舊的、已被 deprecate 的裝置憑證」。

對 Leash 來說這一點必須誠實講:我們的論點是「擴權綁在真人身上」,
而那個綁定的強度來自 app 設定,不是密碼學上的憑證型別。

---

## 之後接 `AttesterGate` 時要改的一件事

現在 `signal` 是一個測試字串。正式接的時候要換成**那筆擴權的 EIP-712 payload hash** ——
這樣一次刷臉只能放寬那一條規則,proof 被攔截也重放不到別的地方。
回應裡的 `nullifier_hash` 是那個人的匿名身分,`AttesterGate` 要記住它才擋得掉重複使用。
