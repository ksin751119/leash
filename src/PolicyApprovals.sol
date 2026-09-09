// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";

/// @title PolicyApprovals — which policy addresses a real human has approved
/// @notice This list is the **second lock** in Leash's security model. The ENS pointer
///         (who points at which policy) is controlled by ADMIN; this list is controlled by
///         a **human**.
///
/// @dev **This contract has no owner, and that is deliberate.**
///
///      The first version had an `owner` and `setAttester(onlyOwner)`, and the deploy
///      script set the owner of `PolicyApprovals`, `LeashResolver` and `LeashRegistry` all
///      to the same ADMIN key. Code review pointed out that this made **one key open both
///      locks**: `setAttester(something that always returns true)` → `approve(anything)`,
///      which flatly refutes the sentence we had written in `PLAN.md` — "if the ADMIN key
///      is stolen the attacker can move the pointer, but cannot point it at a policy that
///      was never approved".
///
///      The fix is not "have a different key hold it" — that only relocates the problem.
///      The fix is to **remove the mutability**: `attester` is `immutable` with no setter,
///      which is precisely why no owner is needed. Changing the attester means deploying a
///      new `PolicyApprovals`, and that is a visible onchain transaction.
///
///      The asymmetry is deliberate, and it is the point of the whole design:
///
///      | Action | Needs attestation | Why |
///      |---|---|---|
///      | `approve` — make a new policy usable | ✅ yes | The first thing a compromised agent wants is to approve permissive rules for itself |
///      | `revoke` — take a policy out of service | ❌ no | When something has gone wrong, hunting for your phone is the last thing you want to do |
///
///      `revoke` is not even restricted to an owner: **anyone can revoke**. That looks
///      strange until you follow it through — revoking can only make the system stricter
///      (that policy now blocks every spend), and putting a permission on the brake pedal
///      does the attacker a favour at exactly the moment things go wrong. It does not
///      matter who pushes it; a brake is a brake.
contract PolicyApprovals is IPolicyApprovals {
    /// @notice The only source of approval. **No setter** — see the contract notes.
    IAttester public immutable attester;

    /// @notice The `isApproved(address)` the interface requires is the auto-generated
    ///         getter of this public mapping.
    mapping(address policy => bool) public isApproved;

    /// @notice The description recorded at approval time; the frontend shows it as "what
    ///         this rule is".
    mapping(address policy => string) public descriptionOf;

    /// @notice Spent attestations. **The core of replay protection** — see `approve`.
    mapping(bytes32 digest => bool) public attestationUsed;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant APPROVAL_TYPEHASH =
        keccak256("PolicyApproval(address policy,string description,uint256 nonce)");
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");

    event PolicyApproved(
        address indexed policy, string description, uint256 nonce, bytes32 attestationHash
    );
    event PolicyRevoked(address indexed policy, address indexed by);

    error ZeroPolicy();
    error ZeroAttester();
    error NotAttested();
    error AlreadyApproved();
    error AttestationReused(bytes32 digest);

    constructor(IAttester attester_) {
        // The attester cannot be 0: that would leave the list permanently unable to
        // approve anything, with no setter to recover. Better to fail at deploy time.
        if (address(attester_) == address(0)) revert ZeroAttester();
        attester = attester_;
    }

    /// @notice Approves a policy. **Requires a human attestation, and each attestation
    ///         can be used exactly once.**
    /// @param nonce Chosen by the issuer; the same (policy, description) pair with a
    ///        different nonce is a different attestation
    ///
    /// @dev **There is no sender check here, and that is correct** — the gate is the
    ///      attestation, not an identity, because this is a **global singleton** list and
    ///      "who submitted the transaction" does not change the outcome.
    ///      (Careful: `LeashAccount` is per-wallet, and widening there requires **both** —
    ///      `msg.sender == address(this)` *and* an attestation. Carrying this comment over
    ///      to that contract would be a bug; code review caught exactly that.)
    ///
    ///      **Replay protection:** the first version's digest had no nonce and kept no
    ///      record of spent attestations. Combined with a public `revoke`, that opens this
    ///      attack once the real `WorldAttester` is live: copy the attestation out of the
    ///      public calldata → `revoke(policy)` → `approve` again with the **same** blob, no
    ///      new face scan from anyone. The digest now carries a nonce, and once
    ///      `attestationUsed` is marked it stays marked forever — **re-approving after a
    ///      revocation requires an attestation with a fresh nonce.**
    function approve(
        address policy,
        string calldata description,
        uint256 nonce,
        bytes calldata attestation
    ) external {
        if (policy == address(0)) revert ZeroPolicy();
        if (isApproved[policy]) revert AlreadyApproved();

        bytes32 digest = approvalDigest(policy, description, nonce);
        if (attestationUsed[digest]) revert AttestationReused(digest);
        if (!attester.verify(digest, attestation)) revert NotAttested();

        attestationUsed[digest] = true;
        isApproved[policy] = true;
        descriptionOf[policy] = description;
        emit PolicyApproved(policy, description, nonce, keccak256(attestation));
    }

    /// @notice Revokes a policy. **Anyone can do it, and no attestation is required.**
    /// @dev See the contract notes — a reduction must never be blocked. Revoking twice
    ///      does not revert; it is idempotent. It also clears `descriptionOf`, otherwise
    ///      the frontend keeps showing the description of a rule that no longer applies.
    function revoke(address policy) external {
        if (!isApproved[policy]) return;
        isApproved[policy] = false;
        delete descriptionOf[policy];
        emit PolicyRevoked(policy, msg.sender);
    }

    /// @notice The EIP-712 digest to be attested. The frontend, the backend and the chain
    ///         all compute it here, so all three agree.
    /// @dev The first version rolled its own `keccak256(abi.encode(...))` — not EIP-712:
    ///      no domain separator, no `\x19\x01` prefix — while `IAttester`'s notes and
    ///      sprint item 8 both say EIP-712. `WorldAttester`'s backend will sign with a
    ///      standard library, and a mismatch simply fails verification.
    ///
    ///      `chainId` and `verifyingContract` go into the domain separator, so one
    ///      attestation cannot be carried to another chain or another approval list.
    function approvalDigest(address policy, string memory description, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(APPROVAL_TYPEHASH, policy, keccak256(bytes(description)), nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev Recomputed every call, never cached — `block.chainid` changes after a chain
    ///      split, and a cached value would then be wrong.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }
}
