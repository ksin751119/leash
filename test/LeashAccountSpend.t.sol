// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { MockRegistry, MockResolver, NameCheckingResolver } from "./mocks/MockRegistry.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract LeashAccountSpendTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    MockRegistry ethRegistry;
    MockRegistry leashRegistry;
    MockResolver resolver;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant POLICY = address(0xB01C);
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    function setUp() public {
        ethRegistry = new MockRegistry();
        leashRegistry = new MockRegistry();
        resolver = new MockResolver();

        ethRegistry.set(address(leashRegistry), address(0));
        leashRegistry.set(address(0), address(resolver));
        resolver.set(POLICY);

        impl = new LeashAccount(address(ethRegistry), new YesApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    /// 快樂路徑:三跳都通,解出 policy 位址。
    function test_resolves_the_policy_through_three_hops() public view {
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY);
    }

    /// 第一跳回 0 = `leash.eth` 的子樹被收回 = **全部 agent 同時停機**。
    function test_hop1_zero_is_the_kill_switch() public {
        ethRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 第二跳回 0 = 子名被撤銷或過期 = **這一個 agent 死**。
    function test_hop2_zero_kills_only_this_agent() public {
        leashRegistry.set(address(0), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 第三跳回 0 = policy 指標被清空 = 換規則那一層。
    function test_hop3_zero_means_no_policy() public {
        resolver.set(address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 任何一跳 revert 都必須 **fail-closed**,而不是讓整筆交易掛掉。
    /// ENS 的合約還在審計期 —— 我們不能因為別人的合約 revert 就讓帳戶卡死。
    function test_a_reverting_hop_fails_closed() public {
        ethRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        ethRegistry.setRevert(false);

        leashRegistry.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
        leashRegistry.setRevert(false);

        resolver.setRevert(true);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// 🔴 **回傳長度不對也要 fail-closed。**
    ///
    /// 而且要注意每一跳的預期長度**不一樣**:hop1/hop2 是 32(address),
    /// hop3 是 **96**(`bytes` = offset 32 + length 32 + 內層 32)。
    /// 對 hop3 檢查 `== 32` 的話快樂路徑永遠不成立,而回報的理由碼會是
    /// 「ENS 讀不到 policy」——完全誤導除錯方向。
    function test_a_malformed_return_length_fails_closed() public {
        leashRegistry.setPad(1);
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// `_dnsEncode` 用寫死的 `leash.eth` 尾段。這條測試確認組出來的值
    /// 與實測值一致 —— 錯了 resolver 收到的名字就是壞的。
    function test_dns_encoding_matches_the_measured_value() public {
        // 透過 resolvePolicy 間接驗證:MockResolver 不看 name,所以改用
        // 一個會檢查 name 的 resolver
        NameCheckingResolver nc =
            new NameCheckingResolver(hex"0776656e646f7273056c656173680365746800", POLICY);
        leashRegistry.set(address(0), address(nc));
        assertEq(acct.resolvePolicy(NODE, LABEL), POLICY, "dns name matched exactly");
    }
}
