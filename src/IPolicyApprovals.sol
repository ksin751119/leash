// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPolicyApprovals —— 批准清單的唯讀面
/// @notice 「這個 policy 位址被真人批准過嗎」。清單的**寫入**要刷臉(`AttesterGate`),
///         但讀取到處都需要 —— resolver 記事件、`LeashAccount` 做強制、前端做顯示。
/// @dev    key 是 **policy 位址**,不是 codehash(2026-09-07 定案,見
///         `docs/PLAN.md`「Policy 層的設計決定」)。EIP-6780 之後「位址 → 程式碼」
///         已經是永久的,CREATE2 重部署那條老反駁不成立了。
interface IPolicyApprovals {
    function isApproved(address policy) external view returns (bool);
}
