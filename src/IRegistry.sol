// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IERC1155Singleton — the ERC-1155 variant ENSv2 uses
/// @notice Every token has a supply of exactly 1, so "holder" is one address rather than
///         a quantity. ENSv2 names are tokens of this kind: a name has a single owner,
///         but it can still be transferred.
interface IERC1155Singleton {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title IRegistry — the ENSv2 resolution backbone
/// @notice A full name (`vendors.leash.eth`) is a chain across registries, strung
///         together by subregistry pointers. Resolving is walking that chain.
///
/// @dev Three functions define the whole of ENSv2 resolution:
///      - `getSubregistry(label)` — descend one level
///      - `getResolver(label)` — stop here and fetch records
///      - `getParent()` — climb back up (used to reassemble the full name)
///
///      **This is our own copy of the interface, written against the ENSv2 spec.** ENS's
///      contracts are still in their Immunefi audit window (2026-08-18 to 09-14), so both
///      addresses and code may change; we deliberately do not depend on their repo.
///      The selectors were checked against the `PermissionedRegistry` actually deployed
///      on Sepolia: `getSubregistry(string)` = `0x35af6216`,
///      `getResolver(string)` = `0xe4ae7d77`.
interface IRegistry is IERC1155Singleton {
    /// @notice Which registry sits under this label. `address(0)` = no subtree.
    function getSubregistry(string calldata label) external view returns (IRegistry);

    /// @notice The resolver for this label. `address(0)` = no records resolvable.
    function getResolver(string calldata label) external view returns (address);

    /// @notice Who this registry hangs under, and under what label.
    function getParent() external view returns (IRegistry parent, string memory label);
}
