// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { IPolicy, SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

/// Costs more than `PolicySet.MEMBER_GAS` (60,000) to run to completion, but nowhere near a
/// test frame's own gas budget. Exists only to pin `MEMBER_GAS`: with the cap on `_ask`'s
/// `staticcall`, this member runs out of gas mid-loop and is reported `POLICY_FAILED`; strip
/// `{ gas: MEMBER_GAS }` from `PolicySet._ask` and the same member is forwarded (effectively)
/// unlimited gas, runs to completion, and returns `OK`.
contract GasHogPolicy is IPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        bytes32 h = bytes32(uint256(0));
        for (uint256 i = 0; i < 2000; i++) {
            h = keccak256(abi.encodePacked(h, i));
        }
        // `h` is read so the loop cannot be optimized away; it is never actually zero.
        return h == bytes32(0) ? Reason.POLICY_FAILED : Reason.OK;
    }
    function describe() external pure returns (string memory) { return "GasHogPolicy"; }
}

/// The composition the demo actually runs, pinned so that a change to any of the three
/// contracts that would alter what a judge sees on screen fails here first.
contract PolicySetDemoTest is Test {
    PolicySet set;

    address constant BEEF = address(0xBEEF); // allow-listed
    address constant CAFE = address(0xCAFE0); // not allow-listed, 5 USDC
    address constant FOOD = address(0xF00D); // not allow-listed, 0.50 USDC
    address constant USDC = address(0x768F);

    uint256 constant CAP = 1e6; // 1 USDC
    uint256 constant PERIOD_LIMIT = 50e6; // 50 USDC, as tightened on chain 2026-09-11
    uint256 constant SPENT = 5e6; // 5 USDC already spent this period

    /// `LeashAccount.POLICY_GAS` — the ceiling the account puts on this whole call.
    uint256 constant POLICY_GAS = 200_000;

    function setUp() public {
        address[][] memory clauses = new address[][](2);
        address[] memory micro = new address[](1);
        micro[0] = address(new MicroPaymentPolicy(CAP));
        address[] memory standard = new address[](1);
        standard[0] = address(new StandardPolicy());
        clauses[0] = micro;
        clauses[1] = standard;
        set = new PolicySet(clauses);
    }

    function _intent(address payee, uint256 amount, bool payeeAllowed)
        internal pure returns (SpendContext memory c)
    {
        c = SpendContext({
            agent: address(0xA6E17),
            payee: payee,
            token: USDC,
            amount: amount,
            tokenAllowed: true,
            payeeAllowed: payeeAllowed,
            txLimit: 500e6,
            periodLimit: PERIOD_LIMIT,
            spentSoFar: SPENT,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    /// Over the micro cap, so clause 1 fails; allow-listed, so clause 2 carries it.
    function test_retainer_passes_through_the_standard_clause() public view {
        assertEq(set.check(_intent(BEEF, 5e6, true)), Reason.OK);
    }

    /// Over the cap AND not allow-listed. The reported reason must be 6, because that is
    /// what the demo page's widen button keys on — reporting clause 1's 7 would leave the
    /// button disabled and the face-scan beat dead.
    function test_newvendor_is_blocked_with_exactly_reason_6() public view {
        assertEq(set.check(_intent(CAFE, 5e6, false)), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The whole argument for OR: same unknown payee situation, allowed because it is small.
    function test_apitopup_passes_through_the_micro_clause_with_no_human() public view {
        assertEq(set.check(_intent(FOOD, 5e5, false)), Reason.OK);
    }

    /// Two payments to strangers, one refused and one allowed, and the only difference is
    /// the size. If this ever stops holding, the demo has lost its point.
    function test_the_only_difference_between_the_two_strangers_is_the_amount() public view {
        SpendContext memory big = _intent(CAFE, 5e6, false);
        SpendContext memory small = _intent(CAFE, 5e5, false); // same payee, smaller
        assertEq(set.check(big), Reason.PAYEE_NOT_ALLOWED);
        assertEq(set.check(small), Reason.OK);
    }

    /// The exception must not be able to swallow the rule.
    function test_a_micro_payment_over_the_period_budget_is_still_refused() public view {
        SpendContext memory c = _intent(FOOD, 5e5, false);
        c.spentSoFar = PERIOD_LIMIT; // nothing left
        // clause 1 fails on the budget, clause 2 fails on the payee — last clause reported
        assertEq(set.check(c), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The account gives this call 200,000 gas and treats anything else as reason 12. Two
    /// members plus the loop must fit, with room to spare.
    ///
    /// Not `view`: `emit`ting the measured gas is a state-changing operation. `set.check()`
    /// itself stays `view` — nothing about what is measured changes.
    function test_it_fits_inside_the_account_s_gas_cap() public {
        SpendContext memory c = _intent(CAFE, 5e6, false);
        uint256 before = gasleft();
        set.check(c);
        uint256 used = before - gasleft();
        emit log_named_uint("PolicySet.check gas (worst case: both clauses evaluated)", used);
        assertLt(used, POLICY_GAS, "over the account's cap");
        assertLt(used, POLICY_GAS / 2, "less than half the cap, so there is headroom");
    }

    /// `PolicySet.MEMBER_GAS` is enforced by nothing else in the suite: deleting
    /// `{ gas: MEMBER_GAS }` from `PolicySet._ask` leaves every other test green, because the
    /// mocks that misbehave either revert, return the wrong shape, or burn all available gas
    /// outright — none of them distinguish "capped at 60,000" from "uncapped". `GasHogPolicy`
    /// does: it costs more than `MEMBER_GAS` but far less than this test's own budget, so it
    /// is `POLICY_FAILED` with the cap in place and would be `OK` without it.
    function test_member_gas_cap_makes_a_costly_member_fail_closed() public {
        address[] memory hog = new address[](1);
        hog[0] = address(new GasHogPolicy());
        address[][] memory clauses = new address[][](1);
        clauses[0] = hog;
        PolicySet hogSet = new PolicySet(clauses);
        assertEq(hogSet.check(_intent(FOOD, 5e5, false)), Reason.POLICY_FAILED);
    }
}
