// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { Reason } from "../src/Reason.sol";
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
import { MockToken } from "./mocks/MockToken.sol";
import {
    FalseReturnToken,
    NoReturnToken,
    ReenteringToken,
    GarbageReturnToken,
    GasBurningPolicy,
    ShortReturnPolicy
} from "./mocks/BadTokens.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

/// @dev 跟 `LeashAccountRules.t.sol` 的 `NoApprovals` 撞名 —— Foundry 把整個
///      test/ 目錄當同一個編譯單元,頂層合約名字要全域唯一,所以加個 2。
contract NoApprovals2 is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return false;
    }
}

contract LeashAccountSpendTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    MockRegistry ethRegistry;
    MockRegistry leashRegistry;
    MockResolver resolver;
    MockToken token;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant POLICY = address(0xB01C);
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    address constant AGENT = address(0xA6E17);
    address constant PAYEE = address(0xBEEF);

    uint256 nonce;
    bytes constant ATT = hex"c0ffee";

    function setUp() public {
        ethRegistry = new MockRegistry();
        leashRegistry = new MockRegistry();
        resolver = new MockResolver();

        ethRegistry.set(address(leashRegistry), address(0));
        leashRegistry.set(address(0), address(resolver));
        resolver.set(POLICY);

        // POLICY(0xB01C) 是任務 5 湊出來、從沒被真的呼叫過的死地址 —— `spend()`
        // 真的會 `call` 它,codeless 位址的呼叫會「成功」但回傳空 returndata,
        // 每一條快樂路徑都會被誤判成 12 POLICY_FAILED。用 `vm.etch` 把
        // `StandardPolicy` 的 runtime bytecode 貼到這個固定位址上 ——
        // resolver 完全不用改,任務 5 那 10 條「只比較位址」的測試也不受影響。
        vm.etch(POLICY, address(new StandardPolicy()).code);

        impl = new LeashAccount(address(ethRegistry), new YesApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));

        token = new MockToken();
        token.mint(wallet, 1_000_000);
    }

    /// 一份完全開放的規則:允許、三個上限都是 0(=不限)、全天時段。
    function _openRule() internal pure returns (LeashStorage.TokenRule memory) {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: 0,
            periodLimit: 0,
            period: 1 days,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
    }

    /// 把 AGENT 綁到 NODE、對 `token` 開一條全開的規則、把 PAYEE 加進白名單。
    /// 大多數 `spend()` 測試都只是想要一條「一定會過」的快樂路徑當起點。
    function _bindAndAllow() internal {
        vm.startPrank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.setRule(NODE, address(token), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(token), PAYEE, ++nonce, ATT);
        vm.stopPrank();
    }

    // ============================================================
    // 任務 5 遺留:ENS 三跳解析(不動)
    // ============================================================

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

    // ============================================================
    // 任務 6:spend() —— 把四道關卡串起來
    // ============================================================

    // --- 🔴 C3 迴歸:假成功 ---

    /// **`token` 和 `payee` 由 agent 指定,可以是 `address(this)`。**
    ///
    /// 第 11 步 `token.transfer(...)` 送出去時 `msg.sender == address(this)` ——
    /// 那正是 `bindAgent` / `tightenRule` / `removePayee` 接受的憑證。
    /// 而如果用 SafeERC20 那種寬鬆的回傳檢查:
    ///   - `token == address(this)` → 打到自己的 fallback
    ///   - `token == address(0)` → 對空位址的呼叫永遠成功、回傳空 returndata
    /// 兩種情況都是 **`spent` 增加、`SpendExecuted` 發出,而錢一分都沒動。**
    /// subgraph 會記下一筆不存在的付款。
    function test_rejects_targets_that_point_back_at_the_account() public {
        _bindAndAllow();
        vm.startPrank(AGENT);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(wallet, PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), wallet, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(0), PAYEE, 1);

        vm.expectRevert(LeashAccount.BadTarget.selector);
        acct.spend(address(token), address(0), 1);

        vm.stopPrank();
    }

    /// 沒有 code 的位址不可能是代幣。
    function test_rejects_a_token_with_no_code() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.BadTarget.selector);
        vm.prank(AGENT);
        acct.spend(address(0xC0DE1E55), PAYEE, 1);
    }

    /// **回傳值檢查要嚴格:恰好 32 bytes 且解出來是 `true`。**
    /// 不用 SafeERC20 的寬鬆版 —— 我們只需要支援自己 demo 用的代幣,
    /// 而寬鬆換來的相容性,在這裡的代價是一個假的成功。
    function test_rejects_tokens_that_do_not_return_true() public {
        _bindAndAllow();
        FalseReturnToken f = new FalseReturnToken();
        NoReturnToken n = new NoReturnToken();

        vm.startPrank(wallet);
        acct.setRule(NODE, address(f), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(f), PAYEE, ++nonce, ATT);
        acct.setRule(NODE, address(n), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(n), PAYEE, ++nonce, ATT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(f), PAYEE, 1);

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(n), PAYEE, 1);
    }

    /// review 找到的 Minor:回傳長度剛好 32 bytes,但不是 0/1(例如 `2`)
    /// 的代幣,原本會讓 `abi.decode(ret, (bool))` 直接炸出裸的 `Panic`,
    /// 蓋掉真正的失敗理由。**這裡斷言的是 `TransferFailed()`,不是任何
    /// panic** —— `vm.expectRevert` 指定精確的 selector,如果實際 revert
    /// 是 `Panic(uint256)` 而不是這個自訂錯誤,這條測試會失敗。
    function test_a_garbage_but_32_byte_return_fails_cleanly_not_a_panic() public {
        _bindAndAllow();
        GarbageReturnToken g = new GarbageReturnToken();

        vm.startPrank(wallet);
        acct.setRule(NODE, address(g), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(g), PAYEE, ++nonce, ATT);
        vm.stopPrank();

        vm.expectRevert(LeashAccount.TransferFailed.selector);
        vm.prank(AGENT);
        acct.spend(address(g), PAYEE, 1);
    }

    function test_zero_amount_reverts() public {
        _bindAndAllow();
        vm.expectRevert(LeashAccount.ZeroAmount.selector);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 0);
    }

    // --- 🔴 重入 ---

    /// 重入鎖是第一道防線,**先記帳是第二道** —— 兩道都失效才會出事。
    ///
    /// **重入呼叫走的是一條除了重入鎖之外完全合法的路徑**:`address(rt)`
    /// 自己也被綁成 agent,`payee` 用真正被允許的 `PAYEE`(不是 `msg.sender`)。
    /// 這樣安排是刻意的 —— 如果重入那筆會被 `NotBoundAgent` 或 `BadTarget`
    /// 這些跟重入無關的護欄擋下來,測試就算重入鎖被整個拿掉也一樣會綠燈,
    /// mutation check 抓不到(這個坑已經實測踩過一次)。
    function test_reentrancy_is_blocked_and_the_ledger_is_already_updated() public {
        ReenteringToken rt = new ReenteringToken();
        vm.startPrank(wallet);
        acct.setRule(NODE, address(rt), _openRule(), ++nonce, ATT);
        acct.allowPayee(NODE, address(rt), PAYEE, ++nonce, ATT);
        acct.bindAgent(AGENT, NODE, LABEL);
        acct.bindAgent(address(rt), NODE, LABEL); // 重入呼叫的 msg.sender 就是 rt 自己
        vm.stopPrank();

        rt.arm(wallet, PAYEE);
        vm.prank(AGENT);
        acct.spend(address(rt), PAYEE, 100);

        // 只記了一次 —— 內層的 spend 被鎖擋掉了。少了鎖的話,重入那筆會
        // 完整跑完(它自己合法),把這裡變成 101。
        assertEq(acct.spentInCurrentPeriod(NODE, address(rt)), 100);
    }

    // --- 🔴 快樂路徑:前面全部測的是「被擋」或「壞代幣」,補一條「真的成功」 ---

    /// OK 路徑釘住:錢真的動、`SpendExecuted` 帶對的欄位。
    function test_happy_path_executes_and_emits_spend_executed() public {
        _bindAndAllow();
        uint256 beforeWallet = token.balanceOf(wallet);
        uint256 beforePayee = token.balanceOf(PAYEE);
        uint64 expectedPeriodEnd = uint64(((block.timestamp / 1 days) + 1) * 1 days);

        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendExecuted(
            NODE, AGENT, PAYEE, address(token), 1, POLICY, 1, 0, expectedPeriodEnd
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);

        assertEq(token.balanceOf(wallet), beforeWallet - 1, "wallet balance decreased");
        assertEq(token.balanceOf(PAYEE), beforePayee + 1, "payee balance increased");
        assertEq(acct.spentInCurrentPeriod(NODE, address(token)), 1);
    }

    // --- 🔴 理由碼全覆蓋:每一個都要「有事件」且「餘額沒變」 ---

    function test_blocked_paths_emit_and_do_not_move_money() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        // 10 PAUSED
        vm.prank(wallet);
        acct.pause();
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.PAUSED, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "paused: no movement");
        vm.prank(wallet);
        acct.unpause();

        // 3 NO_POLICY
        resolver.set(address(0));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.NO_POLICY, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no policy: no movement");
        resolver.set(POLICY);

        // 2 AGENT_REVOKED —— **不 revert**,要留可索引的紀錄
        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.AGENT_REVOKED, address(0), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "revoked: no movement");
    }

    /// **2a 沒綁定 → revert;2b 已撤銷 → 不 revert。**
    /// 凍結文件把 revert 的例外限定在「caller **根本不是**被綁定的 agent」,
    /// 而被撤銷的 agent 是「已綁定」的 —— 撤銷是行政動作,那個 agent
    /// 應該查得到自己為什麼不能動了(revert 的 log 會被丟棄)。
    function test_unbound_reverts_but_revoked_does_not() public {
        _bindAndAllow();

        vm.expectRevert(LeashAccount.NotBoundAgent.selector);
        vm.prank(address(0x4007));
        acct.spend(address(token), PAYEE, 1);

        vm.prank(wallet);
        acct.revokeAgent(AGENT);
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1); // 不 revert
    }

    /// 🔴 M8 迴歸:`PolicyResolved.approved` 要送**真值**。
    /// 初版把事件排在批准檢查之後,那時它只可能是 `true` —— 凍結 schema 裡
    /// 那個欄位就永遠是死的。而「指標指到一份沒被批准的 policy」正是
    /// ADMIN 金鑰被偷時唯一的鏈上訊號。
    function test_policy_resolved_carries_the_real_approval_flag() public {
        _bindAndAllow();
        LeashAccount implNo =
            new LeashAccount(address(ethRegistry), new NoApprovals2(), new MockAttester());
        vm.signAndAttachDelegation(address(implNo), walletPk);
        uint256 before = token.balanceOf(wallet);

        vm.expectEmit(true, true, false, true);
        emit LeashAccount.PolicyResolved(NODE, POLICY, false);
        // 跟其他理由碼測試一樣:不只看 PolicyResolved,連 SpendBlocked
        // 本身有沒有發、理由碼對不對都要斷言 —— 光看 PolicyResolved.approved
        // 是 false,不代表帳戶真的把這筆擋下來記成 POLICY_NOT_APPROVED。
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_NOT_APPROVED, POLICY, 0, 0
        );
        vm.prank(AGENT);
        LeashAccount(payable(wallet)).spend(address(token), PAYEE, 1);

        assertEq(token.balanceOf(wallet), before, "not approved: no movement");
    }

    /// 12 POLICY_FAILED 的三種觸發方式。
    function test_policy_failure_modes_all_fail_closed() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(wallet);

        GasBurningPolicy gasBurner = new GasBurningPolicy();
        resolver.set(address(gasBurner));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(gasBurner), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "gas burner: no movement");

        ShortReturnPolicy shortReturn = new ShortReturnPolicy();
        resolver.set(address(shortReturn));
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(shortReturn), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "short return: no movement");

        resolver.set(address(0xDEAD)); // 沒有 code
        vm.expectEmit(true, true, true, true);
        emit LeashAccount.SpendBlocked(
            NODE, AGENT, PAYEE, address(token), 1, Reason.POLICY_FAILED, address(0xDEAD), 0, 0
        );
        vm.prank(AGENT);
        acct.spend(address(token), PAYEE, 1);
        assertEq(token.balanceOf(wallet), before, "no code: no movement");
    }

    // --- 🔴 C4 迴歸:WALLET 私鑰不受約束,而那是逃生口 ---

    /// **這條測試把邊界釘成規格。**
    /// EIP-7702 只約束打到那個 EOA 的呼叫;WALLET 私鑰照樣能直簽
    /// `USDC.transfer`,policy 那條路徑根本不會執行。
    /// 說「唯一的花費路徑」會被評審一問就破 —— 正確的說法是
    /// 「**agent 的**唯一花費路徑」,而 WALLET 不受約束既是邊界也是逃生口:
    /// 錢包持有者永遠拿得回自己的錢,不會被自己設的 policy 鎖死。
    function test_the_wallet_key_can_always_transfer_directly() public {
        _bindAndAllow();
        uint256 before = token.balanceOf(PAYEE);

        vm.recordLogs();
        vm.prank(wallet);
        token.transfer(PAYEE, 500); // 沒有經過 spend()

        assertEq(token.balanceOf(PAYEE) - before, 500, "the money moved");
        // 而且沒有發出 SpendExecuted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != LeashAccount.SpendExecuted.selector,
                "no SpendExecuted for a direct transfer"
            );
        }
    }
}
