// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Reason —— 攔截理由碼
/// @notice 定稿於 `docs/events.md`。**數字不可重排**:subgraph、前端與 agent 都靠它。
///         1–4、10 由 `LeashAccount` 在呼叫 policy 之前判定;
///         5–9 由 policy 判定(policy 只回答「這筆花費符不符合規則」)。
library Reason {
    uint8 internal constant OK = 0;

    // --- 帳戶層(呼叫 policy 之前)---
    uint8 internal constant AGENT_NOT_BOUND = 1;
    uint8 internal constant AGENT_REVOKED = 2;
    uint8 internal constant NO_POLICY = 3;
    uint8 internal constant POLICY_CODEHASH_NOT_APPROVED = 4;

    // --- policy 層 ---
    uint8 internal constant TOKEN_NOT_ALLOWED = 5;
    uint8 internal constant PAYEE_NOT_ALLOWED = 6;
    uint8 internal constant OVER_TX_LIMIT = 7;
    uint8 internal constant OVER_PERIOD_LIMIT = 8;
    uint8 internal constant OUTSIDE_TIME_WINDOW = 9;

    // --- 帳戶層 ---
    uint8 internal constant PAUSED = 10;
}
