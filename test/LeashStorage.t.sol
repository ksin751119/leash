// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashStorage } from "../src/LeashStorage.sol";

/// @dev 把 library 的 internal 常數暴露出來測。
contract StorageProbe {
    function slot() external pure returns (bytes32) {
        return LeashStorage.SLOT;
    }

    /// 寫一個值進去,再用 `vm.load` 從那個槽位讀回來 —— 證明它真的住在那裡。
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

    /// 這個常數算錯的話,所有狀態都跑到別的槽位 —— 而且不會有任何錯誤訊息。
    /// 測試在這裡重算一次 ERC-7201 的公式,不是抄常數。
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

    /// ERC-7201 要求低 8 bits 為 0(留給未來擴充,也避免與短陣列的槽位計算相撞)。
    function test_slot_is_byte_aligned() public view {
        assertEq(uint256(probe.slot()) & 0xff, 0);
    }

    /// 證明狀態真的落在那個槽位,不只是常數對。
    function test_state_actually_lives_at_that_slot() public {
        probe.setPaused(true);
        assertTrue(probe.paused());

        // `paused` 是 struct 裡的一個 bool 欄位。它前面有四個 mapping,
        // 每個 mapping 佔一個槽位,所以 paused 落在 SLOT + 5(見 LeashStorage 的欄位順序)。
        bytes32 raw = vm.load(address(probe), bytes32(uint256(probe.slot()) + 5));
        assertEq(uint256(raw) & 0xff, 1, "paused is the low byte of SLOT+5");
    }
}
