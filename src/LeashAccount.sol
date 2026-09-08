// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LeashStorage } from "./LeashStorage.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";
import { Reason } from "./Reason.sol";

/// @title LeashAccount —— agent 唯一的花費路徑
/// @notice 一份 EIP-7702 delegate 實作。被委派的 EOA 在任何轉帳之前必須:
///         授權 agent → ENS 三跳解出 policy → 比對批准清單 → 過 policy。
///
/// @dev **不要說「唯一的花費路徑」。** EIP-7702 只約束打到那個 EOA 的呼叫;
///      WALLET 私鑰照樣能直簽 `USDC.transfer`,policy 那條路徑根本不會執行。
///      這既是邊界也是**逃生口** —— 錢包持有者永遠拿得回自己的錢。
///
///      **沒有 `initialize()`。** 全域設定是 `immutable`,烙在 bytecode 裡,
///      所以委派後 storage 空白的那段窗口沒有東西可以搶。per-EOA 的權限
///      一律是 `msg.sender == address(this)`,而只有錢包的私鑰能讓那個 EOA 送交易。
contract LeashAccount {
    using LeashStorage for LeashStorage.AccountStorage;

    // --- 烙在 bytecode 裡 ---

    /// @notice ENSv2 的 .eth registry。解析的起點,也是「全滅」拉桿的位置。
    address public immutable ETH_REGISTRY;

    /// @notice 批准清單。**immutable** —— 見 `PolicyApprovals` 的 C1 註解。
    IPolicyApprovals public immutable APPROVALS;

    /// @notice 擴權的背書來源。**immutable**。
    IAttester public immutable ATTESTER;

    /// @notice **impl 自己被部署時的位址。**
    /// @dev 這是 7702 特有的一個小陷阱:同一份程式碼裡,`address(this)` 和
    ///      「這份程式碼住在哪」是**兩個不同的值**。delegate 執行時
    ///      `address(this)` 是 EOA,而 `immutable` 在部署時被烙進 bytecode,
    ///      所以 `SELF` 記得的是 impl 的位址。
    ///
    ///      attestation 的 digest 需要**兩個都有**:`address(this)` 綁住
    ///      「哪個錢包」,`SELF` 綁住「哪一版 impl」。少了 `SELF`,錢包重新委派到
    ///      新版之後,舊版的 attestation 可以重放(新版可能換了 ERC-7201 命名空間,
    ///      讀不到舊的 `attestationUsed` 紀錄)。
    address public immutable SELF;

    string public constant PARENT_LABEL = "leash";

    /// @notice `namehash("leash.eth")`。`bindAgent` 用它驗證 node 與 label 一致。
    bytes32 public constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @notice 呼叫 policy 的 gas 上限。超過就 fail-closed(理由碼 12)。
    /// @dev 刻意的上限:一份能燒掉全部 gas 的 policy 等於一個 DoS 開關。
    uint256 public constant POLICY_GAS = 200_000;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant PAYEE_TYPEHASH = keccak256(
        "AllowPayee(address impl,bytes32 node,address token,address payee,uint256 nonce)"
    );

    error NotSelf();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error UnknownSelector();

    /// @dev per-EOA 的權限只有這一種。`address(this)` 在 delegate 裡是那個 EOA,
    ///      而只有它的私鑰能讓它送出交易 —— 所以這就是「錢包自己」。
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address ethRegistry_, IPolicyApprovals approvals_, IAttester attester_) {
        ETH_REGISTRY = ethRegistry_;
        APPROVALS = approvals_;
        ATTESTER = attester_;
        SELF = address(this);
    }

    /// @notice **必須有。** 純轉 ETH = 用空 calldata 呼叫 delegate;
    ///         沒有這個函式,委派之後那個錢包就收不到 ETH、加不了 gas。
    receive() external payable { }

    /// @notice 打錯 selector 明確 revert,不要靜默吞掉。
    /// @dev 這個帳戶**不做**通用呼叫轉發(見 spec 的 YAGNI 表)。
    fallback() external payable {
        revert UnknownSelector();
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    function bindingOf(address agent)
        external
        view
        returns (bytes32 node, string memory label, bool revoked)
    {
        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        return (b.node, b.label, b.revoked);
    }

    /// @notice 綁定一個 agent 到一個 ENS 名字。**縮權方向,不需要背書。**
    /// @dev 完整的檢查在任務 3 補上(namehash 一致、已存在就 revert)。
    function bindAgent(address agent, bytes32 node, string calldata label) external onlySelf {
        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        b.node = node;
        b.label = label;
    }

    /// @notice 白名單一個收款人。**擴權 —— 兩個都要。**
    function allowPayee(
        bytes32 node,
        address token,
        address payee,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation(
            keccak256(abi.encode(PAYEE_TYPEHASH, SELF, node, token, payee, nonce)), attestation
        );
        LeashStorage.layout().payees[node][token][payee] = true;
    }

    /// @notice 設定規則。**擴權 —— 兩個都要。** 完整邏輯在任務 4。
    function setRule(
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        nonce;
        attestation;
        LeashStorage.layout().rules[node][token] = rule;
    }

    function payeeDigest(bytes32 node, address token, address payee, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(PAYEE_TYPEHASH, SELF, node, token, payee, nonce)));
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev 背書的消費點。digest 同時綁住這個錢包(`address(this)` 進 domain)
    ///      和這一版 impl(`SELF` 進 structHash)。用掉後永久標記。
    function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private {
        bytes32 d = _digest(structHash);
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        if ($.attestationUsed[d]) revert AttestationReused(d);
        if (!ATTESTER.verify(d, attestation)) revert NotAttested();
        $.attestationUsed[d] = true;
    }
}
