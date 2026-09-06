// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "./IPolicy.sol";
import { Reason } from "./Reason.sol";

/// @title StandardPolicy —— 預設規則:代幣白名單、收款人白名單、單筆上限、週期預算、時段
/// @notice 介面只要求 `view`;這一份刻意收緊成 `pure`。
///         沒有 storage、沒有 owner、沒有 constructor 參數,也不讀任何外部合約 ——
///         所以同一份 bytecode 部署幾次都是同一個 codehash,而且 codehash
///         **完全決定行為**。允許清單因此才管得住它,agent 也能在鏈下完全重現判斷。
///
///         代價寫在這裡以免日後忘記:這份 policy **讀不到外部狀態** ——
///         沒有價格預言機、沒有共用黑名單、沒有跨 agent 共用預算。
///         那些要另外寫一份 `view` 的實作,介面已經留好門。
contract StandardPolicy is IPolicy {
    /// @dev 檢查順序即為理由碼的優先序。多條同時違反時,回報**最外層**的那條。
    ///      這樣 agent 修正一項之後重試,才會逐步收斂而不是在同一層打轉。
    function check(SpendContext calldata ctx) external pure returns (uint8) {
        if (!ctx.tokenAllowed) return Reason.TOKEN_NOT_ALLOWED;
        if (!ctx.payeeAllowed) return Reason.PAYEE_NOT_ALLOWED;

        if (ctx.txLimit != 0 && ctx.amount > ctx.txLimit) return Reason.OVER_TX_LIMIT;

        if (ctx.periodLimit != 0) {
            // 先擋掉「已經超支」,剩下的減法才不會 underflow
            if (ctx.spentSoFar >= ctx.periodLimit) return Reason.OVER_PERIOD_LIMIT;
            if (ctx.amount > ctx.periodLimit - ctx.spentSoFar) return Reason.OVER_PERIOD_LIMIT;
        }

        if (!_inWindow(ctx.nowTs, ctx.windowStart, ctx.windowEnd)) {
            return Reason.OUTSIDE_TIME_WINDOW;
        }

        return Reason.OK;
    }

    function describe() external pure returns (string memory) {
        return "StandardPolicy/1: token+payee allowlist, per-tx cap, period budget, daily window";
    }

    /// @dev `start == end` 視為全天開放。`start > end` 是跨午夜的時段(例如 22:00–06:00)。
    ///      以 UTC 計算 —— 時區換算留給前端,鏈上不猜。
    function _inWindow(uint64 nowTs, uint16 start, uint16 end) private pure returns (bool) {
        if (start == end) return true;
        uint256 minuteOfDay = (uint256(nowTs) % 1 days) / 60;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }
}
