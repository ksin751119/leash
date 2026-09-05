# 事件 Schema(定稿)

**狀態:** 🔒 **已凍結**(2026-09-05)
**日期:** 2026-09-05
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

**理由碼 1–4、10 由 `LeashAccount` 在「呼叫 policy 之前」判定;5–9 由 policy 判定。**

這條線是刻意畫的:綁定關係、policy 指標、codehash 允許清單、暫停 —— 這些是安全關鍵,
永遠留在帳戶自己手上。policy 只回答「這筆花費符不符合規則」,**換掉 policy 動不了控制權**。

## 理由碼(`uint8 reason`)

合約裡是 `enum Reason`,事件裡送 `uint8`。**數字一旦定了就不要重排。**

| 碼 | 名稱 | 意思 | 誰能解除 |
|---|---|---|---|
| 0 | `OK` | 通過 | — |
| 1 | `AGENT_NOT_BOUND` | 這個 agent 不屬於這個名字 | ADMIN |
| 2 | `AGENT_REVOKED` | 已被撤銷 | ADMIN(縮權免刷臉,恢復要刷臉) |
| 3 | `NO_POLICY` | ENS 上讀不到 policy 指標 | ADMIN |
| 4 | `POLICY_CODEHASH_NOT_APPROVED` | policy 位址的 codehash 不在允許清單 | **只有刷臉** |
| 5 | `TOKEN_NOT_ALLOWED` | 這個代幣不在允許清單 | **刷臉** |
| 6 | `PAYEE_NOT_ALLOWED` | 收款人不在白名單 | **刷臉** |
| 7 | `OVER_TX_LIMIT` | 單筆超過上限 | **刷臉** |
| 8 | `OVER_PERIOD_LIMIT` | 本週期累計超過上限 | **刷臉** |
| 9 | `OUTSIDE_TIME_WINDOW` | 不在允許的時段內 | **刷臉** |
| 10 | `PAUSED` | 整個帳戶被暫停 | ADMIN |

> 4–9 是「擴權」,一律要 Selfie Check。1–3、10 是 ADMIN 的日常操作。
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
    bytes32         policyCodehash  // 設定當下讀到的 EXTCODEHASH
);
```

**為什麼 `policyCodehash` 要記在這裡:** ENS 指標由 ADMIN 控制,codehash 允許清單由刷臉控制。
兩者分離才有意義 —— ADMIN 金鑰被偷,攻擊者能改指標,但指不到一份沒被批准過的 code。
把當下的 codehash 記進事件,subgraph 就能直接呈現「這個指標指到的東西被批准過嗎」。

---

### 二、執行層 —— `LeashAccount`

```solidity
/// 每次執行前,從 ENS 解析出來的 policy。
/// 證明「policy 位址真的從 ENS 走過來,不是硬編碼」(DoD 條件之一)。
event PolicyResolved(
    bytes32 indexed node,
    address indexed policy,
    bytes32         policyCodehash,
    bool            codehashApproved
);

event SpendExecuted(
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
    address indexed agent,
    address indexed payee,
    address indexed token,
    uint256         amount,
    uint8           reason,       // 見上表
    address         policy,
    uint256         spentSoFar,
    uint256         limit
);

event AgentBound(address indexed agent, bytes32 indexed node);
event AgentRevoked(address indexed agent, address indexed by);
event Paused(address indexed by);
event Unpaused(address indexed by, bytes32 attestationHash);
```

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
event PolicyCodehashApproved(bytes32 indexed codehash, bytes32 attestationHash);

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
event PolicyCodehashRevoked(bytes32 indexed codehash, address indexed by);
```

---

### 四、身分層 —— `AttesterGate`

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
| 3 | 我的 policy 現在是哪一份、批准過嗎? | `PolicyPointerSet` + `PolicyCodehashApproved` | 必做 |
| 4 | 我上次為什麼被擋? | `SpendBlocked.reason` | **砍單清單第 2 項** |

---

## 變更紀錄

| 日期 | 改了什麼 | 為什麼 |
|---|---|---|
| 2026-09-05 | 初稿 | — |
| 2026-09-05 | 🔒 凍結;補上「誰判定哪些理由碼」 | 動工前定稿 |
