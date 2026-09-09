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

    // --- 🔴 the inverted comparison of `0 = unlimited` ---

    /// **This is the easiest line in the codebase to get backwards.** `0` means
    /// "unlimited", so:
    ///   0 → 100 **tightens** (unlimited becomes finite)
    ///   100 → 0 **widens** (finite becomes unlimited)
    /// A plain `<=` would call both of them tightenings.
    function test_zero_means_unlimited_so_the_comparison_inverts() public {
        _set(_rule(0, 0, 1 days, 0, 0)); // unlimited

        // 0 → 100: tightens, allowed
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).txLimit, 100);

        // 100 → 0: widens, refused
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

    /// Switching it off is always a tightening, whatever the other fields say.
    function test_disabling_the_token_is_always_tightening() public {
        _set(_rule(100, 1000, 1 days, 9 * 60, 17 * 60));
        LeashStorage.TokenRule memory off = _rule(0, 0, 1 days, 0, 0);
        off.allowed = false;
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, off);
        assertFalse(acct.ruleOf(NODE, TOKEN).allowed);
    }

    // --- 🔴 overnight window subsets ---

    /// The semantics of `StandardPolicy._inWindow`: `start == end` is all day,
    /// `start < end` is a same-day interval, `start > end` **crosses midnight**.
    /// So "stricter" cannot be decided by comparing magnitudes.

    function test_all_day_to_a_finite_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 0, 0)); // all day
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

    /// 22:00-06:00 ⊂ 21:00-07:00 — both cross midnight, and the new one is narrower.
    function test_a_narrower_overnight_window_is_tightening() public {
        _set(_rule(100, 0, 1 days, 21 * 60, 7 * 60));
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
        assertEq(acct.ruleOf(NODE, TOKEN).windowStart, 22 * 60);
    }

    /// The other way round is a widening.
    function test_a_wider_overnight_window_is_widening() public {
        _set(_rule(100, 0, 1 days, 22 * 60, 6 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 21 * 60, 7 * 60));
    }

    /// A same-day interval swapped for one crossing midnight: the minute set is not a
    /// subset, so it is refused.
    function test_switching_a_daytime_window_to_overnight_is_widening() public {
        _set(_rule(100, 0, 1 days, 9 * 60, 17 * 60));
        vm.expectRevert(LeashAccount.NotTighter.selector);
        vm.prank(wallet);
        acct.tightenRule(NODE, TOKEN, _rule(100, 0, 1 days, 22 * 60, 6 * 60));
    }

    // --- 🔴 M5 regression: changing `period` must not resurrect the budget ---

    /// **The first version only froze `period` in `tightenRule`, which was half a fix.**
    /// If `spent` is keyed on nothing but `timestamp / period`, then changing `period`
    /// changes the bucket number and the running total reads back as 0 — **"adjust the
    /// period" becomes a free wipe-the-ledger button.**
    ///
    /// The fix is `epoch`: monotonically increasing, occupying the high bits of the
    /// `spent` key.
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

    /// `epoch` must increment when `setRule` changes `period` — a new period means a new
    /// ledger, and since `epoch` never decreases, **wiping the ledger always costs an
    /// attestation**.
    function test_setRule_bumps_epoch_only_when_period_changes() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0);

        _set(_rule(200, 2000, 1 days, 0, 0)); // period unchanged
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 0, "no bump");

        _set(_rule(200, 2000, 7 days, 0, 0)); // period changed
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 1, "bumped");
    }

    /// `period == 0` is an edge case that has to be handled: the `spent` key is
    /// `timestamp / period`, and dividing straight through would panic.
    /// The semantics are defined as "every spend accumulates into one bucket that never
    /// resets" — a lifetime allowance.
    function test_period_zero_is_a_lifetime_budget_not_a_panic() public {
        _set(_rule(100, 1000, 0, 0, 0));
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0, "no division by zero");

        // Push time far forward; the bucket is still the same one
        vm.warp(block.timestamp + 3650 days);
        assertEq(acct.spentInCurrentPeriod(NODE, TOKEN), 0);
    }

    // --- events and payees ---

    /// `setRule` maps onto two frozen events, and which fires when must be stated.
    function test_setRule_emits_token_allowed_when_first_enabled() public {
        vm.expectEmit(true, true, false, false);
        emit LeashAccount.TokenAllowed(NODE, TOKEN, bytes32(0));
        _set(_rule(100, 1000, 1 days, 0, 0));
    }

    function test_payee_can_be_allowed_and_removed() public {
        vm.startPrank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, ++nonce, ATT);
        assertTrue(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));

        acct.removePayee(NODE, TOKEN, PAYEE); // a reduction, no attestation
        assertFalse(acct.isPayeeAllowed(NODE, TOKEN, PAYEE));
        vm.stopPrank();
    }

    /// `allowPayee` is a widening path, and `PayeeAllowed` is its frozen event.
    /// Without that emit the subgraph cannot see a payee being allow-listed — which is one
    /// half of the widening audit trail (the other half being `setRule`'s `TokenAllowed` /
    /// `LimitRaised`).
    function test_allow_payee_emits_payee_allowed() public {
        vm.expectEmit(true, true, false, true);
        emit LeashAccount.PayeeAllowed(NODE, PAYEE, keccak256(ATT));
        vm.prank(wallet);
        acct.allowPayee(NODE, TOKEN, PAYEE, ++nonce, ATT);
    }

    /// `LimitRaised` is a loosening event and must not fire on a setRule that changed
    /// nothing. Using `_isTighter` as the criterion — rather than an ad-hoc "did
    /// periodLimit grow?" — means a byte-identical replay reads as "still just as strict"
    /// and not as a widening.
    function test_setRule_emits_no_limit_raised_when_nothing_changes() public {
        _set(_rule(100, 1000, 1 days, 0, 0));

        vm.recordLogs();
        _set(_rule(100, 1000, 1 days, 0, 0)); // byte-identical content
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 limitRaisedTopic =
            keccak256("LimitRaised(bytes32,address,uint256,uint256,uint64,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != limitRaisedTopic, "no-op setRule must not emit LimitRaised"
            );
        }
    }

    /// Regression test: once `epoch` has been bumped (period changed once), a later
    /// byte-identical replay must still not emit `LimitRaised`. `rule.epoch` — here always
    /// 0, as the `_rule` helper fills it — will not match the now-nonzero `cur.epoch`, and
    /// must not be used to decide whether anything widened: it is a field
    /// `RULE_TYPEHASH` does not cover and `setRule` never trusts.
    function test_setRule_no_limit_raised_after_epoch_has_advanced() public {
        _set(_rule(100, 1000, 1 days, 0, 0));
        _set(_rule(100, 1000, 7 days, 0, 0)); // period changed, so epoch bumps to 1
        assertEq(acct.ruleOf(NODE, TOKEN).epoch, 1);

        vm.recordLogs();
        _set(_rule(100, 1000, 7 days, 0, 0)); // byte-identical replay (epoch still passed as 0)
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 limitRaisedTopic =
            keccak256("LimitRaised(bytes32,address,uint256,uint256,uint64,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != limitRaisedTopic, "epoch drift must not fake a widen");
        }
    }

    // --- both conditions required ---

    function test_expansion_needs_both_self_and_attestation() public {
        // not self
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(address(0xBAD));
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 1, ATT);

        // self, but the attestation is a replay
        vm.startPrank(wallet);
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.expectRevert();
        acct.setRule(NODE, TOKEN, _rule(100, 0, 1 days, 0, 0), 99, ATT);
        vm.stopPrank();
    }

    /// A reduction needs **no** attestation, but is still the wallet's alone to do.
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
