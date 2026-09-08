# LeashAccount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一份 EIP-7702 delegate 實作,讓被委派的 EOA 在任何 ERC-20 轉帳之前,強制走過「授權 agent → ENS 三跳解析 policy → 比對批准清單 → 呼叫 policy」四道關卡。

**Architecture:** 單一 impl 合約,零實例狀態。全域設定(ETH_REGISTRY / APPROVALS / SELF)是 `immutable`,所以**沒有 `initialize()`,沒有搶跑面**。per-EOA 狀態放在 ERC-7201 具名槽位,跑在 EOA 自己的 storage 上。政策違反 → 不轉帳 + 發事件(不 revert),只有授權失敗 revert。擴權要「`msg.sender == address(this)` 且 attestation」兩個都要;縮權永遠免費。

**Tech Stack:** Solidity 0.8.28、Foundry(`evm_version = "prague"`)、OpenZeppelin v5.1.0、`vm.signAndAttachDelegation` 測 7702、`vm.createSelectFork` 打真的 Sepolia。

**Spec:** `docs/superpowers/specs/2026-09-08-leash-account-design.md`

## Global Constraints

以下每一項都是**全域**要求,每個任務的驗收條件都隱含包含它們。數值一律照抄 spec,不要重算。

- **Solidity `0.8.28`,`evm_version = "prague"`**(7702 需要)。已在 `foundry.toml`。
- **ERC-7201 槽位常數:** `0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800`
  = `keccak256(abi.encode(uint256(keccak256("leash.account.v1")) - 1)) & ~bytes32(uint256(0xff))`。
  **任務 1 要用測試把這個值釘住。** 算錯的話所有狀態都跑到別的槽位。
- **`namehash("leash.eth")`** = `0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf`
- **`namehash("vendors.leash.eth")`** = `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121`
- **Sepolia 上已部署的位址**(`docs/deployments.md`,2026-09-08 16:34 UTC 那一組):
  - `ETH_REGISTRY` = `0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2`
  - `LeashRegistry` = `0x6fB6CB4a789067b2283C4d4C657d3422ce742A51`
  - `LeashResolver` = `0x607a4d7363d9E7511a932F82eAE1e12FB609915b`
  - `PolicyApprovals` = `0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4`
  - `StandardPolicy` = `0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b`
  - `MockAttester` = `0x268990a91B0727E80d38d5ED4Ab10d8889754124`
  - `MockUSDC` = `0x768f42455a2d082e23ceef7d51e5787c82d67a39`
- **ENS 三跳的回傳長度不同,不要共用一個常數:** hop1 `32`、hop2 `32`、**hop3 `96`**
  (`bytes` = offset 32 + length 32 + 內層 32)。寫成 `==32` 檢查 hop3 的話**快樂路徑永遠不成立**。
- **`POLICY_GAS = 200_000`。** policy 超過就 fail-closed(理由碼 12)。
- **理由碼**照 `src/Reason.sol`,**數字不准重排**。帳戶層判定 1、2、3、4、10、12;policy 判定 5–9、11。
- **事件簽章**照 `docs/events.md`(已凍結)。只准加欄位,不准改型別、順序、語意。
- **EIP-712 domain:** `name = "Leash"`、`version = "1"`、`chainId = block.chainid`、
  `verifyingContract = address(this)`。與 `PolicyApprovals` / `LeashRegistry` 一致。
- **attestation digest 一定要含 `SELF`**(impl 自己被部署時的位址)。`address(this)` 在
  delegate 裡是 EOA,重新委派到新版 impl 之後仍相同 —— 少了 `SELF` 就能跨版本重放。
- **禁止:** 通用 `execute(target, data)`、原生 ETH 花費、批次花費、EIP-4337、升級機制。
  (7702 的重新委派**就是**升級機制。)
- **每個任務結束前:** `forge fmt` 且 `forge test` 全綠。現有 99 個測試不准變紅。

---

## File Structure

| 檔案 | 責任 | 任務 |
|---|---|---|
| `src/LeashStorage.sol` | **建立** —— ERC-7201 具名槽位、`AccountStorage` / `AgentBinding` / `TokenRule` 三個 struct、取槽位的 `layout()` | 1 |
| `src/LeashLens.sol` | **建立** —— `delegateOf(address)`,讀 EOA 的 code 判斷韁繩還在不在。純 view,不碰狀態 | 1 |
| `src/LeashAccount.sol` | **建立** —— 主體。任務 2–6 逐步長出來,最後約 400 行 | 2,3,4,5,6 |
| `src/Reason.sol` | 不動(理由碼 12 已於 09-08 加好) | — |
| `src/IPolicy.sol` | **修改** —— 補一條介面約束註解:policy 只能在回傳 `OK` 時記帳 | 6 |
| `test/LeashStorage.t.sol` | **建立** —— 釘住槽位常數 | 1 |
| `test/LeashLens.t.sol` | **建立** —— 7702 委派前後、非 23 bytes、前綴不符 | 1 |
| `test/LeashAccountBinding.t.sol` | **建立** —— 綁定、暫停、7702 語意、搶跑防護 | 2,3 |
| `test/LeashAccountRules.t.sol` | **建立** —— `setRule` / `tightenRule` / `_isTighter` / window 子集 / epoch | 4 |
| `test/LeashAccountSpend.t.sol` | **建立** —— `spend` 全流程、每一個理由碼、重入、假成功 | 5,6 |
| `test/LeashAccountFork.t.sol` | **建立** —— 打真的 Sepolia:快樂路徑 + 四種撤銷 | 7 |
| `test/mocks/` | **建立** —— `MockRegistry`(可設定回傳長度)、`ReenteringToken`、`BadReturnToken`、`GasBurningPolicy` | 5 |
| `script/DeployAccount.s.sol` | **建立** —— 部署 impl + lens,委派 WALLET,綁 agent,設規則 | 7 |

**拆檔理由:** `LeashAccount` 的測試按**關注點**分三個檔(綁定 / 規則 / 花費),
不是按「單元 / 整合」分。同一個關注點的測試會一起改,放一起;
而 `spend` 的測試檔會是最大的一個,單獨放才不會跟規則的測試互相干擾。

---

## Task 1: `LeashStorage` + `LeashLens`

最小、最獨立的一塊。先做它有兩個好處:槽位常數一旦釘住,後面所有任務都建在正確的地基上;
而 `LeashLens` 完全不依賴 `LeashAccount`,可以馬上驗證 7702 的 code 佈局。

**Files:**
- Create: `src/LeashStorage.sol`
- Create: `src/LeashLens.sol`
- Test: `test/LeashStorage.t.sol`
- Test: `test/LeashLens.t.sol`

**Interfaces:**
- Consumes: 無
- Produces:
  - `library LeashStorage` 內含 `struct AccountStorage`、`struct AgentBinding`、`struct TokenRule`
  - `function layout() internal pure returns (AccountStorage storage $)`
  - `bytes32 internal constant SLOT`
  - `contract LeashLens` 有 `function delegateOf(address wallet) external view returns (bool leashed, address impl)`

- [ ] **Step 1: 寫失敗的測試 —— 釘住槽位常數**

```solidity
// test/LeashStorage.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashStorage } from "../src/LeashStorage.sol";

/// @dev 把 library 的 internal 常數暴露出來測。
contract StorageProbe {
    function slot() external pure returns (bytes32) {
        return LeashStorage.SLOT;
    }

    /// 寫一個值進去,再用 `vm.load` 從那個槽位讀回來 —— 證明它真的住在那裡。
    function setPaused(bool v) external {
        LeashStorage.layout().paused = v;
    }

    function paused() external view returns (bool) {
        return LeashStorage.layout().paused;
    }
}

contract LeashStorageTest is Test {
    StorageProbe probe;

    function setUp() public {
        probe = new StorageProbe();
    }

    /// 這個常數算錯的話,所有狀態都跑到別的槽位 —— 而且不會有任何錯誤訊息。
    /// 測試在這裡重算一次 ERC-7201 的公式,不是抄常數。
    function test_slot_matches_the_erc7201_formula() public view {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("leash.account.v1")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(probe.slot(), expected, "ERC-7201 derivation");
        assertEq(
            probe.slot(),
            0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800,
            "the value recorded in the spec"
        );
    }

    /// ERC-7201 要求低 8 bits 為 0(留給未來擴充,也避免與短陣列的槽位計算相撞)。
    function test_slot_is_byte_aligned() public view {
        assertEq(uint256(probe.slot()) & 0xff, 0);
    }

    /// 證明狀態真的落在那個槽位,不只是常數對。
    function test_state_actually_lives_at_that_slot() public {
        probe.setPaused(true);
        assertTrue(probe.paused());

        // `paused` 是 struct 裡的一個 bool 欄位。它前面有四個 mapping,
        // 每個 mapping 佔一個槽位,所以 paused 落在 SLOT + 5(見 LeashStorage 的欄位順序)。
        bytes32 raw = vm.load(address(probe), bytes32(uint256(probe.slot()) + 5));
        assertEq(uint256(raw) & 0xff, 1, "paused is the low byte of SLOT+5");
    }
}
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashStorage -vv`
Expected: 編譯失敗,`Source "src/LeashStorage.sol" not found`

- [ ] **Step 3: 寫最小實作**

```solidity
// src/LeashStorage.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashStorage —— `LeashAccount` 的 per-EOA 狀態佈局
/// @notice **這個 library 存在的理由是 EIP-7702 特有的一個風險。**
///
///         委派的程式碼跑在 **EOA 自己的 storage** 上。如果這個 EOA 之後改委派給
///         **另一份佈局不同的 impl**,舊資料會被誤讀成新意義 —— 預算被讀成 admin
///         位址那種災難。
///
///         解法是 ERC-7201 具名槽位:整包狀態放進一個 struct,擺在
///         `keccak256("leash.account.v1")` 推導出的槽位。**版本號寫在字串裡** ——
///         換佈局就換字串,舊槽位永遠不會被誤讀。
library LeashStorage {
    /// @dev 一個 agent 的綁定。`node` 與 `label` 在 `bindAgent` 時一起寫定,
    ///      所以 caller 沒有機會送出不一致的組合(那是綁定時的不變式)。
    struct AgentBinding {
        bytes32 node; // namehash("<label>.leash.eth"),resolver 讀記錄用
        string label; // "vendors",走 LeashRegistry.getResolver(label) 用
        bool revoked;
    }

    /// @dev 一個 (node, token) 的規則。**五個可調欄位**,加一個只增不減的 epoch。
    struct TokenRule {
        bool allowed;
        uint256 txLimit; // 0 = 不限
        uint256 periodLimit; // 0 = 不限
        uint64 period; // 週期長度(秒)。0 = 不設週期
        uint16 windowStart; // UTC 當日分鐘數
        uint16 windowEnd; // start == end 表示全天
        uint32 epoch; // **只增不減。** 任何改動 period 的操作都要 +1
    }

    /// @custom:storage-location erc7201:leash.account.v1
    /// @dev **欄位順序不要動。** `test_state_actually_lives_at_that_slot` 依賴
    ///      `paused` 在 SLOT+5(前面五個 mapping 各佔一槽)。
    struct AccountStorage {
        mapping(address agent => AgentBinding) bindings; // SLOT + 0
        mapping(bytes32 node => mapping(address token => TokenRule)) rules; // SLOT + 1
        mapping(bytes32 node => mapping(address token => mapping(address payee => bool))) payees; // +2
        mapping(bytes32 node => mapping(address token => mapping(uint256 bucket => uint256))) spent; // +3
        mapping(bytes32 digest => bool) attestationUsed; // SLOT + 4
        bool paused; // SLOT + 5
        bool entered; // SLOT + 5(與 paused 共用一槽,各佔一個 byte)
        bool leashedEmitted; // SLOT + 5 —— `Leashed` 只發一次,見 LeashAccount.bindAgent
    }

    /// @dev ERC-7201:`keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff`
    ///      算出來的值由 `test_slot_matches_the_erc7201_formula` 釘住。
    bytes32 internal constant SLOT =
        0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800;

    function layout() internal pure returns (AccountStorage storage $) {
        bytes32 s = SLOT;
        assembly {
            $.slot := s
        }
    }
}
```

- [ ] **Step 4: 跑測試確認它通過**

Run: `forge test --match-contract LeashStorage -vv`
Expected: 3 passed

- [ ] **Step 5: 寫 `LeashLens` 的失敗測試**

```solidity
// test/LeashLens.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashLens } from "../src/LeashLens.sol";

contract Dummy {
    uint256 public x;
}

contract LeashLensTest is Test {
    LeashLens lens;
    uint256 pk = 0xA11CE;
    address alice;
    Dummy impl;

    function setUp() public {
        lens = new LeashLens();
        alice = vm.addr(pk);
        impl = new Dummy();
    }

    /// 沒委派的 EOA:code 是空的。
    function test_plain_eoa_is_not_leashed() public view {
        (bool leashed, address to) = lens.delegateOf(alice);
        assertFalse(leashed);
        assertEq(to, address(0));
    }

    /// 委派之後 code 是 23 bytes 的 `0xef0100 || address`。
    function test_delegated_eoa_reports_its_impl() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed, address to) = lens.delegateOf(alice);
        assertTrue(leashed);
        assertEq(to, address(impl));
    }

    /// 一般合約不是 7702 委派 —— code 長度不是 23。
    function test_a_normal_contract_is_not_a_delegation() public view {
        (bool leashed, address to) = lens.delegateOf(address(impl));
        assertFalse(leashed, "a contract is not a delegation");
        assertEq(to, address(0));
    }

    /// **EIP-7702 的委派變更不發任何 log**,所以 subgraph 索引不到「拆掉韁繩」——
    /// 這個 lens 就是那件事唯一的觀測手段(前端進頁面查一次,監控腳本定期查)。
    /// 這條測試證明它偵測得到委派被移除。
    function test_detects_removal_of_the_delegation() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed,) = lens.delegateOf(alice);
        assertTrue(leashed);

        vm.signAndAttachDelegation(address(0), pk); // 撤銷委派
        (bool after_, address to) = lens.delegateOf(alice);
        assertFalse(after_, "leash is gone");
        assertEq(to, address(0));
    }
}
```

- [ ] **Step 6: 跑測試確認它失敗**

Run: `forge test --match-contract LeashLens -vv`
Expected: 編譯失敗,`Source "src/LeashLens.sol" not found`

- [ ] **Step 7: 寫 `LeashLens`**

```solidity
// src/LeashLens.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashLens —— 韁繩還在嗎
/// @notice **EIP-7702 的委派變更不發任何 log。** 所以「這個錢包還被 policy 管著嗎」
///         這件事 subgraph 索引不到,只能靠 `eth_call` 輪詢 ——
///         前端進頁面時查一次,監控腳本定期查。這份合約就是那個查詢。
///
/// @dev `PLAN.md` 原本寫的是 `isLeashed(bytes32 node) → (bool, address)`,走
///      「ENS → 錢包 → 委派對象」。**那個方向不存在** —— ENS 記的是 node → policy,
///      沒有 node → wallet 的反查表,而建一張要多一份合約和多一份維護。
///      改成拿錢包位址來問。
contract LeashLens {
    /// @notice 讀 `wallet` 的 code,判斷它是不是一個 EIP-7702 委派。
    /// @return leashed 是不是委派
    /// @return impl 委派的對象;不是委派時回 `address(0)`
    ///
    /// @dev 委派後的 code 恰好是 23 bytes 的 `0xef0100 || address` ——
    ///      一個雙射,所以讀出位址比讀 codehash 有用(位址可以直接顯示在 UI 上,
    ///      而 codehash 只是那 23 bytes 的 keccak,資訊量完全相同)。
    function delegateOf(address wallet) external view returns (bool leashed, address impl) {
        if (wallet.code.length != 23) return (false, address(0));
        bytes memory c = wallet.code;
        if (uint8(c[0]) != 0xef || uint8(c[1]) != 0x01 || uint8(c[2]) != 0x00) {
            return (false, address(0));
        }
        // 跳過 3 bytes 前綴。`mload(add(c, 0x23))` 讀的是 c 的第 3..35 byte,
        // 右移 96 bits 留下高位的 20 bytes。
        assembly {
            impl := shr(96, mload(add(c, 0x23)))
        }
        return (true, impl);
    }
}
```

- [ ] **Step 8: 跑測試確認它通過**

Run: `forge test --match-contract LeashLens -vv`
Expected: 4 passed

- [ ] **Step 9: 格式化並跑全部測試**

Run: `forge fmt && forge test`
Expected: 106 passed(原 99 + 3 + 4),0 failed

- [ ] **Step 10: Commit**

```bash
git add src/LeashStorage.sol src/LeashLens.sol test/LeashStorage.t.sol test/LeashLens.t.sol
git commit -m "feat: LeashStorage(ERC-7201 佈局)+ LeashLens(讀 7702 委派)

ERC-7201 具名槽位是必要的而不是講究:委派的程式碼跑在 EOA 自己的 storage 上,
之後改委派給另一份佈局不同的 impl 時,舊資料會被誤讀成新意義。版本號寫在
字串裡(leash.account.v1),換佈局就換字串。

測試不抄常數,而是在測試裡重算一次 ERC-7201 的公式,並用 vm.load 證明狀態
真的落在那個槽位 —— 算錯的話所有狀態都跑到別處,而且不會有任何錯誤訊息。

LeashLens 取代 PLAN 原本寫的 isLeashed(bytes32 node):node → wallet 這個
方向不存在,ENS 記的是 node → policy。改成拿錢包位址問。
EIP-7702 的委派變更不發 log,所以這是「韁繩還在嗎」唯一的觀測手段。"
```

---

## Task 2: `LeashAccount` 骨架 —— 7702 語意、`receive`、attestation 消費

這個任務不做任何業務邏輯,只把**地基**架好:immutables、7702 的呼叫面、
EIP-712 digest 的計算與消費。做完之後應該能證明兩件關鍵的事:
**委派後 EOA 收得到 ETH**、**攻擊者搶不到控制權**。

**Files:**
- Create: `src/LeashAccount.sol`
- Test: `test/LeashAccountBinding.t.sol`

**Interfaces:**
- Consumes: `LeashStorage.layout()`、`LeashStorage.AccountStorage`(任務 1)
- Produces:
  - `constructor(address ethRegistry_, IPolicyApprovals approvals_, IAttester attester_)`
  - `address public immutable ETH_REGISTRY` / `IPolicyApprovals public immutable APPROVALS`
    / `IAttester public immutable ATTESTER` / `address public immutable SELF`
  - `string public constant PARENT_LABEL = "leash"`
  - `bytes32 public constant PARENT_NODE`
  - `function domainSeparator() public view returns (bytes32)`
  - `receive() external payable` / `fallback() external payable`
  - `error NotSelf()` / `error NotAttested()` / `error AttestationReused(bytes32)` / `error UnknownSelector()`
  - `modifier onlySelf()`
  - `function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private`

- [ ] **Step 1: 寫失敗的測試 —— 7702 語意與搶跑防護**

```solidity
// test/LeashAccountBinding.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract MockApprovals is IPolicyApprovals {
    mapping(address => bool) public approved;

    function set(address p, bool v) external {
        approved[p] = v;
    }

    function isApproved(address p) external view returns (bool) {
        return approved[p];
    }
}

contract LeashAccountBindingTest is Test {
    LeashAccount impl;
    MockApprovals approvals;
    MockAttester attester;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant AGENT = address(0xA6E17);
    address constant ATTACKER = address(0xBAD);
    address constant ETH_REGISTRY = address(0xE45);

    bytes constant ATT = hex"c0ffee";
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    /// 委派過的 EOA,用 LeashAccount 的介面來呼叫它。
    LeashAccount acct;

    function setUp() public {
        approvals = new MockApprovals();
        attester = new MockAttester();
        impl = new LeashAccount(ETH_REGISTRY, approvals, attester);
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    // --- 7702 語意 ---

    /// 委派後 EOA 的 code 是 23 bytes 的 `0xef0100 || impl`。
    function test_delegation_layout() public view {
        assertEq(wallet.code.length, 23);
        assertEq(uint8(wallet.code[0]), 0xef);
        assertEq(uint8(wallet.code[1]), 0x01);
        assertEq(uint8(wallet.code[2]), 0x00);
    }

    /// 🔴 **C2 迴歸:委派之後那個錢包必須收得到 ETH。**
    ///
    /// 純轉 ETH = 用**空 calldata** 呼叫 delegate。沒有 `receive()` 的話
    /// Solidity 的 dispatcher 會 revert,而那意味著 faucet、交易所、
    /// `cast send --value` 全部失效 —— 委派之後就加不了 gas。
    function test_delegated_wallet_can_still_receive_eth() public {
        deal(address(this), 1 ether);
        uint256 before = wallet.balance;
        (bool ok,) = payable(wallet).call{ value: 1 ether }("");
        assertTrue(ok, "empty calldata must hit receive()");
        assertEq(wallet.balance - before, 1 ether);
    }

    /// 打錯 selector 要明確 revert,不要靜默吞掉 ——
    /// 靜默接受會讓「打錯 selector」看起來像成功。
    function test_unknown_selector_reverts() public {
        vm.expectRevert(LeashAccount.UnknownSelector.selector);
        (bool ok,) = wallet.call(abi.encodeWithSignature("notAFunction()"));
        ok; // 由 expectRevert 判定
    }

    /// `address(this)` 在 delegate 裡是 **EOA**,而 `SELF` 是 impl 自己的位址。
    /// 這兩個是不同的值,而 attestation 的 digest 需要**兩個都有**:
    /// `address(this)` 綁住「哪個錢包」,`SELF` 綁住「哪一版 impl」。
    function test_address_this_is_the_eoa_but_self_is_the_impl() public view {
        assertEq(acct.SELF(), address(impl), "SELF is baked in at deploy time");
        // domainSeparator 用 address(this) —— 在 delegate 裡就是 wallet
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                wallet
            )
        );
        assertEq(acct.domainSeparator(), expected, "verifyingContract is the EOA");
    }

    /// 兩個 EOA 委派到同一份 impl,storage 完全獨立。
    function test_two_wallets_sharing_one_impl_are_independent() public {
        uint256 pk2 = 0xB0B;
        address w2 = vm.addr(pk2);
        vm.signAndAttachDelegation(address(impl), pk2);

        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        (bytes32 n1,,) = acct.bindingOf(AGENT);
        (bytes32 n2,,) = LeashAccount(payable(w2)).bindingOf(AGENT);
        assertEq(n1, NODE);
        assertEq(n2, bytes32(0), "the other wallet knows nothing about this agent");
    }

    // --- 🔴 決定 2 迴歸:沒有 initialize,沒有搶跑面 ---

    /// **委派後 storage 是空的,而這是攻擊者唯一的窗口。**
    ///
    /// spike 證明過:如果有 `initialize()`,任何人都能搶先呼叫並把自己設成 admin。
    /// 我們的做法是**根本沒有初始化動作** —— 全域設定是 immutable,
    /// per-EOA 的權限一律是 `msg.sender == address(this)`,而只有錢包的私鑰
    /// 能讓那個 EOA 送出交易。
    ///
    /// 這條測試逐一證明攻擊者在那個窗口裡什麼都做不到。
    function test_attacker_cannot_seize_a_freshly_delegated_wallet() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.bindAgent(ATTACKER, NODE, LABEL);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(NODE, address(0xDEAD), ATTACKER, 1, ATT);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.setRule(
            NODE,
            address(0xDEAD),
            LeashStorage.TokenRule(true, 0, 0, 0, 0, 0, 0),
            1,
            ATT
        );

        vm.stopPrank();

        (bytes32 n,,) = acct.bindingOf(ATTACKER);
        assertEq(n, bytes32(0), "nothing was seized");
    }

    /// 對 **impl 本身**呼叫必須是惰性的 —— impl 沒有被任何人委派,
    /// 它的 `address(this)` 是自己,所以理論上它能對自己下指令。
    /// 那不會傷害任何錢包(狀態在 impl 自己的 storage,沒有 EOA 讀它),
    /// 但我們仍然要確認**外部人**動不了它。
    function test_calling_the_impl_directly_does_nothing_for_an_outsider() public {
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(ATTACKER);
        impl.bindAgent(ATTACKER, NODE, LABEL);
    }

    // --- attestation ---

    /// digest 必須含 `SELF`,否則重新委派到新版 impl 之後可以跨版本重放。
    function test_attestation_digest_is_bound_to_the_impl_version() public {
        LeashAccount impl2 = new LeashAccount(ETH_REGISTRY, approvals, attester);
        bytes32 d1 = acct.payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        vm.signAndAttachDelegation(address(impl2), walletPk);
        bytes32 d2 = LeashAccount(payable(wallet)).payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        assertTrue(d1 != d2, "same wallet, different impl version, different digest");
    }
}
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 編譯失敗,`Source "src/LeashAccount.sol" not found`

- [ ] **Step 3: 寫 `LeashAccount` 的骨架**

只寫這個任務要的部分。`bindAgent` / `allowPayee` / `setRule` / `bindingOf` / `payeeDigest`
在這一步只需要存在到足以讓測試編譯與通過 —— 完整邏輯是任務 3 和 4。

```solidity
// src/LeashAccount.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LeashStorage } from "./LeashStorage.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";
import { Reason } from "./Reason.sol";

/// @title LeashAccount —— agent 唯一的花費路徑
/// @notice 一份 EIP-7702 delegate 實作。被委派的 EOA 在任何轉帳之前必須:
///         授權 agent → ENS 三跳解出 policy → 比對批准清單 → 過 policy。
///
/// @dev **不要說「唯一的花費路徑」。** EIP-7702 只約束打到那個 EOA 的呼叫;
///      WALLET 私鑰照樣能直簽 `USDC.transfer`,policy 那條路徑根本不會執行。
///      這既是邊界也是**逃生口** —— 錢包持有者永遠拿得回自己的錢。
///
///      **沒有 `initialize()`。** 全域設定是 `immutable`,烙在 bytecode 裡,
///      所以委派後 storage 空白的那段窗口沒有東西可以搶。per-EOA 的權限
///      一律是 `msg.sender == address(this)`,而只有錢包的私鑰能讓那個 EOA 送交易。
contract LeashAccount {
    using LeashStorage for LeashStorage.AccountStorage;

    // --- 烙在 bytecode 裡 ---

    /// @notice ENSv2 的 .eth registry。解析的起點,也是「全滅」拉桿的位置。
    address public immutable ETH_REGISTRY;

    /// @notice 批准清單。**immutable** —— 見 `PolicyApprovals` 的 C1 註解。
    IPolicyApprovals public immutable APPROVALS;

    /// @notice 擴權的背書來源。**immutable**。
    IAttester public immutable ATTESTER;

    /// @notice **impl 自己被部署時的位址。**
    /// @dev 這是 7702 特有的一個小陷阱:同一份程式碼裡,`address(this)` 和
    ///      「這份程式碼住在哪」是**兩個不同的值**。delegate 執行時
    ///      `address(this)` 是 EOA,而 `immutable` 在部署時被烙進 bytecode,
    ///      所以 `SELF` 記得的是 impl 的位址。
    ///
    ///      attestation 的 digest 需要**兩個都有**:`address(this)` 綁住
    ///      「哪個錢包」,`SELF` 綁住「哪一版 impl」。少了 `SELF`,錢包重新委派到
    ///      新版之後,舊版的 attestation 可以重放(新版可能換了 ERC-7201 命名空間,
    ///      讀不到舊的 `attestationUsed` 紀錄)。
    address public immutable SELF;

    string public constant PARENT_LABEL = "leash";

    /// @notice `namehash("leash.eth")`。`bindAgent` 用它驗證 node 與 label 一致。
    bytes32 public constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @notice 呼叫 policy 的 gas 上限。超過就 fail-closed(理由碼 12)。
    /// @dev 刻意的上限:一份能燒掉全部 gas 的 policy 等於一個 DoS 開關。
    uint256 public constant POLICY_GAS = 200_000;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant PAYEE_TYPEHASH = keccak256(
        "AllowPayee(address impl,bytes32 node,address token,address payee,uint256 nonce)"
    );

    error NotSelf();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error UnknownSelector();

    /// @dev per-EOA 的權限只有這一種。`address(this)` 在 delegate 裡是那個 EOA,
    ///      而只有它的私鑰能讓它送出交易 —— 所以這就是「錢包自己」。
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address ethRegistry_, IPolicyApprovals approvals_, IAttester attester_) {
        ETH_REGISTRY = ethRegistry_;
        APPROVALS = approvals_;
        ATTESTER = attester_;
        SELF = address(this);
    }

    /// @notice **必須有。** 純轉 ETH = 用空 calldata 呼叫 delegate;
    ///         沒有這個函式,委派之後那個錢包就收不到 ETH、加不了 gas。
    receive() external payable { }

    /// @notice 打錯 selector 明確 revert,不要靜默吞掉。
    /// @dev 這個帳戶**不做**通用呼叫轉發(見 spec 的 YAGNI 表)。
    fallback() external payable {
        revert UnknownSelector();
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    function bindingOf(address agent)
        external
        view
        returns (bytes32 node, string memory label, bool revoked)
    {
        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        return (b.node, b.label, b.revoked);
    }

    /// @notice 綁定一個 agent 到一個 ENS 名字。**縮權方向,不需要背書。**
    /// @dev 完整的檢查在任務 3 補上(namehash 一致、已存在就 revert)。
    function bindAgent(address agent, bytes32 node, string calldata label) external onlySelf {
        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        b.node = node;
        b.label = label;
    }

    /// @notice 白名單一個收款人。**擴權 —— 兩個都要。**
    function allowPayee(
        bytes32 node,
        address token,
        address payee,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation(
            keccak256(abi.encode(PAYEE_TYPEHASH, SELF, node, token, payee, nonce)), attestation
        );
        LeashStorage.layout().payees[node][token][payee] = true;
    }

    /// @notice 設定規則。**擴權 —— 兩個都要。** 完整邏輯在任務 4。
    function setRule(
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        nonce;
        attestation;
        LeashStorage.layout().rules[node][token] = rule;
    }

    function payeeDigest(bytes32 node, address token, address payee, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(PAYEE_TYPEHASH, SELF, node, token, payee, nonce)));
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev 背書的消費點。digest 同時綁住這個錢包(`address(this)` 進 domain)
    ///      和這一版 impl(`SELF` 進 structHash)。用掉後永久標記。
    function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private {
        bytes32 d = _digest(structHash);
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        if ($.attestationUsed[d]) revert AttestationReused(d);
        if (!ATTESTER.verify(d, attestation)) revert NotAttested();
        $.attestationUsed[d] = true;
    }
}
```

- [ ] **Step 4: 跑測試確認它通過**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 8 passed

- [ ] **Step 5: 格式化並跑全部測試**

Run: `forge fmt && forge test`
Expected: 114 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountBinding.t.sol
git commit -m "feat: LeashAccount 骨架 —— 7702 語意、receive、attestation 消費

沒有 initialize():全域設定是 immutable,烙在 bytecode 裡,所以委派後
storage 空白的那段窗口沒有東西可以搶。測試逐一證明攻擊者在那個窗口裡
bindAgent / allowPayee / setRule 全部拿不到。

receive() 是必要的而不是禮貌:純轉 ETH = 用空 calldata 呼叫 delegate,
沒有它就 revert,委派之後那個錢包收不到 ETH、加不了 gas。已實測。

SELF 記錄 impl 自己被部署時的位址。這是 7702 特有的陷阱:同一份程式碼裡
address(this) 和「這份程式碼住在哪」是兩個不同的值。attestation 的 digest
兩個都要 —— address(this) 綁哪個錢包,SELF 綁哪一版 impl,否則重新委派後
可以跨版本重放。"
```

---

## Task 3: agent 綁定與暫停 —— 不對稱的完整實作

**Files:**
- Modify: `src/LeashAccount.sol`(補齊 `bindAgent`、新增 `unbindAgent` / `revokeAgent` / `restoreAgent` / `pause` / `unpause`)
- Modify: `test/LeashAccountBinding.t.sol`(追加)

**Interfaces:**
- Consumes: 任務 2 的 `onlySelf`、`_consumeAttestation`、`_digest`
- Produces:
  - `bindAgent(address agent, bytes32 node, string calldata label)`
  - `unbindAgent(address agent)` / `revokeAgent(address agent)` / `restoreAgent(address agent, bytes32 node, string calldata label, uint256 nonce, bytes calldata attestation)`
  - `pause()` / `unpause()` / `paused()`
  - `nodeFor(string memory label) public pure returns (bytes32)`
  - `error NodeLabelMismatch(bytes32 expected, bytes32 got)` / `error AlreadyBound()` / `error NotBoundAgent()` / `error NotSelfOrAgent()`
  - 事件 `AgentBound` / `AgentRevoked` / `Paused` / `Unpaused` 照 `docs/events.md`

- [ ] **Step 1: 寫失敗的測試**

```solidity
    // 追加到 test/LeashAccountBinding.t.sol

    // --- 🔴 M2 迴歸:node 與 label 必須一致 ---

    /// **`node` 不只是 resolver 的 key —— 它也是 `rules` / `payees` / `spent` 的 key。**
    ///
    /// 所以 `bindAgent(agentB, node=vendors, label="payroll")` 會讓 agentB 花
    /// **vendors 那份真人核准過的額度與預算**,卻由 **payroll 的 policy** 判斷。
    /// 而 `AgentBound(agent, node)` 事件不帶 label,鏈下**完全看不出來**。
    ///
    /// 固定父層之下算 namehash 只要**兩次 keccak**(約 200 gas),
    /// 把一個看不見的錯誤設定換成一個 revert。
    function test_bind_rejects_a_node_label_mismatch() public {
        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashAccount.NodeLabelMismatch.selector, acct.nodeFor(LABEL), payrollNode
            )
        );
        vm.prank(wallet);
        acct.bindAgent(AGENT, payrollNode, LABEL);
    }

    function test_nodeFor_matches_the_recorded_namehashes() public view {
        assertEq(acct.nodeFor("vendors"), NODE);
        assertEq(
            acct.nodeFor("payroll"),
            0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8
        );
    }

    // --- 🔴 M4 迴歸:撤銷後不能免費重綁 ---

    /// 凍結文件對理由碼 2 的規定是「縮權免刷臉,**恢復要刷臉**」。
    /// 如果 `bindAgent` 能覆蓋既有綁定,那撤銷之後免費重綁就繞過了那條規定。
    function test_bind_rejects_an_existing_binding() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        vm.expectRevert(LeashAccount.AlreadyBound.selector);
        acct.bindAgent(AGENT, NODE, LABEL);
        vm.stopPrank();
    }

    /// 恢復一個被撤銷的 agent 要背書。
    function test_restore_requires_an_attestation() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        (,, bool revoked) = acct.bindingOf(AGENT);
        assertTrue(revoked);

        acct.restoreAgent(AGENT, NODE, LABEL, 1, ATT);
        (,, bool after_) = acct.bindingOf(AGENT);
        assertFalse(after_, "restored");
        vm.stopPrank();
    }

    /// **但綁錯名字不能變成永久的。** `unbindAgent` 完全免費(解綁是縮權),
    /// 之後就能重新綁到正確的名字 —— 兩步都是縮權,中間沒有任何一刻權限比原本大。
    function test_a_mis_binding_is_correctable_for_free() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        acct.unbindAgent(AGENT);
        (bytes32 n,,) = acct.bindingOf(AGENT);
        assertEq(n, bytes32(0), "back to unbound");

        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        acct.bindAgent(AGENT, payrollNode, "payroll");
        (bytes32 n2,,) = acct.bindingOf(AGENT);
        assertEq(n2, payrollNode, "rebound with no attestation");
        vm.stopPrank();
    }

    // --- 縮權任何時候都能做 ---

    /// agent 可以撤銷自己 —— 縮權不該有門檻。
    function test_an_agent_can_revoke_itself() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.prank(AGENT);
        acct.revokeAgent(AGENT);
        (,, bool revoked) = acct.bindingOf(AGENT);
        assertTrue(revoked);
    }

    function test_a_stranger_cannot_revoke_someone_elses_agent() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.expectRevert(LeashAccount.NotSelfOrAgent.selector);
        vm.prank(ATTACKER);
        acct.revokeAgent(AGENT);
    }

    // --- 🔴 M6 迴歸:pause 免費,unpause 也必須免費 ---

    /// 任何未被撤銷的被綁定 agent 都能踩煞車 —— 踩煞車只會讓系統更嚴。
    function test_any_bound_agent_can_pause() public {
        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        vm.prank(AGENT);
        acct.pause();
        assertTrue(acct.paused());
    }

    function test_a_revoked_agent_cannot_pause() public {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.revokeAgent(AGENT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.NotBoundAgent.selector);
        vm.prank(AGENT);
        acct.pause();
    }

    /// **`unpause` 不能要背書。** 否則被入侵的 agent 可以免費 `pause`、
    /// 反覆逼持有者刷臉 —— 那是一個 DoS。免費的煞車必須配免費的放開。
    /// 凍結文件也把理由碼 10 列為「ADMIN 的日常操作」,不需刷臉。
    function test_unpause_is_free_and_only_the_wallet_can_do_it() public {
        vm.prank(wallet);
        acct.pause();

        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(AGENT);
        acct.unpause();

        vm.prank(wallet);
        acct.unpause();
        assertFalse(acct.paused());
    }
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 編譯失敗,`Member "unbindAgent" not found`

- [ ] **Step 3: 實作**

```solidity
    // 取代任務 2 那個佔位版的 bindAgent,並新增其餘函式

    bytes32 private constant RESTORE_TYPEHASH = keccak256(
        "RestoreAgent(address impl,address agent,bytes32 node,string label,uint256 nonce)"
    );

    event AgentBound(address indexed agent, bytes32 indexed node);
    /// @dev 證明這個 EOA 現在委派給 LeashAccount。**subgraph 的 template 觸發點** ——
    ///      7702 的委派不發 log,所以索引端只能靠這個知道要監聽哪個位址。
    event Leashed(bytes32 indexed node, address indexed wallet, address impl);
    event AgentRevoked(address indexed agent, address indexed by);
    event Paused(address indexed by);
    event Unpaused(address indexed by, bytes32 attestationHash);

    error NodeLabelMismatch(bytes32 expected, bytes32 got);
    error AlreadyBound();
    error NotBoundAgent();
    error NotSelfOrAgent();

    /// @notice `namehash("<label>.leash.eth")`。
    /// @dev 父層固定,所以只要一次 keccak 接上 `PARENT_NODE` —— 兩次 keccak,不是迴圈。
    function nodeFor(string memory label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
    }

    function paused() external view returns (bool) {
        return LeashStorage.layout().paused;
    }

    /// @notice 綁定一個 agent。**縮權方向,不需要背書** —— 從零開始給權限,
    ///         而那個權限的內容完全由 ENS 那一側(ADMIN)和批准清單(真人)決定。
    ///
    /// @dev `node` 與 `label` **必須一致**。`node` 不只是 resolver 的 key,
    ///      它也是 `rules` / `payees` / `spent` 的 key —— 不一致會讓這個 agent
    ///      花 A 名字的預算卻由 B 名字的 policy 判斷,而 `AgentBound` 不帶 label,
    ///      鏈下看不出來。
    function bindAgent(address agent, bytes32 node, string calldata label) external onlySelf {
        bytes32 expected = nodeFor(label);
        if (node != expected) revert NodeLabelMismatch(expected, node);

        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        LeashStorage.AgentBinding storage b = $.bindings[agent];
        // 已存在就 revert:否則「撤銷後免費重綁」會繞過凍結文件對理由碼 2 的規定
        // (恢復要刷臉)。綁錯的補救是 `unbindAgent` 再 `bindAgent`,兩步都是縮權。
        if (b.node != bytes32(0)) revert AlreadyBound();

        b.node = node;
        b.label = label;
        emit AgentBound(agent, node);

        // **第一次綁定時發 `Leashed`。**
        //
        // EIP-7702 的委派**不發任何 log**,所以 subgraph 沒有 factory 事件可以
        // 觸發 template —— 它不知道要監聽哪些 EOA 位址。這一筆就是那個觸發點。
        // (`Leashed` 已經在凍結 schema 裡,這裡給它一個明確的發出時機。)
        // demo 另外會在 subgraph.yaml 寫死錢包位址當保險,見 sprint 項目 9。
        // `b.node == 0` 的分支已經在上面確認過(否則 AlreadyBound),
        // 所以能走到這裡的都是「這個 agent 的第一次綁定」。
        // 但 `Leashed` 是**錢包層級**的事實,不該每綁一個 agent 就重發一次 ——
        // 用一個獨立的旗標記住它。
        if (!$.leashedEmitted) {
            $.leashedEmitted = true;
            emit Leashed(node, address(this), SELF);
        }
    }

    /// @notice 完全解除綁定。**縮權,完全免費。**
    /// @dev 這是「綁錯名字」的補救路徑。解綁之後那個 agent 什麼都不能做,
    ///      可以重新 `bindAgent` 到正確的名字 —— 中間沒有任何一刻權限比原本大。
    function unbindAgent(address agent) external {
        _requireSelfOrAgent(agent);
        delete LeashStorage.layout().bindings[agent];
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice 撤銷一個 agent(保留綁定,標記為 revoked)。**縮權,不需要背書。**
    /// @dev 與 `unbindAgent` 的差別:這裡保留 node/label,所以 `spend` 走到 2b
    ///      會發出可索引的 `SpendBlocked(AGENT_REVOKED)`,agent 查 subgraph
    ///      就知道自己為什麼不能動了。`unbindAgent` 則讓它變成「從未綁定」,
    ///      那會在 2a 直接 revert。
    function revokeAgent(address agent) external {
        _requireSelfOrAgent(agent);
        LeashStorage.layout().bindings[agent].revoked = true;
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice 恢復一個被撤銷的 agent。**擴權 —— 兩個都要。**
    /// @dev 三個參數全部進 digest,所以一份恢復用的背書不能被挪去恢復別的 agent
    ///      或把它綁到別的名字。
    function restoreAgent(
        address agent,
        bytes32 node,
        string calldata label,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        bytes32 expected = nodeFor(label);
        if (node != expected) revert NodeLabelMismatch(expected, node);
        _consumeAttestation(
            keccak256(
                abi.encode(RESTORE_TYPEHASH, SELF, agent, node, keccak256(bytes(label)), nonce)
            ),
            attestation
        );

        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        b.node = node;
        b.label = label;
        b.revoked = false;
        emit AgentBound(agent, node);
    }

    /// @notice 全面暫停。**錢包自己或任何未被撤銷的被綁定 agent 都能按。**
    /// @dev 踩煞車只會讓系統更嚴,讓它需要權限是在真的出事的那一刻幫攻擊者省事。
    function pause() external {
        if (msg.sender != address(this)) {
            LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[msg.sender];
            if (b.node == bytes32(0) || b.revoked) revert NotBoundAgent();
        }
        LeashStorage.layout().paused = true;
        emit Paused(msg.sender);
    }

    /// @notice 解除暫停。**只有錢包自己,而且不需要背書。**
    /// @dev **不能要背書。** 任何 agent 都能免費 `pause`,若 `unpause` 要刷臉,
    ///      被入侵的 agent 就能反覆逼持有者刷臉 —— 那是一個 DoS。
    ///      免費的煞車必須配免費的放開,兩邊都由錢包自己控制。
    ///      凍結文件也把理由碼 10 列為「ADMIN 的日常操作」,不需刷臉。
    ///
    ///      `Unpaused` 的凍結簽章有一個 `attestationHash` 欄位 —— 送 `bytes32(0)`,
    ///      subgraph 要把 0 解讀為「不需背書的解除」,而不是「缺資料」。
    function unpause() external onlySelf {
        LeashStorage.layout().paused = false;
        emit Unpaused(msg.sender, bytes32(0));
    }

    function _requireSelfOrAgent(address agent) private view {
        if (msg.sender != address(this) && msg.sender != agent) revert NotSelfOrAgent();
        if (LeashStorage.layout().bindings[agent].node == bytes32(0)) revert NotBoundAgent();
    }
```

- [ ] **Step 4: 跑測試確認它通過**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 19 passed

- [ ] **Step 5: 格式化並跑全部測試**

Run: `forge fmt && forge test`
Expected: 125 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountBinding.t.sol
git commit -m "feat: agent 綁定與暫停 —— 擴權/縮權的不對稱

bindAgent 檢查 node == namehash(label + '.leash.eth')。node 不只是 resolver
的 key,它也是 rules/payees/spent 的 key —— 不一致會讓 agent 花 A 名字的
預算卻由 B 名字的 policy 判斷,而 AgentBound 事件不帶 label,鏈下看不出來。
固定父層之下只要兩次 keccak,約 200 gas。

bindAgent 對已存在的綁定 revert(否則撤銷後免費重綁會繞過凍結文件對理由碼 2
的規定:恢復要刷臉),但加上完全免費的 unbindAgent 讓綁錯不會變成永久的 ——
解綁再重綁,兩步都是縮權,中間沒有任何一刻權限比原本大。

unpause 刻意不要背書:任何 agent 都能免費 pause,若解除要刷臉,被入侵的
agent 就能反覆逼持有者刷臉。免費的煞車必須配免費的放開。"
```

---

## Task 4: 規則與收款人 —— `setRule` / `tightenRule` / window 子集 / epoch

**這是整份計畫邏輯最容易寫錯的一個任務。** 兩個地方會**靜默地放寬規則**:
`0 = 不限` 的比較反轉、跨午夜時段的子集判斷。兩者都要有專門測試。

**Files:**
- Modify: `src/LeashAccount.sol`
- Test: `test/LeashAccountRules.t.sol`

**Interfaces:**
- Consumes: 任務 2 的 `onlySelf` / `_consumeAttestation`;`LeashStorage.TokenRule`
- Produces:
  - `setRule(bytes32 node, address token, LeashStorage.TokenRule calldata rule, uint256 nonce, bytes calldata attestation)`
  - `tightenRule(bytes32 node, address token, LeashStorage.TokenRule calldata rule)`
  - `removePayee(bytes32 node, address token, address payee)`
  - `ruleOf(bytes32 node, address token) external view returns (LeashStorage.TokenRule memory)`
  - `spentInCurrentPeriod(bytes32 node, address token) external view returns (uint256)`
  - `error NotTighter()`
  - 事件 `TokenAllowed` / `LimitRaised` / `TokenRemoved` / `LimitLowered` / `PayeeAllowed` / `PayeeRemoved`

- [ ] **Step 1: 寫失敗的測試 —— 先寫兩個最容易寫反的**

```solidity
// test/LeashAccountRules.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract NoApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return false;
    }
}

contract LeashAccountRulesTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    uint256 walletPk = 0x8A11E7;
    address wallet;

    address constant TOKEN = address(0x05DC);
    address constant PAYEE = address(0xBEEF);
    bytes constant ATT = hex"c0ffee";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_757_000_000);
        impl = new LeashAccount(address(0xE45), new NoApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    function _rule(uint256 txLimit, uint256 periodLimit, uint64 period, uint16 ws, uint16 we)
        internal
        pure
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: txLimit,
            periodLimit: periodLimit,
            period: period,
            windowStart: ws,
            windowEnd: we,
            epoch: 0
        });
    }

    function _set(LeashStorage.TokenRule memory r) internal {
        vm.prank(wallet);
        acct.setRule(NODE, TOKEN, r, ++nonce, ATT);
    }

    // --- 🔴 `0 = 不限` 的比較反轉 ---

    /// **這是最容易寫反的一行。** `0` 代表「不限」,所以:
    ///   0 → 100 是**收緊**(從無限變成有限)
    ///   100 → 0 是**放寬**(從有限變成無限)
    /// 單純的 `<=` 會把兩者都判成收緊。
    function test_zero_means_unlimited_so_the_comparison_inverts() public {
        _set(_rule(0, 0, 1 days, 0, 0)); // 無限額度

        // 0 → 100:收緊,允許
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 100);

        // 100 → 0:放寬,拒絕
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(0, 0, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 100, "unchanged");
    }

    function test_lowering_a_finite_limit_is_tightening() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 50);
        assertEq(acct.ruleOf(NODE, TOKEN).periodLimit, 500);
    }

    function test_raising_a_finite_limit_is_not_tightening() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(200, 1000, 1 days, 0, 0));
    }

    /// 直接關掉一定是收緊,不管其他欄位長什麼樣。
    function test_disabling_the_token_is_always_tightening() public {
        _set(_rule(100, 1000, 1 days, 9 * 60, 17 * 60));
        LeashStorage.TokenRule memory off = _rule(0, 0, 1 days, 0, 0);
        off.allowed = false;
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, off);
        assertFalse(acct.ruleOf(NODE, TOKEN).allowed);
    }

    // --- 🔴 跨午夜的時段子集 ---

    /// `StandardPolicy._inWindow` 的語意:`start == end` 全天;
    /// `start < end` 同日區間;`start > end` **跨午夜**。
    /// 所以「更嚴」不能只比數字大小。

    function test_all_day_to_a_finite_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 0, 0)); // 全天
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 9 * 60, 17 * 60));
        assertEq(acct.ruleOf(NODE, TOKEN).windowStart, 9 * 60);
    }

    function test_a_finite_window_to_all_day_is_widening() public {
        _set(_rule(100, 0, 1 days, 9 * 60, 17 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0));
    }

    /// 22:00–06:00 ⊂ 21:00–07:00 —— 兩者都跨午夜,新的比較窄。
    function test_a_narrower_overnight_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 21 * 60, 7 * 60));
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
        assertEq(acct.ruleOf(NODE, TOKEN).windowStart, 22 * 60);
    }

    /// 反過來就是放寬。
    function test_a_wider_overnight_window_is_widening() public {
        _set(_rule(100, 0, 1 days, 22 * 60, 6 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 21 * 60, 7 * 60));
    }

    /// 同日區間換成跨午夜:分鐘集合不是子集,拒絕。
    function test_switching_a_daytime_window_to_overnight_is_widening() public {
        _set(_rule(100, 0, 1 days, 9 * 60, 17 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
    }

    // --- 🔴 M5 迴歸:改 period 不能讓預算復活 ---

    /// **初版只讓 `tightenRule` 凍結 `period`,那修了一半。**
    /// 如果 `spent` 的 key 只是 `timestamp / period`,那麼一改 `period`
    /// 桶的編號就變了,累計讀出來是 0 —— **「調整週期」變成一個免費的清帳鈕。**
    ///
    /// 修法是 `epoch`:只增不減,`spent` 以它為 key 的高位。
    function test_tighten_cannot_touch_period_or_epoch() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 1000, 7 days, 0, 0));

        LeashStorage.TokenRule memory bumped = _rule(100, 1000, 1 days, 0, 0);
        bumped.epoch = 1;
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, bumped);
    }

    /// `setRule` 改 `period` 時 `epoch` 必須遞增 —— 換週期意味著換一套帳,
    /// 而 `epoch` 只增不減,所以**清帳這件事永遠需要一份 attestation**。
    function test_setRule_bumps_epoch_only_when_period_changes() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0);

        _set(_rule(200, 2000, 1 days, 0, 0)); // period 沒變
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0, "no bump");

        _set(_rule(200, 2000, 7 days, 0, 0)); // period 變了
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 1, "bumped");
    }

    /// `period == 0` 是一個要處理的邊界:`spent` 的 key 是
    /// `timestamp / period`,直接除會 panic。
    /// 語意定義為「所有花費累計進一個永不重置的桶」= 終身額度。
    function test_period_zero_is_a_lifetime_budget_not_a_panic() public {
        _set(_rule(100, 1000, 0, 0, 0));
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0, "no division by zero");

        // 時間推很久,桶仍然是同一個
        vm.warp(block.timestamp + 3650 days);
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0);
    }

    // --- 事件與收款人 ---

    /// `setRule` 對應到兩個凍結事件,要講明何時發哪一個。
    function test_setRule_emits_token_allowed_when_first_enabled() public {
        vm.expectEmit(true, true, false, false);
        emit LeashAccount.TokenAllowed(NODE, TOKEN, bytes32(0));
        _set(_rule(100, 1000, 1 days, 0, 0));
    }

    function test_payee_can_be_allowed_and_removed() public {
        vm.startPrank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, ++nonce, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));

        acct.removePayee(NODE, TOKEN, PAYEE); // 縮權,不需背書
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
        vm.stopPrank();
    }

    // --- 兩個都要 ---

    function test_expansion_needs_both_self_and_attestation() public {
        // 不是 self
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(address(0xBAD));
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 1, ATT);

        // 是 self,但 attestation 重放
        vm.startPrank(wallet);
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.expectRevert();
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.stopPrank();
    }

    /// 縮權**不需要** attestation,但仍然只有錢包自己能做。
    function test_reduction_needs_self_but_no_attestation() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(address(0xBAD));
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));

        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 50);
    }
}
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashAccountRules -vv`
Expected: 編譯失敗,`Member "tightenRule" not found`

- [ ] **Step 3: 實作 —— `_lteOrUnlimited` 與 `_windowIsSubset` 是重點**

```solidity
    bytes32 private constant RULE_TYPEHASH = keccak256(
        "SetRule(address impl,bytes32 node,address token,bool allowed,uint256 txLimit,uint256 periodLimit,uint64 period,uint16 windowStart,uint16 windowEnd,uint256 nonce)"
    );

    event TokenAllowed(bytes32 indexed node, address indexed token, bytes32 attestationHash);
    event LimitRaised(
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        uint64 period,
        bytes32 attestationHash
    );
    event TokenRemoved(bytes32 indexed node, address indexed token, address indexed by);
    event LimitLowered(
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        address indexed by
    );
    event PayeeAllowed(bytes32 indexed node, address indexed payee, bytes32 attestationHash);
    event PayeeRemoved(bytes32 indexed node, address indexed payee, address indexed by);

    error NotTighter();

    function ruleOf(bytes32 node, address token)
        external
        view
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.layout().rules[node][token];
    }

    function isPayeeAllowed(bytes32 node, address token, address payee)
        external
        view
        returns (bool)
    {
        return LeashStorage.layout().payees[node][token][payee];
    }

    function spentInCurrentPeriod(bytes32 node, address token) external view returns (uint256) {
        LeashStorage.TokenRule storage r = LeashStorage.layout().rules[node][token];
        return LeashStorage.layout().spent[node][token][_bucket(r)];
    }

    /// @notice 設定規則。**擴權 —— 兩個都要。**
    /// @dev `period` 改變時 `epoch` 自動遞增。**這是唯一能讓 `spent` 換桶的路徑**,
    ///      而它需要 attestation —— 所以清帳永遠要一份背書。
    function setRule(
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation(
            keccak256(
                abi.encode(
                    RULE_TYPEHASH,
                    SELF,
                    node,
                    token,
                    rule.allowed,
                    rule.txLimit,
                    rule.periodLimit,
                    rule.period,
                    rule.windowStart,
                    rule.windowEnd,
                    nonce
                )
            ),
            attestation
        );

        LeashStorage.TokenRule storage cur = LeashStorage.layout().rules[node][token];
        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;
        uint32 epoch = cur.epoch;
        if (cur.period != rule.period) epoch += 1; // 換週期 = 換一套帳

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.period = rule.period;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        cur.epoch = epoch;

        bytes32 h = keccak256(attestation);
        if (!wasAllowed && rule.allowed) emit TokenAllowed(node, token, h);
        emit LimitRaised(node, token, oldLimit, rule.periodLimit, rule.period, h);
    }

    /// @notice 收緊規則。**縮權 —— 只要 `address(this)`,不需要背書。**
    /// @dev 要求**每一個欄位都弱單調收緊**。這把「更嚴」變成一個可檢查的斷言,
    ///      而配對式的 raise/lower 函式會漏掉 window 和 period ——
    ///      而漏掉的那些正好可以被用來放寬。
    function tightenRule(bytes32 node, address token, LeashStorage.TokenRule calldata rule)
        external
        onlySelf
    {
        LeashStorage.TokenRule storage cur = LeashStorage.layout().rules[node][token];
        if (!_isTighter(cur, rule)) revert NotTighter();

        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        // period 與 epoch 刻意不動 —— 見 `_isTighter`

        if (wasAllowed && !rule.allowed) emit TokenRemoved(node, token, msg.sender);
        if (oldLimit != rule.periodLimit) {
            emit LimitLowered(node, token, oldLimit, rule.periodLimit, msg.sender);
        }
    }

    /// @notice 移除一個收款人。**縮權,不需要背書。**
    function removePayee(bytes32 node, address token, address payee) external onlySelf {
        LeashStorage.layout().payees[node][token][payee] = false;
        emit PayeeRemoved(node, payee, msg.sender);
    }

    /// @dev **弱單調收緊**的定義。每一條都有專門測試。
    function _isTighter(LeashStorage.TokenRule storage old_, LeashStorage.TokenRule calldata new_)
        private
        view
        returns (bool)
    {
        if (old_.allowed && !new_.allowed) return true; // 直接關掉一定更嚴
        if (!old_.allowed) return false; // 原本就關著,沒有更嚴可言
        // period 與 epoch 不准動:改 period 會換桶,累計歸零 ——
        // 「調低上限」反而讓可花的變多。清帳只能走 setRule(要背書)。
        if (new_.period != old_.period || new_.epoch != old_.epoch) return false;
        return _lteOrUnlimited(new_.txLimit, old_.txLimit)
            && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
            && _windowIsSubset(new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd);
    }

    /// @dev `0 = 不限`,所以比較會反轉:
    ///      `0 → 100` 收緊(true);`100 → 0` 放寬(false);`100 → 50` 收緊。
    ///      **這是最容易寫反的一行。**
    function _lteOrUnlimited(uint256 new_, uint256 old_) private pure returns (bool) {
        if (old_ == 0) return true; // 原本無限,任何值(含 0)都不更寬
        if (new_ == 0) return false; // 原本有限,改成無限 = 放寬
        return new_ <= old_;
    }

    /// @dev 新的分鐘集合必須是舊的子集。三種情況:
    ///      - 舊的是全天(`start == end`)→ 任何新時段都是收緊
    ///      - 新的是全天、舊的不是 → 放寬
    ///      - 兩者都是有限區間 → 逐分鐘檢查子集
    ///
    ///      **刻意用 O(1440) 的迴圈,不用不等式湊。** 這是 `view`(gas 不重要,
    ///      而 `tightenRule` 一天跑不到幾次),而跨午夜的子集判斷用不等式很容易
    ///      寫錯,寫錯會**靜默地放寬規則**。清楚勝過聰明。
    function _windowIsSubset(uint16 ns, uint16 ne, uint16 os, uint16 oe)
        private
        pure
        returns (bool)
    {
        if (os == oe) return true; // 舊的全天
        if (ns == ne) return false; // 新的全天、舊的不是
        for (uint16 m = 0; m < 1440; ++m) {
            if (_inWindow(m, ns, ne) && !_inWindow(m, os, oe)) return false;
        }
        return true;
    }

    /// @dev 與 `StandardPolicy._inWindow` 同語意。`start > end` 表示跨午夜。
    function _inWindow(uint16 minuteOfDay, uint16 start, uint16 end)
        private
        pure
        returns (bool)
    {
        if (start == end) return true;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }

    /// @dev `spent` 的 key。`epoch` 放高位、週期索引放低位,兩者不互相污染
    ///      (`period` 最小 1 秒,`timestamp / 1` 遠小於 `2^224`)。
    ///      `period == 0` 時所有花費累計進同一個桶 = 永不重置的終身額度。
    function _bucket(LeashStorage.TokenRule storage r) private view returns (uint256) {
        uint256 hi = uint256(r.epoch) << 224;
        return r.period == 0 ? hi : hi | (block.timestamp / r.period);
    }
```

- [ ] **Step 4: 跑測試確認它通過**

Run: `forge test --match-contract LeashAccountRules -vv`
Expected: 17 passed

- [ ] **Step 5: 格式化並跑全部測試**

Run: `forge fmt && forge test`
Expected: 142 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountRules.t.sol
git commit -m "feat: 規則與收款人 —— tightenRule 把「更嚴」變成可檢查的斷言

TokenRule 有五個可調欄位,配對式的 raise/lower 函式會漏掉 window 和 period,
而漏掉的那些正好可以被用來放寬。改成單一入口 tightenRule,要求每一個欄位
都弱單調收緊。

兩個會靜默放寬規則的地方各有專門測試:
- 0 = 不限 讓比較反轉:0→100 是收緊,100→0 是放寬。單純的 <= 會判錯
- 跨午夜時段的子集:(21,7)→(22,6) 是收緊,(22,6)→(21,7) 是放寬。
  刻意用 O(1440) 迴圈而不用不等式湊 —— 這是 view,而寫錯會靜默放寬

M5 真正修好:spent 的 key 是 (epoch << 224 | periodIdx),epoch 只增不減,
只有 setRule 在 period 改變時 +1。所以清帳永遠需要一份 attestation,
免費的 tightenRule 拿不到。period == 0 定義為永不重置的終身額度。"
```

---

## Task 5: ENS 三跳解析 —— 每一跳的回傳長度都不一樣

**Files:**
- Modify: `src/LeashAccount.sol`
- Create: `test/mocks/MockRegistry.sol`(可設定回傳長度與 revert 行為)
- Test: `test/LeashAccountSpend.t.sol`(這個檔在本任務建立,只放解析相關的測試)

**Interfaces:**
- Consumes: `ETH_REGISTRY`、`PARENT_LABEL`
- Produces:
  - `function resolvePolicy(bytes32 node, string memory label) public view returns (address)`
  - `error` 無 —— 解不出來回 `address(0)`,由 `spend` 轉成理由碼 3

- [ ] **Step 1: 寫失敗的測試**

```solidity
// test/mocks/MockRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 可以設定「回傳長度不對」與「revert」—— 用來測 fail-closed。
///      ENS 的合約還在 Immunefi 審計期,行為可能變 —— 我們不能因為
///      別人的合約壞掉就讓帳戶整個卡死。
contract MockRegistry {
    address public sub;
    address public res;
    bool public shouldRevert;
    uint256 public padBytes; // >0 時回傳多餘的 bytes,長度就不對了

    function set(address sub_, address res_) external {
        sub = sub_;
        res = res_;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function setPad(uint256 n) external {
        padBytes = n;
    }

    function getSubregistry(string calldata) external view returns (address) {
        if (shouldRevert) revert("boom");
        return sub;
    }

    function getResolver(string calldata) external view returns (address) {
        if (shouldRevert) revert("boom");
        if (padBytes > 0) {
            // 回傳長度不是 32 —— 用 assembly 直接回一段任意長度
            assembly {
                let p := mload(0x40)
                mstore(p, 1)
                return(p, 8)
            }
        }
        return res;
    }
}

/// @dev 只實作 ENSIP-10,回傳 `bytes`(96 bytes 的 ABI 編碼)。
contract MockResolver {
    address public policy;
    bool public shouldRevert;

    function set(address p) external {
        policy = p;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function resolve(bytes calldata, bytes calldata) external view returns (bytes memory) {
        if (shouldRevert) revert("boom");
        return abi.encode(policy);
    }
}
```

```solidity
// test/LeashAccountSpend.t.sol —— 本任務只加解析相關的測試
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { MockRegistry, MockResolver } from "./mocks/MockRegistry.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract LeashAccountSpendTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    MockRegistry ethRegistry;
    MockRegistry leashRegistry;
    MockResolver resolver;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant POLICY = address(0xB01C);
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    function setUp() public {
        ethRegistry = new MockRegistry();
        leashRegistry = new MockRegistry();
        resolver = new MockResolver();

        ethRegistry.set(address(leashRegistry), address(0));
        leashRegistry.set(address(0), address(resolver));
        resolver.set(POLICY);

        impl = new LeashAccount(address(ethRegistry), new YesApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    /// 快樂路徑:三跳都通,解出 policy 位址。
    function test_resolves_the_policy_through_three_hops() public view {
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY);
    }

    /// 第一跳回 0 = `leash.eth` 的子樹被收回 = **全部 agent 同時停機**。
    function test_hop1_zero_is_the_kill_switch() public {
        ethRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 第二跳回 0 = 子名被撤銷或過期 = **這一個 agent 死**。
    function test_hop2_zero_kills_only_this_agent() public {
        leashRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 第三跳回 0 = policy 指標被清空 = 換規則那一層。
    function test_hop3_zero_means_no_policy() public {
        resolver.set(address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 任何一跳 revert 都必須 **fail-closed**,而不是讓整筆交易掛掉。
    /// ENS 的合約還在審計期 —— 我們不能因為別人的合約 revert 就讓帳戶卡死。
    function test_a_reverting_hop_fails_closed() public {
        ethRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        ethRegistry.setRevert(false);

        leashRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        leashRegistry.setRevert(false);

        resolver.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 🔴 **回傳長度不對也要 fail-closed。**
    ///
    /// 而且要注意每一跳的預期長度**不一樣**:hop1/hop2 是 32(address),
    /// hop3 是 **96**(`bytes` = offset 32 + length 32 + 內層 32)。
    /// 對 hop3 檢查 `== 32` 的話快樂路徑永遠不成立,而回報的理由碼會是
    /// 「ENS 讀不到 policy」—— 完全誤導除錯方向。
    function test_a_malformed_return_length_fails_closed() public {
        leashRegistry.setPad(1);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }
}
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: 編譯失敗,`Member "resolvePolicy" not found`

- [ ] **Step 3: 實作**

```solidity
    /// @notice 從 ENS 解出這個名字該過哪一份 policy。解不出來回 `address(0)`。
    ///
    /// @dev **三跳,而且每一跳的回傳長度不一樣:**
    ///
    ///      | 跳 | 呼叫 | 預期 returndata |
    ///      |---|---|---|
    ///      | 1 | `ETH_REGISTRY.getSubregistry("leash")` | 32 |
    ///      | 2 | `LeashRegistry.getResolver(label)` | 32 |
    ///      | 3 | `LeashResolver.resolve(dns, addr(node))` | **96** |
    ///
    ///      第三跳回傳 `bytes`,ABI 編碼是 offset(32) + length(32) + 內層(32)。
    ///      **寫成 `== 32` 檢查的話快樂路徑永遠不成立**,而且理由碼會是
    ///      `NO_POLICY`(「ENS 讀不到 policy」)—— 完全誤導除錯方向。
    ///
    ///      全部用低階 `staticcall` 並各自檢查自己的預期長度:ENS 的合約還在
    ///      Immunefi 審計期(至 09-14),位址可能變動或行為改變。我們不能因為
    ///      別人的合約 revert 就讓帳戶整個卡死 —— 解不出來就是 `NO_POLICY`,
    ///      錢不動,而那正是安全的預設。
    ///
    ///      這條路徑同時是三層撤銷的實作:hop1 回 0 = 全滅、
    ///      hop2 回 0 = 這一個 agent 死(撤銷或 `expiry` 到期)、
    ///      hop3 回 0 = 換規則那一層清空了指標。
    function resolvePolicy(bytes32 node, string memory label) public view returns (address) {
        address reg = _staticAddress(
            ETH_REGISTRY, abi.encodeWithSignature("getSubregistry(string)", PARENT_LABEL)
        );
        if (reg == address(0)) return address(0);

        address res =
            _staticAddress(reg, abi.encodeWithSignature("getResolver(string)", label));
        if (res == address(0)) return address(0);

        bytes memory inner = abi.encodeWithSignature("addr(bytes32)", node);
        bytes memory dnsName = _dnsEncode(label);
        (bool ok, bytes memory ret) = res.staticcall{ gas: HOP_GAS }(
            abi.encodeWithSignature("resolve(bytes,bytes)", dnsName, inner)
        );
        // 96 = offset(32) + length(32) + 內層(32)
        if (!ok || ret.length != 96) return address(0);
        bytes memory decoded = abi.decode(ret, (bytes));
        if (decoded.length != 32) return address(0);
        address policy = abi.decode(decoded, (address));
        // policy 不能是自己 —— 同樣的憑證問題,見 `spend` 的 BadTarget 護欄
        if (policy == address(this)) return address(0);
        return policy;
    }

    /// @dev 每一跳的 gas 上限。ENS 那邊壞掉不能拖垮我們。
    uint256 private constant HOP_GAS = 100_000;

    function _staticAddress(address target, bytes memory cd) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall{ gas: HOP_GAS }(cd);
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev DNS wire format:`<len><label>...<len>eth<0>`。
    ///      父層固定是 `leash.eth`,所以只有第一段是變數。
    ///      實測:`vendors.leash.eth` = `0x0776656e646f7273056c656173680365746800`
    function _dnsEncode(string memory label) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, hex"056c656173680365746800");
    }
```

- [ ] **Step 4: 跑測試確認它通過**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: 6 passed

- [ ] **Step 5: 加一條驗證 DNS 編碼的測試(它是寫死的,必須對)**

```solidity
    /// `_dnsEncode` 用寫死的 `leash.eth` 尾段。這條測試確認組出來的值
    /// 與 `docs/deployments.md` 記錄的實測值一致 —— 錯了 resolver 收到的名字就是壞的。
    function test_dns_encoding_matches_the_measured_value() public view {
        // 透過 resolvePolicy 間接驗證:MockResolver 不看 name,所以改用
        // 一個會檢查 name 的 resolver
        NameCheckingResolver nc = new NameCheckingResolver(
            hex"0776656e646f7273056c656173680365746800", POLICY
        );
        leashRegistry.set(address(0), address(nc));
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY, "dns name matched exactly");
    }
```

```solidity
// 追加到 test/mocks/MockRegistry.sol
/// @dev 只在 `name` 完全相符時回傳 policy —— 用來驗證 DNS 編碼。
contract NameCheckingResolver {
    bytes public expected;
    address public policy;

    constructor(bytes memory expected_, address policy_) {
        expected = expected_;
        policy = policy_;
    }

    function resolve(bytes calldata name, bytes calldata) external view returns (bytes memory) {
        require(keccak256(name) == keccak256(expected), "wrong dns name");
        return abi.encode(policy);
    }
}
```

- [ ] **Step 6: 跑測試、格式化、跑全部**

Run: `forge test --match-contract LeashAccountSpend -vv && forge fmt && forge test`
Expected: 7 passed;全部 149 passed

- [ ] **Step 7: Commit**

```bash
git add src/LeashAccount.sol test/mocks/MockRegistry.sol test/LeashAccountSpend.t.sol
git commit -m "feat: ENS 三跳解析 —— 每一跳的回傳長度都不一樣

hop1/hop2 回 32 bytes(address),hop3 回 **96**(bytes 的 offset+length+內層)。
09-08 用 cast rpc eth_call 對已部署的合約實測過。對 hop3 檢查 ==32 的話
快樂路徑永遠不成立,而且理由碼會是 NO_POLICY(ENS 讀不到 policy)——
完全誤導除錯方向,可能燒掉半天。

三跳全部用低階 staticcall 並各自限 gas、各自檢查自己的預期長度。ENS 的合約
還在 Immunefi 審計期,不能因為別人的合約 revert 就讓帳戶整個卡死 ——
解不出來就是 NO_POLICY,錢不動,那正是安全的預設。

這條路徑同時是三層撤銷的實作:hop1 回 0 = 全滅、hop2 回 0 = 這一個 agent 死
(撤銷或 expiry 到期)、hop3 回 0 = 指標被清空。"
```

---

## Task 6: `spend()` —— 把四道關卡串起來

**Files:**
- Modify: `src/LeashAccount.sol`
- Modify: `src/IPolicy.sol`(補一條介面約束註解)
- Create: `test/mocks/BadTokens.sol`
- Test: `test/LeashAccountSpend.t.sol`(追加)

**Interfaces:**
- Consumes: 任務 3 的綁定與暫停、任務 4 的規則與 `_bucket`、任務 5 的 `resolvePolicy`。
  **`LeashAccount.sol` 的 import 要補上** `import { IPolicy, SpendContext } from "./IPolicy.sol";`
  —— `SpendContext` 是 `IPolicy.sol` 裡的頂層 struct,不是 interface 的成員。
- Produces:
  - `spend(address token, address payee, uint256 amount) external`
  - `error NotBoundAgent()`(已存在)/ `error Reentrant()` / `error BadTarget()` / `error ZeroAmount()` / `error TransferFailed()`
  - 事件 `PolicyResolved` / `SpendExecuted` / `SpendBlocked`

- [ ] **Step 1: 寫失敗的測試 —— 先寫「假成功」那一組,那是最危險的**

```solidity
// test/mocks/BadTokens.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 回傳 `false` 的 ERC-20。帳戶必須 revert,不能當成成功。
contract FalseReturnToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev 什麼都不回傳的老式 ERC-20。**嚴格檢查**必須拒絕它。
contract NoReturnToken {
    function transfer(address, uint256) external { }
}

/// @dev 在 transfer 裡回頭再打 `spend` —— 測重入鎖與「先記帳」。
contract ReenteringToken {
    address public target;
    bool public armed;

    function arm(address t) external {
        target = t;
        armed = true;
    }

    function transfer(address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(
                abi.encodeWithSignature("spend(address,address,uint256)", address(this), msg.sender, 1)
            );
            ok; // 失敗是預期的
        }
        return true;
    }
}

/// @dev 燒掉所有 gas 的 policy —— 測 `POLICY_GAS` 上限與 fail-closed。
contract GasBurningPolicy {
    function check(bytes calldata) external pure returns (uint8) {
        while (true) { }
        return 0;
    }

    function describe() external pure returns (string memory) {
        return "GasBurningPolicy";
    }
}

/// @dev 回傳長度不對的 policy。
contract ShortReturnPolicy {
    function check(bytes calldata) external pure returns (bytes memory) {
        return hex"01";
    }

    function describe() external pure returns (string memory) {
        return "ShortReturnPolicy";
    }
}
```

```solidity
    // 追加到 test/LeashAccountSpend.t.sol

    // --- 🔴 C3 迴歸:假成功 ---

    /// **`token` 和 `payee` 由 agent 指定,可以是 `address(this)`。**
    ///
    /// 第 11 步 `token.transfer(...)` 送出去時 `msg.sender == address(this)` ——
    /// 那正是 `bindAgent` / `tightenRule` / `removePayee` 接受的憑證。
    /// 而如果用 SafeERC20 那種寬鬆的回傳檢查:
    ///   - `token == address(this)` → 打到自己的 fallback
    ///   - `token == address(0)` → 對空位址的呼叫永遠成功、回傳空 returndata
    /// 兩種情況都是 **`spent` 增加、`SpendExecuted` 發出,而錢一分都沒動。**
    /// subgraph 會記下一筆不存在的付款。
    function test_rejects_targets_that_point_back_at_the_account() public {
        _bindAndAllow();
        vm.startPrank(AGENT);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(wallet, PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), wallet, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(0), PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), address(0), 1);

        vm.stopPrank();
    }

    /// 沒有 code 的位址不可能是代幣。
    function test_rejects_a_token_with_no_code() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.BadTarget.selector);
        vm.prank(AGENT);
        acct.spend(address(0xC0DE1E55), PAYEE, 1);
    }

    /// **回傳值檢查要嚴格:恰好 32 bytes 且解出來是 `true`。**
    /// 不用 SafeERC20 的寬鬆版 —— 我們只需要支援自己 demo 用的代幣,
    /// 而寬鬆換來的相容性,在這裡的代價是一個假的成功。
    function test_rejects_tokens_that_do_not_return_true() public {
        _bindAndAllow();
        FalseReturnToken f = new FalseReturnToken();
        NoReturnToken n = new NoReturnToken();

        vm.startPrank(wallet);
        acct.setRule(NODE, address(f), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(f), PAYEE, ++nonce, ATT);
        acct.setRule(NODE, address(n), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(n), PAYEE, ++nonce, ATT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(f), PAYEE, 1);

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(n), PAYEE, 1);
    }

    function test_zero_amount_reverts() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.ZeroAmount.selector);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 0);
    }

    // --- 🔴 重入 ---

    /// 重入鎖是第一道防線,**先記帳是第二道** —— 兩道都失效才會出事。
    function test_reentrancy_is_blocked_and_the_ledger_is_already_updated() public {
        ReenteringToken rt = new ReenteringToken();
        vm.startPrank(wallet);
        acct.setRule(NODE, address(rt), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(rt), PAYEE, ++nonce, ATT);
        acct.bindAgent(AGENT, NODE, LABEL);
        vm.stopPrank();

        rt.arm(wallet);
        vm.prank(AGENT);
        acct.spend(address(rt), PAYEE, 100);

        // 只記了一次 —— 內層的 spend 被鎖擋掉了
        assertEq(acct.spentInCurrentPeriod(NODE, address(rt)), 100);
    }

    // --- 🔴 理由碼全覆蓋:每一個都要「有事件」且「餘額沒變」 ---

    function test_blocked_paths_emit_and_do_not_move_money() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        // 10 PAUSED
        vm.prank(wallet);
        acct.pause();
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "paused: no movement");
        vm.prank(wallet);
        acct.unpause();

        // 3 NO_POLICY
        resolver.set(address(0));
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no policy: no movement");
        resolver.set(POLICY);

        // 2 AGENT_REVOKED —— **不 revert**,要留可索引的紀錄
        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "revoked: no movement");
    }

    /// **2a 沒綁定 → revert;2b 已撤銷 → 不 revert。**
    /// 凍結文件把 revert 的例外限定在「caller **根本不是**被綁定的 agent」,
    /// 而被撤銷的 agent 是「已綁定」的 —— 撤銷是行政動作,那個 agent
    /// 應該查得到自己為什麼不能動了(revert 的 log 會被丟棄)。
    function test_unbound_reverts_but_revoked_does_not() public {
        _bindAndAllow();

        vm.expectRevert(LeashAccount.NotBoundAgent.selector);
        vm.prank(address(0xN07));
        acct.spend(address(token), PAYEE, 1);

        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1); // 不 revert
    }

    /// 🔴 M8 迴歸:`PolicyResolved.approved` 要送**真值**。
    /// 初版把事件排在批准檢查之後,那時它只可能是 `true` —— 凍結 schema 裡
    /// 那個欄位就永遠是死的。而「指標指到一份沒被批准的 policy」正是
    /// ADMIN 金鑰被偷時唯一的鏈上訊號。
    function test_policy_resolved_carries_the_real_approval_flag() public {
        _bindAndAllow();
        LeashAccount implNo =
            new LeashAccount(address(ethRegistry), new NoApprovals2(), new MockAttester());
        vm.signAndAttachDelegation(address(implNo), walletPk);

        vm.expectEmit(true, true, false, true);
        emit LeashAccount.PolicyResolved(NODE, POLICY, false);
        vm.prank(AGENT);
        LeashAccount(payable(wallet)).spend(address(token), PAYEE, 1);
    }

    /// 12 POLICY_FAILED 的三種觸發方式。
    function test_policy_failure_modes_all_fail_closed() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        resolver.set(address(new GasBurningPolicy()));
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "gas burner: no movement");

        resolver.set(address(new ShortReturnPolicy()));
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "short return: no movement");

        resolver.set(address(0xDEAD)); // 沒有 code
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no code: no movement");
    }

    // --- 🔴 C4 迴歸:WALLET 私鑰不受約束,而那是逃生口 ---

    /// **這條測試把邊界釘成規格。**
    /// EIP-7702 只約束打到那個 EOA 的呼叫;WALLET 私鑰照樣能直簽
    /// `USDC.transfer`,policy 那條路徑根本不會執行。
    /// 說「唯一的花費路徑」會被評審一問就破 —— 正確的說法是
    /// 「**agent 的**唯一花費路徑」,而 WALLET 不受約束既是邊界也是逃生口:
    /// 錢包持有者永遠拿得回自己的錢,不會被自己設的 policy 鎖死。
    function test_the_wallet_key_can_always_transfer_directly() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(PAYEE);

        vm.recordLogs();
        vm.prank(wallet);
        token.transfer(PAYEE, 500); // 沒有經過 spend()

        assertEq(token.balanceOf(PAYEE) - before, 500, "the money moved");
        // 而且沒有發出 SpendExecuted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != LeashAccount.SpendExecuted.selector,
                "no SpendExecuted for a direct transfer"
            );
        }
    }
```

- [ ] **Step 2: 跑測試確認它失敗**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: 編譯失敗,`Member "spend" not found`

- [ ] **Step 3: 實作 `spend`**

```solidity
    event PolicyResolved(bytes32 indexed node, address indexed policy, bool approved);
    event SpendExecuted(
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        address policy,
        uint256 spentAfter,
        uint256 limit,
        uint64 periodEnd
    );
    event SpendBlocked(
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        uint8 reason,
        address policy,
        uint256 spentSoFar,
        uint256 limit
    );

    error Reentrant();
    error BadTarget();
    error ZeroAmount();
    error TransferFailed();

    /// @notice **agent 唯一的花費路徑。**
    ///
    /// @dev `node` 與 `label` 不由 caller 提供,從 `bindings[msg.sender]` 讀 ——
    ///      那消滅了「node 與 label 不一致」一整類要驗證的錯誤。
    ///
    ///      **被擋 ≠ revert。** 政策違反 → 不轉帳、發 `SpendBlocked`、正常結束,
    ///      因為 subgraph 要索引得到「為什麼被擋」。只有 **2a(caller 根本不是
    ///      被綁定的 agent)** 才 revert —— 那不是政策決定,是入侵。
    function spend(address token, address payee, uint256 amount) external {
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();

        // 1. 重入鎖
        if ($.entered) revert Reentrant();
        $.entered = true;

        // 2a. 綁定過嗎 —— 沒有就 revert
        LeashStorage.AgentBinding storage b = $.bindings[msg.sender];
        if (b.node == bytes32(0)) revert NotBoundAgent();
        bytes32 node = b.node;

        // 護欄:token / payee 不能指回自己或 0,token 必須有 code。
        // 放在授權之後、政策之前 —— 這不是政策違反,是格式錯誤。
        if (amount == 0) revert ZeroAmount();
        if (token == address(this) || payee == address(this)) revert BadTarget();
        if (token == address(0) || payee == address(0)) revert BadTarget();
        if (token.code.length == 0) revert BadTarget();

        // 2b. 被撤銷了嗎 —— **不 revert**,發可索引的事件
        if (b.revoked) {
            _blocked($, node, payee, token, amount, Reason.AGENT_REVOKED, address(0));
            return;
        }

        // 3. 暫停
        if ($.paused) {
            _blocked($, node, payee, token, amount, Reason.PAUSED, address(0));
            return;
        }

        // 4. ENS 三跳
        address policy = resolvePolicy(node, b.label);
        if (policy == address(0)) {
            _blocked($, node, payee, token, amount, Reason.NO_POLICY, address(0));
            return;
        }

        // 5. 批准清單 —— **事件在這裡發,帶真值**
        bool approved = APPROVALS.isApproved(policy);
        emit PolicyResolved(node, policy, approved);
        if (!approved) {
            _blocked($, node, payee, token, amount, Reason.POLICY_NOT_APPROVED, policy);
            return;
        }

        // 6-7. 組 SpendContext
        LeashStorage.TokenRule storage r = $.rules[node][token];
        uint256 bucket = _bucket(r);
        uint256 spentSoFar = $.spent[node][token][bucket];

        SpendContext memory ctx = SpendContext({
            agent: msg.sender,
            payee: payee,
            token: token,
            amount: amount,
            tokenAllowed: r.allowed,
            payeeAllowed: $.payees[node][token][payee],
            txLimit: r.txLimit,
            periodLimit: r.periodLimit,
            spentSoFar: spentSoFar,
            nowTs: uint64(block.timestamp),
            windowStart: r.windowStart,
            windowEnd: r.windowEnd
        });

        // 8. 呼叫 policy，限 gas、檢查回傳長度、fail-closed
        uint8 reason = _askPolicy(policy, ctx);

        // 9. 被擋
        if (reason != Reason.OK) {
            $.entered = false;
            emit SpendBlocked(
                node, msg.sender, payee, token, amount, reason, policy, spentSoFar, r.periodLimit
            );
            return;
        }

        // 10. **先記帳** —— 在外部呼叫之前。重入鎖是第一道防線,這是第二道。
        uint256 spentAfter = spentSoFar + amount;
        $.spent[node][token][bucket] = spentAfter;

        // 11. 轉帳。**嚴格檢查:恰好 32 bytes 且是 true。**
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", payee, amount));
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) revert TransferFailed();

        // 12. 事件
        uint64 periodEnd = r.period == 0
            ? 0
            : uint64(((block.timestamp / r.period) + 1) * r.period);
        emit SpendExecuted(
            node, msg.sender, payee, token, amount, policy, spentAfter, r.periodLimit, periodEnd
        );

        // 13. 解鎖
        $.entered = false;
    }

    /// @dev 限 gas 呼叫 policy,任何異常都當成理由碼 12。
    ///      **一份能燒掉全部 gas 的 policy 等於一個 DoS 開關**,所以上限是刻意的。
    function _askPolicy(address policy, SpendContext memory ctx) private returns (uint8) {
        (bool ok, bytes memory ret) =
            policy.call{ gas: POLICY_GAS }(abi.encodeCall(IPolicy.check, (ctx)));
        if (!ok || ret.length != 32) return Reason.POLICY_FAILED;
        uint256 raw = abi.decode(ret, (uint256));
        if (raw > type(uint8).max) return Reason.POLICY_FAILED;
        return uint8(raw);
    }

    function _blocked(
        LeashStorage.AccountStorage storage $,
        bytes32 node,
        address payee,
        address token,
        uint256 amount,
        uint8 reason,
        address policy
    ) private {
        $.entered = false;
        LeashStorage.TokenRule storage r = $.rules[node][token];
        emit SpendBlocked(
            node,
            msg.sender,
            payee,
            token,
            amount,
            reason,
            policy,
            $.spent[node][token][_bucket(r)],
            r.periodLimit
        );
    }
```

- [ ] **Step 4: 補 `IPolicy` 的介面約束**

```solidity
    // 追加到 src/IPolicy.sol 的 `check` 註解
    ///
    ///      🔴 **policy 只能在回傳 `Reason.OK` 時記帳。**
    ///
    ///      因為帳戶在被擋時**不 revert** —— 如果 policy 先扣了共用預算才回傳
    ///      「超限」,那筆扣款不會被回滾,共用預算會漏。
    ///      `SharedBudgetPolicy` 現在的寫法剛好是對的(先檢查再累加),
    ///      但那是巧合而不是被要求的。**現在它被要求了。**
```

- [ ] **Step 5: 跑測試確認它通過**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: 全部 passed

- [ ] **Step 6: 格式化並跑全部測試**

Run: `forge fmt && forge test`
Expected: 全綠

- [ ] **Step 7: Commit**

```bash
git add src/LeashAccount.sol src/IPolicy.sol test/mocks/BadTokens.sol test/LeashAccountSpend.t.sol
git commit -m "feat: spend() —— 四道關卡串起來

流程:重入鎖 → 2a 綁定(沒有就 revert)→ 格式護欄 → 2b 撤銷(發事件不 revert)
→ 暫停 → ENS 三跳 → 批准清單(事件帶真值)→ 組 ctx → 限 gas 問 policy
→ 先記帳 → 轉帳 → 事件。

三個關鍵順序:
- 2a revert 而 2b 不 revert:凍結文件把 revert 的例外限定在「根本不是被綁定的
  agent」,而被撤銷的 agent 是已綁定的 —— 它該查得到自己為什麼不能動了
- 先記帳再轉帳:重入鎖是第一道防線,這是第二道,兩道都失效才會出事
- PolicyResolved 在批准檢查當下發出,帶真值。排在檢查之後的話那個欄位
  永遠是 true,而「指標指到沒被批准的 policy」正是 ADMIN 金鑰被偷時
  唯一的鏈上訊號

C3 護欄:token/payee 不能是 address(this) 或 address(0),token 必須有 code,
而且回傳值嚴格檢查恰好 32 bytes 的 true —— 寬鬆檢查會造成「回報成功但沒轉帳」,
subgraph 記下一筆不存在的付款。

C4 邊界寫成測試:WALLET 直簽 transfer 會成功且不發 SpendExecuted。"
```

---

## Task 7: fork 測試與部署

**Files:**
- Test: `test/LeashAccountFork.t.sol`
- Create: `script/DeployAccount.s.sol`
- Modify: `docs/deployments.md`

- [ ] **Step 1: 寫 fork 測試**

打真的 Sepolia,用 `docs/deployments.md` 裡 09-08 16:34 那一組位址。
**快樂路徑必須在這一層驗過** —— 前面所有的測試都用 mock registry,
只有這一層證明我們對真實 ENSv2 的假設是對的。

```solidity
// test/LeashAccountFork.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @dev 需要 `SEPOLIA_RPC`。沒設就 skip(CI 上不一定有 RPC)。
contract LeashAccountForkTest is Test {
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;
    address constant STANDARD_POLICY = 0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b;
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    LeashAccount impl;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        impl = new LeashAccount(
            ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER)
        );
    }

    /// **這條測試是整個 ENS 主張的證明。**
    /// 三跳打真的 ENSv2,解出真的 policy 位址。
    function test_resolves_the_real_policy_on_sepolia() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));
        assertEq(acct.resolvePolicy(NODE, "vendors"), STANDARD_POLICY);
    }

    /// 那份 policy 真的在批准清單裡。
    function test_the_real_policy_is_approved() public view {
        if (address(impl) == address(0)) return;
        assertTrue(IPolicyApprovals(APPROVALS).isApproved(STANDARD_POLICY));
    }

    /// **拿掉 ENS 就過不了。** 用 `vm.mockCall` 讓第一跳回 0 ——
    /// 等同 `ETHRegistry.setSubregistry(leash.eth, 0x0)`(全滅拉桿)。
    function test_removing_the_ens_subtree_stops_resolution() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));

        vm.mockCall(
            ETH_REGISTRY,
            abi.encodeWithSignature("getSubregistry(string)", "leash"),
            abi.encode(address(0))
        );
        assertEq(acct.resolvePolicy(NODE, "vendors"), address(0), "no ENS, no policy");
    }
}
```

- [ ] **Step 2: 跑 fork 測試**

Run: `set -a && . /home/ubuntu/DEV/ETHOnline2026/.env && set +a && forge test --match-contract Fork -vv`
Expected: 3 passed

- [ ] **Step 3: 寫部署腳本**

`script/DeployAccount.s.sol`:部署 `LeashAccount` impl 與 `LeashLens`,
用 `ADMIN_PK` 廣播,並印出位址。**委派 WALLET 是另一筆交易**
(需要 `WALLET_PK` 簽 authorization),用 `cast send --auth` 手動送,
不要塞進腳本 —— 那把鑰匙不該出現在部署流程裡。

```solidity
// script/DeployAccount.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashLens } from "../src/LeashLens.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

contract DeployAccount is Script {
    uint256 constant SEPOLIA = 11155111;
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;

    function run() external {
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        LeashAccount impl =
            new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
        LeashLens lens = new LeashLens();
        vm.stopBroadcast();

        console.log("LeashAccount impl", address(impl));
        console.log("LeashLens        ", address(lens));
        console.log("");
        console.log("Next (WALLET_PK signs its own delegation - do NOT put it in a script):");
        console.log("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...");
    }
}
```

- [ ] **Step 4: 模擬部署**

Run: `set -a && . /home/ubuntu/DEV/ETHOnline2026/.env && set +a && forge script script/DeployAccount.s.sol:DeployAccount --rpc-url "$SEPOLIA_RPC"`
Expected: `SIMULATION COMPLETE`,無 revert

- [ ] **Step 5: 真的部署(**需要人明確授權** —— 這是鏈上狀態變更)**

Run: 加 `--broadcast --slow`
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`

- [ ] **Step 6: 委派 WALLET 並跑一次真的花費**

```bash
# 1. 委派(WALLET 自己簽 authorization)
cast send $WALLET_ADDR --auth $IMPL --private-key $WALLET_PK --rpc-url $R
# 2. 確認韁繩在
cast call $LENS 'delegateOf(address)(bool,address)' $WALLET_ADDR --rpc-url $R
# 3. 綁 agent(WALLET 對自己送交易)
cast send $WALLET_ADDR 'bindAgent(address,bytes32,string)' $AGENT_ADDR $NODE vendors \
  --private-key $WALLET_PK --rpc-url $R
```

- [ ] **Step 7: 更新 `docs/deployments.md`,加入 impl 與 lens 的位址與交易**

- [ ] **Step 8: Commit**

```bash
git add test/LeashAccountFork.t.sol script/DeployAccount.s.sol docs/deployments.md
git commit -m "feat: LeashAccount fork 測試與部署

fork 測試打真的 Sepolia,是整個 ENS 主張的證明 —— 前面所有測試都用 mock
registry,只有這一層驗證我們對真實 ENSv2 的假設是對的。
包含「拿掉 ENS 就過不了」:用 vm.mockCall 讓第一跳回 0,等同全滅拉桿。

部署腳本刻意**不含** WALLET_PK。委派要 WALLET 自己簽 authorization,
那把鑰匙不該出現在部署流程裡 —— 用 cast send --auth 手動送。"
```

---

## Self-Review

**Spec coverage** —— 逐節對照:

| Spec 章節 | 由哪個任務實作 |
|---|---|
| 架構 / 一份 impl 零實例狀態 | 2 |
| Storage:ERC-7201 | 1 |
| 花費流程(13 步) | 6 |
| 2a/2b 拆開 | 6 |
| `PolicyResolved` 送真值 | 6 |
| 先記帳再轉帳 | 6 |
| 週期索引 / `period == 0` / epoch | 4 |
| ENS 三跳 + 每跳長度 | 5 |
| `bindAgent` 檢查 namehash | 3 |
| `receive()` / `fallback()` | 2 |
| 權限表(兩個都要) | 2(`onlySelf`)、3(綁定/暫停)、4(規則) |
| `tightenRule` / `_windowIsSubset` | 4 |
| `Unpaused` 送 `bytes32(0)` / `setRule` 事件對應 | 3、4 |
| attestation digest 含 `SELF` | 2 |
| 理由碼 12 | 6(`Reason.sol` 已於 09-08 加好) |
| `IPolicy` 介面約束 | 6 |
| `AttesterGate` 不存在 | 已記在 `events.md`(09-08) |
| subgraph 找不到監聽對象 | **不在本計畫** —— 屬 sprint 項目 9,已記在 spec |
| `LeashLens` | 1 |
| 錯誤處理總表 | 5(解析)、6(其餘) |
| 測試計畫 | 每個任務的測試步驟 |
| YAGNI 表 | 全程不做 |

**唯一的 gap 是 subgraph 的監聽對象**,那是 sprint 項目 9 的事,spec 已經記下兩個解法
(寫死 demo 錢包位址 / 第一次 `bindAgent` 發 `Leashed`)。**任務 3 的 `bindAgent`
應該順手發 `Leashed`** —— 加進任務 3 的實作。

**Placeholder scan:** 無 `TBD` / `TODO` / 「加上適當的錯誤處理」/ 「類似任務 N」。
每個 code step 都有實際程式碼。

**Type consistency 檢查發現三處要修:**
1. 任務 2 的佔位 `setRule` 少了 `epoch` 欄位在 `TokenRule` 的位置 —— 任務 1 定義了 7 個欄位,
   任務 2 的測試 `LeashStorage.TokenRule(true, 0, 0, 0, 0, 0, 0)` 是 7 個,一致 ✅
2. 任務 6 用 `SpendContext`,那來自 `src/IPolicy.sol` —— 要 `import { IPolicy, SpendContext }`。
   **任務 6 的 import 要補上。**
3. 任務 3 的 `bindAgent` 要發 `Leashed(node, wallet, impl)`(見上方 gap)。
   事件簽章:`event Leashed(bytes32 indexed node, address indexed wallet, address impl)`,
   在**第一次**綁定時發(`b.node == 0` 那一支),參數 `(node, address(this), SELF)`。
