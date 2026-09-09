// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy } from "./IPolicy.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";

/// @title LeashResolver — hangs a policy address under an ENS name
/// @notice Each agent is an ENS name (`vendors.acme.eth`), and that name's resolver
///         record holds which policy the agent must satisfy. `LeashAccount` walks this
///         resolution before every agent-initiated payment; if it does not resolve, that is
///         reason code 3 and no money moves. (The wallet's own key is not constrained by
///         any of this — see the notes on `LeashAccount`.)
///
/// @dev **Only ENSIP-10 `resolve(bytes,bytes)` is implemented.** That is not laziness, it
///      is what measurement showed: the minimal resolvers on ENSv2 Sepolia (the one
///      behind `nick.eth`, for instance) **do not have** `addr(bytes32)` or
///      `text(bytes32,string)` as external functions at all — calling them reverts, and
///      `supportsInterface` returns false across the board. The ENSv2 read convention is
///      the single `resolve()` entry point; the legacy interfaces belong to the old world.
///      Full measurements in `docs/ensv2-sepolia.md`.
///
///      The other measured fact that makes onchain enforcement possible: `resolve()`
///      **returns data directly** and does not revert with `OffchainLookup`. So a contract
///      can complete the registry walk and the record read inside the transaction,
///      **with no CCIP-read gateway**. Without that, the whole design collapses.
contract LeashResolver {
    // --- selectors of the inner calls ENSIP-10 supports (compile-time constants, not
    //     transcribed from memory) ---
    bytes4 private constant SEL_ADDR = bytes4(keccak256("addr(bytes32)"));
    bytes4 private constant SEL_ADDR_COIN = bytes4(keccak256("addr(bytes32,uint256)"));
    bytes4 private constant SEL_TEXT = bytes4(keccak256("text(bytes32,string)"));
    bytes4 private constant SEL_RESOLVE = bytes4(keccak256("resolve(bytes,bytes)"));
    bytes4 private constant SEL_ERC165 = bytes4(keccak256("supportsInterface(bytes4)"));

    /// @dev ENS's coin type for the EVM. `addr(node, 60)` is equivalent to `addr(node)`.
    uint256 private constant COIN_TYPE_ETH = 60;

    address public owner;

    /// @notice The approval list. **`immutable`, with no setter** — this is the other
    ///         half of the C1 fix.
    /// @dev The first version had `setApprovalsSource(onlyOwner)`. Even with
    ///      `PolicyApprovals.setAttester` locked shut, as long as ADMIN can repoint *this*
    ///      pointer, a stolen key can: deploy its own `PolicyApprovals` with its own
    ///      attester → `setApprovalsSource(that one)` → `approve(anything)`. **Both locks
    ///      still open with the same key; it just takes one more step.**
    ///
    ///      So the **pointer** to the second lock has to be immutable too. Replacing it
    ///      means deploying a new `LeashResolver` and calling
    ///      `LeashRegistry.setResolver(label, theNewOne)` — a visible onchain transaction,
    ///      and the new resolver's policy pointers start empty, so an attacker would have
    ///      to repoint every single name from scratch.
    ///
    ///      The constructor rejects `address(0)`: there is no setter to recover with, so
    ///      failing at deploy time is the better outcome.
    IPolicyApprovals public immutable approvals;

    /// @notice ENS node → policy address. `address(0)` = unset / cleared = fully halted.
    mapping(bytes32 node => address policy) public policyOf;

    event PolicyPointerSet(
        bytes32 indexed node, address indexed policy, address indexed setBy, bool approved
    );
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroOwner();
    error ZeroApprovals();
    /// @dev The inner call's selector is one we do not recognise. **Revert rather than
    ///      return empty** — if the caller cannot tell "unset" from "unsupported", there
    ///      is no way to fail closed.
    error UnsupportedResolverCall(bytes4 selector);
    error UnsupportedCoinType(uint256 coinType);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, IPolicyApprovals approvals_) {
        if (owner_ == address(0)) revert ZeroOwner();
        if (address(approvals_) == address(0)) revert ZeroApprovals();
        owner = owner_;
        approvals = approvals_;
        emit OwnerTransferred(address(0), owner_);
    }

    // ---------------------------------------------------------------
    // Writes (ADMIN)
    // ---------------------------------------------------------------

    /// @notice Sets which policy a given agent name must satisfy.
    /// @dev **`approved` is deliberately not checked here.** The pointer is controlled by
    ///      ADMIN and the approval list by a face scan; separating the two is the whole
    ///      point. If the ADMIN key is stolen the attacker can move the pointer, but when
    ///      it points at a policy that was never approved, `LeashAccount` blocks the spend
    ///      (reason code 4). Enforcement lives in the account layer, not here.
    ///
    ///      Setting `address(0)` is a **reduction** (that agent halts immediately) and must
    ///      never be blocked — when something has gone wrong, hunting for your phone is the
    ///      last thing you want to do.
    function setPolicy(bytes32 node, address policy) external onlyOwner {
        policyOf[node] = policy;
        emit PolicyPointerSet(node, policy, msg.sender, _isApproved(policy));
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroOwner();
        emit OwnerTransferred(owner, to);
        owner = to;
    }

    // ---------------------------------------------------------------
    // ENSIP-10
    // ---------------------------------------------------------------

    /// @notice The ENSIP-10 wildcard resolution entry point.
    /// @param  data The inner call, ABI-encoded: `addr(bytes32)`,
    ///              `addr(bytes32,uint256)`, or `text(bytes32,string)`.
    /// @return The inner call's return value, ABI-encoded once more (as ENSIP-10 requires).
    ///
    /// @dev **`name` is deliberately unused.** The node is already in the inner calldata;
    ///      re-hashing the DNS-encoded name to cross-check it would defend against an
    ///      attack that does not exist in our trust model — the caller derived that node
    ///      itself in order to make the query. ENS's own `ExtendedResolver` does the same.
    ///      The parameter stays because the interface requires it, not because it is
    ///      useful.
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
            // ENSIP-9: the multi-coin form returns raw bytes, not an address
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
    // Read-only helpers
    // ---------------------------------------------------------------

    /// @notice Fetches "where it points" and "is it approved" together, saving a round trip.
    /// @dev    This is how both `LeashAccount` and the frontend use it.
    function policyAndApproval(bytes32 node) external view returns (address policy, bool approved) {
        policy = policyOf[node];
        approved = _isApproved(policy);
    }

    // ---------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------

    /// @dev Three text records, all of them **for humans**, none on the enforcement path:
    ///      - `policy`      → the policy address as a hex string (`dig`-style lookups,
    ///                        frontend display)
    ///      - `description` → the policy's own `describe()`; empty string if unreachable
    ///      - `leash`       → a version marker, so a reader can see at a glance that this
    ///                        name is governed by Leash
    function _text(bytes32 node, string memory key) private view returns (string memory) {
        bytes32 k = keccak256(bytes(key));
        address policy = policyOf[node];

        if (k == keccak256("policy")) {
            return policy == address(0) ? "" : _toHexString(policy);
        }
        if (k == keccak256("description")) {
            if (policy == address(0)) return "";
            // describe() is pure, so a staticcall is always safe. A broken policy must
            // not blow up the display path.
            (bool ok, bytes memory ret) = policy.staticcall(abi.encodeCall(IPolicy.describe, ()));
            if (!ok || ret.length == 0) return "";
            return abi.decode(ret, (string));
        }
        if (k == keccak256("leash")) {
            return "leash-v1";
        }
        // An unknown text key **returns the empty string; it does not revert.**
        //
        // The first version reverted, on the grounds that "the caller has to tell unset
        // from unsupported". That reasoning is right for an **unknown selector** in
        // `resolve` (it is on the enforcement path, where failing closed means something)
        // and wrong for a **text key**: text records are display-only, off the enforcement
        // path, and ENS UIs routinely batch-query `avatar` / `com.twitter` /
        // `description` — one revert takes the whole batch down and the name looks broken
        // in the ENS frontend.
        return "";
    }

    /// @dev `approvals` is immutable and cannot be 0 at construction, so the only case
    ///      left to guard is a zero policy. Failing closed still holds: the zero address
    ///      is never "approved".
    function _isApproved(address policy) private view returns (bool) {
        if (policy == address(0)) return false;
        return approvals.isApproved(policy);
    }

    function _toHexString(address a) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; ++i) {
            // The truncation is deliberate: we want only the lowest byte each round
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(v >> (8 * (19 - i)));
            out[2 + i * 2] = digits[b >> 4];
            out[3 + i * 2] = digits[b & 0x0f];
        }
        return string(out);
    }
}
