// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAttester } from "./IAttester.sol";

/// @title MockAttester —— demo 與測試用,**不做任何驗證**
/// @notice ⚠️ 這份合約對任何輸入都回 `true`。它存在的理由有兩個:
///         1. 錄影片和跑測試時不必每次都真的刷一次臉
///         2. World 那邊出狀況時,整條線還跑得動(換一個位址的事)
///
/// @dev **絕對不要部署到會拿真錢的地方。** `describe()` 刻意把這件事寫進字串裡,
///      前端顯示的時候看得見 —— 我們不想在 demo 畫面上假裝有真人把關。
contract MockAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }

    function describe() external pure returns (string memory) {
        return "MockAttester (NO verification - testing only)";
    }
}
