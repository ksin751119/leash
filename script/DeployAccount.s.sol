// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashLens } from "../src/LeashLens.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title DeployAccount —— 部署 LeashAccount impl 與 LeashLens
/// @notice 只做兩件事:部署一份 `LeashAccount`(全域設定 immutable、零實例狀態,
///         所以每個 WALLET 委派過去都用同一份 impl)跟一份 `LeashLens`。
///
/// @dev **刻意不含 `WALLET_PK`。** 委派(`cast send $WALLET --auth $impl`)是
///      WALLET 自己對自己簽的一筆 authorization,不是 ADMIN 能代打的動作 ——
///      那把私鑰不該出現在部署腳本裡,委派要用 `cast send --auth` 手動送。
///      理由同 `script/Deploy.s.sol` 的 chainid 護欄:部署腳本能碰的鑰匙
///      應該正好是「部署這件事」需要的那一把,多一把就多一個外洩面。
contract DeployAccount is Script {
    uint256 constant SEPOLIA = 11155111;

    // 09-08 16:34 UTC 那組位址,見 docs/deployments.md。跟 LeashAccount 的
    // immutable 建構參數必須完全對上 —— 這三個值一旦烙進 impl 的 bytecode
    // 就再也改不了,烙錯就得整份重新部署。
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;

    function run() external {
        // 拿錯 RPC 會把 impl 部署到別的鏈上,而位址是決定性的 ——
        // 那看起來會像成功了。理由跟 `script/Deploy.s.sol` 一樣。
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        LeashAccount impl =
            new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
        LeashLens lens = new LeashLens();
        vm.stopBroadcast();

        console.log("LeashAccount impl", address(impl));
        console.log("LeashLens        ", address(lens));
        console.log("");
        console.log("Next (WALLET_PK signs its own delegation - do NOT put it in a script):");
        console.log("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...");
    }
}
