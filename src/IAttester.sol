// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAttester —— 「這件事有真人背書」的抽象
/// @notice 只有**擴權**要過這道門(批准新 policy、調高額度、加白名單收款人)。
///         縮權永遠不需要 —— 出事時你不會想先找手機刷臉。
///
/// @dev 這個介面存在的理由是**時程風險**,不是抽象美學:World 的核准什麼時候到
///      不在我們手上,所以合約從第一天就只認介面,實作可以晚點換。
///      2026-09-07 已實測 Selfie Check 端對端可用,所以 `WorldAttester` 做得出來;
///      但介面留著仍然有價值 —— demo 用 mock 才不必每跑一次就刷一次臉。
interface IAttester {
    /// @param digest 被背書的東西的 hash(EIP-712 typed data hash)
    /// @param attestation 背書資料。`WorldAttester` 放的是後端用 signer key 簽的簽章;
    ///        `MockAttester` 不看。
    /// @return ok 通過與否。**實作不得 revert 表達失敗** —— 呼叫端要能區分
    ///         「沒通過」和「這個 attester 壞了」。
    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool ok);

    /// @notice 給人看的識別字串,會出現在前端與 demo 裡
    function describe() external pure returns (string memory);
}
