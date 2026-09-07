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

## 一個還沒解開的矛盾(2026-09-07)

四個來源互相打架:

| 來源 | 說什麼 |
|---|---|
| 官方文件 | Selfie Check「currently uses World ID **3.0**, with World ID 4.0 support not yet available」 |
| `precheck` (v1) | `enable_face_check: true`、`can_user_verify: "yes"`、action `active` |
| **v2 verify 端點** | **`invalid_action: Action not found.`** |
| v4 verify 端點 | 認得這個 app,只抱怨缺 `responses`(**沒有**回「尚未遷移到 4.0」) |

v2 對 `expand-policy`、一個不存在的 action、空字串**回完全相同的錯誤**,
所以那不是名字打錯 —— **v2 看不到這個 app 的任何 action**。
配上 v4 認得它,合理的解讀是:**我們的 app 是照 World ID 4.0 RP 開的**
(Portal 上有 RP ID 和 signer address 可以佐證),而 Selfie Check 文件說只支援 3.0。

> 保留一個可能:v2 也許是為了不洩漏 action 清單,才對所有情況回同一個錯誤。
> 那樣的話「Action not found」就只是誤導,不是實情 —— 但那本身也是 feedback 素材。

**這個矛盾從外面問不出答案。** 唯一的決定性測試就是真的跑一次 IDKit。
而那會燒掉唯一的一次驗證 —— 所以上面那件事要先做。

三種可能的結果,各自的下一步:

1. **跑得完** —— 文件的 3.0 說法過時了,改用 v4 驗證。最好的情況。
2. **IDKit 說這個 credential 不可用** —— 需要 World 把 app 降到 3.0,或等
   Selfie Check 的 4.0 支援。這時候才真的需要找 Mateo,而且問題很具體、好回答。
3. **跑得完但後端驗不過** —— 換 v4 的 `responses` 格式重送。

無論哪一種,結果都要記進 `../docs/world-feedback.md`。
「四個官方來源對同一個 app 講四種話」本身就是那份文件裡的好素材。

---

## 之後接 `AttesterGate` 時要改的一件事

現在 `signal` 是一個測試字串。正式接的時候要換成**那筆擴權的 EIP-712 payload hash** ——
這樣一次刷臉只能放寬那一條規則,proof 被攔截也重放不到別的地方。
回應裡的 `nullifier_hash` 是那個人的匿名身分,`AttesterGate` 要記住它才擋得掉重複使用。
