// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { IPolicy, SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";
import {
    AlwaysOK, AlwaysBlock, StatefulPolicy, RevertingPolicy,
    LongReturnPolicy, HugeReturnPolicy, GasBurnerPolicy
} from "./mocks/PolicyMocks.sol";

contract PolicySetTest is Test {
    AlwaysOK ok1;
    AlwaysOK ok2;
    AlwaysBlock blockPayee;   // 6
    AlwaysBlock blockTxLimit; // 7

    function setUp() public {
        ok1 = new AlwaysOK();
        ok2 = new AlwaysOK();
        blockPayee = new AlwaysBlock(Reason.PAYEE_NOT_ALLOWED);
        blockTxLimit = new AlwaysBlock(Reason.OVER_TX_LIMIT);
    }

    function _ctx() internal pure returns (SpendContext memory c) {
        c = SpendContext({
            agent: address(0xA6E17),
            payee: address(0xF00D),
            token: address(0x05DC),
            amount: 5e5,
            tokenAllowed: true,
            payeeAllowed: false,
            txLimit: 0,
            periodLimit: 50e6,
            spentSoFar: 5e6,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    function _one(address a) internal pure returns (address[] memory m) {
        m = new address[](1);
        m[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory m) {
        m = new address[](2);
        m[0] = a;
        m[1] = b;
    }

    function _set(address[][] memory clauses) internal returns (PolicySet) {
        return new PolicySet(clauses);
    }

    function _clauses1(address[] memory a) internal pure returns (address[][] memory c) {
        c = new address[][](1);
        c[0] = a;
    }

    function _clauses2(address[] memory a, address[] memory b)
        internal pure returns (address[][] memory c)
    {
        c = new address[][](2);
        c[0] = a;
        c[1] = b;
    }

    // --- AND inside a clause ---

    function test_a_clause_of_two_passes_only_when_both_pass() public {
        PolicySet both = _set(_clauses1(_two(address(ok1), address(ok2))));
        assertEq(both.check(_ctx()), Reason.OK);

        PolicySet oneFails = _set(_clauses1(_two(address(ok1), address(blockPayee))));
        assertEq(oneFails.check(_ctx()), Reason.PAYEE_NOT_ALLOWED);
    }

    function test_a_clause_reports_its_first_failing_member() public {
        PolicySet s = _set(_clauses1(_two(address(blockTxLimit), address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.OVER_TX_LIMIT);
    }

    // --- OR between clauses ---

    function test_a_later_clause_rescues_an_earlier_failure() public {
        PolicySet s = _set(_clauses2(_one(address(blockPayee)), _one(address(ok1))));
        assertEq(s.check(_ctx()), Reason.OK);
    }

    function test_a_passing_first_clause_is_enough() public {
        PolicySet s = _set(_clauses2(_one(address(ok1)), _one(address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.OK);
    }

    /// The decision that keeps the demo working: the last clause is the general rule, and
    /// its reason is the one an operator can act on. Reporting the first clause's reason
    /// would tell an agent "over the cap" when the fix is "get this payee allow-listed".
    function test_when_nothing_passes_the_last_clauses_reason_is_reported() public {
        PolicySet s = _set(_clauses2(_one(address(blockTxLimit)), _one(address(blockPayee))));
        assertEq(s.check(_ctx()), Reason.PAYEE_NOT_ALLOWED);

        PolicySet reversed = _set(_clauses2(_one(address(blockPayee)), _one(address(blockTxLimit))));
        assertEq(reversed.check(_ctx()), Reason.OVER_TX_LIMIT);
    }

    // --- a member that misbehaves ---

    /// The guarantee the whole design rests on: a member cannot write, because it is reached
    /// by `staticcall` and the write reverts.
    function test_a_member_that_writes_storage_cannot_be_a_member() public {
        StatefulPolicy stateful = new StatefulPolicy();
        PolicySet s = _set(_clauses1(_one(address(stateful))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
        assertEq(stateful.seen(), 0, "the write must not have landed");
    }

    function test_a_reverting_member_fails_the_whole_set() public {
        PolicySet s = _set(_clauses2(_one(address(new RevertingPolicy())), _one(address(ok1))));
        // Not rescued by the second clause: a broken member is reported, not routed around.
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    function test_a_member_returning_the_wrong_length_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(new LongReturnPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    /// 256 truncated to a `uint8` is 0, which is `Reason.OK`, which pays.
    function test_a_member_returning_256_does_not_truncate_into_OK() public {
        PolicySet s = _set(_clauses1(_one(address(new HugeReturnPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    /// A `staticcall` to an address with no code SUCCEEDS and returns zero bytes. Without
    /// the length check that reads as `OK` and the payment goes through.
    function test_a_member_with_no_code_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(0xDEAD))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    function test_a_member_that_burns_all_its_gas_fails_closed() public {
        PolicySet s = _set(_clauses1(_one(address(new GasBurnerPolicy()))));
        assertEq(s.check(_ctx()), Reason.POLICY_FAILED);
    }

    // --- the constructor refuses a set that would allow everything ---

    function test_an_empty_clause_list_is_refused() public {
        address[][] memory none = new address[][](0);
        vm.expectRevert(PolicySet.EmptySet.selector);
        new PolicySet(none);
    }

    function test_an_empty_clause_is_refused() public {
        address[][] memory c = new address[][](2);
        c[0] = _one(address(ok1));
        c[1] = new address[](0);
        vm.expectRevert(PolicySet.EmptyClause.selector);
        new PolicySet(c);
    }

    function test_a_zero_member_is_refused() public {
        vm.expectRevert(PolicySet.ZeroMember.selector);
        new PolicySet(_clauses1(_one(address(0))));
    }

    // --- shape is readable and fixed ---

    function test_the_shape_is_readable() public {
        PolicySet s = _set(_clauses2(_two(address(ok1), address(ok2)), _one(address(blockPayee))));
        assertEq(s.clauseCount(), 2);
        assertEq(s.memberCount(), 3);
        assertEq(s.memberAt(0), address(ok1));
        assertEq(s.memberAt(2), address(blockPayee));
    }
}
