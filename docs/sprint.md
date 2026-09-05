# Sprint Plan — Leash

**期間:** 2026-09-04 → 2026-09-14(11 天)
**團隊:** 1 人
**Sprint Goal:**

> 讓一個 AI agent 在鏈上花錢,額度規則存在 ENS 名字底下、agent 改不了;
> agent 靠 subgraph 決定要不要送交易;人類刷臉才能放寬規則,收緊隨時可做。

---

## 假設(不對就告訴我,整份會重算)

| 假設 | 值 | 影響 |
|---|---|---|
| 每日可投入 | **9 小時** | 直接決定能不能做完 |
| 提交截止 | **9/14** | 9/13 必須全部完成,9/14 只留提交 |
| 影片 | 2–4 分鐘,三個賽道共用一支 | 省 4 小時 |

---

## 產能

```
理論產能   11 天 × 9 小時          = 99 小時
有效產能   × 70%(除錯、卡住、重做) = 69 小時
```

**必做項目合計 73 小時。**

> ⚠️ **這是 106% 的產能,buffer 是負的。**
> 標準做法是留 20% buffer(commit 到 55 小時)。我們留不起。
> 所以下面有一份**預先講好的砍單清單** —— 落後時照順序砍,不要臨場才想。

---

## 工作項目

點數 = 小時。`M` = 必做(缺了就拿不到某個獎),`S` = 應做,`X` = 有餘力才做。

| # | 項目 | h | 級別 | 依賴 | 風險 |
|---|---|---|---|---|---|
| 1 | Repo init、foundry、**EIP-7702 在 Sepolia 的可行性驗證** | 4 | M | — | 🔴 未驗證 |
| 2 | **事件 schema 定稿**(寫死在文件裡再動工) | 2 | M | — | 🟡 改動代價高 |
| 3 | `PolicyEngine` + policy 合約(額度、白名單、週期預算) | 6 | M | 2 | 🟢 |
| 4 | `LeashRegistry` —— 實作 ENSv2 `IRegistry` | 5 | M | 2 | 🟡 介面沒範例 |
| 5 | `LeashResolver` —— **只實作 ENSIP-10 `resolve(bytes,bytes)`** | 4 | M | 4 | 🔴 見下方陷阱 |
| 6 | ENS 接線 + 鏈上解析走通(`setResolver`/`setSubregistry`) | 4 | M | 3,4,5 | 🟢 指令已備 |
| 7a | `LeashAccount` —— 執行前強制過 policy 的合約錢包 | 5 | M | 3,6 | 🟢 |
| 7b | 升級成 **EIP-7702 delegate**(EOA 直接被 policy 管) | 5 | **X** | 1,7a | 🔴 工具鏈風險 |
| 8 | `AttesterGate` —— EIP-712 驗證擴權簽章,**介面化雙實作** | 4 | M | 3 | 🟢 |
| 9 | Subgraph:schema + mappings + 部署 Studio + 索引 | 6 | M | 2,6,7a | 🟡 索引要時間 |
| 10 | Agent 決策迴路:查 subgraph → 判斷 → 簽 → 送 | 6 | M | 9 | 🟢 |
| 11 | World:IDKit + 後端驗證 + EIP-712 簽發 | 6 | M† | 8 | 🔴 **外部核准** |
| 12 | 前端單頁 | 5 | M | 8,9,11 | 🟢 |
| 13 | 端對端彩排 + 修 | 5 | M | 全部 | 🟡 |
| 14 | README(公開 repo、架構圖、跑法) | 3 | M | 13 | 🟢 |
| 15 | 影片 2–4 分鐘 | 4 | M | 13 | 🟡 常被壓到最後 |
| 16 | World feedback document 定稿 | 2 | M | 11 | 🟢 已寫大半 |
| 17 | 三個賽道各自提交 | 2 | M | 14,15,16 | 🟢 |

**† 項目 11 卡在外部核准。** 見下方「World 應變」。

**必做合計(不含 7b):73h** · **有效產能 69h**

---

## 日程

| 日 | 日期 | 主軸 | 項目 | h |
|---|---|---|---|---|
| 1 | 9/4 | **先驗證再動工** | 1, 2 | 6 |
| 2 | 9/5 | Policy 核心 | 3 | 6 |
| 3 | 9/6 | ENS 合約 | 4, 5 | 9 |
| 4 | 9/7 | **ENS 走通** ⛳ | 6, 7a | 9 |
| 5 | 9/8 | Subgraph 上線 ⛳ | 9, 8 | 10 |
| 6 | 9/9 | Agent 會思考 ⛳ · **World 死線** | 10 | 6 |
| 7 | 9/10 | World 整合 或 應變 | 11 | 6 |
| 8 | 9/11 | 前端 | 12 | 5 |
| 9 | 9/12 | **端對端跑得動** ⛳ | 13 | 5 |
| 10 | 9/13 | 交件 | 14, 15, 16 | 9 |
| 11 | 9/14 | **只做提交,不寫程式** | 17 | 2 |

⛳ = 里程碑,當天沒到就啟動砍單。

---

## 三個決定性的判斷

### ① 事件 schema 先定稿,再寫合約(項目 2)

Subgraph 吃的是事件。合約寫完才發現事件不夠用,代價是**重新部署 + 重新索引 + 改 mapping + 改 agent 查詢** —— 一次連鎖四層。

**2 小時先把事件寫死在文件裡**,是這整份計畫裡投報率最高的一筆。

至少要有:
```
PolicyResolved(agent, policyAddr, ensNode)
SpendAttempted(agent, payee, token, amount, allowed, reason)
LimitChanged(agent, oldLimit, newLimit, attestationHash)
PayeeAdded(agent, payee, attestationHash)
AgentRevoked(agent, by)
```

### ② Attester 從第一天就介面化(項目 8)

```solidity
interface IAttester { function verify(bytes calldata) external view returns (bool); }
```

兩個實作:`WorldAttester` 和 `MockAttester`。合約只認介面。

**這樣 World 什麼時候到都不痛** —— 核准來了就是換一個地址,30 分鐘的事,不是重寫。
沒來就用 mock,而且在 README 和影片裡誠實說明卡在哪(理由已完整寫在 `world-feedback.md`)。

**這 30 分鐘的設計,買掉整份計畫最大的一個風險。**

### ③ 7702 降級成「先做合約錢包,行有餘力再升級」(項目 7a/7b)

EIP-7702 的故事比較好聽(既有 EOA 直接被 policy 管),但工具鏈風險高,而且**三個獎項沒有一個要求它**。

先做 `LeashAccount`(一般合約錢包,執行前強制過 policy),demo 效果一樣。
7b 列為 stretch,9/12 之前沒把必做做完就直接放棄。

---

## 風險

| # | 風險 | 機率 | 衝擊 | 對策 |
|---|---|---|---|---|
| 1 | **World 核准不來** | 中 | 高 | 介面化雙實作(判斷②)。**9/9 收盤為死線**,沒到就切 mock,不再等 |
| 2 | **ENSv2 resolver 只吃 ENSIP-10** | 已確認 | 高 | 已實測:legacy `addr()`/`text()` **不支援**。只實作 `resolve(bytes,bytes)`,別浪費時間在相容層 |
| 3 | EIP-7702 在 Sepolia 的工具鏈 | 中 | 中 | 第 1 天就驗,不通就砍 7b。不要拖到第 8 天才發現 |
| 4 | Subgraph 索引比預期慢 | 中 | 中 | 9/8 就部署,留 4 天發現問題。**不要等功能全寫完才部署** |
| 5 | 影片被壓到最後一天 | **高** | 高 | 9/13 排整段時間。9/12 端對端就要能跑,影片才有東西拍 |
| 6 | 單人,任何卡住都是全面停擺 | 高 | 高 | 每個里程碑當天沒到就砍單,不要用「明天補回來」自我安慰 |
| 7 | `leash.eth` 一年後過期 | 低 | 低 | 已註冊到 2027-09-02。評審期間內無虞 |

---

## 預先講好的砍單順序

落後時**從上往下砍**,不要臨場開會跟自己辯論:

1. **7b** EIP-7702 升級 —— 已是 stretch,直接放棄 (−5h)
2. **Agent 的第 4 個問題**(「我上次為什麼被擋」)—— 三個問題足以證明 load-bearing (−2h)
3. **前端的 policy 顯示改成直接讀合約**,不走 subgraph —— agent 那邊仍在用,不影響 The Graph 的條件 (−2h)
4. **World → MockAttester** —— 只在核准真的沒來時 (−4h)
5. **測試只留 happy path** —— hackathon 不是產品 (−4h)

砍到第 3 項就回到 62h,低於產能,還有 7h buffer。

---

## Definition of Done

**每個合約:**
- [ ] 部署到 Sepolia,地址記進 `docs/deployments.md`
- [ ] 至少一條 happy path 測試通過
- [ ] 事件與 `docs/events.md` 定稿一致

**整體(9/12 收盤前):**
- [ ] 四幕 demo 從頭到尾跑得動,不用手動介入
- [ ] Agent 真的在查 subgraph,不是讀死資料
- [ ] Policy 位址真的從 ENS 走過來,不是硬編碼
- [ ] 撤銷 agent 的交易能當場執行,不需刷臉

**保本底線(9/14,無論進度如何):**
- [ ] **一定要送出提交。** ETHGlobal 規則:「You must submit your hack before the
      submission deadline. **Partial or incomplete hacks are still eligible for stake
      being returned.**」不送 = 押金沒了 + 三個獎全空。做不完也要送。
- [ ] Team 已建立(單人也要建一人隊,否則無法提交)

**交件(9/13 收盤前):**
- [ ] repo 公開,README 含架構圖與跑法
- [ ] 影片 2–4 分鐘,四幕都拍到
- [ ] `world-feedback.md` 定稿
- [ ] 三個賽道的提交表單各自填好

---

## 每日自問(30 秒,不要跳過)

1. 今天的里程碑到了嗎?沒到 → **現在就砍單**,不是明天
2. World 有回音嗎?9/9 之後這題不再問,直接走 mock
3. 有沒有撞到新的 World 摩擦?→ 當場記進 `world-feedback.md`
