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
- agent 送交易時,EIP-7702 delegate 先用 `staticcall` 問那份 policy
- policy 回傳的不是 OK → **不轉帳**,發 `SpendBlocked(reason)`,交易正常結束
- **agent 沒有繞過的路徑**,因為檢查發生在它自己的執行流程裡

policy 是一份完整的 smart contract,不是一張設定表。它想怎麼判斷都行 ——
看金額、看對象、看時間、看歷史累計,甚至有自己的記憶(見「Policy 層的設計決定」)。

> **為什麼被擋不是 revert:** revert 的 log 會被鏈丟棄,subgraph 就索引不到被擋的紀錄,
> agent 也就問不出「我上次為什麼被擋」—— 而那正是 The Graph 賽道要看的東西。
> 「擋下來」的證據是**錢沒有動**,不是交易紅字。只有授權失敗(caller 不是被綁定的 agent)才 revert。
> 完整論證見 `events.md`。

## 為什麼 ENS 是骨架而不是裝飾

policy 的**位址從 ENS 解析出來**。7702 delegate 每次執行都要走一次:

```
RootRegistry.getSubregistry("eth")
  → ETHRegistry.getSubregistry("acme")
    → AcmeRegistry.getResolver("vendors")
      → resolver.resolve(dnsName, text(node, "policy"))
        → policy 合約位址
          → EXTCODEHASH 比對允許清單
            → staticcall check(SpendContext)
```

**拿掉 ENS,delegate 解不出 policy,任何花費都過不了(理由碼 3)。**

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
                    │  人類 / 組織     │              │ staticcall
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

### 金鑰模型(關鍵)—— 三把,不是兩把

| 鑰匙 | 持有什麼 | 能做什麼 | 刻意做不到什麼 |
|---|---|---|---|
| **ADMIN** | `leash.eth` + ENS EAC 角色 | 改規則、發子名、撤銷 agent、批准 codehash(要帶簽章) | **絕不做 7702 委派**,不裝營運資金 |
| **WALLET** | 錢;被 7702 委派成 `LeashAccount` | 付錢(每筆都要過 policy) | **ENS 上的角色是 `0`** —— 不是檢查出來的,是它從來就沒有過 |
| **AGENT** | 什麼都不持有 | 發起花費請求 | 拿不到錢、拿不到權限,只是個被 policy 認得的 `msg.sender` |

**為什麼一定要拆:** `LeashAccount` 對外送交易時 `msg.sender` 就是 WALLET。
如果 WALLET 同時握有 ENS 權限,一份壞掉的 policy 可以透過它呼叫 `ETHRegistry.setResolver`,
**把規則指到自己身上**。我們用「拆開」解決,不是用「檢查」解決。

已實測驗證:`cast call --from` 下,WALLET / AGENT 的 ENS 角色皆為 `0`,所有 ENS 變更一律 revert。

> 壞掉的 policy 最多把 WALLET 的錢花光。**它動不了控制權,因為 WALLET 從來就沒有控制權可以借給它。**

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

## Policy 層的設計決定(2026-09-06 定案)

### policy 是什麼

一份合約、一個位址,回答一個問題:「這筆花費符不符合規則?」回傳一個 `uint8`。
**它不碰錢、不存資料、不改任何東西。**

規則要獨立成合約而不是寫死在錢包裡,理由有四個:

| 理由 | 說明 |
|---|---|
| **可以被指向** | 規則有位址,才能寫進 ENS 記錄。**ENS 賽道的立論就在這裡** |
| 換規則不搬錢 | 錢一直在 LeashAccount 裡,改的只是它去問誰 |
| 一份規則多處用 | 不同子名可以指同一份,也可以各指各的 |
| 權限可以切開 | 「改規則」和「動錢」變兩件事,交給兩把不同的鑰匙 |

### 呼叫方式:`staticcall`,不是 `delegatecall`

原本的架構圖畫 `delegatecall`,**改掉了**。

| 做法 | policy 能寫嗎 | 能讀外部狀態嗎 | codehash 保證什麼 |
|---|---|---|---|
| `delegatecall` | **能寫整個帳戶** | 能 | 幾乎不保證 —— 同一份 code 在不同 storage 下行為不同 |
| `staticcall` + `view` | 不能 | **能**(預言機、共用黑名單) | 保證邏輯,但外部值會變 |
| `staticcall` + `pure` | 不能 | 不能 | **完全決定行為**,鏈下可重現 |

決定:**`IPolicy.check` 宣告 `view`,`StandardPolicy` 實作 `pure`。**
Solidity 允許 override 時收緊可變性,所以留門是零成本。

**兩個實測支撐這個決定:**

1. 7702 委派後 delegate 讀到的是 EOA 的**空 storage**(`decimals()` 回 0)——
   任何「把規則存在自己 storage 裡」的 policy 在 delegatecall 之下都是壞的
2. `immutable` 讀取**需要 `view`,不能是 `pure`**(Solc 0.8.28 Error 2527)——
   `PolicySet` 需要它,還好介面已經放寬

> ⚠️ **「policy 改不了東西」的保證來自 `staticcall`,不是來自 `pure`。**
> staticcall 之下 EVM 禁止一切寫入,跟函式宣告什麼無關。`pure` 多買到的只有決定性。

### policy 可以有記憶,但寫入的動作由帳戶執行

`delegatecall` + slot 命名空間(ERC-7201 那套)**不能用** —— 命名空間是慣例不是強制,
delegatecall 之下 `SSTORE` 沒有任何限制,一行就能寫進 codehash 允許清單,
Selfie Check 整道閘門被繞過(**循環授權:門鎖的鑰匙放在門後面**)。

改成帳戶代寫:

```solidity
// LeashAccount:命名空間來自「呼叫我的人是誰」,policy 偽造不了
mapping(address policy => mapping(bytes32 => bytes32)) private _scratch;
function readScratch(bytes32 key) external view returns (bytes32) {
    return _scratch[msg.sender][key];
}

// IPolicy:讀用 callback(staticcall 內可以),寫用回傳值
function check(SpendContext calldata ctx)
    external view returns (uint8 reason, bytes32[] memory writes);  // (key,value) 成對,上限 8

// LeashAccount.execute:實際執行 SSTORE 的是帳戶
for (uint i; i < w.length; i += 2) _scratch[policy][w[i]] = w[i+1];
```

**安全論證:** policy 本來就能對任何一筆花費回傳 `OK`。
給它「寫自己那格」的能力**沒有多給任何原本沒有的權限** —— 最壞是把自己的帳本寫爛,
導致自己的判斷變爛,而它本來就能直接判斷爛。**不動安全模型,只擴充表達力。**

換來的:滾動 24 小時窗、每個收款人分開計數、冷卻時間、累進限制(連三次被擋自動降額)。

**狀態放帳戶不放 policy**,因為:

| | 狀態在 policy | **狀態在帳戶(採用)** |
|---|---|---|
| 換 policy | 舊狀態卡在舊合約,要遷移 | 換一格,舊的自動失效 |
| policy 有 bug | **炸到所有用這份 policy 的錢包** | 只炸自己 |

### 允許清單的 key 用 **codehash**,不用位址

**先砍掉一個不成立的理由:** 教科書講的「CREATE2 + selfdestruct 可以換掉同位址的 code」,
在 **EIP-6780 之後已經死了** —— selfdestruct 只有在建立的同一筆交易內才真的刪 code。
所以「位址 → 程式碼」現在是永久的,不要再用這條當理由。

codehash 真正買到的:

1. **可以批准一份還不存在的程式碼** ← 見下一節,這是位址做不到的
2. **人在刷臉時同意的是「邏輯」** —— 可以自己編譯 `StandardPolicy.sol` 比對出同一個指紋。
   「批准位址 `0x7A3f…`」則要先去查那個位址裝什麼
3. 7702 委派的 EOA 當 policy:23 bytes 的 designator 指紋不可能等於一份 957 bytes 合約的指紋;
   就算誤批准了,一換委派指紋就變,自動失效。**位址擋不住這條**

它**買不到**的(要誠實):policy 自己是個 `view` proxy 的話,兩種做法都被繞過。
真正的防線是「批准前有人讀過那份 code」——那正是 Selfie Check 那一步的意義。

> ❌ **一度考慮「位址 + codehash 配對釘死」,已收回。** 它解決的 7702 問題 codehash 本來就免疫,
> 卻會關掉「預先批准」的能力。

### 預先批准的規則庫(特色功能,零額外合約成本)

因為指紋是從 source 算出來的,**不需要鏈上有任何東西**,所以人可以批准還沒部署的規則。

```
人在方便的時候(有手機、光線好、不趕時間)刷一次臉,
一口氣批准五種情境的規則指紋:

  平常            0x9c2e…    ← 已部署
  採購旺季        0x41ba…    ← 未部署
  緊急凍結        0x7f03…    ← 未部署
  週末唯讀        0xd218…    ← 未部署
  新供應商觀察期   0x88e1…    ← 未部署

之後 ADMIN 在這五種之間切換不用再刷臉 —— 每一種都已經被真人同意過。
真的要用的時候才部署,誰部署都可以。
```

**把「人的同意」和「鏈上的存在」解耦。人不必在系統需要它的那一刻在場。**

前端要顯示 `已批准 · 未部署` 這個狀態 —— 零成本,而且很好講。

### 多份 policy:析取範式(DNF)

`(A ∧ B) ∨ (C ∧ D) ∨ (E)` —— 子句內 AND,子句間 OR。
**不做巢狀運算式**,任何布林式都能寫成這個形狀,而它只是陣列的陣列,不需要 parser。

OR 不是理論需求,是真實花錢規則的常見形狀:
- 「單筆 ≤ 500」**OR**「有真人簽章」← agent 錢包最經典的模式
- 「收款人在白名單」**OR**「金額 ≤ 50」← 陌生地址只能小額

**`PolicySet` 本身實作 `IPolicy`,所以帳戶、ENS、codehash 閘門、事件、subgraph 全部不用改。**

成員用 `immutable` 烤進 bytecode,所以**成員不同 → codehash 不同**(已實測)。
批准一個 `PolicySet` 的指紋 = 批准**這個確切的組合**;換掉任何一份成員或改分組,都要重新刷臉。
閘門從「管每份規則」升級成「管規則的組合方式」—— 比原本更嚴。

**被擋時回報哪個理由:走最遠的那個子句。** 那是 agent 離通過最近的一條路,最有行動價值。

成員的 codehash **在批准時驗一次**,不要每筆花費都驗 —— PolicySet 的指紋已經涵蓋成員名單。

### 錢包層總預算(取代階層式 policy)

「一筆交易同時過多層 policy」沿 ENS 階層疊加很漂亮,但**真正的成本不在 policy,在帳本要分層**
(`mapping(node => spent)`、事件要能表達計進哪幾層、subgraph 三種 entity),3–4h 且連鎖四層。

九成的效果用一個檢查就買到:

```solidity
// LeashAccount 自己判,在呼叫任何 policy 之前
if (walletSpent + amount > walletLimit) return Reason.OVER_WALLET_LIMIT;  // 碼 11
```

Demo 畫面幾乎一樣:**三個 agent 各有額度、共用一個總預算,總預算爆了全部一起停。**

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
| **規則庫** | 已批准的 codehash 清單,每筆標 `已部署` / `已批准 · 未部署`(零成本加分項) |
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

---

## v2 方向:一次性批次授權(ephemeral code)

> 2026-09-06 討論結論。**這次不做**,寫進 README 的 what's next。

「把 code 帶進交易、驗 hash、跑完就銷毀」這個模式,**用在規則上是錯的,用在一次性操作上是對的**。

| | 規則(policy) | 一次性批次 |
|---|---|---|
| 使用次數 | 反覆用 | **用一次** |
| 適合 | 常駐 | **ephemeral** |

形狀:「這次要跑一批 20 筆特殊付款。人刷臉批准**這整批操作的 hash**,
執行時把 code 帶進來、驗 hash、跑完、銷毀、燒掉 nonce。
這批操作永遠只能跑一次,鏈上不留下一份可以被再次呼叫的東西。」

**為什麼不用在 policy 上(實測數字):**

```
StandardPolicy  runtime 957 bytes · initcode 985 bytes

每筆付款若走 ephemeral:
  CREATE                 32,000
  code deposit  957×200  191,400
  calldata ~985 bytes    ~15,800
  執行 + 銷毀             ~20,000
  ─────────────────────────────
                        ~260,000 gas

對照:呼叫已部署的 policy   ~3,600 gas      →  約 70 倍
```

而且 `selfdestruct` 的刪除**在交易結束時才生效**(實測 `code gone in same tx? false`)——
整筆交易進行中那份 code 一直都在,「用完就消失」消失在所有事情都已經發生之後。

加上我們的 policy 是 `pure`/`view`:沒有 storage、沒有 owner、不持有資產,
**沒有攻擊面可以降**。真正的風險是「指標指到不該指的地方」,那條由 codehash 允許清單擋,
跟 policy 有沒有常駐無關。

## 阻塞項

| 項目 | 送出日 | 卡住誰 | 備援 |
|---|---|---|---|
| World Selfie Check feature flag(email) | 2026-09-02 | World demo 全線 | 9/5 沒回音就開 Discord 第三條線 |
| World Sandbox 存取(表單) | 2026-09-02 | Sandbox App 安裝 | iOS TestFlight 是公開連結,可先裝 |

**沒有 World 也能做完的部分:** 合約、ENS 接線、subgraph。
建置順序照這個排,把 World 留到最後接,回信時間就不在關鍵路徑上。

開工前的完整準備步驟見 **`prep-checklist.md`**。
