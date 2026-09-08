// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 可以設定「回傳長度不對」與「revert」—— 用來測 fail-closed。
///      ENS 的合約還在 Immunefi 審計期,行為可能變 —— 我們不能因為
///      別人的合約壞掉就讓帳戶整個卡死。
contract MockRegistry {
    address public sub;
    address public res;
    bool public shouldRevert;
    uint256 public padBytes; // >0 時回傳多餘的 bytes,長度就不對了

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
            // 回傳長度不是 32 —— 用 assembly 直接回一段任意長度
            assembly {
                let p := mload(0x40)
                mstore(p, 1)
                return(p, 8)
            }
        }
        return res;
    }
}

/// @dev 只實作 ENSIP-10,回傳 `bytes`(96 bytes 的 ABI 編碼)。
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

/// @dev 只在 `name` 完全相符時回傳 policy —— 用來驗證 DNS 編碼。
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
