// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LeashStorage } from "./LeashStorage.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";
import { IPolicy, SpendContext } from "./IPolicy.sol";
import { Reason } from "./Reason.sol";

/// @title LeashAccount — the agent's only spending path
/// @notice An EIP-7702 delegate implementation. Before any **agent-initiated** transfer,
///         the delegated EOA must: authorise the agent → walk three ENS hops to a policy →
///         check it against the approval list → pass the policy. (The wallet's own key is
///         not constrained — see below.)
///
/// @dev **Do not call it "the only spending path".** EIP-7702 constrains only calls *to*
///      that EOA; the WALLET private key can still sign `USDC.transfer` directly, and the
///      policy path never executes. This is both the boundary and the **escape hatch** —
///      the wallet's owner can always retrieve their own funds.
///
///      **There is no `initialize()`.** The global configuration is `immutable`, burned
///      into the bytecode, so the window after delegation where storage is still blank has
///      nothing to race for. Per-EOA authority is always `msg.sender == address(this)`, and
///      only the wallet's private key can make that EOA send a transaction.
contract LeashAccount {
    using LeashStorage for LeashStorage.AccountStorage;

    // --- burned into the bytecode ---

    /// @notice ENSv2's .eth registry. The start of resolution, and where the "kill
    ///         everything" lever sits.
    address public immutable ETH_REGISTRY;

    /// @notice The approval list. **immutable** — see the C1 notes on `PolicyApprovals`.
    IPolicyApprovals public immutable APPROVALS;

    /// @notice The attestation source for widening. **immutable**.
    IAttester public immutable ATTESTER;

    /// @notice **The address the impl itself was deployed at.**
    /// @dev A small trap specific to 7702: inside one piece of code, `address(this)` and
    ///      "where this code lives" are **two different values**. When the delegate runs,
    ///      `address(this)` is the EOA, whereas an `immutable` was burned into the bytecode
    ///      at deploy time — so `SELF` remembers the impl's address.
    ///
    ///      An attestation digest needs **both**: `address(this)` binds *which wallet*,
    ///      `SELF` binds *which impl version*. Without `SELF`, once a wallet redelegates to
    ///      a new version, an attestation from the old version could be replayed (the new
    ///      version may use a different ERC-7201 namespace and so cannot see the old
    ///      `attestationUsed` records).
    address public immutable SELF;

    string public constant PARENT_LABEL = "leash";

    /// @notice `namehash("leash.eth")`. `bindAgent` uses it to verify node and label agree.
    bytes32 public constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @notice The gas cap on calling a policy. Exceeding it fails closed (reason code 12).
    /// @dev A deliberate cap: a policy that can burn all the gas is a DoS switch.
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
    /// @dev Evidence that this EOA now delegates to LeashAccount. **The subgraph's
    ///      template trigger** — 7702 delegation emits no log, so this is the only way an
    ///      indexer learns which address to watch.
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

    /// @dev `node` is deliberately not indexed — the three indexed slots go to `agent` /
    ///      `payee` / `token`, the fields subgraph queries filter on most (see
    ///      `docs/events.md`).
    event PolicyResolved(bytes32 indexed node, address indexed policy, bool approved);
    event SpendExecuted(
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        address policy,
        uint256 spentAfter,
        uint256 limit,
        uint64 periodEnd
    );
    event SpendBlocked(
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        uint8 reason,
        address policy,
        uint256 spentSoFar,
        uint256 limit
    );

    error NotSelf();
    error NotAttested();
    error AttestationReused(bytes32 digest);
    error UnknownSelector();
    error NodeLabelMismatch(bytes32 expected, bytes32 got);
    error AlreadyBound();
    error NotBoundAgent();
    error RevokedNeedsRestore();
    error NotSelfOrAgent();
    error NotTighter();
    error Reentrant();
    error BadTarget();
    error ZeroAmount();
    error TransferFailed();

    /// @dev The only form of per-EOA authority. Inside a delegate, `address(this)` is that
    ///      EOA, and only its private key can make it send a transaction — so this *is*
    ///      "the wallet itself".
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

    /// @notice **Mandatory.** A plain ETH transfer is a call to the delegate with empty
    ///         calldata; without this function, a delegated wallet can no longer receive
    ///         ETH sent with adequate gas.
    /// @dev The guarantee has a ceiling: the old-style `.transfer()` / `.send()` transfers
    ///      that carry only the 2300-gas stipend **still fail** against a 7702-delegated
    ///      wallet — after delegation every call goes through a dispatcher first, and that
    ///      fixed overhead alone exceeds 2300 gas, with or without a `receive()`. What this
    ///      rescues is plain value transfers with adequate gas, not those two throttled
    ///      APIs.
    receive() external payable { }

    /// @notice An unknown selector reverts explicitly rather than being swallowed.
    /// @dev This account **does not** do general-purpose call forwarding (see the YAGNI
    ///      table in the spec).
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

    /// @notice `namehash("<label>.leash.eth")`.
    /// @dev The parent is fixed, so one keccak against `PARENT_NODE` suffices — two keccaks
    ///      in total, not a loop.
    function nodeFor(string memory label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
    }

    function paused() external view returns (bool) {
        return LeashStorage.layout().paused;
    }

    /// @notice Binds an agent. **Points in the reducing direction, so no attestation** —
    ///         it grants authority starting from zero, and the *content* of that authority
    ///         is decided entirely by the ENS side (ADMIN) and the approval list (a human).
    ///
    /// @dev `node` and `label` **must agree**. `node` is not only the resolver's key; it is
    ///      also the key for `rules` / `payees` / `spent` — a mismatch would let this agent
    ///      spend name A's budget while being judged by name B's policy, and since
    ///      `AgentBound` carries no label, that would be invisible offchain.
    function bindAgent(address agent, bytes32 node, string calldata label) external onlySelf {
        bytes32 expected = nodeFor(label);
        if (node != expected) revert NodeLabelMismatch(expected, node);

        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        LeashStorage.AgentBinding storage b = $.bindings[agent];
        // Revert if it already exists: otherwise "rebind for free after a revocation"
        // would sidestep what the frozen document says about reason code 2 (restoring
        // requires a face scan). This guard alone is not sufficient against that attack —
        // `unbindAgent` also has to refuse a revoked binding, since it would otherwise
        // delete `node` and quietly reopen this branch. See `unbindAgent`. With both
        // guards in place, the only remedy left through this path is "bound to the wrong
        // name" — `unbindAgent` then `bindAgent`, both reductions — on an agent that was
        // never revoked.
        if (b.node != bytes32(0)) revert AlreadyBound();

        b.node = node;
        b.label = label;
        emit AgentBound(agent, node);

        // **Emit `Leashed` on the first bind.**
        //
        // EIP-7702 delegation **emits no log at all**, so a subgraph has no factory event
        // to trigger a template from — it does not know which EOA addresses to watch. This
        // is that trigger. (`Leashed` was already in the frozen schema; this gives it a
        // definite moment of emission.)
        // The demo additionally hardcodes the wallet address in subgraph.yaml as a
        // fallback; see sprint item 9.
        // The `b.node == 0` branch was already established above (otherwise AlreadyBound),
        // so anything reaching here is this agent's first bind.
        // But `Leashed` is a **wallet-level** fact and must not be re-emitted for every
        // agent bound — a separate flag remembers it.
        if (!$.leashedEmitted) {
            $.leashedEmitted = true;
            emit Leashed(node, address(this), SELF);
        }
    }

    /// @notice Unbinds completely. **A reduction, entirely free — unless the binding is
    ///         revoked, in which case it is refused.**
    /// @dev This is the remedy for "bound to the wrong name". Once unbound the agent can do
    ///      nothing, and it can be `bindAgent`-ed again to the correct name — at no point
    ///      in between does it hold more authority than before.
    ///
    ///      A revoked binding is the one case this must refuse: deleting it would clear
    ///      `node` back to zero, and `bindAgent`'s `AlreadyBound` guard only fires while
    ///      `node` is non-zero. `revoke → unbind → bind` would then restore full authority
    ///      to a revoked agent with no attestation at all, defeating the reason-code-2
    ///      requirement that restoring needs a face scan. Refusing costs nothing in
    ///      capability: a revoked agent is already powerless (`spend` reaches step 2b and
    ///      emits `SpendBlocked(AGENT_REVOKED)`), so this only forfeits storage cleanup,
    ///      never a capability. The only route out of `revoked` is `restoreAgent`, which is
    ///      attested. The legitimate use of this function — correcting a mis-binding on an
    ///      agent that was never revoked — is unaffected.
    function unbindAgent(address agent) external {
        _requireSelfOrAgent(agent);
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        if ($.bindings[agent].revoked) revert RevokedNeedsRestore();
        delete $.bindings[agent];
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice Revokes an agent (the binding is kept and marked revoked). **A reduction,
    ///         no attestation.**
    /// @dev How it differs from `unbindAgent`: node/label are kept, so `spend` reaches step
    ///      2b and emits an indexable `SpendBlocked(AGENT_REVOKED)` — the agent can query
    ///      the subgraph and learn why it is stuck. `unbindAgent` instead makes it "never
    ///      bound", which reverts outright at 2a.
    function revokeAgent(address agent) external {
        _requireSelfOrAgent(agent);
        LeashStorage.layout().bindings[agent].revoked = true;
        emit AgentRevoked(agent, msg.sender);
    }

    /// @notice Restores a revoked agent. **A widening — both conditions required.**
    /// @dev All three parameters go into the digest, so an attestation issued for one
    ///      restoration cannot be redirected to restore a different agent or to bind it to
    ///      a different name.
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

    /// @notice Pauses everything. **The wallet itself, or any bound agent that has not
    ///         been revoked, can press it.**
    /// @dev Hitting the brake can only make the system stricter; requiring a permission for
    ///      it does the attacker a favour at exactly the moment things go wrong.
    function pause() external {
        if (msg.sender != address(this)) {
            LeashStorage.AgentBinding storage b = LeashStorage.layout().bindings[msg.sender];
            if (b.node == bytes32(0) || b.revoked) revert NotBoundAgent();
        }
        LeashStorage.layout().paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses. **The wallet itself only, and no attestation.**
    /// @dev **It must not require an attestation.** Any agent can `pause` for free, so if
    ///      `unpause` cost a face scan, a compromised agent could force the holder to scan
    ///      their face over and over — that is a DoS. A free brake demands a free release,
    ///      both controlled by the wallet itself. The frozen document also lists reason
    ///      code 10 as "an ADMIN's routine operation", needing no scan.
    ///
    ///      The frozen signature of `Unpaused` has an `attestationHash` field — we send
    ///      `bytes32(0)`, and the subgraph must read 0 as "an unpause that needs no
    ///      attestation", not as missing data.
    function unpause() external onlySelf {
        LeashStorage.layout().paused = false;
        emit Unpaused(msg.sender, bytes32(0));
    }

    function _requireSelfOrAgent(address agent) private view {
        if (msg.sender != address(this) && msg.sender != agent) revert NotSelfOrAgent();
        if (LeashStorage.layout().bindings[agent].node == bytes32(0)) revert NotBoundAgent();
    }

    /// @notice Allow-lists a payee. **A widening — both conditions required.**
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

    /// @notice Reads the current rule for (node, token).
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

    /// @notice Sets a rule. **A widening — both conditions required.**
    /// @dev `epoch` increments automatically when `period` changes. **Changing `period`
    ///      alone already changes the bucket** — the low bits of `_bucket` are simply
    ///      `timestamp / period`, independent of `epoch`. What `epoch` actually provides is
    ///      **key-space isolation**: sitting in the high bits of `_bucket`, it removes the
    ///      risk that a new generation's period happens to compute the same bucket as the
    ///      old one, giving each generation's ledger its own addresses, uncontaminated and
    ///      unoverwritten by the previous one.
    ///      Nor does "wiping the ledger always costs an attestation" rest on `epoch`
    ///      itself — it holds because this is the only function in the whole contract that
    ///      writes `period`, and `tightenRule`'s `_isTighter` check guarantees it never
    ///      touches `period`, so the only path that can change the bucket is this one,
    ///      which requires an attestation.
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
        // All-zero means this (node, token) has never been written by setRule — there is
        // no old ledger to wipe, so it does not count as "changing the period". Without
        // this check, the very first setRule would read epoch 0 as "period changed from its
        // default 0 to rule.period" and bump it for nothing, contradicting
        // `test_setRule_bumps_epoch_only_when_period_changes`.
        bool exists = cur.allowed || cur.txLimit != 0 || cur.periodLimit != 0 || cur.period != 0
            || cur.windowStart != 0 || cur.windowEnd != 0 || cur.epoch != 0;
        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;
        uint32 epoch = cur.epoch;
        // "Did it widen?" has to be decided before the write, comparing old against new —
        // compare after writing and you are comparing `cur` with itself, which is always
        // true. It uses `_isTighterIgnoringEpoch` rather than `_isTighter`; the reason is
        // in that function's own notes: as far as `setRule` is concerned, `rule.epoch` is
        // not covered by the attestation and is never trusted, so comparing it against
        // `cur.epoch` would misread the irrelevant noise of "epoch has been bumped before"
        // as a widening.
        // `_isTighterIgnoringEpoch` returns false for any old rule that is currently
        // disabled ("already off, nothing stricter it could become"), so the first
        // enable (or a re-enable) always lands in !tighterOrEqual and `LimitRaised` is
        // emitted alongside `TokenAllowed` — which is exactly right for "open a token with
        // no cap": both events belong.
        bool tighterOrEqual = _isTighterIgnoringEpoch(cur, rule);
        if (exists && cur.period != rule.period) epoch += 1; // new period = a new ledger

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.period = rule.period;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        cur.epoch = epoch;

        bytes32 h = keccak256(attestation);
        if (!wasAllowed && rule.allowed) emit TokenAllowed(node, token, h);
        // "Raised" fires only on an actual widening — a byte-identical (or stricter)
        // setRule must not emit an event named after loosening. The test is the same
        // subset/magnitude criterion `tightenRule` uses (`_isTighterIgnoringEpoch`) rather
        // than an ad-hoc "did periodLimit grow?" rule, which would miss a widened
        // window/period and reopen exactly the hole `tightenRule` was written to close.
        if (!tighterOrEqual) {
            emit LimitRaised(node, token, oldLimit, rule.periodLimit, rule.period, h);
        }
    }

    /// @notice Tightens a rule. **A reduction — `address(this)` only, no attestation.**
    /// @dev Requires that **every field is weakly monotonically tightened**. That turns
    ///      "stricter" into a checkable assertion, whereas a pair of raise/lower functions
    ///      would leave window and period uncovered — and precisely those omissions could
    ///      then be used to widen.
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
        // `period` and `epoch` are deliberately left alone — see `_isTighter`

        if (wasAllowed && !rule.allowed) emit TokenRemoved(node, token, msg.sender);
        if (oldLimit != rule.periodLimit) {
            emit LimitLowered(node, token, oldLimit, rule.periodLimit, msg.sender);
        }
    }

    /// @notice Removes a payee. **A reduction, no attestation.**
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

    /// @notice The digest `setRule` will consume. Needed because a caller has to know what
    ///         to have signed, and with a real attester there is no way to guess it.
    /// @dev `epoch` is deliberately not in `RULE_TYPEHASH` and so is not here either — see
    ///      `_isTighterIgnoringEpoch` for why `setRule` never trusts the caller's value.
    function ruleDigest(
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce
    ) public view returns (bytes32) {
        return _digest(
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
            )
        );
    }

    /// @notice The digest `restoreAgent` will consume.
    function restoreDigest(address agent, bytes32 node, string calldata label, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return _digest(
            keccak256(
                abi.encode(RESTORE_TYPEHASH, SELF, agent, node, keccak256(bytes(label)), nonce)
            )
        );
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev Where an attestation is spent. The digest binds both this wallet
    ///      (`address(this)` goes into the domain) and this impl version (`SELF` goes into
    ///      the structHash). Marked permanently once used.
    function _consumeAttestation(bytes32 structHash, bytes calldata attestation) private {
        bytes32 d = _digest(structHash);
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();
        if ($.attestationUsed[d]) revert AttestationReused(d);
        if (!ATTESTER.verify(d, attestation)) revert NotAttested();
        $.attestationUsed[d] = true;
    }

    /// @dev The definition of **weakly monotonic tightening**. Each clause has its own
    ///      dedicated test.
    function _isTighter(LeashStorage.TokenRule storage old_, LeashStorage.TokenRule calldata new_)
        private
        view
        returns (bool)
    {
        if (old_.allowed && !new_.allowed) return true; // switching it off is always stricter
        if (!old_.allowed) return false; // already off; nothing stricter it could become
        // `period` and `epoch` must not move: changing `period` changes the bucket and
        // zeroes the running total — so "lower the cap" would actually increase what can be
        // spent. Wiping the ledger goes only through setRule, which needs an attestation.
        if (new_.period != old_.period || new_.epoch != old_.epoch) return false;
        return _lteOrUnlimited(new_.txLimit, old_.txLimit)
            && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
            && _windowIsSubset(new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd);
    }

    /// @dev The same criterion as `_isTighter`, but **ignoring `epoch` entirely** — only
    ///      `setRule` uses it, to decide whether to emit `LimitRaised`. `RULE_TYPEHASH` has
    ///      no `epoch` field, so the attestation does not cover it, and nowhere else does
    ///      `setRule` trust the caller's `rule.epoch` (see the epoch computation in
    ///      `setRule`, which only counts up from `cur.epoch`). Comparing with `_isTighter`
    ///      directly would mean that once `epoch` has been bumped (period changed once),
    ///      any later byte-identical replay would fail the comparison — the caller's
    ///      customary `epoch: 0` against a now-nonzero `cur.epoch` — and be misread as a
    ///      widening, emitting a spurious `LimitRaised`.
    function _isTighterIgnoringEpoch(
        LeashStorage.TokenRule storage old_,
        LeashStorage.TokenRule calldata new_
    ) private view returns (bool) {
        if (old_.allowed && !new_.allowed) return true;
        if (!old_.allowed) return false;
        if (new_.period != old_.period) return false; // same reason as `_isTighter`, minus epoch
        return _lteOrUnlimited(new_.txLimit, old_.txLimit)
            && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
            && _windowIsSubset(new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd);
    }

    /// @dev `0 = unlimited`, so the comparison inverts:
    ///      `0 → 100` tightens (true); `100 → 0` widens (false); `100 → 50` tightens.
    ///      **This is the easiest line in the file to get backwards.**
    function _lteOrUnlimited(uint256 new_, uint256 old_) private pure returns (bool) {
        if (old_ == 0) return true; // was unlimited; no value (0 included) is wider
        if (new_ == 0) return false; // was finite, now unlimited = a widening
        return new_ <= old_;
    }

    /// @dev The new set of minutes must be a subset of the old one. Three cases:
    ///      - The old window is all day (`start == end`) → any new window tightens
    ///      - The new window is all day and the old one is not → a widening
    ///      - Both are bounded intervals → check the subset minute by minute
    ///
    ///      **The O(1440) loop is deliberate; no inequality juggling.** `pure`/`view` means
    ///      "writes no state", not "free" — this loop is called from `tightenRule`, which is
    ///      external and state-changing, so the gas is really paid in a transaction. The two
    ///      common cases ("old is all day", "new is all day and old is not") return early
    ///      and are O(1); the loop only pays in full when both are bounded intervals and the
    ///      new one really is a subset of the old (confirming that requires all 1440
    ///      minutes) — measured at about 480k gas
    ///      (`test_a_narrower_overnight_window_is_tightening`). `tightenRule` is a
    ///      reduction, run a handful of times a day at most, and paying that gas on Sepolia
    ///      is immaterial. An inequality-based overnight subset test is very easy to get
    ///      backwards, and getting it backwards produces **no revert and no error** — it
    ///      just silently widens the rule. Spending the gas to eliminate a bug that would
    ///      never be noticed is a good trade.
    function _windowIsSubset(uint16 ns, uint16 ne, uint16 os, uint16 oe)
        private
        pure
        returns (bool)
    {
        if (os == oe) return true; // old window is all day
        if (ns == ne) return false; // new window is all day and the old one was not
        for (uint16 m = 0; m < 1440; ++m) {
            if (_inWindow(m, ns, ne) && !_inWindow(m, os, oe)) return false;
        }
        return true;
    }

    /// @dev Same semantics as `StandardPolicy._inWindow`. `start > end` crosses midnight.
    function _inWindow(uint16 minuteOfDay, uint16 start, uint16 end) private pure returns (bool) {
        if (start == end) return true;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }

    /// @dev The key into `spent`. `epoch` occupies the high bits and the period index the
    ///      low bits, so neither contaminates the other (`period` is at least 1 second, and
    ///      `timestamp / 1` is far below `2^224`).
    ///      When `period == 0` every spend accumulates into one bucket = a lifetime
    ///      allowance that never resets.
    function _bucket(LeashStorage.TokenRule storage r) private view returns (uint256) {
        uint256 hi = uint256(r.epoch) << 224;
        return r.period == 0 ? hi : hi | (block.timestamp / r.period);
    }

    /// @notice Resolves, from ENS, which policy this name must satisfy. Returns
    ///         `address(0)` if it does not resolve.
    ///
    /// @dev **Three hops, and each returns a different number of bytes:**
    ///
    ///      | Hop | Call | Expected returndata |
    ///      |---|---|---|
    ///      | 1 | `ETH_REGISTRY.getSubregistry("leash")` | 32 |
    ///      | 2 | `LeashRegistry.getResolver(label)` | 32 |
    ///      | 3 | `LeashResolver.resolve(dns, addr(node))` | **96** |
    ///
    ///      Hop three returns `bytes`, whose ABI encoding is offset (32) + length (32) +
    ///      inner (32). **Check it for `== 32` and the happy path never succeeds** — while
    ///      the reason code says `NO_POLICY` ("ENS has no policy pointer"), which sends you
    ///      to debug entirely the wrong thing.
    ///
    ///      All three use low-level `staticcall` and each checks its own expected length:
    ///      ENS's contracts are still in their Immunefi audit window (through 09-14), so
    ///      addresses may move and behaviour may change. Another contract reverting must not
    ///      wedge this account — failing to resolve is `NO_POLICY`, no money moves, and that
    ///      is the safe default.
    ///
    ///      **The right length does not mean the right structure, and no externally
    ///      returned data is ever passed to `abi.decode`.** `abi.decode` reverts on
    ///      malformed input (a bad offset/length in the header, or an `address` whose high
    ///      12 bytes are not clean) rather than returning a failure value — which would let
    ///      a broken (or malicious) ENS contract returning right-length, wrong-content data
    ///      make `resolvePolicy` revert, breaking the "never reverts" guarantee.
    ///      So all three hops read words in assembly and validate structure and padding
    ///      themselves; the details are in `_wordToAddress`.
    ///
    ///      This path is also the implementation of the three revocation layers: hop1
    ///      returning 0 = everything halts, hop2 returning 0 = this one agent dies (revoked
    ///      or `expiry` lapsed), hop3 returning 0 = the swap-the-rules layer cleared the
    ///      pointer.
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
        // 96 = offset(32) + length(32) + inner(32). **Checking the total length alone is
        // not enough** — the right length with a forged header (an offset that is not 0x20,
        // say) still makes `abi.decode(ret, (bytes))` revert, breaking the "never reverts"
        // guarantee. (Measured on 2026-09-08 with an isolated forge test: `abi.decode`
        // really does revert on this kind of malformed input; it is not a theoretical
        // risk.) So no externally returned bytes are ever passed to `abi.decode`; we read
        // the three words in assembly and validate the structure ourselves.
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
        // The policy must not be this account — the same authority-confusion problem; see
        // the BadTarget guards in `spend`
        if (policy == address(this)) return address(0);
        return policy;
    }

    /// @dev The per-hop gas cap. Breakage on the ENS side must not drag us down with it.
    uint256 private constant HOP_GAS = 100_000;

    function _staticAddress(address target, bytes memory cd) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall{ gas: HOP_GAS }(cd);
        if (!ok || ret.length != 32) return address(0);
        // Again, no `abi.decode` on externally returned data — same reason as hop three;
        // see the notes on `_wordToAddress` below.
        uint256 word;
        assembly {
            word := mload(add(ret, 0x20))
        }
        return _wordToAddress(word);
    }

    /// @dev Reads a 32-byte word as an address, **validating that the high 12 bytes are
    ///      zero ourselves**.
    ///
    ///      Two options are both unusable here:
    ///      - `abi.decode(bytes, (address))` does check the high bits and reverts when they
    ///        are dirty (verified by measurement) — but `resolvePolicy`'s contract is "never
    ///        reverts", and an ENS contract returning dirty data would wedge the whole
    ///        account.
    ///      - Truncating the word to `uint160` in assembly (`address(uint160(word))`) does
    ///        not revert, but does not validate either — a resolver returning garbage in the
    ///        high bits would be silently truncated into an address that looks legitimate
    ///        and is not remotely what was intended, and then allowed through.
    ///
    ///      Neither is safe, so we do the check ourselves: dirty high bits are treated as
    ///      `address(0)` (sharing the same "did not resolve" signal as every other hop1 /
    ///      hop2 / hop3 failure, so the caller has nothing extra to distinguish), and only a
    ///      clean word is truncated and returned. **This is the only place padding is
    ///      validated** — the callers (`resolvePolicy`, `_staticAddress`) trust the value
    ///      returned here and do not re-check it, so there is no duplicated logic that would
    ///      have to be fixed in two places.
    function _wordToAddress(uint256 word) private pure returns (address) {
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev DNS wire format: `<len><label>...<len>eth<0>`.
    ///      The parent is always `leash.eth`, so only the first segment varies.
    ///      Measured: `vendors.leash.eth` = `0x0776656e646f7273056c656173680365746800`
    function _dnsEncode(string memory label) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, hex"056c656173680365746800");
    }

    /// @notice **The agent's only spending path.**
    ///
    /// @dev `node` and `label` are not supplied by the caller; they are read from
    ///      `bindings[msg.sender]` — which eliminates an entire class of "node and label
    ///      disagree" validation.
    ///
    ///      **Blocked ≠ revert.** A policy violation means: no transfer, emit
    ///      `SpendBlocked`, return normally — because the subgraph has to be able to index
    ///      *why* it was blocked. Only **2a (the caller is not a bound agent at all)**
    ///      reverts; that is not a policy decision, it is an intrusion. **2b (bound but
    ///      revoked) does not revert** — revocation is an administrative act, and that agent
    ///      deserves to be able to look up why it is stuck (logs from a reverted call are
    ///      discarded).
    function spend(address token, address payee, uint256 amount) external {
        LeashStorage.AccountStorage storage $ = LeashStorage.layout();

        // 1. Reentrancy lock — the first line of defence, before even checking whether
        //    this is a bound agent.
        if ($.entered) revert Reentrant();
        $.entered = true;

        // 2a. Is it bound? If not, revert — this is an intrusion, not a policy decision.
        LeashStorage.AgentBinding storage b = $.bindings[msg.sender];
        if (b.node == bytes32(0)) revert NotBoundAgent();
        bytes32 node = b.node;

        // Guards: token / payee must not point back at this account or at 0, and token
        // must have code. Placed after authorisation and before policy — these are
        // malformed inputs, not policy violations.
        if (amount == 0) revert ZeroAmount();
        if (token == address(this) || payee == address(this)) revert BadTarget();
        if (token == address(0) || payee == address(0)) revert BadTarget();
        if (token.code.length == 0) revert BadTarget();

        // The blocking branches (2b/3/4/5) share one pair of "spent so far / limit"
        // values — `token` has passed the guards by now, so the lookup is safe. Looking it
        // up once here and passing values down rather than a storage reference keeps
        // `_blocked` from recomputing it: without `--via-ir`, recomputing pushes that
        // function into stack-too-deep (measured, not hypothetical).
        LeashStorage.TokenRule storage r = $.rules[node][token];
        uint256 spentSoFar = $.spent[node][token][_bucket(r)];

        // 2b. Revoked? **Do not revert** — emit an indexable event.
        if (b.revoked) {
            _blocked(
                $,
                node,
                payee,
                token,
                amount,
                Reason.AGENT_REVOKED,
                address(0),
                spentSoFar,
                r.periodLimit
            );
            return;
        }

        // 3. Paused
        if ($.paused) {
            _blocked(
                $, node, payee, token, amount, Reason.PAUSED, address(0), spentSoFar, r.periodLimit
            );
            return;
        }

        // 4. The three ENS hops
        address policy = resolvePolicy(node, b.label);
        if (policy == address(0)) {
            _blocked(
                $,
                node,
                payee,
                token,
                amount,
                Reason.NO_POLICY,
                address(0),
                spentSoFar,
                r.periodLimit
            );
            return;
        }

        // 5. The approval list — **the event is emitted here, carrying the real value**.
        //    Placed after the check, that field could only ever be true — and "the pointer
        //    aims at an unapproved policy" is exactly the one onchain signal that the ADMIN
        //    key has been stolen.
        bool approved = APPROVALS.isApproved(policy);
        emit PolicyResolved(node, policy, approved);
        if (!approved) {
            _blocked(
                $,
                node,
                payee,
                token,
                amount,
                Reason.POLICY_NOT_APPROVED,
                policy,
                spentSoFar,
                r.periodLimit
            );
            return;
        }

        // Steps 6-13 are split into a separate function: holding the locals for ctx
        // construction + the policy call + the transfer all inside one `spend` blows up
        // with "stack too deep" without `--via-ir` (measured, not hypothetical). The split
        // is purely a compiler constraint, not a layering decision.
        _execute($, node, token, payee, amount, policy);
    }

    /// @dev The second half of `spend`: build the `SpendContext`, ask the policy under a
    ///      gas cap, **write the ledger before transferring**, emit the event.
    ///      `msg.sender` carries over from the outer call — a private function call is not
    ///      an external call and does not change `msg.sender`.
    function _execute(
        LeashStorage.AccountStorage storage $,
        bytes32 node,
        address token,
        address payee,
        uint256 amount,
        address policy
    ) private {
        // 6-7. Build the SpendContext — the policy never touches the account's storage;
        //      it sees only this bundle of inputs.
        LeashStorage.TokenRule storage r = $.rules[node][token];
        uint256 bucket = _bucket(r);
        uint256 spentSoFar = $.spent[node][token][bucket];

        // 8. Call the policy: capped gas, checked return length, fail closed.
        uint8 reason = _askPolicy(
            policy,
            SpendContext({
                agent: msg.sender,
                payee: payee,
                token: token,
                amount: amount,
                tokenAllowed: r.allowed,
                payeeAllowed: $.payees[node][token][payee],
                txLimit: r.txLimit,
                periodLimit: r.periodLimit,
                spentSoFar: spentSoFar,
                nowTs: uint64(block.timestamp),
                windowStart: r.windowStart,
                windowEnd: r.windowEnd
            })
        );

        // 9. Blocked — shares one path with 2b/3/4/5 rather than pasting the
        //    "unlock + emit SpendBlocked" logic again (a duplication review caught). `$` is
        //    already in scope here, so calling `_blocked` costs nothing extra on the stack.
        if (reason != Reason.OK) {
            _blocked($, node, payee, token, amount, reason, policy, spentSoFar, r.periodLimit);
            return;
        }

        // 10. **Write the ledger first** — before the external call. The reentrancy lock
        //     is the first line of defence and this is the second; it takes both failing to
        //     cause harm (a transfer that can reenter but a ledger that only counts once).
        uint256 spentAfter = spentSoFar + amount;
        $.spent[node][token][bucket] = spentAfter;

        // Steps 11-12 are split out for the same reason: once `_execute` is holding the
        // locals for ctx construction and the policy call, adding the transfer's and the
        // event's locals on top hits stack-too-deep again.
        _transferAndEmit(node, token, payee, amount, policy, r.period, r.periodLimit, spentAfter);

        // 13. Unlock
        $.entered = false;
    }

    /// @dev The last stretch of `_execute`: transfer, then emit `SpendExecuted`. It exists
    ///      purely to keep `_execute` from holding too many locals (stack too deep; see the
    ///      notes above).
    function _transferAndEmit(
        bytes32 node,
        address token,
        address payee,
        uint256 amount,
        address policy,
        uint64 period,
        uint256 periodLimit,
        uint256 spentAfter
    ) private {
        // 11. The transfer. **Strict: exactly 32 bytes, and it must be true.** Not
        //     SafeERC20's permissive variant — the compatibility permissiveness buys is
        //     paid for with "reported success, transferred nothing".
        //
        //     Same approach as `_askPolicy`: never `abi.decode(ret, (bool))` on externally
        //     returned data. A token that returns 32 bytes that are not 0/1 (the integer 2,
        //     say) would make `abi.decode` revert with a `Panic` and bury the real reason
        //     for the failure. Instead we read it as a `uint256` and judge it ourselves,
        //     attributing every failure to `TransferFailed()`.
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", payee, amount));
        if (!ok || ret.length != 32) revert TransferFailed();
        uint256 rawReturn = abi.decode(ret, (uint256));
        if (rawReturn != 1) revert TransferFailed();

        // 12. Events
        uint64 periodEnd = period == 0 ? 0 : uint64(((block.timestamp / period) + 1) * period);
        emit SpendExecuted(
            node, msg.sender, payee, token, amount, policy, spentAfter, periodLimit, periodEnd
        );
    }

    /// @dev Calls the policy under a gas cap, treating any anomaly as reason code 12 (the
    ///      policy is broken, not "the policy said no"). **A policy that can burn all the
    ///      gas is a DoS switch**, so the cap is deliberate; a return length other than 32
    ///      fails closed just the same.
    ///
    ///      The `raw > type(uint8).max` clamp is load-bearing and **fails open without
    ///      it**: a policy returning 256 truncates to 0, which is `Reason.OK`, and the
    ///      transfer executes. A mutation sweep found exactly that — deleting the clamp
    ///      left every test green — so it is now pinned by
    ///      `test_policy_return_over_uint8_max_is_clamped_to_policy_failed`, which fails
    ///      when the clamp is removed.
    function _askPolicy(address policy, SpendContext memory ctx) private returns (uint8) {
        (bool ok, bytes memory ret) =
            policy.call{ gas: POLICY_GAS }(abi.encodeCall(IPolicy.check, (ctx)));
        if (!ok || ret.length != 32) return Reason.POLICY_FAILED;
        uint256 raw = abi.decode(ret, (uint256));
        if (raw > type(uint8).max) return Reason.POLICY_FAILED;
        return uint8(raw);
    }

    /// @dev The shared blocking path: release the reentrancy lock, emit `SpendBlocked`.
    ///      **No revert** — the evidence of a policy violation is that money did not move,
    ///      not that the transaction went red.
    ///      `spentSoFar` / `limit` are computed by the caller and passed in rather than
    ///      looked up again here; the reason is in the notes inside `spend`
    ///      (stack too deep).
    function _blocked(
        LeashStorage.AccountStorage storage $,
        bytes32 node,
        address payee,
        address token,
        uint256 amount,
        uint8 reason,
        address policy,
        uint256 spentSoFar,
        uint256 limit
    ) private {
        $.entered = false;
        emit SpendBlocked(node, msg.sender, payee, token, amount, reason, policy, spentSoFar, limit);
    }
}
