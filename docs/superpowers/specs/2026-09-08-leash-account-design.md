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

`LeashAccount` 是 **agent 的唯一花費路徑**。它把上面四件事變成付款的前置條件,
而且是在 agent 自己的執行流程裡發生的 —— **agent 沒有繞過的選項,
因為檢查不是在它之外,而是在它之內。**

拿掉 ENS,第 4 步解不出 policy,任何 agent 發起的花費都過不了(理由碼 3)。

> ⚠️ **不要說成「唯一的花費路徑」。那句話是假的,而且評審一問就破。**
> EIP-7702 只約束**打到那個 EOA 的呼叫**。WALLET 私鑰照樣可以直接簽
> `to = USDC, data = transfer(任何人, 餘額)`,policy 那條路徑根本不會執行。
>
> 這既是邊界也是**逃生口**:錢包持有者永遠拿得回自己的錢,不會被自己設的
> policy 鎖死。誠實講出來比被問倒好,而且這個版本的故事更站得住。
>
> **要有一條測試把這個邊界釘住:** WALLET 直簽的轉帳成功、且**不發** `SpendExecuted`。

---

## 決策紀錄

實作前先寫下四個已定案的分岔,免得日後被當成「隨手選的」。

| # | 決定 | 否決的選項 | 理由 |
|---|---|---|---|
| 1 | **直接做 7702 delegate**,不做獨立合約錢包 | 合約錢包(sprint 原案)、一份 bytecode 兩用 | 7702 的故事是「既有 EOA 直接被 policy 管,不用搬錢」。工具鏈風險 09-03 已實測解除 |
| 2 | **沒有 `initialize()`**,全域設定寫成 `immutable` | `initialize()` 限 `msg.sender == address(this)` | 沒有初始化動作 = 沒有搶跑面。而且 impl 位址本身就代表整套控制面,`delegateOf` 一個呼叫就問得完 |
| 3 | **「受哪個 ENS 名字管」由 WALLET 自己綁** | 由 ADMIN 綁 | 威脅模型是「agent 被入侵」,不是「錢包持有者害自己」。WALLET 只能在**已被真人核准過的規則集**之間選 |
| 4 | **解析從 `ETH_REGISTRY` 開始**(三跳) | 從 RootRegistry 走四跳、resolver 位址寫死 | 三跳是「保留全部三層撤銷」的最短路徑。四跳多的那一跳買不到撤銷能力;寫死 resolver 會讓 ENS 變成裝飾 |
| 5 | **擴權是「兩個都要」:`msg.sender == address(this)` **且** attestation** | 只要 attestation(初版) | 見下方 C1 —— 只要 attestation 的話,被入侵的 agent 配上 `MockAttester` 一步就能自己擴權 |
| 6 | **`unpause` 只要 `address(this)`,不要 attestation** | 要 attestation(初版) | 凍結文件把理由碼 10 列為「ADMIN 的日常操作」。而且任何 agent 都能免費 `pause`,若 `unpause` 要刷臉,被入侵的 agent 可以反覆逼人刷臉(DoS) |
| 7 | **不做獨立的 `AttesterGate` 合約** | 照凍結文件第四節做一份 | attestation 的消費者只有兩個(`LeashAccount`、`PolicyApprovals`),各自內嵌一段驗證比多一層轉發簡單。**這是對凍結文件的偏離,必須記在變更紀錄裡** |
| 8 | **`setRule`(要 attestation)+ `tightenRule`(只要 `address(this)`)** | 六個各自獨立的 raise/lower 函式 | `TokenRule` 有五個可調欄位,配對式的函式會漏掉 window 和 period。`tightenRule` 要求**每一個欄位都弱單調收緊**,把「更嚴」變成可檢查的斷言 |

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
| 2a | **綁定過嗎**:`bindings[msg.sender].node != 0` | **revert** `NotBoundAgent` |
| 2b | **被撤銷了嗎**:`!revoked` | `SpendBlocked(AGENT_REVOKED)`,return |
| 3 | `paused`? | `SpendBlocked(PAUSED)`,return |
| 4 | **ENS 三跳** → policy 位址 | 任何一跳失敗或回 `0x0` → `SpendBlocked(NO_POLICY)` |
| 5 | `approved = APPROVALS.isApproved(policy)`,**發 `PolicyResolved(node, policy, approved)`** | |
| 6 | `!approved` | `SpendBlocked(POLICY_NOT_APPROVED)`,return |
| 7 | 用帳戶自己的 `rules` / `payees` / `spent` 組 `SpendContext` | |
| 8 | `policy.check{gas: POLICY_GAS}(ctx)` | 呼叫失敗或回傳長度 ≠ 32 → `SpendBlocked(POLICY_FAILED)`。**注意這裡是 32,與 ENS 第三跳的 96 不同** |
| 9 | `reason != OK` | `SpendBlocked(reason)`,return |
| 10 | **`spent[node][token][period] += amount`** | |
| 11 | `token.transfer(payee, amount)`,檢查回傳值 | **revert** |
| 12 | 發 `SpendExecuted` | |
| 13 | 解鎖 | |

### 為什麼 2a revert 而 2b 不 revert

**這條線是刻意畫的,而且初版畫錯了。** 初版把「沒綁定」和「已撤銷」都收斂成
`revert NotBoundAgent`,結果是**理由碼 1 和 2 永遠發不出來** ——
直接違反 `events.md`「理由碼 1–4、10 由 `LeashAccount` 判定」。

凍結文件把 revert 的例外限定在「caller **根本不是**被綁定的 agent」。
而**被撤銷的 agent 是「已綁定」的** —— 撤銷是一個行政動作,那個 agent
應該查得到自己為什麼不能動了(The Graph 賽道的第 4 個問題)。revert 的 log 會被丟棄,
它就查不到。

- **2a 沒綁定 → revert。** 那不是政策決定,是入侵,沒必要留可索引的紀錄
- **2b 已撤銷 → `SpendBlocked(2)`。** 那是政策決定,要留紀錄

> 「擋下來」的證據是**錢沒有動**,不是交易紅字。

### `PolicyResolved.approved` 要送真值

初版把這個事件排在批准檢查**之後**,那時 `approved` 只可能是 `true` ——
凍結 schema 裡那個欄位就永遠是死的。移到檢查**當下**發出,
subgraph 才看得到「指標指到一份沒被批准的 policy」這件事,
而那正是 ADMIN 金鑰被偷時唯一的鏈上訊號。

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
    // 任何一跳 staticcall 失敗、回傳長度不符**該跳的預期**、或回 0x0 → 回 address(0)
}
```

#### 🔴 每一跳的回傳長度不一樣,寫錯就一筆都付不出去

初版只寫「回傳長度不對」,沒說明是多少。**如果實作對第三跳檢查 `== 32`,
快樂路徑永遠不成立**,而且回報的理由碼會是 `NO_POLICY`(「ENS 上讀不到 policy」)——
完全誤導除錯方向,可能燒掉半天。

09-08 對已部署的合約實測(`cast rpc eth_call`,原始 returndata 不解碼):

| 跳 | 呼叫 | 原始 returndata | 為什麼 |
|---|---|---|---|
| 1 | `ETH_REGISTRY.getSubregistry("leash")` | **32 bytes** | 回傳 `address` |
| 2 | `LeashRegistry.getResolver("vendors")` | **32 bytes** | 回傳 `address` |
| 3 | `LeashResolver.resolve(dns, inner)` | **96 bytes** | 回傳 `bytes`:offset(32) + length(32) + 內層(32) |

第三跳的實際位元組:

```
0x 0000…0020   ← offset = 32
   0000…0020   ← length = 32
   0000…b70f52e0ffc361e6e3c7765a58068308d4fa75cc   ← 內層 abi.encode(address)
```

所以第三跳要:`returndatasize() == 96` → 解出外層 `bytes` → 確認其長度為 32 → 再解 `address`。

**實作要求:**
- 每一跳用低階 `staticcall` 並各自檢查自己的預期長度,不要共用一個常數
- 用**有界的** `returndatacopy`,不要無界複製別人回傳的資料(對方是外部合約)
- 每一跳都加 gas 上限 —— ENS 的合約在審計期,不能讓它拖垮我們
- **測試要對每一跳的長度各寫一條**,而且快樂路徑必須在 fork 測試裡跑過真的鏈

**三跳全部用 `staticcall` 並包在 `try` / 低階呼叫裡** ——
ENS 那邊的合約還在 Immunefi 審計期(至 09-14),位址可能變動或行為改變。
我們不能因為別人的合約 revert 就讓帳戶整個卡死;解不出來就是 `NO_POLICY`,
錢不動,而那正是安全的預設。

`label` 與 `node` 兩者都來自綁定,由錢包持有者在 `bindAgent` 時一起寫定 ——
**caller 沒有機會送出不一致的組合。** 這是一個綁定時的不變式,不是每筆花費要驗的東西。

### 🔴 `bindAgent` **必須**檢查 `node == namehash(label + ".leash.eth")`

初版寫「不檢查」,理由是「鏈上算 namehash 要迴圈 keccak,而算錯只是解不出 policy」。
**兩個前提都是錯的。**

**錯一:成本。** 父層固定是 `leash.eth`,所以只要**兩次 keccak**,不是迴圈:

```solidity
bytes32 expected = keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
```

`PARENT_NODE = namehash("leash.eth")` 是編譯期常數
(`0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf`)。約 200 gas,一次。

**錯二:後果。** `node` **不只是** resolver 的 key —— 它也是 `rules` / `payees` / `spent`
的 key。所以:

```
bindAgent(agentB, node = namehash("vendors.leash.eth"), label = "payroll")
```

會讓 agentB 花 **vendors 那份真人核准過的額度與預算**,卻由 **payroll 的 policy** 判斷。
兩套規則被錯接在一起,而 `AgentBound(agent, node)` 事件**不帶 label**
(`events.md`),所以**鏈下完全看不出來**。

200 gas 一次,把一個看不見的錯誤設定換成一個 revert。**要檢查。**

---

## 非 `spend` 的呼叫面:`receive()` 是必要的,不是禮貌

**委派之後,純轉 ETH 進那個 EOA = 用空 calldata 呼叫 delegate。**
兩個都沒有 → Solidity 的 dispatcher revert → **那個錢包收不到 ETH,加不了 gas。**
faucet、交易所、`cast send --value` 全部失效,而 `PLAN.md` 明寫要分次補款。

09-08 用本機 anvil 實測確認:

| delegate | `payable(eoa).call{value: 1 ether}("")` |
|---|---|
| 沒有 `receive()` | **`false`** |
| 有 `receive()` | `true`,餘額正確增加 |

```solidity
receive() external payable { }              // 必須有,否則錢包變成單向的
fallback() external payable { revert UnknownSelector(); }   // 明確拒絕,不要靜默吞掉
```

> **這一條同時是我 09-08 修正記憶時修過頭的地方。** `ensv2-sepolia.md` 原本記著
> 「交易的 `to` 不可是被委派的 EOA 本身」,我把整條標成錯的 —— 但它對**空 calldata**
> 的情況是對的,只有對「非空且 selector 對得上」的情況是錯的。兩種 calldata 要分開講。

`fallback` 用 `revert` 而不是靜默接受,因為靜默接受會讓「打錯 selector」
看起來像成功。這個帳戶不做通用呼叫轉發(見 YAGNI 表)。

## 允許清單的變更:擴權要 attestation,縮權不要

型別上的不對稱是刻意的 —— 看函式簽章就知道哪些操作需要真人。

> 🔴 **這張表初版有一個 critical。** 初版的擴權那幾列只寫「要 attestation」,
> 沒有 sender 檢查 —— 因為我照抄了 `PolicyApprovals.sol` 的註解
> 「門檻是背書,不是身分」。**那個註解在它自己的情境裡是對的,套到這裡是錯的:**
> `PolicyApprovals` 是全域單例,「誰送這筆交易」真的不重要;
> 而 per-wallet 的帳戶**有一個天然的正規送出者**(錢包自己)。
>
> 配上 `MockAttester`(對任何輸入回 `true`,而且**就是我們 09-08 部署在 Sepolia
> 上正在用的那一個**),被入侵的 agent 三步就能清空錢包:
> `allowPayee(自己)` → `allowToken(無限額度)` → `spend(全部餘額)`。
> 它沒有繞過檢查 —— **它改寫了檢查的輸入。**
>
> 而且這復活了決定 2 想殺掉的攻擊:委派後 storage 空白的那段窗口,
> 任何人都能先把自己種進白名單,等真正的持有者綁定 agent 之後就生效,
> 而持有者沒有理由去看。**決定 2 是對的,但不夠。**

| 動作 | 誰可以 | 要 attestation | 事件 |
|---|---|---|---|
| `bindAgent(agent, node, label)` | `address(this)` | ❌ | `AgentBound` |
| `restoreAgent(agent, attestation)` | `address(this)` | ✅ | `AgentBound` |
| `revokeAgent(agent)` | `address(this)` **或該 agent 自己** | ❌ | `AgentRevoked` |
| `pause()` | `address(this)` 或任何**未被撤銷的**被綁定 agent | ❌ | `Paused` |
| `unpause()` | `address(this)` | ❌ | `Unpaused` |
| `setRule(node, token, rule, attestation)` | `address(this)` | ✅ | `TokenAllowed` / `LimitRaised` |
| `allowPayee(node, token, payee, attestation)` | `address(this)` | ✅ | `PayeeAllowed` |
| `tightenRule(node, token, rule)` | `address(this)` | ❌ | `LimitLowered` / `TokenRemoved` |
| `removePayee(node, token, payee)` | `address(this)` | ❌ | `PayeeRemoved` |

**擴權是「兩個都要」(two-of-two):`msg.sender == address(this)` **且** 有效的 attestation。**

**`bindAgent` 對已存在的綁定必須 revert。** 否則「撤銷一個 agent 之後免費重新綁回來」
就繞過了凍結文件對理由碼 2 的規定(`AGENT_REVOKED` 的解除條件是
「ADMIN(縮權免刷臉,**恢復要刷臉**)」)。恢復走 `restoreAgent`,要 attestation。
每個函式一行的成本,而它把 C1 那條攻擊鏈的第一步就切斷了。

**`pause()` 連 agent 自己都能按。** 理由跟 `PolicyApprovals.revoke` 一樣:
踩煞車只會讓系統更嚴,讓它需要權限是在出事的那一刻幫攻擊者省事。
**但 `unpause` 因此不能要 attestation** —— 否則被入侵的 agent 可以免費 `pause`、
反覆逼持有者刷臉。免費的煞車必須配免費的放開,兩邊都由錢包自己控制。

### `tightenRule`:把「更嚴」變成可檢查的斷言

`TokenRule` 有五個可調欄位(`allowed` / `txLimit` / `periodLimit` / `period` / 時段)。
配對式的 raise/lower 函式會漏掉 window 和 period,而**漏掉的那些正好可以被用來放寬**:

> `period` 一改,`periodIdx` 就變,`spent` 的計數歸零 —— **「調低上限」反而讓可花的變多。**

所以縮權只有一個入口,而且它要求**每一個欄位都弱單調收緊**:

```solidity
function _isTighter(TokenRule memory old_, TokenRule memory new_) private pure returns (bool) {
    if (old_.allowed && !new_.allowed) return true;      // 直接關掉一定更嚴
    if (!old_.allowed) return false;                     // 原本就關著,沒有更嚴可言
    return _lteOrUnlimited(new_.txLimit, old_.txLimit)
        && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
        && new_.period == old_.period                    // ← 不准動,見上
        && _windowIsSubset(new_, old_);
}
```

注意 `0 = 不限` 的語意讓「比較大小」不是單純的 `<=`:從 `0` 改成 `100` 是**收緊**,
從 `100` 改成 `0` 是**放寬**。`_lteOrUnlimited` 要處理這個反轉,**而且要有專門測試** ——
這是最容易寫反的一行。

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

## 對已凍結文件的四處增修 —— **其中一項不是加法**

`docs/events.md` 的凍結規則是「只准加欄位、加事件,**不准改既有欄位的型別、順序或語意**」。
初版聲稱只有兩處增修、都是加法。**那是錯的** —— review 抓出實際是四處,
而且有一處是偏離、一處是值域擴大、一處根本是我寫錯。
凍結規則的意義就是逼這種事浮出來,所以全部列在下面,並且要在 `events.md`
的變更紀錄留下對應的行。

### 1. 新增理由碼 12 `POLICY_FAILED`

第 8 步 fail-closed 時沒有現成的碼可用。挪用 `POLICY_NOT_APPROVED`(4)會誤導
subgraph —— 那個碼的語意是「這份 policy 沒被真人批准」,而這裡的情況是
「這份 policy 壞了或吃太多 gas」。兩者的處置完全不同。

### 2. `IPolicy` 新增一條介面約束

> **policy 只能在回傳 `Reason.OK` 時記帳。**

因為帳戶在被擋時**不 revert**,如果 policy 先扣了共用預算才回傳「超限」,
那筆扣款不會被回滾,共用預算會漏。`SharedBudgetPolicy` 現在的寫法剛好是對的
(先檢查再累加),但那是巧合而不是被要求的 —— 寫進 `IPolicy` 的文件註解。

### 3. `AttesterGate` 不會存在,那些事件改由消費者發出 ⚠️ **偏離**

`events.md` 第四節有一個獨立元件 `AttesterGate`,帶 `AttestationAccepted(...)`。
我們決定不做(決定 7)—— attestation 的消費者只有 `LeashAccount` 和 `PolicyApprovals`,
各自內嵌驗證比多一層轉發簡單,而多一份合約在 5 天的預算裡買不到東西。

**這改變的是「誰發這個事件」**,不是欄位。subgraph 的資料來源要跟著改。
要在 `events.md` 標注這個元件不存在,免得日後有人以為漏做了。

另外 `AttestationAccepted.action` 的文件寫「對應理由碼 4–9」,而我們還需要涵蓋
**11**(共用預算)。那是**擴大既有欄位的值域**,變更紀錄要記一行。

### 4. 理由碼 10 `PAUSED` ⚠️ **這一項是 spec 錯了,不是文件要改**

凍結表寫:`| 10 | PAUSED | 整個帳戶被暫停 | **ADMIN** |`,下方註明
「1–3、10 是 ADMIN 的日常操作」——**不需刷臉**。

初版 spec 寫 `unpause(attestation)`,**與凍結文件直接衝突**。

**凍結文件是對的。** 而且理由比「文件先寫」更實質:任何被綁定的 agent 都能免費
`pause`,若 `unpause` 要刷臉,被入侵的 agent 就能反覆逼持有者刷臉 —— 那是一個 DoS。
免費的煞車必須配免費的放開。已依決定 6 改成 `address(this)`。

**我把這一項列在這裡,是因為初版 spec 聲稱「只有兩處增修、都是加法」而那是錯的。**
四處裡有一處是偏離(第 3 項)、一處是值域擴大(第 3 項後半)、一處根本是我寫錯
(第 4 項)。凍結規則的意義就是逼這種事浮出來,不該悄悄改掉。

### 一件不是文件問題、但會讓 subgraph 索引不到的事

`SpendExecuted` / `SpendBlocked` **是從每一個 EOA 自己發出來的**,不是從一份共用合約。
而 7702 的委派**不發任何 log**,所以沒有 factory 事件可以觸發 subgraph 的 template ——
**subgraph 不知道要監聽哪些位址。**

兩個解法,sprint 項目 9 要挑:
- 在 `subgraph.yaml` 裡**寫死** demo 用的錢包位址(最簡單,hackathon 足夠)
- 在**第一次 `bindAgent`** 時發 `Leashed(node, wallet, impl)` 當 template 的觸發點
  (較乾淨,而且 `Leashed` 已經在凍結 schema 裡,正好給它一個明確的觸發時機)

**建議兩個都做:** 發 `Leashed` 是對的設計,寫死位址是 demo 的保險。


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
| `token.transfer` revert 或回傳非 32-byte `true` | **revert**(整筆原子回滾) |
| `amount == 0` | **revert** `ZeroAmount` —— 沒有意義,而且會污染 subgraph |
| `token` 或 `payee` 是 `address(this)` / `address(0)` | **revert** `BadTarget`(見下) |
| `token.code.length == 0` | **revert** `BadTarget` |
| attestation 已用過 | **revert** `AttestationReused` |

### 🔴 `token` 和 `payee` 由 agent 指定,必須擋掉指回自己

第 11 步 `token.transfer(payee, amount)` 送出去時,`msg.sender == address(this)` ——
**那正是 `bindAgent` / `tightenRule` / `removePayee` 接受的那個憑證。**

今天的 selector 沒有碰撞(`transfer` 是 `0xa9059cbb`),所以不是立即的接管。
但危險在回傳值檢查:如果用 SafeERC20 那種寬鬆慣例
(`success && (ret.length == 0 || abi.decode(ret) == true)`),那麼:

- `token == address(this)` → 打到自己的 `fallback`,若 `fallback` 不 revert 就**回報成功但沒有轉帳**
- `token == address(0)` → 對空位址的呼叫**永遠成功、回傳空 returndata** → 寬鬆檢查判定成功

兩種情況都是:**`spent` 增加、`SpendExecuted` 發出,而錢一分都沒動。**
subgraph 會記下一筆不存在的付款。

```solidity
if (token == address(this) || payee == address(this)) revert BadTarget();
if (token == address(0)   || payee == address(0))     revert BadTarget();
if (token.code.length == 0)                           revert BadTarget();
// policy 也不能是自己 —— 同樣的憑證問題
if (policy == address(this)) return NO_POLICY;
```

**而且回傳值檢查要嚴格:** 恰好 32 bytes 且解出來是 `true`。
不用 SafeERC20 的寬鬆版 —— 我們只需要支援自己 demo 用的代幣,
不需要相容那些回傳空值的老式 ERC-20。**寬鬆換來的相容性,在這裡的代價是一個假的成功。**

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
| **每一跳的長度** | fork + mock | 第 1/2 跳 32 bytes、第 3 跳 96 bytes。**故意回傳錯長度的假 registry 要被判成 `NO_POLICY`** |
| **收 ETH** | 7702 | 委派後 `payable(wallet).call{value: 1 ether}("")` **必須成功** |
| **C1 迴歸** | 7702 + `MockAttester` | **在 mock attester 接著的情況下**,非 `address(this)` 的 caller 呼叫每一個擴權函式都要失敗 |
| **C4 邊界** | 7702 | WALLET 直簽 `USDC.transfer` **成功**,且**不發** `SpendExecuted` —— 把逃生口釘成規格 |
| **假成功** | mock | `token`/`payee` = `address(this)` / `address(0)` / 無 code → revert,`spent` 不變 |
| **`period` 不能復活預算** | — | 花掉一部分 → `tightenRule` 改 `period` → 必須 revert;`setRule` 改 period 後累計不得歸零而變得可花更多 |
| **`0 = 不限` 的反轉** | — | `txLimit` 從 `0`→`100` 是收緊(允許);`100`→`0` 是放寬(`tightenRule` 要拒絕) |
| **impl 直接呼叫是惰性的** | — | 直接對 impl 位址呼叫 `spend` / 擴權函式,不得有任何效果 |
| **理由碼全覆蓋** | mock | 每一個碼:`SpendBlocked` 有發出 **且** `balanceOf` 沒變 |

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
