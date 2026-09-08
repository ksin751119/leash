# LeashAccount 設計 —— 強制執行的 EIP-7702 帳戶

**日期:** 2026-09-08
**Sprint 項目:** 7a(取代原本的「合約錢包」版本,直接做 7702 delegate)
**狀態:** 已核准,待實作

---

## 這份東西要解決什麼

前面五份合約各自做完了自己的事,但**沒有任何東西強制它們被使用**:

- `StandardPolicy` 會判斷,但沒有人一定要問它
- `LeashResolver` 解得出 policy 位址,但沒有人一定要去解
- `PolicyApprovals` 記著哪些 policy 被批准過,但沒有人一定要比對
- `LeashRegistry` 能撤銷子名,但撤銷了不影響任何實際的花費

`LeashAccount` 是**唯一的花費路徑**。它把上面四件事變成付款的前置條件,
而且是在 agent 自己的執行流程裡發生的 —— **agent 沒有繞過的選項,
因為檢查不是在它之外,而是在它之內。**

拿掉 ENS,第 4 步解不出 policy,任何花費都過不了(理由碼 3)。

---

## 決策紀錄

實作前先寫下四個已定案的分岔,免得日後被當成「隨手選的」。

| # | 決定 | 否決的選項 | 理由 |
|---|---|---|---|
| 1 | **直接做 7702 delegate**,不做獨立合約錢包 | 合約錢包(sprint 原案)、一份 bytecode 兩用 | 7702 的故事是「既有 EOA 直接被 policy 管,不用搬錢」。工具鏈風險 09-03 已實測解除 |
| 2 | **沒有 `initialize()`**,全域設定寫成 `immutable` | `initialize()` 限 `msg.sender == address(this)` | 沒有初始化動作 = 沒有搶跑面。而且 impl 位址本身就代表整套控制面,`delegateOf` 一個呼叫就問得完 |
| 3 | **「受哪個 ENS 名字管」由 WALLET 自己綁** | 由 ADMIN 綁 | 威脅模型是「agent 被入侵」,不是「錢包持有者害自己」。WALLET 只能在**已被真人核准過的規則集**之間選 |
| 4 | **解析從 `ETH_REGISTRY` 開始**(三跳) | 從 RootRegistry 走四跳、resolver 位址寫死 | 三跳是「保留全部三層撤銷」的最短路徑。四跳多的那一跳買不到撤銷能力;寫死 resolver 會讓 ENS 變成裝飾 |

### 09-08 用本機 anvil 實測推翻的兩條舊筆記

`docs/ensv2-sepolia.md` 原本記著兩個 7702「陷阱」,**都是誤讀**
(當時委派的對象是 `MockUSDC`,一個沒有對應函式的 ERC-20):

| 舊筆記 | 實測結果 |
|---|---|
| 交易的 `to` 不可是被委派的 EOA 本身 | ❌ 錯。`to = EOA` **就是**呼叫 delegate 函式的正常方式 |
| delegate 必須 stateless | ❌ 錯。delegate **可以有 storage**,存在 **EOA 自己**的 storage 上。兩個 EOA 共用一份 impl,storage 完全獨立 |

**這對設計是好消息:** 每個錢包有自己的允許清單與預算,不需要在 impl 裡開 mapping。

而 spike 找到一個**真的**漏洞:

> 🔴 委派後 EOA 的 storage 是空的,**任何人都能搶先呼叫 `initialize` 把自己設成 admin。**

決定 2 就是為了消滅這個攻擊面。

---

## 架構

### 一份 impl,零個實例狀態

```solidity
contract LeashAccount {
    // 烙在 bytecode 裡。沒有 initialize,沒有搶跑面。
    address          immutable ETH_REGISTRY;  // ENSv2 的 .eth registry,解析起點
    IPolicyApprovals immutable APPROVALS;
    IAttester        immutable ATTESTER;

    string constant PARENT_LABEL = "leash";   // ETH_REGISTRY 底下我們那個名字
}
```

換控制面的方式是**部署新的 impl 再重新委派** —— 而重新委派本身就是錢包持有者
手上的逃生口,不需要另外設計一個。

### Storage:ERC-7201 具名槽位(必要,不是講究)

委派的程式碼跑在 **EOA 自己的 storage** 上。如果這個 EOA 之後改委派給
**另一份佈局不同的 impl**,舊資料會被誤讀成新意義 —— 預算被讀成 admin 位址那種災難。

```solidity
/// @custom:storage-location erc7201:leash.account.v1
struct AccountStorage {
    mapping(address agent => AgentBinding) bindings;
    mapping(bytes32 node => mapping(address token => TokenRule)) rules;
    mapping(bytes32 node => mapping(address token => mapping(address payee => bool))) payees;
    mapping(bytes32 node => mapping(address token => mapping(uint256 periodIdx => uint256))) spent;
    mapping(bytes32 digest => bool) usedAttestations;
    bool paused;
    bool entered;              // 重入鎖
}

// ERC-7201:keccak256(abi.encode(uint256(keccak256("leash.account.v1")) - 1)) & ~bytes32(uint256(0xff))
// 09-08 算出的值,實作時要用測試把它釘住(算錯就是所有狀態都跑到別的槽位)
bytes32 private constant SLOT =
    0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800;
```

版本號寫在字串裡(`v1`),換佈局就換字串,舊槽位永遠不會被誤讀。

```solidity
struct AgentBinding {
    bytes32 node;      // namehash("<label>.leash.eth"),resolver 讀記錄用
    string  label;     // "vendors",走 LeashRegistry.getResolver(label) 用
    bool    revoked;
}

struct TokenRule {
    bool    allowed;
    uint256 txLimit;      // 0 = 不限
    uint256 periodLimit;  // 0 = 不限
    uint64  period;       // 週期長度(秒)。0 視為不設週期
    uint16  windowStart;  // UTC 當日分鐘數
    uint16  windowEnd;    // start == end 表示全天
}
```

---

## 花費流程

```
agent → EOA.spend(address token, address payee, uint256 amount)
```

**`node` 和 `label` 不由 caller 提供,從 `bindings[msg.sender]` 讀。**
自我審查時發現原本的簽章讓 caller 自己送 `node`,那會產生「node 和 label 不一致」
這一整類要驗證的錯誤。改成綁定時就寫定,這個問題在編譯期就不存在了 ——
一個 agent 對應一個名字,這也符合「多個 agent、各指向不同 policy」的模型。

| 步 | 動作 | 失敗行為 |
|---|---|---|
| 1 | 重入鎖 `entered` | **revert** |
| 2 | **授權**:`bindings[msg.sender].node != 0` 且 `!revoked`,取出 `node` / `label` | **revert** `NotBoundAgent` |
| 3 | `paused`? | `SpendBlocked(PAUSED)`,return |
| 4 | **ENS 三跳** → policy 位址 | 任何一跳失敗或回 `0x0` → `SpendBlocked(NO_POLICY)` |
| 5 | `APPROVALS.isApproved(policy)` | false → `SpendBlocked(POLICY_NOT_APPROVED)` |
| 6 | 發 `PolicyResolved(node, policy, true)` | |
| 7 | 用帳戶自己的 `rules` / `payees` / `spent` 組 `SpendContext` | |
| 8 | `policy.check{gas: POLICY_GAS}(ctx)` | 呼叫失敗或回傳長度 ≠ 32 → `SpendBlocked(POLICY_FAILED)` |
| 9 | `reason != OK` | `SpendBlocked(reason)`,return |
| 10 | **`spent[node][token][period] += amount`** | |
| 11 | `token.transfer(payee, amount)`,檢查回傳值 | **revert** |
| 12 | 發 `SpendExecuted` | |
| 13 | 解鎖 | |

### 為什麼第 2 步 revert 而其他步不 revert

**這條線是刻意畫的。** caller 根本不是被綁定的 agent → 那不是政策決定,是入侵,
沒有必要留下可索引的紀錄。政策違反 → 不轉帳、發事件、正常結束,
因為 subgraph 要索引得到「為什麼被擋」(The Graph 賽道的第 4 個問題)。

> 「擋下來」的證據是**錢沒有動**,不是交易紅字。

### 為什麼第 10 步在第 11 步之前

`token.transfer` 是外部呼叫。惡意的收款人(或惡意代幣)可以在轉帳的
callback 裡回頭再打 `spend`。重入鎖是第一道防線,**先記帳是第二道** ——
兩道都失效才會出事。

### 週期索引:`period == 0` 是一個要處理的邊界

`spent` 以 `periodIdx = block.timestamp / rule.period` 為 key,而 `TokenRule.period`
允許是 `0`(不設週期)—— **直接除會 panic。**

```solidity
uint256 periodIdx = rule.period == 0 ? 0 : block.timestamp / rule.period;
uint64  periodEnd = rule.period == 0
    ? 0                                        // 0 = 「沒有週期」,不是「已經結束」
    : uint64((periodIdx + 1) * rule.period);
```

`period == 0` 時所有花費累計進 `periodIdx = 0`,也就是**永不重置的總額** ——
配上 `periodLimit` 就是一個終身額度。這是合理的語意,不是 fallback。
`SpendExecuted.periodEnd` 送 `0` 表示「不會重置」,subgraph 要照這個解讀。

**這個邊界要有專門的測試**,不能只靠 fuzz 碰巧撞到。

### ENS 三跳

```solidity
function _resolvePolicy(bytes32 node, string memory agentLabel)
    private view returns (address policy)
{
    // 1. ETH_REGISTRY.getSubregistry("leash") → LeashRegistry
    //    這一跳讓 ETHRegistry.setSubregistry(leash.eth, 0x0) 成為「全滅」拉桿
    // 2. LeashRegistry.getResolver(agentLabel) → LeashResolver
    //    這一跳讓 revoke(label) 與 expiry 到期成為「殺一個 agent」的手段
    // 3. LeashResolver.resolve(dnsName, abi.encodeCall(addr, node)) → policy
    // 任何一跳 staticcall 失敗、回傳長度不對、或回 0x0 → 回 address(0)
}
```

**三跳全部用 `staticcall` 並包在 `try` / 低階呼叫裡** ——
ENS 那邊的合約還在 Immunefi 審計期(至 09-14),位址可能變動或行為改變。
我們不能因為別人的合約 revert 就讓帳戶整個卡死;解不出來就是 `NO_POLICY`,
錢不動,而那正是安全的預設。

`label` 與 `node` 兩者都來自綁定,由錢包持有者在 `bindAgent` 時一起寫定 ——
**caller 沒有機會送出不一致的組合。** 這是一個綁定時的不變式,不是每筆花費要驗的東西。

`bindAgent` 應該檢查 `node == namehash(label + ".leash.eth")` 嗎?
**不檢查。** 鏈上算 namehash 要迴圈 keccak,而算錯的後果只是「解不出 policy」
(理由碼 3,錢不動),傷害僅限於綁定者自己。付這個 gas 買不到安全,
只買到早一步的錯誤訊息。**寫進實作註解,免得被當成漏掉的檢查。**

---

## 允許清單的變更:擴權要 attestation,縮權不要

型別上的不對稱是刻意的 —— 看函式簽章就知道哪些操作需要真人。

| 動作 | 誰可以 | 事件 |
|---|---|---|
| `bindAgent(agent, node)` | `msg.sender == address(this)` | `AgentBound` |
| `revokeAgent(agent)` | `address(this)` **或該 agent 自己** | `AgentRevoked` |
| `pause()` | `address(this)` 或任何**未被撤銷的**被綁定 agent | `Paused` |
| `unpause(attestation)` | 要 attestation | `Unpaused` |
| `allowToken(node, token, rule, attestation)` | 要 attestation | `TokenAllowed` |
| `allowPayee(node, token, payee, attestation)` | 要 attestation | `PayeeAllowed` |
| `raiseLimit(node, token, newLimit, period, attestation)` | 要 attestation | `LimitRaised` |
| `removeToken` / `removePayee` / `lowerLimit` | `address(this)` | `TokenRemoved` / `PayeeRemoved` / `LimitLowered` |

**`pause()` 連 agent 自己都能按。** 理由跟 `PolicyApprovals.revoke` 一樣:
踩煞車只會讓系統更嚴,讓它需要權限是在出事的那一刻幫攻擊者省事。

### attestation 的 digest 綁住什麼

```solidity
digest = keccak256(abi.encode(
    TYPEHASH,          // 每個動作一個
    address(this),     // ← 這個錢包。A 的背書挪不到 B
    block.chainid,     // ← 這條鏈
    node, token, ...,  // 動作的參數
    nonce              // ← 防重放
));
require(!usedAttestations[digest]);
```

`address(this)` 在 7702 delegate 裡就是**那個 EOA**,所以同一份 impl 底下
每個錢包的 digest 天然不同 —— 不需要額外的 salt。

---

## 對已凍結文件的兩處增修(都是加法)

`docs/events.md` 的凍結規則是「只准加欄位、加事件」。這兩項符合。

### 1. 新增理由碼 12 `POLICY_FAILED`

第 8 步 fail-closed 時沒有現成的碼可用。挪用 `POLICY_NOT_APPROVED`(4)會誤導
subgraph —— 那個碼的語意是「這份 policy 沒被真人批准」,而這裡的情況是
「這份 policy 壞了或吃太多 gas」。兩者的處置完全不同。

### 2. `IPolicy` 新增一條介面約束

> **policy 只能在回傳 `Reason.OK` 時記帳。**

因為帳戶在被擋時**不 revert**,如果 policy 先扣了共用預算才回傳「超限」,
那筆扣款不會被回滾,共用預算會漏。`SharedBudgetPolicy` 現在的寫法剛好是對的
(先檢查再累加),但那是巧合而不是被要求的 —— 寫進 `IPolicy` 的文件註解。

---

## `LeashLens` —— 韁繩還在嗎

`PLAN.md` 原本寫 `isLeashed(bytes32 node) → (bool, address)`,走「ENS → 錢包 → 委派對象」。
**這個方向不存在** —— ENS 記的是 node → policy,沒有 node → wallet 的反查表,
而建一張反查表要多一份合約和多一筆維護。

改成:

```solidity
contract LeashLens {
    function delegateOf(address wallet) external view returns (bool leashed, address impl);
}
```

讀 `wallet.code`,檢查長度是 23 且前綴為 `0xef0100`,回傳後面那 20 bytes。
前端進頁面時查一次,監控腳本定期查。

**EIP-7702 的委派變更不發任何 log**,所以 subgraph 索引不到「拆掉韁繩」這件事 ——
只能靠 `eth_call` 輪詢。這已經寫在 `events.md`,`LeashLens` 是它的實作。

---

## 錯誤處理總表

| 情況 | 行為 |
|---|---|
| caller 不是被綁定的 agent | **revert** `NotBoundAgent` |
| 重入 | **revert** `Reentrant` |
| ENS 任一跳 revert / 回傳長度不對 / 回 `0x0` | `SpendBlocked(NO_POLICY)` |
| policy 不在批准清單 | `SpendBlocked(POLICY_NOT_APPROVED)` |
| `policy.check` revert / 超過 gas 上限 / 回傳長度 ≠ 32 | `SpendBlocked(POLICY_FAILED)` |
| policy 回傳 `reason != OK` | `SpendBlocked(reason)` |
| `token.transfer` revert 或回傳 `false` | **revert**(整筆原子回滾) |
| `amount == 0` | **revert** `ZeroAmount` —— 沒有意義,而且會污染 subgraph |
| attestation 已用過 | **revert** `AttestationReused` |

**`POLICY_GAS = 200_000`。** policy 真的需要更多就會 fail-closed。
這是刻意的上限:一份能燒掉全部 gas 的 policy 等於一個 DoS 開關。
數字寫成 `constant` 並在文件裡講明。

---

## 測試計畫

| 層 | 工具 | 蓋什麼 |
|---|---|---|
| **7702 語意** | `vm.signAndAttachDelegation` | 委派後可呼叫、storage 屬於 EOA、兩個 EOA 互不干擾、**攻擊者搶不到控制權** |
| **fork** | `vm.createSelectFork(sepolia)` | ENS 三跳打真的 registry,用 09-08 已部署的位址。**快樂路徑必須在這一層驗過** |
| **單元** | mock registry / mock policy | 每一個理由碼各一條測試,含 `POLICY_FAILED` 的三種觸發方式(revert / 燒 gas / 回傳長度錯) |
| **重入** | 惡意代幣與惡意收款人 | 鎖有效,而且「先記帳」在鎖失效時仍然擋得住 |
| **不對稱** | — | 每一個擴權函式沒有 attestation 就失敗;每一個縮權函式不需要 attestation |
| **fuzz** | — | 預算記帳不溢位、不少扣;任意 `amount` 序列的累計等於逐筆相加 |
| **三層撤銷** | fork | 換 policy / `revoke(label)` / `expiry` 到期 / `setSubregistry(0x0)` 各自讓花費停下來 |

**Definition of Done:** fork 測試裡,一個委派過的 EOA 能付款成功、
能被四種撤銷手段各自擋下來,而且每一種都留下正確的理由碼。

---

## 明確不做的事(YAGNI)

| 不做 | 為什麼 |
|---|---|
| 通用的 `execute(target, data)` | `SpendContext` 已凍結成 payee/token/amount 的形狀。通用呼叫要 policy 去解 calldata,那是另一個專案 |
| 原生 ETH 花費 | demo 用 MockUSDC。`token` 欄位保留,ETH 之後用 `address(0)` 慣例補得上 |
| 批次花費 | 一次一筆,事件才對得起來 |
| EIP-4337 相容 | 三個獎項沒有一個要求 |
| 升級機制 | 7702 的重新委派**就是**升級機制 |
