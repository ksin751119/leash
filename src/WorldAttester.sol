// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ECDSA } from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import { IAttester } from "./IAttester.sol";

/// @title WorldAttester — "a live human authorised this", checked onchain
/// @notice Replaces `MockAttester` on `LeashAccount`'s widening paths. The backend verifies
///         a Selfie Check proof against World's v4 endpoint and only then signs; this
///         contract checks that signature.
///
/// @dev **What this proves onchain, stated exactly:** the RP signer authorised this precise
///      digest, before this deadline. It does **not** prove a human was present — that link
///      is World App performing Selfie Check, the v4 endpoint verifying the proof, and our
///      backend signing only afterwards. Only the first step is World's.
///
///      The proof's `signal` is the digest, so one face scan authorises exactly one
///      widening and an intercepted proof cannot be moved to another.
contract WorldAttester is IAttester {
    /// @notice The World RP signer. **`immutable`, with no setter.**
    /// @dev Identical to the C1 fix on `PolicyApprovals`: a mutable signer pointer hands
    ///      both locks to one key. Rotating the signer means deploying a new attester,
    ///      which is a visible onchain transaction — and the EIP-712 domain below binds
    ///      `verifyingContract`, so signatures do not carry across that redeployment.
    address public immutable SIGNER;

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant ATTESTATION_TYPEHASH =
        keccak256("LeashAttestation(bytes32 digest,uint64 deadline)");
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");

    error ZeroSigner();

    constructor(address signer_) {
        // No setter exists to recover from a zero signer: the list of things this attester
        // could ever approve would be empty forever. Better to fail at deploy time.
        if (signer_ == address(0)) revert ZeroSigner();
        SIGNER = signer_;
    }

    /// @inheritdoc IAttester
    /// @dev **This function must never revert**, and holding that is why it looks like this.
    ///      `attestation` is attacker-controlled, and OpenZeppelin's `ECDSA.recover` reverts
    ///      on a bad length, a malleable `s`, or a zero recovery — so `tryRecover`, which
    ///      returns an error enum, is mandatory rather than stylistic. The length is checked
    ///      before any slicing, and no externally-supplied bytes reach `abi.decode`. Same
    ///      discipline as `LeashAccount.resolvePolicy`.
    ///
    ///      Layout, 73 bytes: `deadline`(8) ‖ `r`(32) ‖ `s`(32) ‖ `v`(1). Packed rather than
    ///      `abi.encode(uint64, bytes)`, because that produces an offset/length header which
    ///      would itself have to be validated — the hop-three trap from `resolvePolicy`.
    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool) {
        if (attestation.length != 73) return false;

        uint64 deadline = uint64(bytes8(attestation[0:8]));
        if (block.timestamp > deadline) return false;

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(
            attestationHash(digest, deadline),
            uint8(attestation[72]),
            bytes32(attestation[8:40]),
            bytes32(attestation[40:72])
        );
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == SIGNER;
    }

    /// @notice What the backend signs, and the one value the JS side has to reproduce byte
    ///         for byte.
    /// @dev Exposed as a view because a mismatch between the two implementations has
    ///      exactly one symptom — "the signature does not verify" — and nothing that says
    ///      whether the encoding, the key, the deadline or `v` was at fault. `crosscheck.mjs`
    ///      compares against this.
    ///
    ///      Note that `deadline` is a `uint64` in the type but a full 32-byte word inside
    ///      `abi.encode`. The JS side must left-pad it.
    function attestationHash(bytes32 digest, uint64 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, digest, deadline));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev Recomputed every call rather than cached, matching `PolicyApprovals`,
    ///      `LeashRegistry` and `LeashAccount` — `block.chainid` changes after a chain split
    ///      and a cached value would then be wrong.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @inheritdoc IAttester
    function describe() external pure returns (string memory) {
        return "WorldAttester/1: ECDSA over EIP-712 by the World RP signer (rp_ef35d4e2d4f1a031). Onchain this proves the RP signer authorised this exact digest before its deadline; that a live human was present is enforced offchain by Selfie Check.";
    }
}
