// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashLens — is the leash still on?
/// @notice **An EIP-7702 delegation change emits no log at all.** So "is this wallet
///         still governed by a policy?" cannot be indexed by a subgraph; it can only be
///         polled with `eth_call` — once when the frontend loads, periodically from a
///         monitoring script. This contract is that query.
///
/// @dev `PLAN.md` originally specified `isLeashed(bytes32 node) → (bool, address)`,
///      walking ENS → wallet → delegate. **That direction does not exist** — ENS records
///      node → policy, there is no node → wallet reverse index, and building one means
///      another contract and another thing to keep in sync. So it asks by wallet address
///      instead.
contract LeashLens {
    /// @notice Reads `wallet`'s code and decides whether it is an EIP-7702 delegation.
    /// @return leashed Whether it is a delegation
    /// @return impl What it delegates to; `address(0)` when it is not a delegation
    ///
    /// @dev Delegated code is exactly the 23 bytes `0xef0100 || address` — a bijection,
    ///      which is why returning the address beats returning a codehash (the address
    ///      can go straight into the UI, whereas the codehash is just the keccak of those
    ///      23 bytes and carries identical information).
    function delegateOf(address wallet) external view returns (bool leashed, address impl) {
        if (wallet.code.length != 23) return (false, address(0));
        bytes memory c = wallet.code;
        if (uint8(c[0]) != 0xef || uint8(c[1]) != 0x01 || uint8(c[2]) != 0x00) {
            return (false, address(0));
        }
        // Skip the 3-byte prefix. `mload(add(c, 0x23))` reads bytes 3..35 of c;
        // shifting right by 96 bits leaves the high 20 bytes.
        assembly {
            impl := shr(96, mload(add(c, 0x23)))
        }
        return (true, impl);
    }
}
