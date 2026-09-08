// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title LeashAccountFork —— 打真的 Sepolia,不是 mock
/// @notice 前面所有測試(`LeashAccountBinding`、`LeashAccountRules`、
///         `LeashAccountSpend`……)的 ENS registry 全部是 mock。**這一份是唯一
///         一份打真的 ENSv2 合約的測試** —— 只有它能證明我們對「三跳、每跳的
///         returndata 長度、最後解出的位址真的在批准清單裡」這些假設,
///         在真的鏈上也成立。
///
/// @dev 需要 `SEPOLIA_RPC`。沒設就用 `vm.skip` 整份跳過(CI 上不一定有網路),
///      **skip 跟 pass 在 forge 的輸出裡是兩種不同的狀態** —— 用 skip 而不是
///      單純 `return`,是為了不讓「沒有 RPC、什麼都沒驗證」的執行結果
///      看起來跟「三跳真的解出來了」一樣是綠的。
contract LeashAccountForkTest is Test {
    // 09-08 16:34 UTC 那組位址,見 docs/deployments.md。
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;
    address constant STANDARD_POLICY = 0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b;
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    LeashAccount impl;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            // `vm.skip` 而非 bare `return`:每個測試各自的
            // `if (address(impl) == address(0)) return;` 只防得住「這個測試
            // 自己沒做事卻回報 PASS」,防不住「整份 fork 測試沒打到鏈上,
            // 卻在 CI 報表裡跟真的驗證過一樣是綠的」——那才是真正的風險。
            // `vm.skip` 讓 forge 把這些測試標成 SKIPPED,跟 PASSED 分開列。
            vm.skip(true, "SEPOLIA_RPC not set - skipping live Sepolia fork test");
            return;
        }
        vm.createSelectFork(rpc);
        impl = new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
    }

    /// **這條測試是整個 ENS 主張的證明。**
    /// 三跳打真的 ENSv2,解出真的 policy 位址 —— 不是 mock registry 回傳的
    /// 假值,是 2026-09-08 16:34 UTC 那次真的部署、真的 `setSubregistry`/
    /// `register`/`setPolicy` 接線之後,鏈上真正存在的狀態。
    function test_resolves_the_real_policy_on_sepolia() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));
        assertEq(acct.resolvePolicy(NODE, "vendors"), STANDARD_POLICY);
    }

    /// 那份 policy 真的在批准清單裡 —— 不是「resolvePolicy 剛好回傳了一個
    /// 非零位址」,是那個位址真的通過了 `PolicyApprovals.approve`。
    function test_the_real_policy_is_approved() public view {
        if (address(impl) == address(0)) return;
        assertTrue(IPolicyApprovals(APPROVALS).isApproved(STANDARD_POLICY));
    }

    /// **拿掉 ENS 就過不了。** 用 `vm.mockCall` 讓第一跳回 0 ——
    /// 等同 `ETHRegistry.setSubregistry(leash.eth, 0x0)`(全滅拉桿,見
    /// `docs/deployments.md`「三層撤銷」表的最重那一層)。
    function test_removing_the_ens_subtree_stops_resolution() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));

        vm.mockCall(
            ETH_REGISTRY,
            abi.encodeWithSignature("getSubregistry(string)", "leash"),
            abi.encode(address(0))
        );
        assertEq(acct.resolvePolicy(NODE, "vendors"), address(0), "no ENS, no policy");
    }
}
