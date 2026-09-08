// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import {
    MockRegistry,
    MockResolver,
    NameCheckingResolver,
    MalformedHeaderResolver,
    DirtyPaddingResolver,
    DirtyAddressRegistry
} from "./mocks/MockRegistry.sol";

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

    /// resolve() 回傳長度剛好是 96,但 header 的 offset 是假的(0x40,不是
    /// 合法的 0x20)。**只檢查總長度不夠** —— 長度對但結構是假的資料一樣要
    /// fail-closed,不能讓 `abi.decode` 在這種輸入上 revert、壞了
    /// `resolvePolicy` 絕不 revert 的保證。
    function test_a_malformed_header_fails_closed() public {
        MalformedHeaderResolver bad = new MalformedHeaderResolver(POLICY);
        leashRegistry.set(address(0), address(bad));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// header 合法(offset/length 都是 0x20),但 payload 的高 12 bytes 不是
    /// 0。`abi.decode(bytes, (address))` 會擋住這個並 revert,但直接用
    /// assembly 截斷成 uint160 的話會安靜地放行一個看起來合法的地址 ——
    /// 兩者都不安全,必須自己驗證 padding 乾不乾淨。
    function test_dirty_address_padding_on_hop3_fails_closed() public {
        DirtyPaddingResolver dirty = new DirtyPaddingResolver(POLICY);
        leashRegistry.set(address(0), address(dirty));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }

    /// hop1/hop2 共用 `_staticAddress`,跟 hop3 一樣不能對外部回傳資料呼叫
    /// `abi.decode`——同一個漏洞類型,同一份函式,補上對應的測試:回傳長度
    /// 合法(32 bytes),但高 12 bytes 是髒的。
    ///
    /// **低 160 bits 刻意填一個真的能用的 resolver(`resolver`,已經設定好會
    /// 回傳 `POLICY`)**,而不是隨便一個死地址 —— 如果只填死地址,少了 padding
    /// 檢查時 hop3 一樣會因為打到沒有程式碼的位址而自然回傳 `address(0)`,
    /// 測試就測不出 hop2 的 padding 檢查有沒有被拿掉(這個坑已經實測踩過一次:
    /// 用 0xDEAD 當低位時,移除檢查後測試依然通過,因為錯誤湊巧被 hop3 擋住)。
    /// 換成真正可用的 resolver,拿掉檢查就會讓整條路徑「成功」解出 `POLICY`,
    /// 才是這條測試真正要抓的錯。
    function test_dirty_address_padding_on_hop2_fails_closed() public {
        DirtyAddressRegistry dirty = new DirtyAddressRegistry(address(resolver));
        ethRegistry.set(address(dirty), address(0));
        assertEq(acct.resolvePolicy(NODE, LABEL), address(0));
    }
}
