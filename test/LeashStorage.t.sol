// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashStorage } from "../src/LeashStorage.sol";

/// @dev Exposes the library's internal constants so they can be tested.
contract StorageProbe {
    function slot() external pure returns (bytes32) {
        return LeashStorage.SLOT;
    }

    /// Write a value, then read it back from that slot with `vm.load` — proving it
    /// really lives there.
    function setPaused(bool v) external {
        LeashStorage.layout().paused = v;
    }

    function paused() external view returns (bool) {
        return LeashStorage.layout().paused;
    }
}

contract LeashStorageTest is Test {
    StorageProbe probe;

    function setUp() public {
        probe = new StorageProbe();
    }

    /// Get this constant wrong and every piece of state lands in a different slot —
    /// with no error message of any kind. This test recomputes the ERC-7201 formula
    /// rather than copying the constant.
    function test_slot_matches_the_erc7201_formula() public view {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("leash.account.v1")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(probe.slot(), expected, "ERC-7201 derivation");
        assertEq(
            probe.slot(),
            0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800,
            "the value recorded in the spec"
        );
    }

    /// ERC-7201 requires the low 8 bits to be zero (reserved for future use, and to
    /// avoid colliding with the slot arithmetic of short arrays).
    function test_slot_is_byte_aligned() public view {
        assertEq(uint256(probe.slot()) & 0xff, 0);
    }

    /// Proves the state actually lands at that slot, not merely that the constant is right.
    function test_state_actually_lives_at_that_slot() public {
        probe.setPaused(true);
        assertTrue(probe.paused());

        // `paused` is a bool field in the struct. Five mappings precede it, one slot
        // each, so `paused` lands at SLOT + 5 (see the field order in LeashStorage).
        bytes32 raw = vm.load(address(probe), bytes32(uint256(probe.slot()) + 5));
        assertEq(uint256(raw) & 0xff, 1, "paused is the low byte of SLOT+5");
    }
}
