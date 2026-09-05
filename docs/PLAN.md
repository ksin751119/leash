# ETHOnline 2026 — 專案總覽

> 狀態:規劃中。**2026-09-04 之前不得撰寫任何專案程式碼**(Start from Scratch 賽道規定)。
> 本目錄的文件為設計與研究筆記,不屬於「程式碼」,規則允許。

---

## 一句話

**給 AI agent 一張公司信用卡 —— 額度寫在鏈上,agent 改不了,公司隨時可以剪卡。**

## 問題

AI agent 開始能動錢了,但目前的做法只有兩種,都不好:

1. **把私鑰交給 agent** —— 它想做什麼就做什麼,沒有任何約束
2. **每一筆都要人簽名** —— 那就不叫自動化了

現有的中間方案(session key、允許清單、Zodiac Roles、ERC-7579 modules)全部把權限表達成**設定值**:
可以呼叫哪些位址、哪些 selector、上限多少。設定值撐不起「這筆該不該花」這種判斷。

## 我們的答案

**把權限表達成程式碼(policy as code),在鏈上執行。**

- 每個 agent 綁一份 **policy 合約**
- agent 送交易時,EIP-7702 delegate 先 `delegatecall` 那份 policy
- policy 回傳 false → 整筆 revert
- **agent 沒有繞過的路徑**,因為檢查發生在它自己的執行流程裡

policy 是一份完整的 smart contract,不是一張設定表。它想怎麼判斷都行 ——
看金額、看對象、看時間、看歷史累計、看鏈上狀態。

## 為什麼 ENS 是骨架而不是裝飾

policy 的**位址從 ENS 解析出來**。7702 delegate 每次執行都要走一次:

```
RootRegistry.getSubregistry("eth")
  → ETHRegistry.getSubregistry("acme")
    → AcmeRegistry.getResolver("vendors")
      → resolver.resolve(dnsName, text(node, "policy"))
        → policy 合約位址
          → delegatecall
```

**拿掉 ENS,delegate 解不出 policy,交易直接 revert。**

而且這條路徑帶來三層撤銷手段(全部一筆交易):

| 層級 | 動作 | 效果 |
|---|---|---|
| 輕 | 改 resolver 上的 policy 記錄 | 換一條更嚴的規則 |
| 中 | 收回 `vendors.acme.eth` 子名 | 這一個 agent 死 |
| **重** | `ETHRegistry.setSubregistry("acme", 新 registry)` | **全部 agent 同時死** |

再加上 ENSv2 `Entry` 原生的 `expiry` —— agent 的名字可以只發 24 小時,
到期自動失效,續期要人。免費的 dead-man's switch。

---

## 架構

```
                    ┌─────────────────────────────┐
                    │  ENSv2 (Sepolia)            │
                    │  acme.eth                   │
                    │   └─ 自訂 PermissionedRegistry│
                    │       ├─ vendors.acme.eth   │──┐
                    │       ├─ payroll.acme.eth   │  │ policy 位址
                    │       └─ subs.acme.eth      │  │ 存在 resolver 記錄
                    └─────────────────────────────┘  │
                                  ▲                  ▼
                     Selfie Check │          ┌───────────────┐
                     才能「擴權」  │          │ Policy 合約   │
                                  │          │ (stateless)   │
                    ┌─────────────┴───┐      └───────┬───────┘
                    │  人類 / 組織     │              │ delegatecall
                    └─────────────────┘              │
                                                     │
   ┌──────────┐   MCP    ┌──────────────┐   tx   ┌───┴────────────┐
   │ AI Agent │ ───────▶ │ MCP Server   │ ─────▶ │ EIP-7702       │
   └────┬─────┘          └──────┬───────┘        │ delegate (EOA) │
        │                       │                └────────────────┘
        │  查詢額度/歷史/被擋原因  │
        ▼                       ▼
   ┌─────────────────────────────────┐
   │  Subgraph (The Graph)           │
   │  索引 policy 註冊 + 每一次執行    │
   └─────────────────────────────────┘
```

### 金鑰模型(關鍵)

- **人類持有 EOA 主金鑰** —— 可以無視 policy(這是刻意的,人是最終權威)
- **agent 持有 session key** —— 一切都要過 policy

如果 agent 拿到主金鑰,整套強制機制歸零。這點必須在 README 講清楚。

---

## Demo(四幕,約 3 分鐘)

| 幕 | 內容 | 對應 sponsor |
|---|---|---|
| **1 · 正常** | agent 付廠商 $200。查 subgraph:額度夠、付過這對象 → policy 通過 → 上鏈 | The Graph |
| **2 · 擋下** | agent 要付**全新地址 $5,000**。subgraph 說沒看過這對象、超過月額度。**就算 agent 程式被改掉硬送,鏈上照樣 revert** | 核心論點 |
| **3 · 真人放行** | 人類確認這筆是真的 → **Selfie Check** → 更新 ENS 上的 policy → agent 重送成功 | World |
| **4 · 全滅** | `setSubregistry` 一筆交易 → **全公司 agent 同時停機**,全程沒碰 agent 帳戶 | ENS |

**每一家 sponsor 各自擁有一幕。** 評審看影片不用猜我們在幹嘛。

### 擴權 / 縮權的不對稱(設計重點)

| 動作 | 要 Selfie Check |
|---|---|
| 開新 agent 子名 | ✅ 要 |
| 調高額度 | ✅ 要 |
| 加新白名單收款人 | ✅ 要 |
| **撤銷 agent / 調低額度** | ❌ **不要** |

被入侵的 agent 最想做的就是幫自己註冊更寬鬆的規則,所以「擴權」必須綁在真人身上。
但「縮權」永遠不該被擋 —— 出事時你不會想先找手機刷臉。

---

## 賽道與獎項

**Start from Scratch**(已於報名時選定,**不可更換**)。

因為交付物是 100% 全新程式碼。`tx-approver`(`/home/ubuntu/DEV/tx-mcp`)只是動機與 prior art,
**程式碼不重用**,且其 commit 全部是 2026-07-15,本來也不符合 Classic。

鎖定三個 partner prize(上限 3 個),全部在 **Sepolia**,一條鏈搞定:

| Sponsor | 金額 | 名額 |
|---|---|---|
| ENS — Best Use of ENSv2 | $4,500 | 4(含 Runner-Up $500) |
| The Graph — Best AI Tooling (From Scratch) | 1st $2,500 / 2nd $1,500 / 3rd $1,000 | 3(排名) |
| World — Selfie Check | $3,500 | 未公布 |

**已排除**:
- **Hedera x402**($6,000)—— 其 exact scheme 要求付款方簽一筆原生 `TransferTransaction`,
  Hedera 合約帳戶沒有能簽原生交易的金鑰 → **我們的 policy 錢包不能當付款方**,
  policy 層會在自己的 demo 裡消失。另外 Hedera 沒有 EIP-7702,The Graph 也沒有 hosted service。
- **Arc**($2,500 起,split evenly)—— 三條賽道全部強制 frontend + backend + 架構圖 + 簡報,
  又要第二條鏈與 Circle Agent Stack。**唯一一個要為它額外做東西的**,獎金還會被稀釋。

細節見 `prizes.md`。

---

## 風險

| 風險 | 嚴重度 | 對策 |
|---|---|---|
| ENSv2 審計期(8/18–9/14)重新部署,位址變動 | 中 | 位址集中在單一 config,別散落 |
| ENSv2 是 Beta,可能有 bug | 中 | 這反而是 World/ENS 想要的 feedback 素材 |
| 7702 delegate 實作是全新領域 | 高 | 最先做、留最多時間 |
| 三個 sponsor 整合 + 影片 + feedback 文件 | 中 | 第 8 天必須凍結功能 |

### 已排除的風險

- ~~ENSv2 解析需要 CCIP-read,合約讀不到~~ → **實測排除**,見 `ensv2-sepolia.md`

---

## 時程(9/4 開工)

| 天 | 內容 |
|---|---|
| 1–2 | PolicyRegistry + policy 合約介面 + 第一份 policy(額度/白名單) |
| 3–4 | **EIP-7702 delegate**,ENS walk 解析 policy(最高風險,先做) |
| 5 | Subgraph:索引註冊事件與每次執行 |
| 6 | MCP server:agent 端,查 subgraph 做決策 |
| 7 | Selfie Check + 極簡前端(只有刷臉與改額度兩件事) |
| 8 | **凍結功能**。錄影、README、World feedback 文件 |
| 9 | 緩衝 / 提交 |

---

## 待決事項

- [x] ~~註冊哪個 ENS 名字~~ → **`leash.eth`**,8.000021 USDC/yr,2026-09-02 實測仍可用
- [x] ~~付款用什麼代幣~~ → **MockUSDC**(ENS 註冊本來就要用,不多引入一個東西)
- [x] ~~World Selfie Check Sandbox App 的實際流程~~ → 已研究,見 `prep-checklist.md` 步驟 4
- [x] ~~前端做到什麼程度~~ → **一頁,不做第二頁**(2026-09-02 定案)

### 前端範圍(定案,不再擴大)

單一頁面,三個區塊:

| 區塊 | 內容 |
|---|---|
| **目前 policy** | 從 subgraph 讀:額度、已用、白名單收款人、agent 清單 |
| **提高權限** | 改額度 / 加收款人 / 開新 agent → **一律先過 Selfie Check** |
| **降低權限** | 撤銷 agent / 調低額度 → **不刷臉,一鍵執行** |

**不做的:** 登入系統、多帳號、交易歷史頁、設定頁、行動版最佳化(桌機 + 手機掃 QR 即可)。

**為什麼壓到一頁:**

1. 這一頁就把 demo 的核心對比講完了 —— 擴權要刷臉、縮權不用。多一頁只是稀釋它。
2. World 目前卡在外部核准。萬一到 demo 前都沒通,**一頁式最容易換成降級版**(mock attester),換掉一個按鈕的行為就好。
3. 三個賽道的評分項裡,只有 World 需要看得到畫面。ENS 和 The Graph 看的是鏈上與 subgraph。

## v2 方向:控制平面 / 執行平面分離(不在本次範圍)

> 2026-09-04 討論結論。**這次不做**,只寫進 README 與 demo 最後一頁。

### 觀察

Leash 同時在做兩件事,而它們對「鏈」的需求相反:

| 層 | 做什麼 | 想要的鏈 |
|---|---|---|
| **控制平面** | 規則放哪、誰能改、真人簽核 | 要有 ENS(名字即指標)、要有 World ID。**只有 Ethereum 有** |
| **執行平面** | 錢在哪、每筆轉帳被檢查 | 要便宜、要快、要確定性終局、流量本身就是支付 |

我們把金鑰拆成 ADMIN / WALLET / AGENT 三把時,**ADMIN 與 WALLET 之間那條線,就是這兩個平面的切線**。
架構已經是這個形狀了,只是目前兩邊都跑在 Sepolia 上。

### 支付鏈(如 Circle Arc)帶來什麼

1. **gas 就是 USDC** → 補掉下面那個洞(見「已知缺口」)。一條 spend cap 真的封死全部支出,含手續費。
2. **確定性終局** → 「今日已花 X」這個累加器不必處理 reorg 造成的重複計 / 漏計。
3. **鏈上流量本來就是支付** → policy engine 的價值與「多少 tx 是轉帳」成正比。

### 為什麼不整套搬過去

支付鏈上**沒有 ENSv2 registry**,也沒有 World ID。搬過去等於砍掉控制平面,
剩下的是「一個會擋超額轉帳的合約」—— 那個不特別,而 Leash 一半的價值在控制平面。

正確的形狀不是搬家,是**兩邊各放各的**:名字 / 權限 / 真人簽核留 Ethereum,錢與高頻檢查放支付鏈。

### 已知缺口:gas 不在 policy 管轄內

**目前設計管的是 USDC 轉帳,但 WALLET 付 gas 燒的是 ETH,policy 完全碰不到。**
嚴格講「每日上限 100 USDC」是不完整的 —— agent 可以在失敗迴圈裡把 ETH 燒光。

**本次的處置(要做,成本近乎零):** WALLET 只放剛好夠 demo 的 ETH,不一次灌滿;
在 README 誠實寫出這個邊界,並指向 v2 的解法(gas 與 spend 同幣種)。

### 為什麼這次不做

`prizes.md`(2026-09-01)已評估過 Arc 獎項:三條賽道全部強制要前端、Track 2 要整套
Circle Agent Stack、獎金 split evenly 不封頂。**是所有候選裡唯一「要為它額外做東西」的。**
距交件 10 天,多一條鏈即為超載。

賽後再議 —— Circle 自有 hackathon 與 grant,屆時不趕。

## 阻塞項

| 項目 | 送出日 | 卡住誰 | 備援 |
|---|---|---|---|
| World Selfie Check feature flag(email) | 2026-09-02 | World demo 全線 | 9/5 沒回音就開 Discord 第三條線 |
| World Sandbox 存取(表單) | 2026-09-02 | Sandbox App 安裝 | iOS TestFlight 是公開連結,可先裝 |

**沒有 World 也能做完的部分:** 合約、ENS 接線、subgraph。
建置順序照這個排,把 World 留到最後接,回信時間就不在關鍵路徑上。

開工前的完整準備步驟見 **`prep-checklist.md`**。
