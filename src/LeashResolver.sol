// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy } from "./IPolicy.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";

/// @title LeashResolver —— 把 policy 位址掛在 ENS 名字底下
/// @notice 每個 agent 是一個 ENS 名字(`vendors.acme.eth`),名字的 resolver 記錄
///         存的就是那個 agent 該過哪一份 policy。`LeashAccount` 每次付款前走一次
///         這條解析;解不出來就是理由碼 3,錢不動。
///
/// @dev **只實作 ENSIP-10 `resolve(bytes,bytes)`。** 這不是偷懶,是實測結論:
///      ENSv2 Sepolia 上的極簡 resolver(例如 `nick.eth` 用的那支)**根本沒有**
///      `addr(bytes32)` / `text(bytes32,string)` 這兩個外部函式,直接呼叫會 revert,
///      `supportsInterface` 也一律回 false。ENSv2 的讀取慣例就是 `resolve()` 一個入口,
///      legacy 介面是舊世界的東西。完整實測見 `docs/ensv2-sepolia.md`。
///
///      另一個讓「鏈上強制」成立的實測結論:`resolve()` **直接回傳資料**,
///      不會 revert 成 `OffchainLookup`。所以合約可以在交易執行當下把 registry walk
///      跟記錄讀取一次做完,**不需要 CCIP-read gateway**。沒有這一條,整個設計不成立。
contract LeashResolver {
    // --- ENSIP-10 內層呼叫支援的 selector(編譯期常數,不靠記憶抄) ---
    bytes4 private constant SEL_ADDR = bytes4(keccak256("addr(bytes32)"));
    bytes4 private constant SEL_ADDR_COIN = bytes4(keccak256("addr(bytes32,uint256)"));
    bytes4 private constant SEL_TEXT = bytes4(keccak256("text(bytes32,string)"));
    bytes4 private constant SEL_RESOLVE = bytes4(keccak256("resolve(bytes,bytes)"));
    bytes4 private constant SEL_ERC165 = bytes4(keccak256("supportsInterface(bytes4)"));

    /// @dev ENS 的 EVM 幣別。`addr(node, 60)` 等同 `addr(node)`。
    uint256 private constant COIN_TYPE_ETH = 60;

    address public owner;

    /// @notice 批准清單。可以是 `address(0)`(尚未接上),那時一律回報「未批准」——
    ///         fail-closed,不會因為清單沒接就默認放行。
    IPolicyApprovals public approvals;

    /// @notice ENS 節點 → policy 位址。`address(0)` = 沒設 / 已清空 = 全面停機。
    mapping(bytes32 node => address policy) public policyOf;

    event PolicyPointerSet(
        bytes32 indexed node, address indexed policy, address indexed setBy, bool approved
    );
    event ApprovalsSourceSet(address indexed approvals, address indexed setBy);
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroOwner();
    /// @dev 內層呼叫的 selector 我們不認識。**revert 而不是回空值** —— 呼叫端
    ///      分不出「沒設定」和「不支援」的話,fail-closed 就無從做起。
    error UnsupportedResolverCall(bytes4 selector);
    error UnsupportedCoinType(uint256 coinType);
    error UnknownTextKey(string key);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, IPolicyApprovals approvals_) {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
        approvals = approvals_;
        emit OwnerTransferred(address(0), owner_);
        emit ApprovalsSourceSet(address(approvals_), msg.sender);
    }

    // ---------------------------------------------------------------
    // 寫入(ADMIN)
    // ---------------------------------------------------------------

    /// @notice 指定某個 agent 名字該過哪一份 policy。
    /// @dev **這裡刻意不檢查 `approved`。** 指標由 ADMIN 控制、批准清單由刷臉控制,
    ///      兩層分開才有意義:ADMIN 金鑰被偷,攻擊者改得動指標,但指到一份沒被批准過的
    ///      policy 時 `LeashAccount` 會擋下來(理由碼 4)。強制在帳戶層,不在這裡。
    ///
    ///      設成 `address(0)` 是**縮權**(該 agent 立刻全面停機),永遠不該被擋 ——
    ///      出事時你不會想先找手機刷臉。
    function setPolicy(bytes32 node, address policy) external onlyOwner {
        policyOf[node] = policy;
        emit PolicyPointerSet(node, policy, msg.sender, _isApproved(policy));
    }

    function setApprovalsSource(IPolicyApprovals approvals_) external onlyOwner {
        approvals = approvals_;
        emit ApprovalsSourceSet(address(approvals_), msg.sender);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroOwner();
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    // ---------------------------------------------------------------
    // ENSIP-10
    // ---------------------------------------------------------------

    /// @notice ENSIP-10 萬用解析入口。
    /// @param  data 內層呼叫,ABI 編碼過的 `addr(bytes32)` / `addr(bytes32,uint256)` /
    ///              `text(bytes32,string)`。
    /// @return 內層呼叫的回傳值,再 ABI 編碼一層(ENSIP-10 的規定)。
    ///
    /// @dev **`name` 刻意不使用。** node 已經在內層 calldata 裡了,再把 DNS 編碼的名字
    ///      重新 hash 一次去比對,是為了防一個我們的信任模型裡不存在的攻擊 ——
    ///      呼叫端本來就是自己算出 node 才來查的。ENS 官方的 `ExtendedResolver` 也是這樣做。
    ///      參數保留是因為介面要合,不是因為它有用。
    function resolve(
        bytes calldata,
        /* name */
        bytes calldata data
    )
        external
        view
        returns (bytes memory)
    {
        bytes4 sel = bytes4(data[0:4]);

        if (sel == SEL_ADDR) {
            bytes32 node = abi.decode(data[4:], (bytes32));
            return abi.encode(policyOf[node]);
        }

        if (sel == SEL_ADDR_COIN) {
            (bytes32 node, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            if (coinType != COIN_TYPE_ETH) revert UnsupportedCoinType(coinType);
            // ENSIP-9:多幣別型別回傳的是 raw bytes,不是 address
            return abi.encode(abi.encodePacked(policyOf[node]));
        }

        if (sel == SEL_TEXT) {
            (bytes32 node, string memory key) = abi.decode(data[4:], (bytes32, string));
            return abi.encode(_text(node, key));
        }

        revert UnsupportedResolverCall(sel);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == SEL_RESOLVE || id == SEL_ERC165;
    }

    // ---------------------------------------------------------------
    // 唯讀輔助
    // ---------------------------------------------------------------

    /// @notice 一次拿到「指到哪」和「批准了嗎」,省一趟 RPC。
    /// @dev    `LeashAccount` 和前端都是這樣用。
    function policyAndApproval(bytes32 node) external view returns (address policy, bool approved) {
        policy = policyOf[node];
        approved = _isApproved(policy);
    }

    // ---------------------------------------------------------------
    // 內部
    // ---------------------------------------------------------------

    /// @dev 三個 text 記錄,全部是**給人看的**,沒有一個在強制路徑上:
    ///      - `policy`      → policy 位址的十六進位字串(`dig`-style 查詢、前端顯示)
    ///      - `description` → policy 自己的 `describe()`,問不到就回空字串
    ///      - `leash`       → 版本標記,讓人一眼看出這個名字是被 Leash 管的
    function _text(bytes32 node, string memory key) private view returns (string memory) {
        bytes32 k = keccak256(bytes(key));
        address policy = policyOf[node];

        if (k == keccak256("policy")) {
            return policy == address(0) ? "" : _toHexString(policy);
        }
        if (k == keccak256("description")) {
            if (policy == address(0)) return "";
            // describe() 是 pure,staticcall 一定安全。壞掉的 policy 不該讓顯示路徑爆掉。
            (bool ok, bytes memory ret) = policy.staticcall(abi.encodeCall(IPolicy.describe, ()));
            if (!ok || ret.length == 0) return "";
            return abi.decode(ret, (string));
        }
        if (k == keccak256("leash")) {
            return "leash-v1";
        }
        revert UnknownTextKey(key);
    }

    /// @dev 清單沒接上就一律「未批准」。fail-closed。
    function _isApproved(address policy) private view returns (bool) {
        if (policy == address(0) || address(approvals) == address(0)) return false;
        return approvals.isApproved(policy);
    }

    function _toHexString(address a) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; ++i) {
            // 截斷是刻意的:每次只要最低那個 byte
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(v >> (8 * (19 - i)));
            out[2 + i * 2] = digits[b >> 4];
            out[3 + i * 2] = digits[b & 0x0f];
        }
        return string(out);
    }
}
