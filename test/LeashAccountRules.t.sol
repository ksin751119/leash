// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract NoApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return false;
    }
}

contract LeashAccountRulesTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    uint256 walletPk = 0x8A11E7;
    address wallet;

    address constant TOKEN = address(0x05DC);
    address constant PAYEE = address(0xBEEF);
    bytes constant ATT = hex"c0ffee";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_757_000_000);
        impl = new LeashAccount(address(0xE45), new NoApprovals(), new MockAttester());
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    function _rule(uint256 txLimit, uint256 periodLimit, uint64 period, uint16 ws, uint16 we)
        internal
        pure
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: txLimit,
            periodLimit: periodLimit,
            period: period,
            windowStart: ws,
            windowEnd: we,
            epoch: 0
        });
    }

    function _set(LeashStorage.TokenRule memory r) internal {
        vm.prank(wallet);
        acct.setRule(NODE, TOKEN, r, ++nonce, ATT);
    }

    // --- 🔴 `0 = 不限` 的比較反轉 ---

    /// **這是最容易寫反的一行。** `0` 代表「不限」,所以:
    ///   0 → 100 是**收緊**(從無限變成有限)
    ///   100 → 0 是**放寬**(從有限變成無限)
    /// 單純的 `<=` 會把兩者都判成收緊。
    function test_zero_means_unlimited_so_the_comparison_inverts() public {
        _set(_rule(0, 0, 1 days, 0, 0)); // 無限額度

        // 0 → 100:收緊,允許
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 100);

        // 100 → 0:放寬,拒絕
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(0, 0, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 100, "unchanged");
    }

    function test_lowering_a_finite_limit_is_tightening() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 50);
        assertEq(acct.ruleOf(NODE, TOKEN).periodLimit, 500);
    }

    function test_raising_a_finite_limit_is_not_tightening() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(200, 1000, 1 days, 0, 0));
    }

    /// 直接關掉一定是收緊,不管其他欄位長什麼樣。
    function test_disabling_the_token_is_always_tightening() public {
        _set(_rule(100, 1000, 1 days, 9 * 60, 17 * 60));
        LeashStorage.TokenRule memory off = _rule(0, 0, 1 days, 0, 0);
        off.allowed = false;
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, off);
        assertFalse(acct.ruleOf(NODE, TOKEN).allowed);
    }

    // --- 🔴 跨午夜的時段子集 ---

    /// `StandardPolicy._inWindow` 的語意:`start == end` 全天;
    /// `start < end` 同日區間;`start > end` **跨午夜**。
    /// 所以「更嚴」不能只比數字大小。

    function test_all_day_to_a_finite_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 0, 0)); // 全天
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 9 * 60, 17 * 60));
        assertEq(acct.ruleOf(NODE, TOKEN).windowStart, 9 * 60);
    }

    function test_a_finite_window_to_all_day_is_widening() public {
        _set(_rule(100, 0, 1 days, 9 * 60, 17 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0));
    }

    /// 22:00–06:00 ⊂ 21:00–07:00 —— 兩者都跨午夜,新的比較窄。
    function test_a_narrower_overnight_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 21 * 60, 7 * 60));
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
        assertEq(acct.ruleOf(NODE, TOKEN).windowStart, 22 * 60);
    }

    /// 反過來就是放寬。
    function test_a_wider_overnight_window_is_widening() public {
        _set(_rule(100, 0, 1 days, 22 * 60, 6 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 21 * 60, 7 * 60));
    }

    /// 同日區間換成跨午夜:分鐘集合不是子集,拒絕。
    function test_switching_a_daytime_window_to_overnight_is_widening() public {
        _set(_rule(100, 0, 1 days, 9 * 60, 17 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
    }

    // --- 🔴 M5 迴歸:改 period 不能讓預算復活 ---

    /// **初版只讓 `tightenRule` 凍結 `period`,那修了一半。**
    /// 如果 `spent` 的 key 只是 `timestamp / period`,那麼一改 `period`
    /// 桶的編號就變了,累計讀出來是 0 —— **「調整週期」變成一個免費的清帳鈕。**
    ///
    /// 修法是 `epoch`:只增不減,`spent` 以它為 key 的高位。
    function test_tighten_cannot_touch_period_or_epoch() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 1000, 7 days, 0, 0));

        LeashStorage.TokenRule memory bumped = _rule(100, 1000, 1 days, 0, 0);
        bumped.epoch = 1;
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, bumped);
    }

    /// `setRule` 改 `period` 時 `epoch` 必須遞增 —— 換週期意味著換一套帳,
    /// 而 `epoch` 只增不減,所以**清帳這件事永遠需要一份 attestation**。
    function test_setRule_bumps_epoch_only_when_period_changes() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0);

        _set(_rule(200, 2000, 1 days, 0, 0)); // period 沒變
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0, "no bump");

        _set(_rule(200, 2000, 7 days, 0, 0)); // period 變了
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 1, "bumped");
    }

    /// `period == 0` 是一個要處理的邊界:`spent` 的 key 是
    /// `timestamp / period`,直接除會 panic。
    /// 語意定義為「所有花費累計進一個永不重置的桶」= 終身額度。
    function test_period_zero_is_a_lifetime_budget_not_a_panic() public {
        _set(_rule(100, 1000, 0, 0, 0));
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0, "no division by zero");

        // 時間推很久,桶仍然是同一個
        vm.warp(block.timestamp + 3650 days);
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0);
    }

    // --- 事件與收款人 ---

    /// `setRule` 對應到兩個凍結事件,要講明何時發哪一個。
    function test_setRule_emits_token_allowed_when_first_enabled() public {
        vm.expectEmit(true, true, false, false);
        emit LeashAccount.TokenAllowed(NODE, TOKEN, bytes32(0));
        _set(_rule(100, 1000, 1 days, 0, 0));
    }

    function test_payee_can_be_allowed_and_removed() public {
        vm.startPrank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, ++nonce, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));

        acct.removePayee(NODE, TOKEN, PAYEE); // 縮權,不需背書
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
        vm.stopPrank();
    }

    /// `allowPayee` 是擴權路徑,凍結事件裡對應的是 `PayeeAllowed`。
    /// 少了這個 emit,subgraph 看不到白名單一個收款人這件事 ——
    /// 那是擴權稽核軌跡的另一半(另一半是 `setRule` 的 `TokenAllowed`/`LimitRaised`)。
    function test_allow_payee_emits_payee_allowed() public {
        vm.expectEmit(true, true, false, true);
        emit LeashAccount.PayeeAllowed(NODE, PAYEE, keccak256(ATT));
        vm.prank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, ++nonce, ATT);
    }

    /// `LimitRaised` 是「放寬」事件,不該在什麼都沒變的 setRule 上發。
    /// 用 `_isTighter`(而不是另外湊一條「periodLimit 有沒有變大」)當判準,
    /// 逐位元組相同的重放應該被判為「仍然一樣嚴」,不算變寬。
    function test_setRule_emits_no_limit_raised_when_nothing_changes() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.recordLogs();
        _set(_rule(100, 1000, 1 days, 0, 0)); // 內容逐位元組相同
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 limitRaisedTopic =
            keccak256("LimitRaised(bytes32,address,uint256,uint256,uint64,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != limitRaisedTopic, "no-op setRule must not emit LimitRaised"
            );
        }
    }

    /// 迴歸測試:一旦 `epoch` 曾經被撞過(period 換過一次),之後逐位元組相同
    /// 的重放呼叫仍然不該發 `LimitRaised`。`rule.epoch`(這裡是 `_rule` helper
    /// 固定填的 0)對不上目前非零的 `cur.epoch`,不能被拿來當「有沒有變寬」的
    /// 依據 —— 那是 `RULE_TYPEHASH` 沒保護、`setRule` 本來就不採信的欄位。
    function test_setRule_no_limit_raised_after_epoch_has_advanced() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        _set(_rule(100, 1000, 7 days, 0, 0)); // period 換了,epoch 撞到 1
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 1);

        vm.recordLogs();
        _set(_rule(100, 1000, 7 days, 0, 0)); // 逐位元組相同的重放(epoch 傳的還是 0)
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 limitRaisedTopic =
            keccak256("LimitRaised(bytes32,address,uint256,uint256,uint64,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != limitRaisedTopic, "epoch drift must not fake a widen");
        }
    }

    // --- 兩個都要 ---

    function test_expansion_needs_both_self_and_attestation() public {
        // 不是 self
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(address(0xBAD));
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 1, ATT);

        // 是 self,但 attestation 重放
        vm.startPrank(wallet);
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.expectRevert();
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.stopPrank();
    }

    /// 縮權**不需要** attestation,但仍然只有錢包自己能做。
    function test_reduction_needs_self_but_no_attestation() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(address(0xBAD));
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));

        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(50, 500, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 50);
    }
}
