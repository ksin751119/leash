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

/// @dev 回傳「長度剛好 96,但 header 是假的」——`offset` 不是合法的 `0x20`。
///      用來測「只檢查總長度不夠,還要檢查結構」:一個長度對但內容亂寫的
///      resolver 不能讓 `resolvePolicy` revert。
///
///      **第三個 word(payload 的位置)刻意放一個真實地址,不是 0。**
///      `resolvePolicy` 目前的讀法是固定位置讀 word(ret+0x60),不會真的
///      跟著 `offset` 欄位去重新定位 —— 如果拿掉「`offset == 0x20`」這個
///      結構檢查,程式碼會直接把這個真實地址當成合法 policy 放行。放 0 的話,
///      少了檢查也會巧合地回傳 `address(0)`,測試就測不出保護有沒有被拿掉。
contract MalformedHeaderResolver {
    address public policy;

    constructor(address policy_) {
        policy = policy_;
    }

    function resolve(bytes calldata, bytes calldata) external view returns (bytes memory) {
        uint256 p_ = uint256(uint160(policy));
        assembly {
            let p := mload(0x40)
            mstore(p, 0x40) // 假 offset,不是合法的 0x20
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), p_)
            return(p, 0x60)
        }
    }
}

/// @dev header 合法(offset/length 都是 `0x20`),但 payload 的高 12 bytes
///      不是 0 —— 用來測「不能靠 assembly 截斷偷放行地址」:必須自己驗證
///      padding 乾不乾淨,而不是安靜地截斷成一個看起來合法的地址。
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

/// @dev getResolver 回傳長度合法(32 bytes),但高 12 bytes 不是 0 —— 用來測
///      hop1/hop2 共用的 `_staticAddress` 是不是也自己驗證 padding,而不是
///      被動依賴 `abi.decode` 在髒資料上 revert 這件事。`getSubregistry`
///      只是把自己接到下一跳,不需要弄髒。
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

/// @dev `getResolver` 燒掉所有 gas —— 測 `_staticAddress` 共用的 `HOP_GAS`
///      上限。`getSubregistry` 不需要燒,因為這個 mock 是拿來當 hop1 解出的
///      `reg`,燒 gas 的那一跳是 hop2(`reg.getResolver(label)`)。
contract GasBurningRegistry {
    function getSubregistry(string calldata) external pure returns (address) {
        return address(0);
    }

    function getResolver(string calldata) external pure returns (address) {
        while (true) { }
        return address(0);
    }
}
