// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Can be configured to return the wrong length and to revert — for exercising
///      fail-closed behaviour. ENS's contracts are still in their Immunefi audit window
///      and their behaviour may change; another contract breaking must not wedge the
///      account.
contract MockRegistry {
    address public sub;
    address public res;
    bool public shouldRevert;
    uint256 public padBytes; // when >0, return extra bytes so the length is wrong

    function set(address sub_, address res_) external {
        sub = sub_;
        res = res_;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function setPad(uint256 n) external {
        padBytes = n;
    }

    function getSubregistry(string calldata) external view returns (address) {
        if (shouldRevert) revert("boom");
        return sub;
    }

    function getResolver(string calldata) external view returns (address) {
        if (shouldRevert) revert("boom");
        if (padBytes > 0) {
            // Return something other than 32 bytes — emit an arbitrary length directly
            // in assembly
            assembly {
                let p := mload(0x40)
                mstore(p, 1)
                return(p, 8)
            }
        }
        return res;
    }
}

/// @dev Implements ENSIP-10 only, returning `bytes` (96 bytes of ABI encoding).
contract MockResolver {
    address public policy;
    bool public shouldRevert;

    function set(address p) external {
        policy = p;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function resolve(bytes calldata, bytes calldata) external view returns (bytes memory) {
        if (shouldRevert) revert("boom");
        return abi.encode(policy);
    }
}

/// @dev Returns the policy only when `name` matches exactly — for verifying the DNS
///      encoding.
contract NameCheckingResolver {
    bytes public expected;
    address public policy;

    constructor(bytes memory expected_, address policy_) {
        expected = expected_;
        policy = policy_;
    }

    function resolve(bytes calldata name, bytes calldata) external view returns (bytes memory) {
        require(keccak256(name) == keccak256(expected), "wrong dns name");
        return abi.encode(policy);
    }
}

/// @dev Returns exactly 96 bytes with a forged header — `offset` is not the legal `0x20`.
///      This exercises "checking the total length is not enough, the structure must be
///      checked too": a resolver returning the right length with garbage content must not
///      make `resolvePolicy` revert.
///
///      **The third word (where the payload sits) deliberately holds a real address, not
///      0.** `resolvePolicy` reads that word from a fixed position (ret+0x60); it does not
///      actually follow the `offset` field to relocate. So if the `offset == 0x20`
///      structure check were removed, the code would pass this real address through as a
///      legitimate policy. With 0 there instead, a missing check would coincidentally
///      still yield `address(0)` and the test could not detect the protection being
///      removed.
contract MalformedHeaderResolver {
    address public policy;

    constructor(address policy_) {
        policy = policy_;
    }

    function resolve(bytes calldata, bytes calldata) external view returns (bytes memory) {
        uint256 p_ = uint256(uint160(policy));
        assembly {
            let p := mload(0x40)
            mstore(p, 0x40) // forged offset; the legal value is 0x20
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), p_)
            return(p, 0x60)
        }
    }
}

/// @dev A legal header (both offset and length are `0x20`) but the payload's high 12
///      bytes are not zero. This exercises "you cannot let an assembly truncation smuggle
///      an address through": the padding must be validated, not silently truncated into
///      something that looks legitimate.
contract DirtyPaddingResolver {
    address public policy;

    constructor(address policy_) {
        policy = policy_;
    }

    function resolve(bytes calldata, bytes calldata) external view returns (bytes memory) {
        uint256 dirty = (uint256(1) << 160) | uint256(uint160(policy));
        assembly {
            let p := mload(0x40)
            mstore(p, 0x20)
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), dirty)
            return(p, 0x60)
        }
    }
}

/// @dev getResolver returns a legal length (32 bytes) whose high 12 bytes are not zero.
///      This exercises whether `_staticAddress`, shared by hops 1 and 2, also validates
///      padding itself rather than passively relying on `abi.decode` reverting on dirty
///      data. `getSubregistry` merely wires this mock into the next hop and does not need
///      dirtying.
contract DirtyAddressRegistry {
    address public next;

    constructor(address next_) {
        next = next_;
    }

    function getSubregistry(string calldata) external view returns (address) {
        return next;
    }

    function getResolver(string calldata) external view returns (address) {
        uint256 dirty = (uint256(1) << 160) | uint256(uint160(next));
        assembly {
            let p := mload(0x40)
            mstore(p, dirty)
            return(p, 0x20)
        }
    }
}

/// @dev `getResolver` burns all the gas — for exercising the `HOP_GAS` cap shared by
///      `_staticAddress`. `getSubregistry` does not need to burn any, because this mock
///      stands in as the `reg` that hop 1 resolves to, and the hop that burns gas is hop 2
///      (`reg.getResolver(label)`).
contract GasBurningRegistry {
    function getSubregistry(string calldata) external pure returns (address) {
        return address(0);
    }

    function getResolver(string calldata) external pure returns (address) {
        while (true) { }
        return address(0);
    }
}
