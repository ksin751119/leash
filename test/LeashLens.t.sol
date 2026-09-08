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

    /// 沒委派的 EOA:code 是空的。
    function test_plain_eoa_is_not_leashed() public view {
        (bool leashed, address to) = lens.delegateOf(alice);
        assertFalse(leashed);
        assertEq(to, address(0));
    }

    /// 委派之後 code 是 23 bytes 的 `0xef0100 || address`。
    function test_delegated_eoa_reports_its_impl() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed, address to) = lens.delegateOf(alice);
        assertTrue(leashed);
        assertEq(to, address(impl));
    }

    /// 一般合約不是 7702 委派 —— code 長度不是 23。
    function test_a_normal_contract_is_not_a_delegation() public view {
        (bool leashed, address to) = lens.delegateOf(address(impl));
        assertFalse(leashed, "a contract is not a delegation");
        assertEq(to, address(0));
    }

    /// **EIP-7702 的委派變更不發任何 log**,所以 subgraph 索引不到「拆掉韁繩」——
    /// 這個 lens 就是那件事唯一的觀測手段(前端進頁面查一次,監控腳本定期查)。
    /// 這條測試證明它偵測得到委派被移除。
    function test_detects_removal_of_the_delegation() public {
        vm.signAndAttachDelegation(address(impl), pk);
        (bool leashed,) = lens.delegateOf(alice);
        assertTrue(leashed);

        vm.signAndAttachDelegation(address(0), pk); // 撤銷委派
        (bool after_, address to) = lens.delegateOf(alice);
        assertFalse(after_, "leash is gone");
        assertEq(to, address(0));
    }
}
