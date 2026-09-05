// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 一次花費請求的完整脈絡。**由 `LeashAccount` 組好之後整包送進 policy。**
/// @dev    這個 struct 存在的理由:讓 policy 可以是 `pure`。
///         policy 不讀 storage、不讀 `block.timestamp`、不讀 `msg.sender` ——
///         所有輸入都在這裡。三個後果:
///         1. 用 `staticcall` 就夠,不需要 `delegatecall`,沒有 storage 撞位風險
///            (賽前實測:7702 委派後讀到的是 EOA 的空 storage,見 docs/ensv2-sepolia.md)
///         2. codehash 完全決定行為 —— 這正是 codehash 允許清單有意義的前提
///         3. 前端和 agent 可以在鏈下用同一份輸入預演,結果保證一致
struct SpendContext {
    address agent;
    address payee;
    address token;
    uint256 amount;
    // --- 由帳戶查表後填入 ---
    bool tokenAllowed;
    bool payeeAllowed;
    uint256 txLimit; // 單筆上限。0 = 不限
    uint256 periodLimit; // 週期上限。0 = 不限
    uint256 spentSoFar; // 本週期已花(不含這筆)
    uint64 nowTs; // 帳戶傳入的 block.timestamp
    uint16 windowStart; // 允許時段起點,以 UTC 當日分鐘數計(0–1439)
    uint16 windowEnd; // 允許時段終點(不含)。start == end 表示全天開放
}

/// @title IPolicy —— 可替換的規則實作
/// @notice policy 位址存在 ENS 名字的 resolver 記錄裡,由 ADMIN 指定;
///         但「這份 code 有沒有被批准過」由 codehash 允許清單決定,而那份清單要刷臉才能加。
///         兩層分開,ADMIN 金鑰被偷也換不上沒批准過的規則。
interface IPolicy {
    /// @return reason `Reason.OK` 表示放行,其餘為攔截理由碼(5–9)
    function check(SpendContext calldata ctx) external pure returns (uint8 reason);

    /// @notice 給人看的識別字串,會出現在前端與 demo 裡
    function describe() external pure returns (string memory);
}
