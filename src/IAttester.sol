// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAttester — the abstraction for "a real human vouched for this"
/// @notice Only **widening** passes through this gate (approving a new policy, raising a
///         limit, allow-listing a payee). Reduction never needs it — when something has
///         gone wrong, hunting for your phone is the last thing you want to do.
///
/// @dev This interface exists because of **schedule risk**, not for the elegance: when
///      World's approval would land was never in our hands, so the contracts have only
///      ever depended on the interface and the implementation could arrive late.
///      Selfie Check was verified end-to-end on 2026-09-07, so `WorldAttester` is
///      buildable — but the interface still earns its keep: with a mock, a demo run does
///      not cost a face scan every time.
interface IAttester {
    /// @param digest Hash of the thing being vouched for (an EIP-712 typed data hash)
    /// @param attestation The vouching data. `WorldAttester` carries a signature made by
    ///        the backend's signer key; `MockAttester` ignores it.
    /// @return ok Whether it passes. **An implementation must not revert to signal
    ///         failure** — the caller has to be able to tell "did not pass" apart from
    ///         "this attester is broken".
    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool ok);

    /// @notice Human-readable identifier; shown in the frontend and in the demo
    function describe() external pure returns (string memory);
}
