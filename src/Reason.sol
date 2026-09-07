// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Reason —— 攔截理由碼
/// @notice 定稿於 `docs/events.md`。**數字不可重排**:subgraph、前端與 agent 都靠它。
///         1–4、10 由 `LeashAccount` 在呼叫 policy 之前判定;
///         5–9、11 由 policy 判定(policy 只回答「這筆花費符不符合規則」)。
library Reason {
    uint8 internal constant OK = 0;

    // --- 帳戶層(呼叫 policy 之前)---
    uint8 internal constant AGENT_NOT_BOUND = 1;
    uint8 internal constant AGENT_REVOKED = 2;
    uint8 internal constant NO_POLICY = 3;
    /// @dev 批准清單的 key 是 **policy 位址**,不是 codehash(2026-09-07 定案,
    ///      理由見 PLAN.md「允許清單的 key 用位址」)。數字維持 4 不動。
    uint8 internal constant POLICY_NOT_APPROVED = 4;

    // --- policy 層 ---
    uint8 internal constant TOKEN_NOT_ALLOWED = 5;
    uint8 internal constant PAYEE_NOT_ALLOWED = 6;
    uint8 internal constant OVER_TX_LIMIT = 7;
    uint8 internal constant OVER_PERIOD_LIMIT = 8;
    uint8 internal constant OUTSIDE_TIME_WINDOW = 9;

    // --- 帳戶層 ---
    uint8 internal constant PAUSED = 10;

    // --- policy 層(後補)---
    /// @dev 多個 agent 共用一筆總預算時由 `SharedBudgetPolicy` 回傳。
    ///      帳戶不知道有這回事 —— 這正是重點。
    uint8 internal constant OVER_SHARED_LIMIT = 11;
}
