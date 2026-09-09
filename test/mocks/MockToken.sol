// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev A minimal ERC-20 — just enough that `spend()`'s money-moving logic has a real
///      balance to move. `transfer` returns exactly 32 bytes of `true`: `spend`'s strict
///      return check has to accept a well-behaved token, not only be exercised against
///      the broken ones in `BadTokens.sol`.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
