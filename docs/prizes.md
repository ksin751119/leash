# 獎項條件與對應

> 條件擷取自 ETHGlobal ETHOnline 2026 各 sponsor 的獎項頁面(2026-09-01,2026-09-07 複查)。
> 提交上限 **3 個** partner prize。
>
> ⚠️ **2026-09-07 查到的規則:同一個 sponsor 的多條賽道,只算一個 partner prize 名額。**
> 原文:「If a partner offers multiple tracks, applicants can qualify for all while
> only counting as a single partner prize selection.」
> → 選了 The Graph,它三條賽道我們符合哪條就都能拿,**不多花名額**。
> → ENS 第二條(Best Integration into Existing Project, $500)是 **Continuity only**,我們用不到。
> → World 第二條(AgentKit, $3,500)也是 **Continuity only**,用不到。

---

## ✅ ENS — Best Use of ENSv2 · $4,500

**名額 4 個**:1st $1,500 / 2nd $1,500 / 3rd $1,000 / Runner-Up $500

| 條件 | 我們的對應 |
|---|---|
| Must be built on **ENSv2 (Sepolia)** | ✅ 本來就在 Sepolia |
| **ENSv2 features central to the product, not a cosmetic add-on** | ⚠️ 見下方 |
| Demo 必須能跑,不能是 hard-coded values | ✅ |
| Open source + 影片或 live demo(兩者皆有更佳) | ✅ |
| **Bonus: incorporating AI agents as namespaces** | ✅✅ 整個專案就是這件事 |

它點名的功能:hierarchical registry、wildcard resolution、**Enhanced Access Control**、
**Permissioned Resolvers**、record/namespace aliasing、subname ecosystems。

### 怎麼算 central 而非 cosmetic

**裝飾版**:agent 有個 ENS 名字,好看。→ 拿不到獎。

**Central 版**:**ENS 是 policy 的查找路徑本身**。7702 delegate 每次執行都要走 registry walk
才能解出 policy 位址。拿掉 ENS,交易 revert。

再加上三層撤銷(改記錄 / 收子名 / `setSubregistry` 全滅)與原生 `expiry`,
**四種撤銷手段全部來自 ENSv2 原生功能**。

### 對應到它點名的功能

| ENS 點名的 | 我們用在哪 |
|---|---|
| Hierarchical registry | 公司是母名,agent 是子名,`acme.eth` 掛自訂 registry |
| Enhanced Access Control | 資安團隊有「可撤銷」role,沒有「可花錢」role |
| Permissioned Resolvers | policy 指標存在 resolver,誰能改由 EAC 控制 |
| Subname ecosystems | 一間公司多個 agent,各有額度 |
| AI agents as namespaces | ✅ bonus |

---

## ✅ The Graph — Best AI Tooling or AI Use Case (From Scratch)

**1st $2,500 / 2nd $1,500 / 3rd $1,000**(排名制)

| 條件 | 我們的對應 |
|---|---|
| **Use The Graph as a load-bearing part** | ⚠️ 見下方 |
| 必須吃 **live data**(Subgraph Studio 或 The Graph Market),**不可 mock/本地資料** | ✅ 索引我們自己合約的真實事件 |
| **Do meaningful work with the data**:reasoning、decisions、automation 或 NL interface | ✅ 四者中三者 |
| **Must be net-new work begun during hackathon** | ✅ Start from Scratch |
| Open source + 清楚 README + 公開 repo + **2–4 分鐘影片** | ✅ |

### 怎麼算 load-bearing

**弱版**:做個 dashboard 顯示歷史。→ 它明說「單純查一個 subgraph」不夠。

**強版**:**agent 自己去查 subgraph 來做決策**。動手前先問:

1. 這個月我還剩多少額度?
2. 這個收款地址,公司以前付過嗎?第一次出現要更小心
3. 全公司三個 agent 加起來花了多少?(單一 policy 合約看不到別人的)
4. 我上次被擋是為什麼?

**policy 合約管的是單筆;跨時間、跨 agent 的視角只有 subgraph 有。**
拿掉 subgraph,agent 是瞎的,只能亂送然後被鏈上擋。

→ reasoning ✅ decisions ✅ automation ✅

### 另一條(不選)

**Track 1: Best Use of Composable or Standardized Graph Products**($5,000,1st/2nd/3rd)
—— 要求「compose 兩個以上 Graph 產品」或「建立在 standardized schema 上」。

**2026-09-07 重新評估:** 因為同一 sponsor 的多賽道只算一個名額,**投它是零名額成本**。
但仍然不主動為它做東西 —— 如果主線做完還有時間,再看要不要多接一個 Graph 產品
(例如 Token API)湊 composable。**列為 9/12 之後的 stretch,不排進工時。**

---

## ✅ World — Selfie Check · $3,500

**名額 3 個,每隊 $1,166**(2026-09-07 查證,原本未公布)

| 條件 | 我們的對應 |
|---|---|
| Uses Selfie Check(或相容的 World ID credential flow)**in a meaningful way** | ✅ 擴權的唯一入口 |
| 當成 **risk / eligibility / fairness / continuity / abuse-prevention signal** | ✅ **abuse-prevention**,逐字對上 |
| 用 **World ID Sandbox App** 遠端測試與 demo | ⚠️ 要學,**尚未研究** |
| 交 **feedback document**(整合經驗、Developer Portal、Sandbox 狀態、遇到的阻力) | ⚠️ 額外作業 |
| Demonstrate a working application | ✅ |

### 切入點:只有「放寬權限」要刷臉

| 動作 | Selfie Check |
|---|---|
| 開新 agent 子名 | ✅ 要 |
| 調高額度 | ✅ 要 |
| 加新白名單收款人 | ✅ 要 |
| **撤銷 agent / 調低額度** | ❌ **不要** |

**理由很硬**:被入侵的 agent 最想做的就是幫自己註冊更寬鬆的規則。
把「改規則」鎖在真人身上,正是 abuse-prevention 的教科書用法。
而「縮權」不該被擋 —— 出事時你不會想先找手機刷臉。

### 兩道門,別搞混(2026-09-01 查證)

Selfie Check 要跑起來,**要過兩關,申請管道不同**:

| 關卡 | 管道 | 內容 | 出處 |
|---|---|---|---|
| **1. Sandbox App 安裝權** | **Google 表單** https://forms.gle/mqbaiwMvX5MzmKdY8 | 表單名「World ID Sandbox Beta Access Request」,只問 email,給的是 **Firebase App Distribution** 權限 | ETHGlobal World 獎項頁 → Resources → Sandbox Access |
| **2. Selfie Check (Beta) feature flag** | **Email** developers@toolsforhumanity.com | 要附 app_id,由 World 幫你的 app 開旗標 | docs.world.org 三頁都有寫 |

**表單不會幫你開 feature flag** —— 它只問 email,沒問 app_id,而且明講是 Firebase App Distribution。
兩個都要送。

feature flag 這關在官方文件出現三次:

* `world-id/idkit/credentials#selfie-check-beta` — 「[Request access](mailto:developers@toolsforhumanity.com) to enable Selfie Check (Beta) for your app.」(**這頁 ETHGlobal 獎項頁直接連過去**)
* `world-id/credentials/11` — 「Selfie Check (Beta) is access-gated. To use it, request access so the feature flag can be enabled for your app.」
* `world-id/sandbox/testing-selfie-check` — 「Selfie Check (Beta) must be enabled for your app before you can test it.」

三處都是 Mintlify `<Warning>` 元件,在網頁上是彩色告示框,容易掃過去。
把任何 docs.world.org 網址加上 `.md` 就拿得到原始 markdown。

### 評分權重(2026-09-07 從官方 workshop 錄影抄下來)

Mateo Sauton(Tools for Humanity)在 ETHGlobal × World workshop 上逐項唸出來的:

| 權重 | 項目 |
|---|---|
| **30%** | strategic fit —— 這個整合對 World 的產品有沒有意義 |
| **25%** | **feedback 文件的品質** ←「don't be nice」,他明講要聽壞話 |
| 20% | product quality |
| 15% | technical integration（IDKit / AgentKit 有沒有正確接) |
| 10% | 賽後會不會繼續做 |

**feedback 文件佔四分之一,不是附帶作業。** `world-feedback.md` 的優先級要往上調 ——
它跟前端同等重要,而且我們手上有真實素材(五天沒回信、三頁文件三種說法、命名誤導)。

10% 那條用 `PLAN.md` 的 v2 章節回答:控制平面/執行平面分離、一次性批次授權。

### 明講不給獎的東西(我們都不是,但記著)

- 沒有端對端整合的 static demo
- 單純的 agent reputation(看太多了)
- 只是「給 agent 打折」的電商 demo(他們自己做過)

他要的是 **new verticals**。我們的切角(擋 agent 錢包的擴權)不在這張排除清單上。

### 一個會浪費半天的命名陷阱

IDKit 裡兩個 credential 的標籤是反直覺的:

| SDK 標籤 | 實際是什麼 |
|---|---|
| **`selfieCheckLegacy`** | **Selfie Check ← 我們要用的就是這個** |
| `proofOfHuman` | Orb 驗證(高保證) |
| `passport` | NFC 護照 |
| `identityCheck` | 證件屬性(年齡、國籍…) |
| `orbLegacy` / `secureDocumentLegacy` / `documentLegacy` | World ID 3.0 舊 preset |
| `deviceLegacy` | 已 deprecated,官方叫你改用 Selfie Check |

「legacy」看起來像被淘汰的,但它才是對的。**別選 `proofOfHuman`。**
(2026-09-07 從官方 credentials 頁核對:錄影裡唸的是口語,SDK 裡實際是 camelCase。
`deviceLegacy` 被 deprecate、官方指向 Selfie Check —— 這解釋了「legacy」為什麼會
出現在正確答案上。)

> ⚠️ **Selfie Check 目前跑 World ID 3.0,不是 4.0。** 官方原文:「Currently uses
> World ID 3.0 technology, with World ID 4.0 support not yet available.」
> 後果:v4 的 `rp_context`(後端先簽 RP signature)**用不到**,後端驗證要走
> **v2 端點吃 `app_id`**,不是 `/api/v4/verify/{rp_id}`。
V3 / V4 proofs 都可以用。

### 注意

World 的另一條 **AgentKit** 賽道($3,500)寫明 **Continuity only**,我們不能碰。
workshop 另外確認:**AgentKit 只吃 Orb 驗證的 World ID,Selfie Check 不能拿來註冊 AgentBook**
—— 所以就算是 From Scratch 也接不上,排除的判斷是對的。
Selfie Check 沒有這個限制。World 總獎金池 $7,000,兩個賽道各半。

**代價**:多一份 feedback 文件。反過來看,要交作業的賽道通常投的人少。

---

## ❌ 已排除:Hedera x402 · $6,000

原本最吸引人的一條($6,000,3 個固定名額 × $2,000),但**架構上接不起來**。

Hedera 的 exact scheme **不是** EVM 的 EIP-3009,而是原生 `TransferTransaction`。
規格原文:

> The decompiled transaction MUST be a `TransferTransaction` **directly**.
> It MUST NOT be wrapped in a `ScheduleCreateTransaction`.

流程:客戶端用**自己的金鑰**簽一筆部分簽名的 `TransferTransaction`
→ facilitator 以 fee payer 身分補簽 → 送出。

**問題:付款方必須是能用金鑰簽名的 Hedera 帳戶。Hedera 合約帳戶沒有這種金鑰。**

→ **我們的 policy 錢包不能當付款方。** agent 得從一個不受管的帳戶付錢,
policy 層完全不在迴路上 —— 專案會在自己的 demo 裡消失。

(理論上 Hedera 有「contract ID 當 account key」的機制可能有路,
但那是完全沒人走過的領域,不是 solo 9 天該賭的。)

### 另外兩個摩擦

- **Hedera 沒有 EIP-7702** —— HIP-1341 Approved 但未上線;
  hiero-consensus-node#20043 仍 OPEN,卡在 Besu 25.4.1,無時程
- **The Graph 在 Hedera 沒有 hosted service** —— 官方文件要求自架 graph node,或改用 Goldsky

### 但 x402 本身我們用得上

EVM 版的 x402 **支援合約錢包** —— 參考實作有完整的
**ERC-1271**(已部署)+ **EIP-6492**(counterfactual)簽名驗證。
只是那個提交不會投給 Hedera。目前不列入範圍。

---

## ❌ 已排除:Arc · $2,500 / $2,500 / $5,000(全部 split evenly)

概念其實很合(Track 2 Best Agentic Economy 講的就是自主 agent 帶 USDC 錢包做交易),
Arc 也有 EIP-7702、USDC 就是 gas。**但成本結構不對。**

| 條件 | 問題 |
|---|---|
| **Functional MVP with working frontend, backend, and architecture diagram** | ❌ 三條賽道**全部**強制要前端 |
| Track 2 要 **Circle Agent Stack** | ❌ 要學一整套新的 Circle 產品 |
| Track 3 要 9/30 前 **deployed or deployment-ready on Arc mainnet** | ⚠️ 多一條鏈 |
| 影片 + 簡報 + 詳細文件 | ⚠️ 比別家多 |
| split evenly | ⚠️ 名額不封頂,交的人越多分越少 |

**Arc 是四個候選裡唯一一個「要為它額外做東西」的。**
前三個都是把已經要做的東西換個角度講。

---

## 總結

| | 契合度 | 額外成本 | 名額 | 鏈 |
|---|---|---|---|---|
| **ENS** | 天生就是 | 把 ENS 做進解析路徑 | 4 | Sepolia |
| **The Graph** | 高 | 讓 agent 真的去查 | 3(排名) | Sepolia |
| **World** | 需要接,理由很硬 | 新 SDK + feedback 文件 | 3(各 $1,166) | 鏈無關 |
| ~~Hedera~~ | **架構衝突** | — | 3 | — |
| ~~Arc~~ | 概念合 | 前端 + Circle 全家桶 + 第二條鏈 | split | Arc |

**結論:ENS + The Graph + World Selfie Check,全部 Sepolia,一條鏈、一套合約、三個提交。**
