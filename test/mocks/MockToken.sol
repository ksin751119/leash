// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 最小 ERC-20,只夠讓 `spend()` 的搬錢邏輯有真的餘額可以搬。
///      `transfer` 回傳恰好 32 bytes 的 `true` —— `spend` 的嚴格回傳檢查
///      要吃得下一顆正常的代幣,不能只在 `BadTokens.sol` 那些壞代幣上測試。
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
