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
    bytes32 private constant RESTORE_TYPEHASH = keccak256(
        "RestoreAgent(address impl,address agent,bytes32 node,string label,uint256 nonce)"
    );

    event AgentBound(address indexed agent, bytes32 indexed node);
    /// @dev 證明這個 EOA 現在委派給 LeashAccount。**subgraph 的 template 觸發點** ——
    ///      7702 的委派不發 log,所以索引端只能靠這個知道要監聽哪個位址。
    event Leashed(bytes32 indexed node, address indexed wallet, address impl);
    event AgentRevoked(address indexed agent, address indexed by);
    event Paused(address indexed by);
    event Unpaused(address indexed by, bytes32 attestationHash);

    error NotSelf();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error UnknownSelector();
    error NodeLabelMismatch(bytes32 expected, bytes32 got);
    error AlreadyBound();
    error NotBoundAgent();
    error NotSelfOrAgent();

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

    /// @notice `namehash("<label>.leash.eth")`。
    /// @dev 父層固定,所以只要一次 keccak 接上 `PARENT_NODE` —— 兩次 keccak,不是迴圈。
    function nodeFor(string memory label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
    }

    function paused() external view returns (bool) {
        return LeashStorage.layout().paused;
    }

    /// @notice 綁定一個 agent。**縮權方向,不需要背書** —— 從零開始給權限,
    ///         而那個權限的內容完全由 ENS 那一側(ADMIN)和批准清單(真人)決定。
    ///
    /// @dev `node` 與 `label` **必須一致**。`node` 不只是 resolver 的 key,
    ///      它也是 `rules` / `payees` / `spent` 的 key —— 不一致會讓這個 agent
    ///      花 A 名字的預算卻由 B 名字的 policy 判斷,而 `AgentBound` 不帶 label,
    ///      鏈下看不出來。
    function bindAgent(address agent, bytes32 node, string calldata label) external onlySelf {
        bytes32 expected = nodeFor(label);
        if (node != expected) revert NodeLabelMismatch(expected, node);

        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        LeashStorage.AgentBinding storage b = $.bindings[agent];
        // 已存在就 revert:否則「撤銷後免費重綁」會繞過凍結文件對理由碼 2 的規定
        // (恢復要刷臉)。綁錯的補救是 `unbindAgent` 再 `bindAgent`,兩步都是縮權。
        if (b.node != bytes32(0)) revert AlreadyBound();

        b.node = node;
        b.label = label;
        emit AgentBound(agent, node);

        // **第一次綁定時發 `Leashed`。**
        //
        // EIP-7702 的委派**不發任何 log**,所以 subgraph 沒有 factory 事件可以
        // 觸發 template —— 它不知道要監聽哪些 EOA 位址。這一筆就是那個觸發點。
        // (`Leashed` 已經在凍結 schema 裡,這裡給它一個明確的發出時機。)
        // demo 另外會在 subgraph.yaml 寫死錢包位址當保險,見 sprint 項目 9。
        // `b.node == 0` 的分支已經在上面確認過(否則 AlreadyBound),
        // 所以能走到這裡的都是「這個 agent 的第一次綁定」。
        // 但 `Leashed` 是**錢包層級**的事實,不該每綁一個 agent 就重發一次 ——
        // 用一個獨立的旗標記住它。
        if (!$.leashedEmitted) {
            $.leashedEmitted = true;
            emit Leashed(node, address(this), SELF);
        }
    }

    /// @notice 完全解除綁定。**縮權,完全免費。**
    /// @dev 這是「綁錯名字」的補救路徑。解綁之後那個 agent 什麼都不能做,
    ///      可以重新 `bindAgent` 到正確的名字 —— 中間沒有任何一刻權限比原本大。
    function unbindAgent(address agent) external {
        _requireSelfOrAgent(agent);
        delete LeashStorage.layout().bindings[agent];
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice 撤銷一個 agent(保留綁定,標記為 revoked)。**縮權,不需要背書。**
    /// @dev 與 `unbindAgent` 的差別:這裡保留 node/label,所以 `spend` 走到 2b
    ///      會發出可索引的 `SpendBlocked(AGENT_REVOKED)`,agent 查 subgraph
    ///      就知道自己為什麼不能動了。`unbindAgent` 則讓它變成「從未綁定」,
    ///      那會在 2a 直接 revert。
    function revokeAgent(address agent) external {
        _requireSelfOrAgent(agent);
        LeashStorage.layout().bindings[agent].revoked = true;
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice 恢復一個被撤銷的 agent。**擴權 —— 兩個都要。**
    /// @dev 三個參數全部進 digest,所以一份恢復用的背書不能被挪去恢復別的 agent
    ///      或把它綁到別的名字。
    function restoreAgent(
        address agent,
        bytes32 node,
        string calldata label,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        bytes32 expected = nodeFor(label);
        if (node != expected) revert NodeLabelMismatch(expected, node);
        _consumeAttestation(
            keccak256(
                abi.encode(RESTORE_TYPEHASH, SELF, agent, node, keccak256(bytes(label)), nonce)
            ),
            attestation
        );

        LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[agent];
        b.node = node;
        b.label = label;
        b.revoked = false;
        emit AgentBound(agent, node);
    }

    /// @notice 全面暫停。**錢包自己或任何未被撤銷的被綁定 agent 都能按。**
    /// @dev 踩煞車只會讓系統更嚴,讓它需要權限是在真的出事的那一刻幫攻擊者省事。
    function pause() external {
        if (msg.sender != address(this)) {
            LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[msg.sender];
            if (b.node == bytes32(0) || b.revoked) revert NotBoundAgent();
        }
        LeashStorage.layout().paused = true;
        emit Paused(msg.sender);
    }

    /// @notice 解除暫停。**只有錢包自己,而且不需要背書。**
    /// @dev **不能要背書。** 任何 agent 都能免費 `pause`,若 `unpause` 要刷臉,
    ///      被入侵的 agent 就能反覆逼持有者刷臉 —— 那是一個 DoS。
    ///      免費的煞車必須配免費的放開,兩邊都由錢包自己控制。
    ///      凍結文件也把理由碼 10 列為「ADMIN 的日常操作」,不需刷臉。
    ///
    ///      `Unpaused` 的凍結簽章有一個 `attestationHash` 欄位 —— 送 `bytes32(0)`,
    ///      subgraph 要把 0 解讀為「不需背書的解除」,而不是「缺資料」。
    function unpause() external onlySelf {
        LeashStorage.layout().paused = false;
        emit Unpaused(msg.sender, bytes32(0));
    }

    function _requireSelfOrAgent(address agent) private view {
        if (msg.sender != address(this) && msg.sender != agent) revert NotSelfOrAgent();
        if (LeashStorage.layout().bindings[agent].node == bytes32(0)) revert NotBoundAgent();
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
