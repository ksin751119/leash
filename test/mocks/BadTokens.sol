// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "../../src/IPolicy.sol";

/// @dev 回傳 `false` 的 ERC-20。帳戶必須 revert,不能當成成功。
contract FalseReturnToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev 什麼都不回傳的老式 ERC-20。**嚴格檢查**必須拒絕它。
contract NoReturnToken {
    function transfer(address, uint256) external { }
}

/// @dev 在 transfer 裡回頭再打 `spend` —— 測重入鎖與「先記帳」。
///
///      **`payee` 是可設定的參數,不是寫死 `msg.sender`。** 原始設計拿呼叫者
///      (=wallet)當重入那筆的 payee,而 `BadTarget` 擋 `payee == address(this)`——
///      不管重入鎖在不在,那筆重入呼叫都會被 `BadTarget` 擋下來,測試永遠是
///      綠燈,**測不出重入鎖被拿掉**(mutation check 實測踩過這個坑)。
///      改成外部指定一個合法的 payee,讓重入呼叫除了重入鎖之外**沒有任何
///      別的理由會被擋**,mutation check 才抓得到。
contract ReenteringToken {
    address public target;
    address public reentrantPayee;
    bool public armed;

    function arm(address t, address payee_) external {
        target = t;
        reentrantPayee = payee_;
        armed = true;
    }

    function transfer(address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(
                abi.encodeWithSignature(
                    "spend(address,address,uint256)", address(this), reentrantPayee, 1
                )
            );
            ok; // 失敗是預期的(重入鎖擋下來)
        }
        return true;
    }
}

/// @dev 回傳長度剛好 32 bytes,但不是 0 也不是 1 的代幣 —— 用來測「回傳值
///      不是 `abi.decode(ret, (bool))` 吃得下的東西」不能讓 `spend` 炸出
///      一個裸的 `Panic`,蓋掉真正的失敗理由。`TransferFailed()` 才是
///      正確的失敗方式。
contract GarbageReturnToken {
    function transfer(address, uint256) external pure returns (uint256) {
        return 2;
    }
}

/// @dev 燒掉所有 gas 的 policy —— 測 `POLICY_GAS` 上限與 fail-closed。
/// @notice **簽章要跟 `IPolicy.check` 完全一致**(`SpendContext calldata`),
///         不能用 `bytes calldata` 湊 —— selector 對不上,帳戶那層永遠打不進
///         `while (true) {}`,測到的只會是「呼叫一個根本不存在的函式」,
///         `POLICY_GAS` 這道 DoS 防線就完全沒被跑到。
contract GasBurningPolicy is IPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        while (true) { }
        return 0;
    }

    function describe() external pure returns (string memory) {
        return "GasBurningPolicy";
    }
}

/// @dev 回傳長度不對的 policy。**故意不 `is IPolicy`**:selector 只看函式名字
///      跟參數型別,回傳型別對不對不影響 `abi.encodeCall(IPolicy.check, ctx)`
///      能不能打進來 —— 但如果宣告 `is IPolicy`,編譯器會因為回傳型別
///      (`bytes memory` vs 介面要求的 `uint8`)對不上而拒絕編譯。
///      參數型別仍然要跟 `IPolicy.check` 完全一致,理由見 `GasBurningPolicy`。
contract ShortReturnPolicy {
    function check(SpendContext calldata) external pure returns (bytes memory) {
        return hex"01";
    }

    function describe() external pure returns (string memory) {
        return "ShortReturnPolicy";
    }
}
