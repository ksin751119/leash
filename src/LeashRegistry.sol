// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC1155 } from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import { IRegistry, IERC1155Singleton } from "./IRegistry.sol";
import { IAttester } from "./IAttester.sol";

/// @title LeashRegistry —— 每個 agent 一個 ENS 名字
/// @notice 掛在 `leash.eth` 底下(`ETHRegistry.setSubregistry`),負責發 `vendors.leash.eth`
///         這種 agent 子名。每個子名有自己的 resolver 記錄,也就是自己的 policy 指標。
///
/// @dev **為什麼要自己寫一個 registry,而不是把子名都塞進一份 resolver 的 mapping:**
///
///      1. **`expiry` 是免費的 dead-man's switch。** 子名可以只發 24 小時 ——
///         到期之後 `getResolver` 回 `address(0)`,agent 解不出 policy,錢就動不了。
///         續期要人。這一條是 ENSv2 原生的,不必自己寫定時器。
///      2. **三層撤銷的中間那一層。** 收回一個子名 = 殺掉那一個 agent,
///         不影響其他 agent;而換掉整個 registry = 全部 agent 同時停機。
///         沒有 registry,中間這一層就不存在。
///      3. ENSv2 的解析是沿著 subregistry 指標往下走的,所以「掛一個自己的 registry」
///         才是這個架構原本設計的用法,不是繞路。
///
///      **與官方 `PermissionedRegistry` 的差異(刻意的):** 官方用 Enhanced Access
///      Control —— 128 個角色 + 128 個對應的 admin bit。我們用「registry owner +
///      registrar 白名單 + 每個名字一個 owner」這種簡單得多的模型。理由是 EAC 的
///      複雜度買到的是「把個別權限授權下去給第三方」,而 Leash 的金鑰模型只有三把
///      (ADMIN / WALLET / AGENT),沒有要授權給誰。**這是簡化,不是等價實作** ——
///      寫在這裡免得日後被誤讀成完整的 EAC。
///
///      tokenId 的推導**照官方實測反推**:`tokenId = keccak256(label)` 把**低 32 bits
///      清零**,那 32 bits 放版本號。實測 `leash.eth`:
///      `keccak256("leash")` = `0xe5edd0e4…55011342ffc412`,
///      實際 tokenId       = `0xe5edd0e4…5501130000 0000`。
///      版本號在名字被撤銷或過期重發時遞增,舊 token 因此一次失效。
contract LeashRegistry is IRegistry, ERC1155 {
    /// @dev 低 32 bits 是版本號,不屬於名字的身分。
    uint256 internal constant VERSION_MASK = 0xffffffff;

    /// @notice 子名最長可以發多久。
    /// @dev 沒有上限的話,`register(label, owner, .., type(uint64).max)` 會**靜默地
    ///      關掉 dead-man's switch** —— 那正是這份合約存在的主要理由。
    ///      有上限就強迫「長期存活」必須反覆 `renew`,而 `renew` 要背書。
    uint64 public constant MAX_DURATION = 365 days;

    /// @notice `namehash("leash.eth")`。事件裡的 `node` 要用它算。
    /// @dev 凍結的事件 schema 以 `node`(namehash)為 join key,而 registry 內部
    ///      用的是 labelhash 推導的 tokenId。兩者都要有:tokenId 給 ERC-1155,
    ///      node 給 subgraph 跟其他事件對接。
    bytes32 public immutable PARENT_NODE;

    /// @notice 發新子名與續期的背書來源。**`immutable`,沒有 setter。**
    /// @dev C1 的教訓:可變的 attester 指標讓一把被偷的金鑰同時開兩道鎖。
    IAttester public immutable attester;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant REGISTER_TYPEHASH = keccak256(
        "SubnameRegistration(string label,address owner,address resolver,uint64 duration,uint256 nonce)"
    );
    bytes32 private constant RENEW_TYPEHASH =
        keccak256("SubnameRenewal(string label,uint64 duration,uint256 nonce)");
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @notice 用掉的 attestation。防重放,語意與 `PolicyApprovals` 一致。
    mapping(bytes32 digest => bool) public attestationUsed;

    struct Entry {
        address owner; // 這個名字的持有者。`address(0)` = 從未發出
        address subregistry; // 往下一層。agent 名字通常是 0(葉節點)
        address resolver; // 這個 agent 的 policy 指標從哪裡讀
        uint64 expiry; // 到期時間。**過期後兩個 getter 都回 0**
        uint32 version; // 併進 tokenId 低 32 bits
    }

    /// @dev key 是 canonical id(清零版本號的),不是 tokenId ——
    ///      這樣版本遞增之後,記錄仍然找得到。
    mapping(uint256 canonicalId => Entry) internal _entries;

    /// @notice registry 管理者(ADMIN)。可以指派 registrar、可以撤銷任何名字。
    address public owner;

    /// @notice 誰可以發名字。跟 `owner` 分開,是為了讓「發名字」這件事能交給
    ///         一個受背書的合約(例如要刷臉才發新 agent 的那個),而不必交出 owner。
    mapping(address => bool) public isRegistrar;

    IRegistry internal _parent;
    string internal _parentLabel;

    /// @dev ENSv2 規定的事件 —— 索引端靠它知道有新子名。
    event NewSubname(uint256 indexed labelHash, string label);

    /// @dev 以下事件的名稱與欄位**對齊 `docs/events.md` 的凍結 schema**。
    ///      初版擅自改名(`SubnameRegistered` → `NameRegistered` 等)且只帶 tokenId,
    ///      沒帶 `node` —— 那讓 subgraph 無法跟 `PolicyPointerSet` / `SpendExecuted` /
    ///      `AgentBound` 對接(那些都以 `node` 為 key),而且違反凍結規則卻沒留變更紀錄。
    ///      code review 抓到。現在 `node` 是 indexed 的第一個欄位,tokenId 併在後面。
    event SubnameRegistered(
        bytes32 indexed node, string label, address indexed owner, uint64 expiry, uint256 tokenId
    );
    event SubnameRevoked(
        bytes32 indexed node, address indexed by, address indexed holder, uint256 tokenId
    );
    event SubnameRenewed(bytes32 indexed node, uint64 oldExpiry, uint64 newExpiry, uint256 tokenId);
    event ResolverChanged(bytes32 indexed node, address indexed resolver, uint256 tokenId);
    event SubregistryChanged(bytes32 indexed node, address indexed subregistry, uint256 tokenId);
    event RegistrarSet(address indexed registrar, bool allowed);
    event ParentSet(address indexed parent, string label);
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotRegistrar();
    error NotNameOwner();
    error ZeroOwner();
    error ZeroDuration();
    error EmptyLabel();
    error NameTaken(uint256 tokenId, uint64 expiry);
    error NameNotLive(uint256 tokenId);
    error ZeroAttester();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error DurationTooLong(uint64 requested, uint64 max);
    error LabelHasDot();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRegistrar() {
        if (!isRegistrar[msg.sender] && msg.sender != owner) revert NotRegistrar();
        _;
    }

    constructor(address owner_, IAttester attester_, bytes32 parentNode_) ERC1155("") {
        if (owner_ == address(0)) revert ZeroOwner();
        if (address(attester_) == address(0)) revert ZeroAttester();
        owner = owner_;
        attester = attester_;
        PARENT_NODE = parentNode_;
        emit OwnerTransferred(address(0), owner_);
    }

    // ---------------------------------------------------------------
    // IRegistry —— 解析路徑。**這兩個 getter 是整條鏈的熱路徑。**
    // ---------------------------------------------------------------

    /// @inheritdoc IRegistry
    /// @dev 過期就回 0。這是 dead-man's switch 的實際位置。
    function getSubregistry(string calldata label) external view returns (IRegistry) {
        Entry storage e = _entries[canonicalIdOf(label)];
        if (!_isLive(e)) return IRegistry(address(0));
        return IRegistry(e.subregistry);
    }

    /// @inheritdoc IRegistry
    /// @dev 過期就回 0 —— agent 因此解不出 policy,`LeashAccount` 得到理由碼 3,錢不動。
    ///      **「到期自動失效」不需要任何人送交易**,時間到了讀出來的值就變了。
    function getResolver(string calldata label) external view returns (address) {
        Entry storage e = _entries[canonicalIdOf(label)];
        if (!_isLive(e)) return address(0);
        return e.resolver;
    }

    /// @inheritdoc IRegistry
    function getParent() external view returns (IRegistry, string memory) {
        return (_parent, _parentLabel);
    }

    /// @inheritdoc IERC1155Singleton
    /// @dev 兩種情況都回 `address(0)`:
    ///      1. 名字過期 —— 跟解析路徑一致,不會出現「token 還在但名字沒用了」兩套說法
    ///      2. **tokenId 的版本號不是當前版本** —— 這就是那 32 bits 存在的意義。
    ///         名字被撤銷或過期重發之後,舊 tokenId 與新的共用同一個 canonical id,
    ///         少了這道比對,舊 token 會讀到新持有者。
    function ownerOf(uint256 tokenId) public view returns (address) {
        uint256 cid = tokenId & ~VERSION_MASK;
        Entry storage e = _entries[cid];
        if ((tokenId & VERSION_MASK) != e.version) return address(0);
        if (!_isLive(e)) return address(0);
        return e.owner;
    }

    // ---------------------------------------------------------------
    // 發名字 / 收名字
    // ---------------------------------------------------------------

    /// @notice 發一個 agent 子名。
    /// @param duration 秒。**這是那個 dead-man's switch** —— 短期名字到期自動失效。
    /// @return tokenId 含版本號的 tokenId
    ///
    /// @dev 名字已被佔用且還活著 → revert。**過期的名字可以重發**,重發時版本號遞增,
    ///      舊 token 因此一次失效(不需要逐一清理舊持有者的 balance 以外的狀態)。
    function register(
        string calldata label,
        address nameOwner,
        address subregistry,
        address resolver,
        uint64 duration,
        uint256 nonce,
        bytes calldata attestation
    ) external onlyRegistrar returns (uint256 tokenId) {
        if (bytes(label).length == 0) revert EmptyLabel();
        if (nameOwner == address(0)) revert ZeroOwner();
        if (duration == 0) revert ZeroDuration();
        if (duration > MAX_DURATION) revert DurationTooLong(duration, MAX_DURATION);
        _requireNoDot(label);

        // **兩個都要:registrar 且有背書。** 初版只有 `onlyRegistrar`,而
        // `PLAN.md` 的不對稱表寫「開新 agent 子名 → 要刷臉」——
        // 那句話當時是假的,整個合約裡沒有任何需要背書的路徑。code review 抓到。
        _consumeAttestation(
            keccak256(
                abi.encode(
                    REGISTER_TYPEHASH, keccak256(bytes(label)), nameOwner, resolver, duration, nonce
                )
            ),
            attestation
        );

        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];

        if (_isLive(e)) revert NameTaken(cid | e.version, e.expiry);

        // 過期重發:燒掉舊 token 並跳版本,舊 tokenId 從此指不到任何東西
        if (e.owner != address(0)) {
            _burn(e.owner, cid | e.version, 1);
            unchecked {
                e.version += 1;
            }
        }

        e.owner = nameOwner;
        e.subregistry = subregistry;
        e.resolver = resolver;
        e.expiry = uint64(block.timestamp) + duration;

        tokenId = cid | e.version;
        _mint(nameOwner, tokenId, 1, "");

        emit NewSubname(cid, label);
        emit SubnameRegistered(nodeOf(label), label, nameOwner, e.expiry, tokenId);
    }

    /// @notice 收回一個名字。**這是三層撤銷的中間那一層 —— 殺掉一個 agent。**
    /// @dev 不需要任何背書。**縮權永遠不該被擋** —— 出事時你不會想先找手機刷臉。
    ///      registry owner 和名字持有者都能做。做完之後 `getResolver` 立刻回 0。
    ///      版本號遞增,所以這個名字之後重發時是一個新 token。
    function revoke(string calldata label) external {
        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];
        if (!_isLive(e)) revert NameNotLive(cid | e.version);
        if (msg.sender != owner && msg.sender != e.owner) revert NotNameOwner();

        uint256 tokenId = cid | e.version;
        address holder = e.owner;

        // `owner` 一定要清掉:token 在這裡就燒了、版本也跳了,
        // 留著 owner 會讓之後的 `register` 以為還有一個舊 token 要燒(而那個版本從未 mint)。
        // 代價是撤銷之後 `entryOf` 認不出原持有者 —— 所以把它寫進事件,subgraph 才查得到。
        e.owner = address(0);
        e.expiry = 0;
        e.resolver = address(0);
        e.subregistry = address(0);
        unchecked {
            e.version += 1;
        }
        _burn(holder, tokenId, 1);

        emit SubnameRevoked(nodeOf(label), msg.sender, holder, tokenId);
    }

    /// @notice 續期。dead-man's switch 的「按一下」動作。
    /// @dev 限 registrar —— 續期是**擴權方向**(延長 agent 的存活時間)。
    function renew(
        string calldata label,
        uint64 duration,
        uint256 nonce,
        bytes calldata attestation
    ) external onlyRegistrar {
        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];
        if (!_isLive(e)) revert NameNotLive(cid | e.version);
        if (duration == 0) revert ZeroDuration();

        uint64 old = e.expiry;
        uint64 next = old + duration;
        // 續期後的**剩餘**期限也不能超過上限,否則反覆 renew 就等於沒有上限。
        if (next > uint64(block.timestamp) + MAX_DURATION) {
            revert DurationTooLong(next - uint64(block.timestamp), MAX_DURATION);
        }

        // 續期延長 dead-man's switch,**那是擴權**,所以要背書。
        _consumeAttestation(
            keccak256(abi.encode(RENEW_TYPEHASH, keccak256(bytes(label)), duration, nonce)),
            attestation
        );

        e.expiry = next;
        emit SubnameRenewed(nodeOf(label), old, next, cid | e.version);
    }

    // ---------------------------------------------------------------
    // 名字持有者可以改的東西
    // ---------------------------------------------------------------

    /// @notice 換這個 agent 該讀哪一份 policy 指標。**只有 registry owner。**
    ///
    /// @dev **這裡刻意偏離 ENS 的常態,而且那是整個設計的重點。**
    ///      標準 ENS 裡名字持有者當然能設自己的 resolver。我們不行 ——
    ///      因為在 Leash 的模型裡,**名字是韁繩,不是財產:它管住持有者,不屬於持有者。**
    ///
    ///      初版接受 `msg.sender == e.owner`。今天是惰性的(子名發給 ADMIN),
    ///      但只要有一天把子名發給 WALLET —— 而「每個 agent 一個錢包」是很自然的用法 ——
    ///      WALLET 就能**改自己的 policy 指標**,與 `docs/ensv2-sepolia.md` 實測的
    ///      `roles(WALLET) = 0` 和「agent 本來就不該能改自己的 policy」直接矛盾。
    ///      code review 抓到這個潛伏的權限。
    ///
    ///      **誠實界定這個權力的範圍:** ADMIN 可以把名字指到另一份 policy,
    ///      而**不需要背書**。這是刻意的 —— 「換一條更嚴的規則」是三層撤銷裡最輕的那一層,
    ///      不該被擋。代價是 ADMIN 也可以指到一份**較寬鬆**的 policy,
    ///      但那份 policy 必須已經在批准清單裡(意即曾經有真人核准過它),
    ///      所以爆炸半徑上限是「所有已批准的 policy」,不是「任意程式碼」。
    function setResolver(string calldata label, address resolver) external onlyOwner {
        Entry storage e = _requireLive(label);
        e.resolver = resolver;
        emit ResolverChanged(nodeOf(label), resolver, canonicalIdOf(label) | e.version);
    }

    /// @notice 見 `setResolver` —— 同樣只有 registry owner。
    function setSubregistry(string calldata label, address subregistry) external onlyOwner {
        Entry storage e = _requireLive(label);
        e.subregistry = subregistry;
        emit SubregistryChanged(nodeOf(label), subregistry, canonicalIdOf(label) | e.version);
    }

    // ---------------------------------------------------------------
    // 管理
    // ---------------------------------------------------------------

    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        isRegistrar[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    /// @dev 由父層在 `setSubregistry` 之後告知我們自己掛在哪 —— `getParent()` 要用。
    ///      這個值**不影響解析**,只是讓索引端能往上組出完整名字。
    function setParent(IRegistry parent, string calldata label) external onlyOwner {
        _parent = parent;
        _parentLabel = label;
        emit ParentSet(address(parent), label);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroOwner();
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    // ---------------------------------------------------------------
    // 查詢輔助
    // ---------------------------------------------------------------

    /// @notice label 的 canonical id —— labelhash 低 32 bits 清零。
    function canonicalIdOf(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label))) & ~VERSION_MASK;
    }

    /// @notice `namehash("<label>.leash.eth")` —— 事件與 resolver 記錄用的 key。
    /// @dev 父層固定,所以只要一次 keccak 接上 `PARENT_NODE`,不需要走完整的遞迴。
    function nodeOf(string memory label) public view returns (bytes32) {
        return keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @notice 發子名要被背書的 digest。前端、後端、鏈上三邊用同一個算法。
    function registerDigest(
        string calldata label,
        address nameOwner,
        address resolver,
        uint64 duration,
        uint256 nonce
    ) external view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                domainSeparator(),
                keccak256(
                    abi.encode(
                        REGISTER_TYPEHASH,
                        keccak256(bytes(label)),
                        nameOwner,
                        resolver,
                        duration,
                        nonce
                    )
                )
            )
        );
    }

    /// @notice 續期要被背書的 digest。
    function renewDigest(string calldata label, uint64 duration, uint256 nonce)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                domainSeparator(),
                keccak256(abi.encode(RENEW_TYPEHASH, keccak256(bytes(label)), duration, nonce))
            )
        );
    }

    /// @notice 目前活著的 tokenId(含版本號)。名字不存在時回 0。
    function tokenIdOf(string calldata label) external view returns (uint256) {
        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];
        if (e.owner == address(0)) return 0;
        return cid | e.version;
    }

    /// @notice 一次拿到一個 agent 名字的完整狀態,省 RPC。前端和 subgraph 都用這個。
    function entryOf(string calldata label)
        external
        view
        returns (address nameOwner, address resolver, address subregistry, uint64 expiry, bool live)
    {
        Entry storage e = _entries[canonicalIdOf(label)];
        live = _isLive(e);
        // 過期的名字照實回報 expiry 和 owner —— 呼叫端要看得出「曾經有過但過期了」
        // 和「從來沒發過」的差別。live 那個 bool 才是能不能用的答案。
        return (e.owner, e.resolver, e.subregistry, e.expiry, live);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IRegistry).interfaceId || id == type(IERC1155Singleton).interfaceId
            || super.supportsInterface(id);
    }

    // ---------------------------------------------------------------
    // 內部
    // ---------------------------------------------------------------

    function _isLive(Entry storage e) private view returns (bool) {
        return e.owner != address(0) && e.expiry > block.timestamp;
    }

    /// @dev 只檢查「名字還活著」。授權由呼叫端的 modifier 決定 ——
    ///      `setResolver` / `setSubregistry` 是 `onlyOwner`,`revoke` 另有一套
    ///      (owner **或**名字持有者,因為撤銷是縮權)。
    function _requireLive(string calldata label) private view returns (Entry storage e) {
        uint256 cid = canonicalIdOf(label);
        e = _entries[cid];
        if (!_isLive(e)) revert NameNotLive(cid | e.version);
    }

    /// @dev label 裡有 `.` 會產生一個永遠解析不到的名字 —— ENS 的解析是逐層走 label 的,
    ///      `"a.b"` 這個 label 不等於 `a.b.leash.eth`。靜默地發一個壞名字比 revert 糟。
    function _requireNoDot(string calldata label) private pure {
        bytes calldata b = bytes(label);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == ".") revert LabelHasDot();
        }
    }

    /// @dev 背書的消費點。digest 包 EIP-712 domain(綁 chainId 與這份合約),
    ///      並在用掉後永久標記 —— 語意與 `PolicyApprovals` 一致。
    function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
        if (attestationUsed[digest]) revert AttestationReused(digest);
        if (!attester.verify(digest, attestation)) revert NotAttested();
        attestationUsed[digest] = true;
    }

    /// @dev ERC-1155 轉讓之後,`Entry.owner` 要跟著動 —— 否則 `ownerOf` 和 token 餘額
    ///      會給出兩套說法。這是 singleton 語意的代價:同一件事存在兩個地方。
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        super._update(from, to, ids, values);
        // mint(from == 0)和 burn(to == 0)由 register / revoke 自己維護 Entry.owner
        if (from == address(0) || to == address(0)) return;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 cid = ids[i] & ~VERSION_MASK;
            // 版本不符的 token 餘額必為 0,`super._update` 已經會 revert;
            // 這道比對是保險 —— 絕不讓一個過期版本的 token 改寫當前 Entry。
            if ((ids[i] & VERSION_MASK) != _entries[cid].version) continue;
            _entries[cid].owner = to;
        }
    }
}
