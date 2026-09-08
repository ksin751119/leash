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
