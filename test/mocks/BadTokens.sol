// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "../../src/IPolicy.sol";
import { LeashAccount } from "../../src/LeashAccount.sol";

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
///
///      **也順便觀察「先記帳」這第二道防線。** 重入鎖擋得住這裡的內層呼叫,
///      不代表帳戶真的「先記帳、後轉帳」——如果把 `$.spent` 的寫入搬到
///      `_transferAndEmit` 之後,重入鎖仍然生效,測試若只斷言鎖有沒有擋下
///      內層呼叫就完全測不出這個順序被換掉。所以在被 `transfer` 呼叫的當下
///      (轉帳當中、記帳理論上已經寫完的那一刻)反查一次
///      `spentInCurrentPeriod`,把結果存起來:順序對的話這裡看到的是已經
///      入帳的金額,順序被換掉的話這裡看到的是 0。
contract ReenteringToken {
    address public target;
    address public reentrantPayee;
    bytes32 public node;
    bool public armed;
    uint256 public observedSpent;

    function arm(address t, address payee_, bytes32 node_) external {
        target = t;
        reentrantPayee = payee_;
        node = node_;
        armed = true;
    }

    function transfer(address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
            // 「記帳先於轉帳」的觀察點:這行跑的時候,轉帳呼叫已經在路上了
            // (我們自己就是那筆轉帳的 token),所以帳戶如果先寫 `$.spent`
            // 再轉帳,這裡讀到的就已經是入帳後的金額。
            observedSpent = LeashAccount(payable(target)).spentInCurrentPeriod(node, address(this));
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

/// @dev 回傳 256 的 policy —— 測 `_askPolicy` 的 `uint8` clamp。
/// @notice `check` 的介面回傳型別是 `uint8`,但外部合約的回傳資料只受
///         calldata 編碼約束,不受編譯器型別檢查限制,所以宣告成 `uint256`
///         照樣能把 256 塞進 32 bytes 回傳。少了 clamp 的話,`_askPolicy`
///         直接 `uint8(raw)` 截斷,256 truncate 成 0 = `Reason.OK`——一份
///         行為異常的 policy 就這樣被誤判成放行,錢真的會轉出去
///         (整條分支裡唯一的 fail-open 路徑)。故意不 `is IPolicy`,
///         理由同 `ShortReturnPolicy`:回傳型別對不上介面會拒絕編譯,
///         但 selector 只看函式名字跟參數型別,不受影響。
contract OverflowingPolicy {
    function check(SpendContext calldata) external pure returns (uint256) {
        return 256;
    }

    function describe() external pure returns (string memory) {
        return "OverflowingPolicy";
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
