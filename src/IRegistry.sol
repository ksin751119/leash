// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IERC1155Singleton —— ENSv2 用的 ERC-1155 變體
/// @notice 每個 token 的供給量恆為 1,所以「持有者」是一個位址而不是一個數量。
///         ENSv2 的名字就是這種 token:一個名字只有一個 owner,但仍然可以轉讓。
interface IERC1155Singleton {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title IRegistry —— ENSv2 的解析骨幹
/// @notice 一個完整的名字(`vendors.leash.eth`)是一條跨 registry 的鏈,
///         由 subregistry 指標串起來。解析就是沿著這條鏈走。
///
/// @dev 三個函式定義了整個 ENSv2 的解析協定:
///      - `getSubregistry(label)` —— 往下一層走
///      - `getResolver(label)` —— 停在這一層,拿記錄
///      - `getParent()` —— 往上回推(用來組出完整名字)
///
///      **這是我們自己照 ENSv2 規格寫的介面副本。** ENS 的合約還在 Immunefi 審計期
///      (2026-08-18 至 09-14),位址與程式碼都可能變動,所以不從他們的 repo 拉依賴。
///      selector 已對過 Sepolia 上實際部署的 `PermissionedRegistry`:
///      `getSubregistry(string)` = `0x35af6216`、`getResolver(string)` = `0xe4ae7d77`。
interface IRegistry is IERC1155Singleton {
    /// @notice 這個 label 底下掛的是哪一個 registry。`address(0)` = 沒有子樹。
    function getSubregistry(string calldata label) external view returns (IRegistry);

    /// @notice 這個 label 的 resolver。`address(0)` = 解不出任何記錄。
    function getResolver(string calldata label) external view returns (address);

    /// @notice 這個 registry 掛在誰底下、用什麼 label。
    function getParent() external view returns (IRegistry parent, string memory label);
}
