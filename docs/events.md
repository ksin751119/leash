# 事件 Schema(定稿)

**狀態:** 🔒 **已凍結**(2026-09-05 凍結;**2026-09-07 與 09-08 各解凍一次改完又凍回去**,見變更紀錄)
**日期:** 2026-09-08
**為什麼先寫這份:** subgraph 吃的是事件。合約寫完才發現事件不夠用,
代價是重新部署 → 重新索引 → 改 mapping → 改 agent 查詢,一次連鎖四層。
見 `sprint.md` 判斷①。

> **凍結後的規則:** 只准「加欄位、加事件」,不准改既有欄位的型別、順序或語意。
> 真的要改,回來改這份文件,並在下面的變更紀錄留一行。

---

## 先決定一件事:被擋的交易要 revert 還是 no-op?

**這題會決定整個 subgraph 有沒有東西可以索引。**

| | revert | **no-op + 事件(採用)** |
|---|---|---|
| 錢有沒有動 | 沒有 | 沒有 |
| 鏈上留下紀錄 | ❌ **revert 的 log 會被丟棄** | ✅ `SpendBlocked` 進 subgraph |
| agent 問「我上次為什麼被擋」 | 答不出來 | 查 subgraph 就有 |
| Demo 第 2 幕 | 看到一個紅色 revert | 看到一筆**被記錄下來的拒絕**,含理由碼 |

**採用 no-op。** 政策違反 → 不轉帳、發 `SpendBlocked`、正常結束。
只有**授權失敗**(caller 根本不是被綁定的 agent)才 revert —— 那不是政策決定,是入侵。

> 「擋下來」的證據是**錢沒有動**,不是交易紅字。
> 而且 The Graph 那條賽道要的正是「agent 真的在查索引資料做決策」——
> 被擋的紀錄查不到,第 4 個問題就不存在。

---

## 誰判定哪些理由碼

**理由碼 1–4、10 由 `LeashAccount` 在「呼叫 policy 之前」判定;5–9、11 由 policy 判定。**

這條線是刻意畫的:綁定關係、policy 指標、policy 批准清單、暫停 —— 這些是安全關鍵,
永遠留在帳戶自己手上。policy 只回答「這筆花費符不符合規則」,**換掉 policy 動不了控制權**。

## 理由碼(`uint8 reason`)

合約裡是 `enum Reason`,事件裡送 `uint8`。**數字一旦定了就不要重排。**

| 碼 | 名稱 | 意思 | 誰能解除 |
|---|---|---|---|
| 0 | `OK` | 通過 | — |
| 1 | `AGENT_NOT_BOUND` | 這個 agent 不屬於這個名字 | ADMIN |
| 2 | `AGENT_REVOKED` | 已被撤銷 | ADMIN(縮權免刷臉,恢復要刷臉) |
| 3 | `NO_POLICY` | ENS 上讀不到 policy 指標 | ADMIN |
| 4 | `POLICY_NOT_APPROVED` | policy 位址不在批准清單 | **只有刷臉** |
| 5 | `TOKEN_NOT_ALLOWED` | 這個代幣不在允許清單 | **刷臉** |
| 6 | `PAYEE_NOT_ALLOWED` | 收款人不在白名單 | **刷臉** |
| 7 | `OVER_TX_LIMIT` | 單筆超過上限 | **刷臉** |
| 8 | `OVER_PERIOD_LIMIT` | 本週期累計超過上限 | **刷臉** |
| 9 | `OUTSIDE_TIME_WINDOW` | 不在允許的時段內 | **刷臉** |
| 10 | `PAUSED` | 整個帳戶被暫停 | ADMIN |
| 11 | `OVER_SHARED_LIMIT` | 多個 agent 共用的總預算爆了 | **刷臉** |
| 12 | `POLICY_FAILED` | policy 呼叫失敗、超過 gas 上限、或回傳格式不對 | 換一份 policy(ADMIN) |

> 4–9、11 是「擴權」,一律要 Selfie Check。1–3、10、12 是 ADMIN 的日常操作。
>
> **12 為什麼需要獨立的碼:** 帳戶呼叫 policy 時會限 gas 並檢查回傳長度,
> 不合就 fail-closed。挪用 4(`POLICY_NOT_APPROVED`)會誤導 —— 那個碼的語意是
> 「這份 policy 沒被真人批准」,而 12 是「這份 policy 壞了」。兩者的處置完全不同。
> 這張表就是 `PLAN.md`「擴權 / 縮權的不對稱」的機器可讀版本。

---

## 事件

### 一、ENS 層 —— `LeashRegistry` / `LeashResolver`

```solidity
/// 子名被建立。label 用明碼送,subgraph 才能反查名字。
event SubnameRegistered(
    bytes32 indexed node,      // namehash("alpha.leash.eth")
    string          label,     // "alpha"
    address indexed owner,
    uint64          expiry
);

/// 子名被撤銷 —— Demo 第 4 幕的「拔插頭」。
event SubnameRevoked(
    bytes32 indexed node,
    address indexed by
);

/// policy 指標被改寫。這是整個系統的控制面事件。
event PolicyPointerSet(
    bytes32 indexed node,
    address indexed policy,    // 0x0 = 清空,等同全面停機
    address indexed setBy,
    bool            approved        // 設定當下,這個位址在不在批准清單裡
);
```

**為什麼 `approved` 要記在這裡:** ENS 指標由 ADMIN 控制,批准清單由刷臉控制。
兩者分離才有意義 —— **ADMIN 金鑰被偷,攻擊者能改指標,但無法讓一份沒被批准的 policy
在現有清單裡變成已批准**(`PolicyApprovals.attester` 與 `LeashResolver.approvals`
都是 `immutable`,沒有 setter)。

> ⚠️ **2026-09-08 修正過的措辭。** 原本寫的是「指不到一份沒被批准過的 policy」——
> **那句話當時是假的。** code review 指出:`setAttester` 是 `onlyOwner` 且不需背書,
> 而部署時三份合約的 owner 都是同一把 ADMIN 金鑰,所以
> `setAttester(永遠回true)` → `approve(任何東西)` 一路通到底。
> 修法是拿掉那兩個 setter(改 `immutable`),而**主張也要收斂到精確**:
> ADMIN 仍然可以部署一整套新的控制面再把名字指過去 —— 但那是**一連串看得見的鏈上交易**,
> 而且新清單是空的,他得把每一個名字重新指一次。他無法**安靜地**擴權。
把當下的結果記進事件,subgraph 不必自己重算就能呈現「這個指標指到的東西被批准過嗎」。

---

### 二、執行層 —— `LeashAccount`

```solidity
/// 每次執行前,從 ENS 解析出來的 policy。
/// 證明「policy 位址真的從 ENS 走過來,不是硬編碼」(DoD 條件之一)。
event PolicyResolved(
    bytes32 indexed node,
    address indexed policy,
    bool            approved
);

event SpendExecuted(
    bytes32         node,         // 這筆花費是在哪個 ENS 名字底下發生的
    address indexed agent,
    address indexed payee,
    address indexed token,
    uint256         amount,
    address         policy,
    uint256         spentAfter,   // 本週期累計(含這筆)
    uint256         limit,        // 本週期上限
    uint64          periodEnd     // 這個週期何時重置
);

event SpendBlocked(
    bytes32         node,
    address indexed agent,
    address indexed payee,
    address indexed token,
    uint256         amount,
    uint8           reason,       // 見上表
    address         policy,
    uint256         spentSoFar,
    uint256         limit
);

/// 帳戶初始化。證明這個 EOA 現在委派給 LeashAccount。
/// 注意:「拆掉委派」不發事件 —— EIP-7702 沒有 log,只能靠 isLeashed() 輪詢。
event Leashed(bytes32 indexed node, address indexed wallet, address impl);

event AgentBound(address indexed agent, bytes32 indexed node);
event AgentRevoked(address indexed agent, address indexed by);
event Paused(address indexed by);
event Unpaused(address indexed by, bytes32 attestationHash);
```

**為什麼兩個花費事件都帶 `node`:** 一個帳戶底下可以有多個 agent、指向不同的 policy。
沒有 `node`,subgraph 要反查「這筆算在誰頭上」就得自己重建綁定關係的時間軸。
`node` 不設 indexed —— 三個 indexed 名額給了 agent/payee/token,那是實際會被查的維度。

**`SpendExecuted` 和 `SpendBlocked` 為什麼不合併成一個帶 `bool allowed` 的事件:**
subgraph 的 handler 分開寫比較乾淨,而且 agent 查「我還剩多少」和查「我為什麼被擋」
是兩個不同的查詢,分開的 entity 省掉一層 filter。

---

### 三、允許清單的變更 —— `LeashAccount`

**每一筆擴權都必須帶 `attestationHash`。縮權的欄位是 `by`(誰做的),沒有 hash。**
這個型別上的不對稱是刻意的 —— 看事件簽章就知道哪些操作需要真人。

```solidity
// --- 擴權:一律帶 attestationHash ---
event LimitRaised(
    bytes32 indexed node,
    address indexed token,
    uint256         oldLimit,
    uint256         newLimit,
    uint64          period,
    bytes32         attestationHash
);
event PayeeAllowed(bytes32 indexed node, address indexed payee, bytes32 attestationHash);
event TokenAllowed(bytes32 indexed node, address indexed token, bytes32 attestationHash);
event PolicyApproved(address indexed policy, string description, bytes32 attestationHash);

// --- 縮權:不帶 hash,任何時候都能做 ---
event LimitLowered(
    bytes32 indexed node,
    address indexed token,
    uint256         oldLimit,
    uint256         newLimit,
    address indexed by
);
event PayeeRemoved(bytes32 indexed node, address indexed payee, address indexed by);
event TokenRemoved(bytes32 indexed node, address indexed token, address indexed by);
event PolicyRevoked(address indexed policy, address indexed by);
```

---

### 四、身分層 —— ~~`AttesterGate`~~ 由 attestation 的**消費者**發出

> ⚠️ **2026-09-08:`AttesterGate` 這份合約不會存在。**
>
> attestation 的消費者只有三個(`PolicyApprovals`、`LeashRegistry`、之後的
> `LeashAccount`),各自內嵌驗證比多一層轉發簡單,而多一份合約在 5 天的預算裡
> 買不到東西。
>
> **歸屬定案:** `AttestationAccepted` 由 **`LeashAccount`** 發出(它是唯一持有
> per-wallet nonce 的地方,那個事件的價值就在防重放的審計軌跡)。
> `PolicyApprovals` 與 `LeashRegistry` 各自用自己的 `attestationUsed` mapping
> 加上既有事件的 `attestationHash` 欄位承載同樣的資訊。
>
> **`AttesterChanged` 已刪除。** `attester` 現在在三份合約裡都是 `immutable`,
> 沒有 setter,所以沒有這個事件可發 —— 見下方變更紀錄裡的 C1。
>
> `action` 欄位的值域從「理由碼 4–9」擴大到 **4–9 與 11**。

```solidity
/// 一份 attestation 被接受並用掉。nonce 防重放。
event AttestationAccepted(
    bytes32 indexed attestationHash,
    address indexed subject,     // 這份 attestation 授權誰
    uint8           action,      // 對應理由碼 4–9,說明它解除的是哪一項
    uint256         nonce,
    address indexed attester     // WorldAttester 或 MockAttester
);

/// 換 attester 實作 —— World 核准到了就發這一筆。
event AttesterChanged(address indexed oldAttester, address indexed newAttester);
```

**`AttesterChanged` 存在的理由:** `sprint.md` 判斷② 說 attester 從第一天就介面化。
這個事件讓 demo 可以誠實展示「現在跑的是 mock 還是真的 World」,不用嘴上保證。

---

## Agent 要問的四個問題 → 對應哪個事件

| # | 問題 | 讀什麼 | 砍單順位 |
|---|---|---|---|
| 1 | 我這個週期還剩多少? | 最新的 `SpendExecuted.spentAfter` / `limit` | 必做 |
| 2 | 這個收款人付過嗎? | `PayeeAllowed` − `PayeeRemoved` | 必做 |
| 3 | 我的 policy 現在是哪一份、批准過嗎? | `PolicyPointerSet` + `PolicyApproved` | 必做 |
| 4 | 我上次為什麼被擋? | `SpendBlocked.reason` | **砍單清單第 2 項** |

---

## 一件 subgraph 看不到的事:韁繩還在嗎

`isLeashed(node)` 檢查的是「錢包現在還委派給 `LeashAccount` 嗎」。

**EIP-7702 的委派變更不發任何 log**,所以 subgraph 索引不到 ——
這件事只能靠 **`eth_call` 輪詢**(前端進頁面時查一次,監控腳本定期查)。
文件裡寫清楚,免得之後有人以為漏做了事件。

帳戶第一次初始化時發 `Leashed(node, wallet, impl)`,那是「裝上」的紀錄;
「拆掉」沒有對應的事件,這是協定的限制,不是我們的疏漏。

---

## 變更紀錄

| 日期 | 改了什麼 | 為什麼 |
|---|---|---|
| 2026-09-05 | 初稿 | — |
| 2026-09-05 | 🔒 凍結;補上「誰判定哪些理由碼」 | 動工前定稿 |
| 2026-09-07 | **解凍一次**:批准清單的 key 從 codehash 改成**位址** | policy 允許有自己的 storage 之後,codehash 不再決定行為(已實測:同 codehash 兩份合約判斷相反)。詳見 `PLAN.md`「允許清單的 key 用位址」 |
| 2026-09-07 | `PolicyCodehashApproved` → `PolicyApproved(address, string, bytes32)`;`PolicyCodehashRevoked` → `PolicyRevoked(address, address)` | 同上 |
| 2026-09-07 | `PolicyPointerSet.policyCodehash`(bytes32)→ `approved`(bool);`PolicyResolved` 兩個 codehash 欄位合併成 `approved`(bool) | 位址已經是 indexed 參數,再記一次指紋沒有資訊量 |
| 2026-09-07 | 理由碼 4 改名 `POLICY_NOT_APPROVED`(**數字不動**);新增 11 `OVER_SHARED_LIMIT` | 共用預算改由一份 policy 自己記帳,不在帳戶開特例 |
| 2026-09-07 | `SpendExecuted` / `SpendBlocked` 各補一個 `node` 欄位;新增 `Leashed` | 補上之前議定但沒寫進來的三項 |
| 2026-09-07 | 🔒 **重新凍結** —— 合約還沒部署、subgraph 還沒寫,這是最後一次無痛改的機會 | — |
| 2026-09-08 | **解凍第二次**:新增理由碼 **12 `POLICY_FAILED`** | 帳戶對 policy 限 gas 並檢查回傳長度,fail-closed 時沒有現成的碼。挪用 4 會誤導 subgraph |
| 2026-09-08 | `SubnameRegistered` / `SubnameRevoked` 各補一個 `tokenId` 欄位;新增 `SubnameRenewed`;`ResolverChanged` / `SubregistryChanged` 改以 `node` 為第一個 indexed 欄位並帶 `tokenId` | registry 內部用 labelhash 推導的 tokenId,而 subgraph 的 join key 是 `node`(namehash)。**兩者都要有**,否則索引端得自己重建 tokenId→label→namehash 的對照 |
| 2026-09-08 | **刪除 `AttesterChanged`**;`AttesterGate` 這份合約不會存在,`AttestationAccepted` 改由 `LeashAccount` 發出 | code review C1:可變的 attester 指標讓一把被偷的 ADMIN 金鑰同時開兩道鎖。`attester` 改成 `immutable` 之後就沒有 setter,也就沒有這個事件 |
| 2026-09-08 | `PolicyApproved` 補 `nonce` 欄位 | code review C2:原本的 digest 沒有 nonce 也沒記錄用過的 attestation,加上公開的 `revoke` 就能重放 —— 撤銷後用同一份背書重新批准,不需要任何人再刷一次臉 |
| 2026-09-08 | `action` 欄位值域從「理由碼 4–9」擴大到 4–9 與 11 | 共用預算(11)也是擴權,需要背書 |
| 2026-09-08 | 🔒 **重新凍結**。合約已部署但 subgraph 還沒寫 —— 這一批改動要重新部署 `LeashRegistry` 與 `PolicyApprovals`,是有代價的,但比帶著錯的安全論證去評審便宜 | — |

> **這一批改動的由來:** 2026-09-08 依 `superpowers:requesting-code-review` 派出的
> code reviewer 對 `a9f5051..c3c704e` 做的 review,verdict 是 `With fixes`。
> 兩個 Critical(一把鑰匙開兩道鎖、attestation 可重放)推翻的正好是這份文件
> 第 94 行原本寫的那句主張。詳細經過見該次 review 的修正 commit。
