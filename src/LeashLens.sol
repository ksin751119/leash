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
