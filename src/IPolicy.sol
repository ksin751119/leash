// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 一次花費請求的完整脈絡。**由 `LeashAccount` 組好之後整包送進 policy。**
/// @dev    這個 struct 存在的理由:policy 不需要、也不應該去帳戶裡撈東西。
///         帳戶查完表把結論塞進來,policy 只做判斷。兩個後果:
///         1. policy 是被 `call` 的外部合約,**碰不到帳戶的 storage**
///            (只有 `delegatecall` 會破壞這條 —— 我們永遠不用它)
///         2. 前端和 agent 可以用同一份輸入走 `eth_call` 預演,結果保證一致
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
///         但「這個位址有沒有被批准過」由批准清單決定,而那份清單要刷臉才能加。
///         兩層分開,ADMIN 金鑰被偷也換不上沒批准過的規則。
interface IPolicy {
    /// @return reason `Reason.OK` 表示放行,其餘為攔截理由碼
    /// @dev **刻意不是 `view`。** policy 允許有自己的 storage —— 「多個 agent 共用一筆
    ///      總預算」需要有人記帳,而讓 policy 自己記,是唯一不用在帳戶裡開特例的做法。
    ///
    ///      安全保證沒有因此變弱:policy 是被 `call` 的獨立合約,寫的是**自己的** storage。
    ///      能碰到帳戶 storage 的只有 `delegatecall`,我們永遠不用。
    ///
    ///      **有副作用,所以帳戶只在真的要付款時呼叫一次。** 預演走 `eth_call`。
    ///      呼叫端必須:上重入鎖、限 gas、回傳長度不對一律當成擋下(fail-closed)。
    ///
    ///      實作可以收緊可變性(Solidity 允許 override 時收緊)——
    ///      `StandardPolicy` 就是 `pure` 的。
    function check(SpendContext calldata ctx) external returns (uint8 reason);

    /// @notice 給人看的識別字串,會出現在前端與 demo 裡
    function describe() external pure returns (string memory);
}
