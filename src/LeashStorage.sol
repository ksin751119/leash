// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashStorage — the per-EOA state layout for `LeashAccount`
/// @notice **This library exists because of a risk specific to EIP-7702.**
///
///         Delegated code executes against the **EOA's own storage**. If that EOA later
///         redelegates to **a different impl with a different layout**, the old data gets
///         reinterpreted under the new meaning — the kind of disaster where a budget is
///         read back as an admin address.
///
///         The fix is an ERC-7201 namespaced slot: the whole state goes into one struct,
///         parked at the slot derived from `keccak256("leash.account.v1")`. **The version
///         lives inside the string** — change the layout, change the string, and the old
///         slot can never be misread.
library LeashStorage {
    /// @dev One agent's binding. `node` and `label` are written together in `bindAgent`,
    ///      so a caller never gets the chance to submit an inconsistent pair — that is an
    ///      invariant established at bind time.
    struct AgentBinding {
        bytes32 node; // namehash("<label>.leash.eth"), for reading resolver records
        string label; // "vendors", for LeashRegistry.getResolver(label)
        bool revoked;
    }

    /// @dev The rule for one (node, token). **Five tunable fields** plus a monotonically
    ///      increasing epoch.
    struct TokenRule {
        bool allowed;
        uint256 txLimit; // 0 = unlimited
        uint256 periodLimit; // 0 = unlimited
        uint64 period; // period length in seconds. 0 = no period
        uint16 windowStart; // minute of the day, UTC
        uint16 windowEnd; // start == end means all day
        uint32 epoch; // **never decreases.** Any change to `period` must bump it by 1
    }

    /// @custom:storage-location erc7201:leash.account.v1
    /// @dev **Do not reorder these fields.** `test_state_actually_lives_at_that_slot`
    ///      relies on `paused` sitting at SLOT+5 (the five mappings above take one slot
    ///      each).
    struct AccountStorage {
        mapping(address agent => AgentBinding) bindings; // SLOT + 0
        mapping(bytes32 node => mapping(address token => TokenRule)) rules; // SLOT + 1
        mapping(bytes32 node => mapping(address token => mapping(address payee => bool))) payees; // +2
        mapping(bytes32 node => mapping(address token => mapping(uint256 bucket => uint256))) spent; // +3
        mapping(bytes32 digest => bool) attestationUsed; // SLOT + 4
        bool paused; // SLOT + 5
        bool entered; // SLOT + 5 (shares the slot with `paused`, one byte each)
        bool leashedEmitted; // SLOT + 5 - `Leashed` fires once; see LeashAccount.bindAgent
    }

    /// @dev ERC-7201: `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff`.
    ///      The resulting value is pinned by `test_slot_matches_the_erc7201_formula`.
    bytes32 internal constant SLOT =
        0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800;

    function layout() internal pure returns (AccountStorage storage $) {
        bytes32 s = SLOT;
        assembly {
            $.slot := s
        }
    }
}
