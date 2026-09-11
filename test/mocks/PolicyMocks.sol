// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "../../src/IPolicy.sol";
import { Reason } from "../../src/Reason.sol";

/// Always allows.
contract AlwaysOK is IPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        return Reason.OK;
    }
    function describe() external pure returns (string memory) { return "AlwaysOK"; }
}

/// Always blocks with the code it was constructed with.
contract AlwaysBlock is IPolicy {
    uint8 public immutable CODE;
    constructor(uint8 code_) { CODE = code_; }
    function check(SpendContext calldata) external view returns (uint8) { return CODE; }
    function describe() external pure returns (string memory) { return "AlwaysBlock"; }
}

/// Writes storage on every call. Under `staticcall` the write reverts, which is exactly what
/// `PolicySet` relies on to make "a member cannot have side effects" a property of the EVM
/// rather than a promise in a comment.
contract StatefulPolicy is IPolicy {
    uint256 public seen;
    function check(SpendContext calldata) external returns (uint8) {
        seen++;
        return Reason.OK;
    }
    function describe() external pure returns (string memory) { return "StatefulPolicy"; }
}

/// Reverts.
contract RevertingPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        revert("nope");
    }
}

/// Returns 33 bytes: the right kind of answer at the wrong length.
contract LongReturnPolicy {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encodePacked(uint256(0), uint8(0));
    }
}

/// Returns 256 — one past what a `uint8` can hold. Truncating it would produce 0, which is
/// `Reason.OK`, and the payment would go through. This is the same shape of bug that a
/// mutation sweep found load-bearing in `LeashAccount._askPolicy`.
contract HugeReturnPolicy {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(256));
    }
}

/// Burns all the gas it is given: the INVALID opcode consumes whatever gas remains and halts
/// exceptionally, the same outcome `staticcall` would see from any other way of running the
/// budget out.
contract GasBurnerPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        assembly {
            invalid()
        }
    }
}
