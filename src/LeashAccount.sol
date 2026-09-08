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
    bytes32 private constant RULE_TYPEHASH = keccak256(
        "SetRule(address impl,bytes32 node,address token,bool allowed,uint256 txLimit,uint256 periodLimit,uint64 period,uint16 windowStart,uint16 windowEnd,uint256 nonce)"
    );

    event AgentBound(address indexed agent, bytes32 indexed node);
    /// @dev 證明這個 EOA 現在委派給 LeashAccount。**subgraph 的 template 觸發點** ——
    ///      7702 的委派不發 log,所以索引端只能靠這個知道要監聽哪個位址。
    event Leashed(bytes32 indexed node, address indexed wallet, address impl);
    event AgentRevoked(address indexed agent, address indexed by);
    event Paused(address indexed by);
    event Unpaused(address indexed by, bytes32 attestationHash);
    event TokenAllowed(bytes32 indexed node, address indexed token, bytes32 attestationHash);
    event LimitRaised(
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        uint64 period,
        bytes32 attestationHash
    );
    event TokenRemoved(bytes32 indexed node, address indexed token, address indexed by);
    event LimitLowered(
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        address indexed by
    );
    event PayeeAllowed(bytes32 indexed node, address indexed payee, bytes32 attestationHash);
    event PayeeRemoved(bytes32 indexed node, address indexed payee, address indexed by);

    error NotSelf();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error UnknownSelector();
    error NodeLabelMismatch(bytes32 expected, bytes32 got);
    error AlreadyBound();
    error NotBoundAgent();
    error NotSelfOrAgent();
    error NotTighter();

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
        emit PayeeAllowed(node, payee, keccak256(attestation));
    }

    /// @notice 讀取 (node, token) 目前的規則。
    function ruleOf(bytes32 node, address token)
        external
        view
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.layout().rules[node][token];
    }

    function isPayeeAllowed(bytes32 node, address token, address payee)
        external
        view
        returns (bool)
    {
        return LeashStorage.layout().payees[node][token][payee];
    }

    function spentInCurrentPeriod(bytes32 node, address token) external view returns (uint256) {
        LeashStorage.TokenRule storage r = LeashStorage.layout().rules[node][token];
        return LeashStorage.layout().spent[node][token][_bucket(r)];
    }

    /// @notice 設定規則。**擴權 —— 兩個都要。**
    /// @dev `period` 改變時 `epoch` 自動遞增。**這是唯一能讓 `spent` 換桶的路徑**,
    ///      而它需要 attestation —— 所以清帳永遠要一份背書。
    function setRule(
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation(
            keccak256(
                abi.encode(
                    RULE_TYPEHASH,
                    SELF,
                    node,
                    token,
                    rule.allowed,
                    rule.txLimit,
                    rule.periodLimit,
                    rule.period,
                    rule.windowStart,
                    rule.windowEnd,
                    nonce
                )
            ),
            attestation
        );

        LeashStorage.TokenRule storage cur = LeashStorage.layout().rules[node][token];
        // 全零代表這個 (node, token) 從未被 setRule 寫過 —— 沒有舊帳可清,
        // 不算「換週期」。少了這個判斷,第一次 setRule 就會把 epoch 從 0 誤判成
        // 「period 從預設值 0 變成了 rule.period」而白白 +1,跟
        // `test_setRule_bumps_epoch_only_when_period_changes` 對不上。
        bool exists = cur.allowed || cur.txLimit != 0 || cur.periodLimit != 0 || cur.period != 0
            || cur.windowStart != 0 || cur.windowEnd != 0 || cur.epoch != 0;
        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;
        uint32 epoch = cur.epoch;
        // 判斷「有沒有變寬」要在寫入前做,用的是舊值 vs 新值 —— 寫完再比就是
        // 拿 cur 跟自己比,永遠是 true。用 `_isTighterIgnoringEpoch`(不是
        // `_isTighter`)——原因見它自己的註解:`rule.epoch` 對 `setRule` 而言
        // 不受 attestation 保護、也從不被採信,拿它去跟 `cur.epoch` 比會把
        // 「epoch 曾經被撞過」的無關噪音誤判成「變寬」。
        // `_isTighterIgnoringEpoch` 對關閉中的舊規則一律回 false(「原本就關著,
        // 沒有更嚴可言」),所以第一次開啟(或重新開啟)一定落在 !tighterOrEqual,
        // `LimitRaised` 會跟著 `TokenAllowed` 一起發 —— 這正是「開一個沒有上限的
        // token」該有的行為:兩個事件都要有。
        bool tighterOrEqual = _isTighterIgnoringEpoch(cur, rule);
        if (exists && cur.period != rule.period) epoch += 1; // 換週期 = 換一套帳

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.period = rule.period;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        cur.epoch = epoch;

        bytes32 h = keccak256(attestation);
        if (!wasAllowed && rule.allowed) emit TokenAllowed(node, token, h);
        // 「Raised」只在真的變寬時發 —— 逐位元組相同(或更嚴)的 setRule 不該發
        // 一個名字叫「放寬」的事件。用跟 `tightenRule` 共用的同一套子集/大小
        // 判準(`_isTighterIgnoringEpoch`)當依據,而不是另外湊一條「periodLimit
        // 有沒有變大」的規則,否則 window/period 變寬又會漏掉,重演
        // `tightenRule` 當初要修的同一個洞。
        if (!tighterOrEqual) {
            emit LimitRaised(node, token, oldLimit, rule.periodLimit, rule.period, h);
        }
    }

    /// @notice 收緊規則。**縮權 —— 只要 `address(this)`,不需要背書。**
    /// @dev 要求**每一個欄位都弱單調收緊**。這把「更嚴」變成一個可檢查的斷言,
    ///      而配對式的 raise/lower 函式會漏掉 window 和 period ——
    ///      而漏掉的那些正好可以被用來放寬。
    function tightenRule(bytes32 node, address token, LeashStorage.TokenRule calldata rule)
        external
        onlySelf
    {
        LeashStorage.TokenRule storage cur = LeashStorage.layout().rules[node][token];
        if (!_isTighter(cur, rule)) revert NotTighter();

        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        // period 與 epoch 刻意不動 —— 見 `_isTighter`

        if (wasAllowed && !rule.allowed) emit TokenRemoved(node, token, msg.sender);
        if (oldLimit != rule.periodLimit) {
            emit LimitLowered(node, token, oldLimit, rule.periodLimit, msg.sender);
        }
    }

    /// @notice 移除一個收款人。**縮權,不需要背書。**
    function removePayee(bytes32 node, address token, address payee) external onlySelf {
        LeashStorage.layout().payees[node][token][payee] = false;
        emit PayeeRemoved(node, payee, msg.sender);
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

    /// @dev **弱單調收緊**的定義。每一條都有專門測試。
    function _isTighter(LeashStorage.TokenRule storage old_, LeashStorage.TokenRule calldata new_)
        private
        view
        returns (bool)
    {
        if (old_.allowed && !new_.allowed) return true; // 直接關掉一定更嚴
        if (!old_.allowed) return false; // 原本就關著,沒有更嚴可言
        // period 與 epoch 不准動:改 period 會換桶,累計歸零 ——
        // 「調低上限」反而讓可花的變多。清帳只能走 setRule(要背書)。
        if (new_.period != old_.period || new_.epoch != old_.epoch) return false;
        return _lteOrUnlimited(new_.txLimit, old_.txLimit)
            && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
            && _windowIsSubset(new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd);
    }

    /// @dev 跟 `_isTighter` 判準相同,但**完全不看 `epoch`** —— 只有 `setRule`
    ///      用它來決定要不要發 `LimitRaised`。`RULE_TYPEHASH` 沒有 `epoch` 這個
    ///      欄位,attestation 保護不到它,`setRule` 其餘地方也完全不採信呼叫者
    ///      填的 `rule.epoch`(見 `setRule` 內 epoch 的計算,只從 `cur.epoch`
    ///      往上加)。如果直接用 `_isTighter` 比,一旦 `epoch` 曾經被撞過
    ///      (period 換過一次),之後任何一次逐位元組相同的重放呼叫都會因為
    ///      呼叫者慣用的 `epoch: 0` 對不上目前非零的 `cur.epoch`,被誤判成
    ///      「變寬」而白白發一次 `LimitRaised`。
    function _isTighterIgnoringEpoch(
        LeashStorage.TokenRule storage old_,
        LeashStorage.TokenRule calldata new_
    ) private view returns (bool) {
        if (old_.allowed && !new_.allowed) return true;
        if (!old_.allowed) return false;
        if (new_.period != old_.period) return false; // 理由同 `_isTighter`,epoch 除外
        return _lteOrUnlimited(new_.txLimit, old_.txLimit)
            && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
            && _windowIsSubset(new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd);
    }

    /// @dev `0 = 不限`,所以比較會反轉:
    ///      `0 → 100` 收緊(true);`100 → 0` 放寬(false);`100 → 50` 收緊。
    ///      **這是最容易寫反的一行。**
    function _lteOrUnlimited(uint256 new_, uint256 old_) private pure returns (bool) {
        if (old_ == 0) return true; // 原本無限,任何值(含 0)都不更寬
        if (new_ == 0) return false; // 原本有限,改成無限 = 放寬
        return new_ <= old_;
    }

    /// @dev 新的分鐘集合必須是舊的子集。三種情況:
    ///      - 舊的是全天(`start == end`)→ 任何新時段都是收緊
    ///      - 新的是全天、舊的不是 → 放寬
    ///      - 兩者都是有限區間 → 逐分鐘檢查子集
    ///
    ///      **刻意用 O(1440) 的迴圈,不用不等式湊。** `pure`/`view` 只代表不寫
    ///      state,不代表免費 —— 這個迴圈是從 `tightenRule`(external,會改狀態)
    ///      呼叫的,gas 是在交易裡真的付的。兩個常見情況(「舊的全天」「新的
    ///      全天、舊的不是」)都提前 return,是 O(1);迴圈只在兩邊都是有限
    ///      區間、且新的確實是舊的子集(跑滿全部 1440 分鐘才能確認)時才吃到
    ///      全部成本 —— 實測約 480k gas(`test_a_narrower_overnight_window_is_tightening`)。
    ///      `tightenRule` 是縮權操作,一天跑不到幾次,Sepolia 上多付這筆 gas
    ///      無關痛癢。換成不等式湊的跨午夜子集判斷很容易寫反,而寫反**沒有任何
    ///      revert、任何錯誤** —— 只是靜默地放寬規則。花這筆 gas 換掉一個
    ///      不會被發現的 bug,划算。
    function _windowIsSubset(uint16 ns, uint16 ne, uint16 os, uint16 oe)
        private
        pure
        returns (bool)
    {
        if (os == oe) return true; // 舊的全天
        if (ns == ne) return false; // 新的全天、舊的不是
        for (uint16 m = 0; m < 1440; ++m) {
            if (_inWindow(m, ns, ne) && !_inWindow(m, os, oe)) return false;
        }
        return true;
    }

    /// @dev 與 `StandardPolicy._inWindow` 同語意。`start > end` 表示跨午夜。
    function _inWindow(uint16 minuteOfDay, uint16 start, uint16 end) private pure returns (bool) {
        if (start == end) return true;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }

    /// @dev `spent` 的 key。`epoch` 放高位、週期索引放低位,兩者不互相污染
    ///      (`period` 最小 1 秒,`timestamp / 1` 遠小於 `2^224`)。
    ///      `period == 0` 時所有花費累計進同一個桶 = 永不重置的終身額度。
    function _bucket(LeashStorage.TokenRule storage r) private view returns (uint256) {
        uint256 hi = uint256(r.epoch) << 224;
        return r.period == 0 ? hi : hi | (block.timestamp / r.period);
    }

    /// @notice 從 ENS 解出這個名字該過哪一份 policy。解不出來回 `address(0)`。
    ///
    /// @dev **三跳,而且每一跳的回傳長度不一樣:**
    ///
    ///      | 跳 | 呼叫 | 預期 returndata |
    ///      |---|---|---|
    ///      | 1 | `ETH_REGISTRY.getSubregistry("leash")` | 32 |
    ///      | 2 | `LeashRegistry.getResolver(label)` | 32 |
    ///      | 3 | `LeashResolver.resolve(dns, addr(node))` | **96** |
    ///
    ///      第三跳回傳 `bytes`,ABI 編碼是 offset(32) + length(32) + 內層(32)。
    ///      **寫成 `== 32` 檢查的話快樂路徑永遠不成立**,而且理由碼會是
    ///      `NO_POLICY`(「ENS 讀不到 policy」)—— 完全誤導除錯方向。
    ///
    ///      全部用低階 `staticcall` 並各自檢查自己的預期長度:ENS 的合約還在
    ///      Immunefi 審計期(至 09-14),位址可能變動或行為改變。我們不能因為
    ///      別人的合約 revert 就讓帳戶整個卡死 —— 解不出來就是 `NO_POLICY`,
    ///      錢不動,而那正是安全的預設。
    ///
    ///      **長度對不代表結構對,而且全程不對外部回傳資料呼叫 `abi.decode`。**
    ///      `abi.decode` 對畸形輸入(header 的 offset/length 不對、或
    ///      `address` 高 12 bytes 不乾淨)會 revert,而不是回傳失敗值 ——
    ///      那樣一個壞掉(或惡意)的 ENS 合約回傳長度對但內容假的資料,
    ///      就能讓 `resolvePolicy` revert,壞了「絕不 revert」的保證。
    ///      所以三跳全部只用 assembly 讀 word、自己驗證結構與 padding,
    ///      細節見 `_wordToAddress`。
    ///
    ///      這條路徑同時是三層撤銷的實作:hop1 回 0 = 全滅、
    ///      hop2 回 0 = 這一個 agent 死(撤銷或 `expiry` 到期)、
    ///      hop3 回 0 = 換規則那一層清空了指標。
    function resolvePolicy(bytes32 node, string memory label) public view returns (address) {
        address reg = _staticAddress(
            ETH_REGISTRY, abi.encodeWithSignature("getSubregistry(string)", PARENT_LABEL)
        );
        if (reg == address(0)) return address(0);

        address res = _staticAddress(reg, abi.encodeWithSignature("getResolver(string)", label));
        if (res == address(0)) return address(0);

        bytes memory inner = abi.encodeWithSignature("addr(bytes32)", node);
        bytes memory dnsName = _dnsEncode(label);
        (bool ok, bytes memory ret) = res.staticcall{ gas: HOP_GAS }(
            abi.encodeWithSignature("resolve(bytes,bytes)", dnsName, inner)
        );
        // 96 = offset(32) + length(32) + 內層(32)。**只檢查總長度不夠** ——
        // 長度對但 header 是假的(例如 offset 不是 0x20)一樣會讓
        // `abi.decode(ret, (bytes))` revert,壞了「絕不 revert」的保證
        // (2026-09-08 用一個孤立的 forge 測試實測過:`abi.decode` 對這類
        // 畸形輸入真的會 revert,不是理論風險)。所以完全不對外部回傳的
        // bytes 呼叫 `abi.decode`,自己用 assembly 讀三個字、自己驗證結構。
        if (!ok || ret.length != 96) return address(0);
        uint256 offset;
        uint256 innerLength;
        uint256 word;
        assembly {
            offset := mload(add(ret, 0x20))
            innerLength := mload(add(ret, 0x40))
            word := mload(add(ret, 0x60))
        }
        if (offset != 0x20 || innerLength != 0x20) return address(0);
        address policy = _wordToAddress(word);
        // policy 不能是自己 —— 同樣的憑證問題,見 `spend` 的 BadTarget 護欄
        if (policy == address(this)) return address(0);
        return policy;
    }

    /// @dev 每一跳的 gas 上限。ENS 那邊壞掉不能拖垮我們。
    uint256 private constant HOP_GAS = 100_000;

    function _staticAddress(address target, bytes memory cd) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall{ gas: HOP_GAS }(cd);
        if (!ok || ret.length != 32) return address(0);
        // 同樣不對外部回傳資料用 `abi.decode` —— 理由跟 hop3 一樣,見下面
        // `_wordToAddress` 的註解。
        uint256 word;
        assembly {
            word := mload(add(ret, 0x20))
        }
        return _wordToAddress(word);
    }

    /// @dev 把一個 32-byte word 當 address 讀出來,**自己驗證高 12 bytes 是 0**。
    ///
    ///      這裡有兩個都不能用的選項:
    ///      - `abi.decode(bytes, (address))` 會檢查高位並在不乾淨時 revert
    ///        (已實測驗證),但 `resolvePolicy` 的合約是「絕不 revert」——
    ///        一個回傳髒資料的 ENS 合約會直接把整個帳戶卡死。
    ///      - 直接用 assembly 把 word 截斷成 `uint160`(`address(uint160(word))`)
    ///        不會 revert,但也不驗證 —— 一個回傳高位有垃圾的 resolver 會被
    ///        安靜地截斷成一個看起來合法、但完全不是它原本意圖的地址放行。
    ///
    ///      兩者都不安全,所以自己做這個檢查:高位不乾淨就直接當作
    ///      `address(0)`(跟 hop1/hop2/hop3 其他失敗情形共用同一個「解不出來」
    ///      的訊號,呼叫端不需要另外分辨),乾淨才截斷回傳。**這是唯一驗證
    ///      padding 的地方** —— 呼叫端(`resolvePolicy`、`_staticAddress`)
    ///      直接信任這裡回傳的值,不再重複檢查,以免出現「兩處都要改」
    ///      的重複邏輯。
    function _wordToAddress(uint256 word) private pure returns (address) {
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev DNS wire format:`<len><label>...<len>eth<0>`。
    ///      父層固定是 `leash.eth`,所以只有第一段是變數。
    ///      實測:`vendors.leash.eth` = `0x0776656e646f7273056c656173680365746800`
    function _dnsEncode(string memory label) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, hex"056c656173680365746800");
    }
}
