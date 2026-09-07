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
- agent 送交易時,EIP-7702 delegate 先 `call` 那份 policy 問一句
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
          → 比對批准清單(位址)
            → call check(SpendContext)
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
                                  │          │ 可有自己的帳本 │
                    ┌─────────────┴───┐      └───────┬───────┘
                    │  人類 / 組織     │              │ call
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
| **ADMIN** | `leash.eth` + ENS EAC 角色 | 改規則、發子名、撤銷 agent、批准 policy 位址(要帶簽章) | **絕不做 7702 委派**,不裝營運資金 |
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

## Policy 層的設計決定(2026-09-07 定案,推翻 09-06 版)

> **這一節在 9/6 寫過一版,9/7 整節重寫。** 舊版把允許清單的 key 定為 codehash,
> 並因此要求 policy 不得有 storage,再為「共用預算」另外設計了兩套機制。
> 討論後確認那條路是「先選機制、再找需求」。**改成全位址,砍掉三個機制。**
> 舊版的推理保留在下面「為什麼推翻」,免得日後又繞回去。

### policy 是什麼

一份合約、一個位址,回答一個問題:「這筆花費符不符合規則?」回傳一個 `uint8`。
**它不碰錢、碰不到帳戶的 storage。**(它可以有自己的 storage —— 見下面。)

規則要獨立成合約而不是寫死在錢包裡,理由有四個:

| 理由 | 說明 |
|---|---|
| **可以被指向** | 規則有位址,才能寫進 ENS 記錄。**ENS 賽道的立論就在這裡** |
| 換規則不搬錢 | 錢一直在 LeashAccount 裡,改的只是它去問誰 |
| 一份規則多處用 | 不同子名可以指同一份,也可以各指各的 |
| 權限可以切開 | 「改規則」和「動錢」變兩件事,交給兩把不同的鑰匙 |

### 呼叫方式:一般 `call`

| 做法 | policy 能寫**帳戶**的 storage 嗎 | policy 能寫**自己**的 storage 嗎 |
|---|---|---|
| `delegatecall` | **能。整個帳戶都能寫** ← 絕對不用 | 不能(根本沒有「自己」) |
| `staticcall` | 不能 | 不能 |
| **`call`(採用)** | **不能** | **能** |

> ⚠️ **核心保證是「policy 碰不到帳戶的 storage」,而它只被 `delegatecall` 破壞。**
> `call` 和 `staticcall` 在這件事上一樣安全 —— 差別只在 policy 能不能記東西。

**為什麼從 `staticcall` 放寬到 `call`:** 「多個 agent 共用一筆總預算」需要有人記帳。
policy 自己記,是唯一不用在帳戶裡開特例的做法(見下一節)。

**護欄(寫 `LeashAccount` 時務必實作):**

1. **重入鎖** —— policy 是外部合約,可以回頭呼叫帳戶。整個 `execute` 上 mutex。
2. **gas 上限** —— `call{gas: 200_000}`;policy 燒光 gas 不該讓整筆交易死掉,
   回傳失敗一律當成「擋下」(fail-closed)。
3. **回傳值長度檢查** —— 不是剛好 32 bytes 就當擋下。
4. **先扣後付** —— 帳戶自己的記帳在轉帳之前完成。

`delegatecall` + slot 命名空間(ERC-7201 那套)**永遠不用** —— 命名空間是慣例不是強制,
delegatecall 之下 `SSTORE` 沒有任何限制,一行就能寫進批准清單,
Selfie Check 整道閘門被繞過(**循環授權:門鎖的鑰匙放在門後面**)。

### 允許清單的 key 用**位址**

```solidity
mapping(address policy => bool) public approved;   // 只有刷臉能加,任何時候能移除
```

**為什麼位址:位址同時釘住「邏輯」和「資料」,codehash 只釘住邏輯。**

同一份 bytecode 部署兩次,codehash 完全相同,但兩份的 storage 可以完全不同 ——
已實測:兩份同 codehash 的合約,`lo.check(500) = false`、`hi.check(500) = true`。
只要 policy 允許有 storage,codehash 就不再決定行為,它宣稱的保證直接失效。

而「位址 → 程式碼」在 **EIP-6780 之後是永久的**(selfdestruct 只在建立的同一筆交易內
才真的刪 code),所以教科書上「CREATE2 + selfdestruct 可以換掉同位址的 code」
這條反對理由已經死了。**不要再拿它當用 codehash 的理由。**

#### 為什麼推翻 codehash(記下來,免得繞回去)

9/6 版列了三個理由,逐條檢討:

| 當時的理由 | 現在的判斷 |
|---|---|
| 「可以批准還沒部署的程式碼」 | 真的獨特,但**我們用不到** —— 見下面「規則庫」 |
| 「人同意的是邏輯,不是位址」 | 位址一樣可以驗:批准前去看那個位址裝什麼。而且 policy 有 storage 之後,只看邏輯是**不夠**的 |
| 「7702 委派的 EOA 當 policy 會被指紋擋掉」 | 位址批准清單本來就只會有我們部署過的合約;要防這條,批准時檢查 `code.length` 就好 |

**codehash 唯一無可取代的場合:你要驗證的東西根本沒有位址**
(還沒部署、counterfactual、跨鏈比對同一份 code)。Leash 從頭到尾沒有這種東西 ——
所有要驗證的對象都是鏈上活著的實例。

> 「規則庫」這個功能**不需要 codehash**:先把五份 policy 部署好,
> 一次刷臉批准五個位址,之後 ADMIN 在五者之間切換不用再刷臉。
> Demo 的節奏一模一樣,少一層概念。

### 共用預算:一份 policy,不是帳戶裡的特例

需求:每個 agent 有**自己的錢包**,但所有 agent 花的加總不得超過一個總額度。

因為 policy 可以有 storage,這件事塌縮成一份合約,**帳戶完全不用改**:

```solidity
contract SharedBudgetPolicy is IPolicy {
    uint256 public immutable LIMIT;
    uint256 public immutable PERIOD;
    mapping(uint256 period => uint256) public spent;   // 全體共用

    function check(SpendContext calldata ctx) external returns (uint8) {
        uint256 p = block.timestamp / PERIOD;
        if (spent[p] + ctx.amount > LIMIT) return Reason.OVER_SHARED_LIMIT;
        spent[p] += ctx.amount;                        // policy 自己記自己的帳
        return Reason.OK;
    }
}
```

三個 agent 的 ENS 記錄各自指向**同一個位址**,共用預算就成立了 ——
不需要新的合約類型、不需要帳戶多一個欄位、不需要新的事件。

> **這是「policy 是唯一標準」的具體意思:** 凡是「這筆花費該不該過」的判斷,
> 一律在 policy 裡。帳戶只判斷「我該不該信這份 policy」(理由碼 1–4、10)。
> **不為個別需求在帳戶裡開特例。**

`check` 有副作用,所以它**只能由帳戶在真的要付款時呼叫一次**。
前端和 agent 的預演走 `eth_call`(不上鏈,不留下痕跡)。

### 怎麼證明韁繩還在(`isLeashed`)

前面五個問題都答了,但少了第六個:**「我怎麼知道這個錢包現在真的還被管著?」**

我們的錢包是 7702 委派的 EOA。它的行為完全取決於委派到哪裡,而**位址從頭到尾一樣**:

```
委派前   0x46C0…  →  code 是空的,誰拿到私鑰誰花錢
委派後   0x46C0…  →  LeashAccount,每筆都要過 policy
被改掉   0x46C0…  →  委派到別處,韁繩沒了
```

7702 的 code 就是 23 bytes:`0xef0100 || address`,直接讀出委派對象:

```solidity
function delegateOf(address wallet) internal view returns (address impl) {
    if (wallet.code.length != 23) return address(0);
    bytes memory c = wallet.code;
    if (c[0] != 0xef || c[1] != 0x01 || c[2] != 0x00) return address(0);
    assembly { impl := shr(96, mload(add(c, 0x23))) }   // 跳過 3 bytes 前綴
}

function isLeashed(bytes32 node) external view returns (bool, address);  // ENS → 錢包 → 委派對象
```

**任何人(廠商、監控、前端)在跟這個 agent 做生意之前,可以一次呼叫確認韁繩還在**,
不用問人、不用信任何人的說詞。subgraph 索引它之後,「韁繩被解開」就是一個可以告警的事件。

> codehash 也能做這件事(委派 code 與其 hash 一一對應),但**位址更好**:
> UI 可以顯示「目前委派到 `0x1234…`」,codehash 只能顯示「不對」。

### 這一版砍掉的東西

| 砍掉 | 為什麼 | 省下 |
|---|---|---|
| codehash 批准清單 | 位址更準(同時釘資料),且我們沒有「無位址」的需求 | — |
| 「policy 不得有 storage」的限制 | 那是 codehash 的附帶條件,codehash 沒了就沒理由 | — |
| `Write[]` / `_scratch` 代寫管線 | policy 能寫自己的 storage 之後完全多餘 | 1.0h |
| `SharedLedger` 獨立帳本合約 | 併進 `SharedBudgetPolicy` | 1.0h |
| 帳戶層 `walletBudget` + 理由碼 11 | 帳戶不該有花費規則的特例 | 0.7h |
| Merkle root 批准一整包 | 沒有對到任何使用者真的會問的問題 | — |
| 批准前掃 policy bytecode 有沒有 SLOAD | 同上 | — |
| **新增** `SharedBudgetPolicy` | 取代上面兩項,一份合約做完 | −1.0h |
| **新增** `isLeashed` | 補上「韁繩還在嗎」這個真的有人會問的問題 | −1.0h |
| | | **淨省 0.7h** |

### 保留但降級為 stretch:多份 policy 的析取範式(DNF)

`(A ∧ B) ∨ (C ∧ D)` —— 子句內 AND,子句間 OR。**不做巢狀運算式。**
`PolicySet` 本身實作 `IPolicy`,所以帳戶、ENS、批准閘門、事件、subgraph 全部不用改。

OR 是真實花錢規則的常見形狀(「單筆 ≤ 500」**OR**「有真人簽章」),
但它不在四幕 demo 的任何一幕裡。**9/11 主線綠燈之後再看。**

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
| World — Selfie Check | $3,500 | 3(各 $1,166)|

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
| **規則庫** | 已批准的 policy 位址清單,每筆顯示 `describe()` 與目前誰在用 |
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

加上 policy 不持有資產、碰不到帳戶 storage,**沒有攻擊面可以降**。
真正的風險是「指標指到不該指的地方」,那條由位址批准清單擋,跟 policy 有沒有常駐無關。

## 阻塞項

| 項目 | 送出日 | 卡住誰 | 備援 |
|---|---|---|---|
| World Selfie Check feature flag(email) | 2026-09-02 | World demo 全線 | 🔴 **9/5 的 Discord 升級已逾期,9/7 仍未做** |
| World Sandbox 存取(表單) | 2026-09-02 | Sandbox App 安裝 | iOS TestFlight 是公開連結,可先裝 |

> **2026-09-07 查證:官方文件的措辭改了。**
> `docs.world.org/world-id/sandbox/testing-selfie-check` 現在寫的是
> 「To enable the feature flag, **request access through your World point of contact**.」
> (credentials 那頁仍留著 `developers@toolsforhumanity.com` 的 mailto。)
>
> **對 hackathon 來說,「World point of contact」就是 ETHGlobal Discord 裡的 World sponsor 窗口。**
> 這比 email 更快,而且我們已經等了 5 天。**今天就去 Discord 問,不要再等信。**
>
> **2026-09-07,看完官方 workshop 錄影後確認的事:**
> - 旗標是**在 9/5 那場 workshop 現場發給與會者的**(台北時間 03:00,我們沒參加)
> - 窗口是 **Mateo Sauton**(Tools for Humanity),Discord handle 約為 `mrsauton`,
>   他在錄影裡明講「reach out to me on Discord」
> - 他說 Selfie Check 「probably next week」**對所有人開放** —— 那個 next week 就是這週
> - Developer Portal 裡那顆 **request access to sandbox** 按鈕(側邊欄 `World ID Sandbox`
>   → `Install World ID Sandbox`,iOS/Android 兩個分頁)**我們 9/2 已經按過,pending 中**。
>   它管的是 **Sandbox App 安裝**,不是 Selfie Check 旗標 —— 旗標在 Portal 裡沒有任何入口,
>   只能透過窗口。兩個閘門不要搞混。
> - Selfie Check 本來就不需要 Orb,**很可能不需要 Sandbox App**
>   (Sandbox 是為了模擬 Orb 驗證狀態而存在的)—— 一併跟 Mateo 確認,
>   若成立就整條 TestFlight/Firebase 依賴可以砍掉

**沒有 World 也能做完的部分:** 合約、ENS 接線、subgraph。
建置順序照這個排,把 World 留到最後接,回信時間就不在關鍵路徑上。

開工前的完整準備步驟見 **`prep-checklist.md`**。
