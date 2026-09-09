// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC1155 } from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import { IRegistry, IERC1155Singleton } from "./IRegistry.sol";
import { IAttester } from "./IAttester.sol";

/// @title LeashRegistry — one ENS name per agent
/// @notice Hangs under `leash.eth` (via `ETHRegistry.setSubregistry`) and issues agent
///         subnames like `vendors.leash.eth`. Each subname has its own resolver record,
///         which is to say its own policy pointer.
///
/// @dev **Why write a registry at all, instead of stuffing every subname into one
///      resolver's mapping:**
///
///      1. **`expiry` is a free dead man's switch.** A subname can be issued for 24 hours —
///         once it lapses, `getResolver` returns `address(0)`, the agent cannot resolve a
///         policy, and no money moves. Renewal takes a human. This comes native with
///         ENSv2; no timer of our own to write.
///      2. **It is the middle layer of the three revocation layers.** Taking back one
///         subname kills that one agent and leaves the others alone; swapping the whole
///         registry halts every agent at once. Without a registry the middle layer does
///         not exist.
///      3. ENSv2 resolution walks down subregistry pointers, so "hang your own registry"
///         is how the architecture is meant to be used, not a detour.
///
///      **Deliberate differences from the official `PermissionedRegistry`:** theirs uses
///      Enhanced Access Control — 128 roles plus 128 matching admin bits. We use a far
///      simpler model: registry owner + a registrar allow-list + one owner per name. What
///      EAC's complexity buys is delegating individual permissions to third parties, and
///      Leash's key model has exactly three keys (ADMIN / WALLET / AGENT) with nobody to
///      delegate to. **This is a simplification, not an equivalent implementation** —
///      recorded here so it is not later misread as full EAC.
///
///      The tokenId derivation was **reverse-engineered from the deployed contracts**:
///      `tokenId = keccak256(label)` with the **low 32 bits zeroed**, those 32 bits
///      holding a version. Measured on `leash.eth`:
///      `keccak256("leash")` = `0xe5edd0e4…55011342ffc412`,
///      actual tokenId       = `0xe5edd0e4…5501130000 0000`.
///      The version increments when a name is revoked or re-registered after expiry, which
///      invalidates the old token in one step.
contract LeashRegistry is IRegistry, ERC1155 {
    /// @dev The low 32 bits are a version, not part of the name's identity.
    uint256 internal constant VERSION_MASK = 0xffffffff;

    /// @notice The longest a subname can be issued for.
    /// @dev Without a cap, `register(label, owner, .., type(uint64).max)` would **silently
    ///      switch off the dead man's switch** — the very reason this contract exists. With
    ///      a cap, staying alive long-term forces repeated `renew` calls, and `renew`
    ///      requires an attestation.
    uint64 public constant MAX_DURATION = 365 days;

    /// @notice `namehash("leash.eth")`. The `node` in the events is derived from it.
    /// @dev The frozen event schema joins on `node` (a namehash), while the registry
    ///      internally uses a tokenId derived from the labelhash. Both are needed: tokenId
    ///      for ERC-1155, node so the subgraph can join against the other events.
    bytes32 public immutable PARENT_NODE;

    /// @notice The attestation source for issuing and renewing subnames. **`immutable`,
    ///         with no setter.**
    /// @dev The lesson of C1: a mutable attester pointer lets one stolen key open both
    ///      locks.
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

    /// @notice Spent attestations. Replay protection, with the same semantics as
    ///         `PolicyApprovals`.
    mapping(bytes32 digest => bool) public attestationUsed;

    struct Entry {
        address owner; // Holder of this name. `address(0)` = never issued
        address subregistry; // One level down. Usually 0 for an agent name (a leaf)
        address resolver; // Where this agent's policy pointer is read from
        uint64 expiry; // Expiry. **Once past it, both getters return 0**
        uint32 version; // OR-ed into the low 32 bits of the tokenId
    }

    /// @dev Keyed by canonical id (version bits zeroed), not tokenId — so the record is
    ///      still findable after the version increments.
    mapping(uint256 canonicalId => Entry) internal _entries;

    /// @notice The registry administrator (ADMIN). Can appoint registrars and revoke any
    ///         name.
    address public owner;

    /// @notice Who may issue names. Kept separate from `owner` so that issuance can be
    ///         handed to an attested contract (say one that requires a face scan before
    ///         creating a new agent) without handing over ownership.
    mapping(address => bool) public isRegistrar;

    IRegistry internal _parent;
    string internal _parentLabel;

    /// @dev The event ENSv2 mandates — indexers learn about new subnames from it.
    event NewSubname(uint256 indexed labelHash, string label);

    /// @dev The names and fields of the events below **match the frozen schema in
    ///      `docs/events.md`**. The first version renamed them unilaterally
    ///      (`SubnameRegistered` → `NameRegistered` and so on) and carried only a tokenId,
    ///      no `node` — which left the subgraph unable to join against `PolicyPointerSet` /
    ///      `SpendExecuted` / `AgentBound` (all keyed by `node`), and broke the freeze rule
    ///      without recording a change. Code review caught it. `node` is now the first
    ///      indexed field, with the tokenId alongside.
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
    // IRegistry — the resolution path. **These two getters are the hot path of the
    // entire chain.**
    // ---------------------------------------------------------------

    /// @inheritdoc IRegistry
    /// @dev Returns 0 once expired. This is where the dead man's switch actually lives.
    function getSubregistry(string calldata label) external view returns (IRegistry) {
        Entry storage e = _entries[canonicalIdOf(label)];
        if (!_isLive(e)) return IRegistry(address(0));
        return IRegistry(e.subregistry);
    }

    /// @inheritdoc IRegistry
    /// @dev Returns 0 once expired — the agent can then resolve no policy, `LeashAccount`
    ///      reports reason code 3, and no money moves. **Lapsing needs nobody to send a
    ///      transaction**; when the time passes, the value read back simply changes.
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
    /// @dev Returns `address(0)` in two cases:
    ///      1. The name has expired — consistent with the resolution path, so there is
    ///         never a "the token is still there but the name is dead" split story
    ///      2. **The tokenId's version is not the current one** — this is what those 32
    ///         bits are for. After a name is revoked or re-registered post-expiry, the old
    ///         tokenId shares a canonical id with the new one, and without this check the
    ///         old token would read back the new holder.
    function ownerOf(uint256 tokenId) public view returns (address) {
        uint256 cid = tokenId & ~VERSION_MASK;
        Entry storage e = _entries[cid];
        if ((tokenId & VERSION_MASK) != e.version) return address(0);
        if (!_isLive(e)) return address(0);
        return e.owner;
    }

    // ---------------------------------------------------------------
    // Issuing and taking back names
    // ---------------------------------------------------------------

    /// @notice Issues an agent subname.
    /// @param duration In seconds. **This is the dead man's switch** — a short-lived name
    ///        lapses on its own.
    /// @return tokenId The tokenId, version bits included
    ///
    /// @dev Reverts if the name is taken and still live. **An expired name can be
    ///      re-registered**, and re-registering increments the version, which invalidates
    ///      the old token in one step (no need to sweep any per-holder state beyond the
    ///      balance).
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

        // **Both are required: a registrar AND an attestation.** The first version had
        // only `onlyRegistrar`, while the asymmetry table in `PLAN.md` said "issue a new
        // agent subname → face scan required". That sentence was false at the time; no
        // path in the contract required an attestation at all. Code review caught it.
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

        // Re-registration after expiry: burn the old token and bump the version, so the
        // old tokenId points at nothing from here on
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

    /// @notice Takes a name back. **This is the middle of the three revocation layers —
    ///         it kills one agent.**
    /// @dev No attestation of any kind. **A reduction must never be blocked** — when
    ///      something has gone wrong, hunting for your phone is the last thing you want to
    ///      do. Both the registry owner and the name's holder can do it. Afterwards
    ///      `getResolver` returns 0 immediately. The version increments, so a later
    ///      re-registration of this name is a new token.
    function revoke(string calldata label) external {
        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];
        if (!_isLive(e)) revert NameNotLive(cid | e.version);
        if (msg.sender != owner && msg.sender != e.owner) revert NotNameOwner();

        uint256 tokenId = cid | e.version;
        address holder = e.owner;

        // `owner` must be cleared: the token is burned here and the version has already
        // bumped, so leaving `owner` set would make a later `register` think there is
        // still an old token to burn (at a version that was never minted).
        // The cost is that `entryOf` can no longer name the former holder after a
        // revocation — which is why it goes into the event, where the subgraph can find it.
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

    /// @notice Renews. The act of pressing the dead man's switch again.
    /// @dev Registrar-only — renewal points in the **widening direction** (it extends how
    ///      long the agent stays alive).
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
        // The **remaining** term after renewal must also stay under the cap, otherwise
        // repeated renewals amount to no cap at all.
        if (next > uint64(block.timestamp) + MAX_DURATION) {
            revert DurationTooLong(next - uint64(block.timestamp), MAX_DURATION);
        }

        // Renewal extends the dead man's switch, **which is a widening**, so it needs an
        // attestation.
        _consumeAttestation(
            keccak256(abi.encode(RENEW_TYPEHASH, keccak256(bytes(label)), duration, nonce)),
            attestation
        );

        e.expiry = next;
        emit SubnameRenewed(nodeOf(label), old, next, cid | e.version);
    }

    // ---------------------------------------------------------------
    // What can be changed, and by whom
    // ---------------------------------------------------------------

    /// @notice Changes which policy pointer this agent reads. **Registry owner only.**
    ///
    /// @dev **This deliberately departs from normal ENS practice, and that departure is
    ///      the point of the design.** In standard ENS a name's holder can of course set
    ///      its own resolver. Here they cannot — because in Leash's model **a name is a
    ///      leash, not a possession: it governs its holder rather than belonging to them.**
    ///
    ///      The first version accepted `msg.sender == e.owner`. Today that is dormant
    ///      (subnames are issued to ADMIN), but the day a subname is issued to WALLET —
    ///      and "one wallet per agent" is an entirely natural usage — WALLET could
    ///      **repoint its own policy**, in direct contradiction with the measured
    ///      `roles(WALLET) = 0` in `docs/ensv2-sepolia.md` and with the premise that an
    ///      agent must not be able to change its own policy. Code review caught this
    ///      latent permission.
    ///
    ///      **Bounding this power honestly:** ADMIN can point the name at a different
    ///      policy **with no attestation**. That is deliberate — "swap in a stricter rule"
    ///      is the lightest of the three revocation layers and must not be blocked. The
    ///      cost is that ADMIN can also point at a **more permissive** policy — but that
    ///      policy must already be on the approval list (meaning a real human approved it
    ///      at some point), so the blast radius is bounded by "every approved policy", not
    ///      "arbitrary code".
    function setResolver(string calldata label, address resolver) external onlyOwner {
        Entry storage e = _requireLive(label);
        e.resolver = resolver;
        emit ResolverChanged(nodeOf(label), resolver, canonicalIdOf(label) | e.version);
    }

    /// @notice See `setResolver` — registry owner only, for the same reasons.
    function setSubregistry(string calldata label, address subregistry) external onlyOwner {
        Entry storage e = _requireLive(label);
        e.subregistry = subregistry;
        emit SubregistryChanged(nodeOf(label), subregistry, canonicalIdOf(label) | e.version);
    }

    // ---------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------

    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        isRegistrar[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    /// @dev Called by the parent after its `setSubregistry`, to tell us where we hang —
    ///      `getParent()` needs it. The value **does not affect resolution**; it only lets
    ///      an indexer reassemble the full name upwards.
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
    // Query helpers
    // ---------------------------------------------------------------

    /// @notice The label's canonical id — its labelhash with the low 32 bits zeroed.
    function canonicalIdOf(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label))) & ~VERSION_MASK;
    }

    /// @notice `namehash("<label>.leash.eth")` — the key used by the events and by
    ///         resolver records.
    /// @dev The parent is fixed, so one keccak against `PARENT_NODE` suffices; the full
    ///      recursion is unnecessary.
    function nodeOf(string memory label) public view returns (bytes32) {
        return keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @notice The digest to be attested for issuing a subname. The frontend, the backend
    ///         and the chain all compute it the same way.
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

    /// @notice The digest to be attested for a renewal.
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

    /// @notice The currently live tokenId (version bits included). 0 if the name does not
    ///         exist.
    function tokenIdOf(string calldata label) external view returns (uint256) {
        uint256 cid = canonicalIdOf(label);
        Entry storage e = _entries[cid];
        if (e.owner == address(0)) return 0;
        return cid | e.version;
    }

    /// @notice Fetches an agent name's full state in one call, saving round trips. Used by
    ///         both the frontend and the subgraph.
    function entryOf(string calldata label)
        external
        view
        returns (address nameOwner, address resolver, address subregistry, uint64 expiry, bool live)
    {
        Entry storage e = _entries[canonicalIdOf(label)];
        live = _isLive(e);
        // An expired name still reports its expiry and owner faithfully — the caller has
        // to be able to tell "existed once, then lapsed" from "never issued". The `live`
        // bool is the answer to whether it is usable.
        return (e.owner, e.resolver, e.subregistry, e.expiry, live);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IRegistry).interfaceId || id == type(IERC1155Singleton).interfaceId
            || super.supportsInterface(id);
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    function _isLive(Entry storage e) private view returns (bool) {
        return e.owner != address(0) && e.expiry > block.timestamp;
    }

    /// @dev Checks only that the name is still live. Authorisation is the caller's
    ///      modifier's job — `setResolver` / `setSubregistry` are `onlyOwner`, while
    ///      `revoke` has its own rule (owner **or** the name's holder, because revoking is
    ///      a reduction).
    function _requireLive(string calldata label) private view returns (Entry storage e) {
        uint256 cid = canonicalIdOf(label);
        e = _entries[cid];
        if (!_isLive(e)) revert NameNotLive(cid | e.version);
    }

    /// @dev A `.` inside a label produces a name that can never resolve — ENS resolution
    ///      walks one label at a time, and the single label `"a.b"` is not `a.b.leash.eth`.
    ///      Silently issuing a broken name is worse than reverting.
    function _requireNoDot(string calldata label) private pure {
        bytes calldata b = bytes(label);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == ".") revert LabelHasDot();
        }
    }

    /// @dev Where an attestation is spent. The digest wraps the EIP-712 domain (binding
    ///      chainId and this contract) and is marked permanently once used — the same
    ///      semantics as `PolicyApprovals`.
    function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
        if (attestationUsed[digest]) revert AttestationReused(digest);
        if (!attester.verify(digest, attestation)) revert NotAttested();
        attestationUsed[digest] = true;
    }

    /// @dev After an ERC-1155 transfer, `Entry.owner` has to follow — otherwise `ownerOf`
    ///      and the token balance tell two different stories. That is the price of
    ///      singleton semantics: the same fact lives in two places.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        super._update(from, to, ids, values);
        // For mint (from == 0) and burn (to == 0), register / revoke maintain Entry.owner
        // themselves
        if (from == address(0) || to == address(0)) return;
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 cid = ids[i] & ~VERSION_MASK;
            // A token at a stale version necessarily has a zero balance, so
            // `super._update` would already have reverted; this check is belt and braces —
            // never let a stale-version token rewrite the current Entry.
            if ((ids[i] & VERSION_MASK) != _entries[cid].version) continue;
            _entries[cid].owner = to;
        }
    }
}
