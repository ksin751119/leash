// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashLens } from "../src/LeashLens.sol";

contract Dummy {
    uint256 public x;
}

contract LeashLensTest is Test {
    LeashLens lens;
    uint256 pk = 0xA11CE;
    address alice;
    Dummy impl;

    function setUp() public {
        lens = new LeashLens();
        alice = vm.addr(pk);
        impl = new Dummy();
    }

    /// An undelegated EOA: its code is empty.
    function test_plain_eoa_is_not_leashed() public view {
        (bool leashed, address to) = lens.delegateOf(alice);
        assertFalse(leashed);
        assertEq(to, address(0));
    }

    /// After delegation the code is the 23 bytes `0xef0100 || address`.
    function test_delegated_eoa_reports_its_impl() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed, address to) = lens.delegateOf(alice);
        assertTrue(leashed);
        assertEq(to, address(impl));
    }

    /// An ordinary contract is not a 7702 delegation — its code length is not 23.
    function test_a_normal_contract_is_not_a_delegation() public view {
        (bool leashed, address to) = lens.delegateOf(address(impl));
        assertFalse(leashed, "a contract is not a delegation");
        assertEq(to, address(0));
    }

    /// **An EIP-7702 delegation change emits no log**, so a subgraph cannot index
    /// "the leash came off" — this lens is the only way to observe it (the frontend
    /// checks once on load, a monitoring script polls). This test proves it detects a
    /// delegation being removed.
    function test_detects_removal_of_the_delegation() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed,) = lens.delegateOf(alice);
        assertTrue(leashed);

        vm.signAndAttachDelegation(address(0), pk); // revoke the delegation
        (bool after_, address to) = lens.delegateOf(alice);
        assertFalse(after_, "leash is gone");
        assertEq(to, address(0));
    }
}
