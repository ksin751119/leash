# WorldAttester Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MockAttester` on `LeashAccount`'s widening paths with a contract that verifies an ECDSA signature from the World RP signer, so that "widening requires a live human" is enforced onchain rather than promised in a document.

**Architecture:** One new stateless contract, `WorldAttester`, holding an `immutable` signer address and verifying a 73-byte attestation (a `uint64` deadline plus a 65-byte signature) against an EIP-712 struct whose domain binds the chain and the attester's own address. Two public digest getters are added to `LeashAccount` so a caller can compute what needs signing. The backend gains one endpoint that signs only after a Selfie Check proof verifies, with the proof's `signal` bound to the digest so one face scan authorises exactly one widening.

**Tech Stack:** Solidity 0.8.28, Foundry (`evm_version = "prague"`), OpenZeppelin v5.1.0 (`ECDSA.tryRecover`), Node 24 with `@noble/hashes` and `@noble/curves` 2.x.

**Spec:** `docs/superpowers/specs/2026-09-09-world-attester-design.md`

## Global Constraints

Every item is a project-wide requirement; each task's acceptance criteria implicitly include all of them. Copy values verbatim — do not recompute.

- **Solidity `0.8.28`, `evm_version = "prague"`.** Already in `foundry.toml`.
- **`SIGNER = 0x85b89D21DB13f220601430d48244B2AE06120969`** — the address `WORLD_RP_SIGNER_PK` derives to and the signer the Developer Portal shows for `rp_ef35d4e2d4f1a031`. Verified 2026-09-09. Do not rotate.
- **The attestation is exactly 73 bytes, packed:** `deadline` (8, big-endian) ‖ `r` (32) ‖ `s` (32) ‖ `v` (1, value 27 or 28). Any other length is `false`.
- **EIP-712 domain:** `name = "Leash"`, `version = "1"`, `chainId = block.chainid`, `verifyingContract = address(this)` — matching `PolicyApprovals`, `LeashRegistry` and `LeashAccount`, and recomputed per call rather than cached.
- **`ATTESTATION_TYPEHASH = keccak256("LeashAttestation(bytes32 digest,uint64 deadline)")`.**
- **`verify` must never revert.** `IAttester`'s contract requires it, and `attestation` is attacker-controlled. Use `ECDSA.tryRecover`, never `ECDSA.recover`; validate the length before slicing; pass no externally-supplied bytes to `abi.decode`.
- **`@noble/curves` 2.x returns `format: "recovered"` as `[recovery(1) ‖ r(32) ‖ s(32)]`** — the recovery byte is **first**, and its value is 0 or 1. Ethereum's `v` is `27 + recovery`, and the blob wants `r ‖ s ‖ v`. Probed 2026-09-09; getting this wrong fails with the same symptom as an encoding error.
- **Existing tests must stay green:** the pre-plan baseline is 170 passed / 1 skipped for `forge test`, 8 passed for the subgraph. Each task's own expected total accumulates the earlier tasks' new tests on top of that — do not read 170 as a per-task target. `forge fmt` clean.
- **Existing contracts are not modified** except `src/LeashAccount.sol`, which gains two `view` functions and no storage.
- **`WORLD_RP_SIGNER_PK` never leaves the backend** and never appears in a script, a test, or a commit. Tests use their own throwaway keys.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/WorldAttester.sol` | **Create.** The whole feature's onchain half: an immutable signer, the EIP-712 hash, and a non-reverting `verify` | 1 |
| `test/WorldAttester.t.sol` | **Create.** Unit tests for the contract in isolation, including the fuzz never-reverts property | 1 |
| `src/LeashAccount.sol` | **Modify.** Add `ruleDigest` and `restoreDigest` as public views. No storage change, so the ERC-7201 layout is untouched | 2 |
| `test/LeashAccountDigests.t.sol` | **Create.** Proves each getter returns what the corresponding `_consumeAttestation` call site computes | 2 |
| `test/WorldAttesterIntegration.t.sol` | **Create.** `LeashAccount` with `ATTESTER = WorldAttester`: a real signature widens, an expired one does not, and reductions are still free | 3 |
| `world/server.mjs` | **Modify.** Add `POST /api/attest` | 4 |
| `world/attest.mjs` | **Create.** The EIP-712 hashing and signing, kept out of the server so the cross-check can import it | 4 |
| `world/crosscheck.mjs` | **Create.** Asserts the JS hash equals the deployed contract's `attestationHash` | 4 |
| `script/DeployWorldAttester.s.sol` | **Create.** Deploys `WorldAttester` and the new `LeashAccount` impl. Contains no `WALLET_PK` | 5 |
| `docs/deployments.md` | **Modify.** New addresses, the re-delegation transaction, and what is now real | 5 |
| `README.md` | **Modify.** Rewrite the `MockAttester` callout to say which half is now enforced onchain | 5 |

`world/attest.mjs` is separate from `server.mjs` on purpose: the cross-check has to exercise **the same code the server signs with**, and a script cannot import from a file that starts an HTTP listener.

---

## Task 1: `WorldAttester`

**Files:**
- Create: `src/WorldAttester.sol`
- Test: `test/WorldAttester.t.sol`

**Interfaces:**
- Consumes: `src/IAttester.sol` (`verify(bytes32,bytes) external view returns (bool)`, `describe() external pure returns (string memory)`); `openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol`.
- Produces:
  - `constructor(address signer_)`
  - `address public immutable SIGNER`
  - `function attestationHash(bytes32 digest, uint64 deadline) public view returns (bytes32)`
  - `function domainSeparator() public view returns (bytes32)`
  - `function verify(bytes32 digest, bytes calldata attestation) external view returns (bool)`
  - `error ZeroSigner()`

- [ ] **Step 1: Write the failing tests**

```solidity
// test/WorldAttester.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { WorldAttester } from "../src/WorldAttester.sol";

contract WorldAttesterTest is Test {
    /// A throwaway key. The real `WORLD_RP_SIGNER_PK` never appears in a test.
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant WRONG_PK = 0xBADBAD;

    WorldAttester att;
    bytes32 digest;

    function setUp() public {
        att = new WorldAttester(vm.addr(SIGNER_PK));
        digest = keccak256("a widening digest");
        vm.warp(1_800_000_000);
    }

    /// Packs the 73-byte blob the contract expects: deadline ‖ r ‖ s ‖ v.
    function _blob(uint256 pk, bytes32 d, uint64 signedDeadline, uint64 blobDeadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, att.attestationHash(d, signedDeadline));
        return abi.encodePacked(blobDeadline, r, s, v);
    }

    function _valid() internal view returns (bytes memory) {
        uint64 dl = uint64(block.timestamp + 900);
        return _blob(SIGNER_PK, digest, dl, dl);
    }

    // --- the happy path has to be reachable at all ---

    function test_a_valid_signature_inside_its_deadline_passes() public view {
        assertTrue(att.verify(digest, _valid()));
    }

    function test_the_blob_is_exactly_73_bytes() public view {
        assertEq(_valid().length, 73);
    }

    // --- each row below pins one guard; deleting the guard must fail the test ---

    /// Pins the `block.timestamp > deadline` comparison.
    function test_an_expired_deadline_fails() public {
        uint64 dl = uint64(block.timestamp - 1);
        assertFalse(att.verify(digest, _blob(SIGNER_PK, digest, dl, dl)));
    }

    /// The boundary: valid *at* the deadline, invalid one second later.
    function test_the_deadline_is_inclusive() public {
        uint64 dl = uint64(block.timestamp);
        bytes memory blob = _blob(SIGNER_PK, digest, dl, dl);
        assertTrue(att.verify(digest, blob));
        vm.warp(block.timestamp + 1);
        assertFalse(att.verify(digest, blob));
    }

    /// Pins `rec == SIGNER`.
    function test_a_different_signer_fails() public view {
        uint64 dl = uint64(block.timestamp + 900);
        assertFalse(att.verify(digest, _blob(WRONG_PK, digest, dl, dl)));
    }

    /// 🔴 Pins that `deadline` is **inside the signed struct**, not merely beside it.
    /// Sign for one deadline, ship another. If the contract only read the blob's copy,
    /// this would pass and a deadline would be forgeable by whoever holds the blob.
    function test_a_deadline_swapped_after_signing_fails() public view {
        uint64 signed_ = uint64(block.timestamp + 900);
        uint64 shipped = uint64(block.timestamp + 90_000);
        assertFalse(att.verify(digest, _blob(SIGNER_PK, digest, signed_, shipped)));
    }

    /// Pins that `digest` is inside the struct.
    function test_a_signature_for_a_different_digest_fails() public view {
        uint64 dl = uint64(block.timestamp + 900);
        assertFalse(att.verify(digest, _blob(SIGNER_PK, keccak256("another digest"), dl, dl)));
    }

    /// Pins the length check, on both sides of 73 and at zero.
    function test_a_wrong_length_fails() public view {
        bytes memory ok = _valid();
        assertFalse(att.verify(digest, ""));
        assertFalse(att.verify(digest, abi.encodePacked(ok, hex"00")));       // 74
        assertFalse(att.verify(digest, _slice(ok, 72)));                      // 72
    }

    /// Pins `tryRecover`'s upper-half-`s` rejection. Flipping `s` to `n - s` and `v` to the
    /// other parity yields a second signature valid under raw ecrecover.
    function test_a_malleable_signature_fails() public view {
        uint64 dl = uint64(block.timestamp + 900);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, att.attestationHash(digest, dl));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flipped = bytes32(n - uint256(s));
        uint8 otherV = v == 27 ? 28 : 27;
        assertFalse(att.verify(digest, abi.encodePacked(dl, r, flipped, otherV)));
    }

    /// Pins `tryRecover`'s error path rather than a revert.
    function test_an_invalid_v_fails() public view {
        uint64 dl = uint64(block.timestamp + 900);
        (, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, att.attestationHash(digest, dl));
        assertFalse(att.verify(digest, abi.encodePacked(dl, r, s, uint8(0))));
        assertFalse(att.verify(digest, abi.encodePacked(dl, r, s, uint8(29))));
    }

    /// 🔴 Pins `verifyingContract` in the domain: a signature made for one deployment must
    /// not verify on another. Rotating the signer means redeploying, so this path exists.
    function test_a_signature_does_not_carry_to_another_deployment() public {
        bytes memory blob = _valid();
        assertTrue(att.verify(digest, blob));
        WorldAttester other = new WorldAttester(vm.addr(SIGNER_PK));
        assertFalse(other.verify(digest, blob));
    }

    /// 🔴 Pins `IAttester`'s never-revert contract. A `view` call that reverts fails here.
    function testFuzz_verify_never_reverts(bytes32 d, bytes calldata blob) public view {
        att.verify(d, blob);
    }

    function test_the_constructor_rejects_the_zero_signer() public {
        vm.expectRevert(WorldAttester.ZeroSigner.selector);
        new WorldAttester(address(0));
    }

    /// The display string must disclose that liveness is enforced offchain, so a reader
    /// does not assume the chain checks it.
    function test_describe_says_where_liveness_is_enforced() public view {
        assertTrue(_contains(att.describe(), "offchain"));
    }

    /// Both inputs must reach the hash. If either did not, a signature would cover less
    /// than it appears to — and the two tests above that swap a deadline or a digest would
    /// be passing for the wrong reason.
    ///
    /// The encoding itself is anchored in Task 4 Step 5, by comparing against a
    /// locally-deployed copy of this contract. Not by a constant pasted here: a constant
    /// computed the same wrong way twice agrees with itself.
    function test_attestationHash_depends_on_both_inputs() public view {
        bytes32 base = att.attestationHash(digest, 1000);
        assertTrue(att.attestationHash(digest, 1001) != base, "deadline must reach the hash");
        assertTrue(att.attestationHash(keccak256("other"), 1000) != base, "digest must reach the hash");
    }

    function _slice(bytes memory b, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = b[i];
        }
    }

    function _contains(string memory hay, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `forge test --match-contract WorldAttesterTest`
Expected: a compile failure, `Source "src/WorldAttester.sol" not found`

- [ ] **Step 3: Write `src/WorldAttester.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ECDSA } from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import { IAttester } from "./IAttester.sol";

/// @title WorldAttester — "a live human authorised this", checked onchain
/// @notice Replaces `MockAttester` on `LeashAccount`'s widening paths. The backend verifies
///         a Selfie Check proof against World's v4 endpoint and only then signs; this
///         contract checks that signature.
///
/// @dev **What this proves onchain, stated exactly:** the RP signer authorised this precise
///      digest, before this deadline. It does **not** prove a human was present — that link
///      is World App performing Selfie Check, the v4 endpoint verifying the proof, and our
///      backend signing only afterwards. Only the first step is World's.
///
///      The proof's `signal` is the digest, so one face scan authorises exactly one
///      widening and an intercepted proof cannot be moved to another.
contract WorldAttester is IAttester {
    /// @notice The World RP signer. **`immutable`, with no setter.**
    /// @dev Identical to the C1 fix on `PolicyApprovals`: a mutable signer pointer hands
    ///      both locks to one key. Rotating the signer means deploying a new attester,
    ///      which is a visible onchain transaction — and the EIP-712 domain below binds
    ///      `verifyingContract`, so signatures do not carry across that redeployment.
    address public immutable SIGNER;

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant ATTESTATION_TYPEHASH =
        keccak256("LeashAttestation(bytes32 digest,uint64 deadline)");
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");

    error ZeroSigner();

    constructor(address signer_) {
        // No setter exists to recover from a zero signer: the list of things this attester
        // could ever approve would be empty forever. Better to fail at deploy time.
        if (signer_ == address(0)) revert ZeroSigner();
        SIGNER = signer_;
    }

    /// @inheritdoc IAttester
    /// @dev **This function must never revert**, and holding that is why it looks like this.
    ///      `attestation` is attacker-controlled, and OpenZeppelin's `ECDSA.recover` reverts
    ///      on a bad length, a malleable `s`, or a zero recovery — so `tryRecover`, which
    ///      returns an error enum, is mandatory rather than stylistic. The length is checked
    ///      before any slicing, and no externally-supplied bytes reach `abi.decode`. Same
    ///      discipline as `LeashAccount.resolvePolicy`.
    ///
    ///      Layout, 73 bytes: `deadline`(8) ‖ `r`(32) ‖ `s`(32) ‖ `v`(1). Packed rather than
    ///      `abi.encode(uint64, bytes)`, because that produces an offset/length header which
    ///      would itself have to be validated — the hop-three trap from `resolvePolicy`.
    function verify(bytes32 digest, bytes calldata attestation) external view returns (bool) {
        if (attestation.length != 73) return false;

        uint64 deadline = uint64(bytes8(attestation[0:8]));
        if (block.timestamp > deadline) return false;

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(
            attestationHash(digest, deadline),
            uint8(attestation[72]),
            bytes32(attestation[8:40]),
            bytes32(attestation[40:72])
        );
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == SIGNER;
    }

    /// @notice What the backend signs, and the one value the JS side has to reproduce byte
    ///         for byte.
    /// @dev Exposed as a view because a mismatch between the two implementations has
    ///      exactly one symptom — "the signature does not verify" — and nothing that says
    ///      whether the encoding, the key, the deadline or `v` was at fault. `crosscheck.mjs`
    ///      compares against this.
    ///
    ///      Note that `deadline` is a `uint64` in the type but a full 32-byte word inside
    ///      `abi.encode`. The JS side must left-pad it.
    function attestationHash(bytes32 digest, uint64 deadline) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, digest, deadline));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev Recomputed every call rather than cached, matching `PolicyApprovals`,
    ///      `LeashRegistry` and `LeashAccount` — `block.chainid` changes after a chain split
    ///      and a cached value would then be wrong.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @inheritdoc IAttester
    function describe() external pure returns (string memory) {
        return
        "WorldAttester/1: ECDSA over EIP-712 by the World RP signer (rp_ef35d4e2d4f1a031). Onchain this proves the RP signer authorised this exact digest before its deadline; that a live human was present is enforced offchain by Selfie Check.";
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `forge test --match-contract WorldAttesterTest -vv`
Expected: all pass; the fuzz case runs 256 inputs without reverting

- [ ] **Step 5: Mutation-check three guards**

For each, make the edit, run `forge test --match-contract WorldAttesterTest`, confirm the named test fails, then revert.

| Edit | Must fail |
|---|---|
| Delete `if (block.timestamp > deadline) return false;` | `test_an_expired_deadline_fails`, `test_the_deadline_is_inclusive` |
| Replace `attestationHash(digest, deadline)` with `digest` | `test_a_valid_signature_inside_its_deadline_passes`, `test_the_deadline_is_inclusive`, `test_a_signature_does_not_carry_to_another_deployment` |
| **Narrow:** drop `deadline` from `structHash` — `keccak256(abi.encode(ATTESTATION_TYPEHASH, digest))` | `test_a_deadline_swapped_after_signing_fails` |
| Change `return recovered == SIGNER;` to `return true;` | `test_a_different_signer_fails` |

If any mutation leaves the suite green, the test is vacuous — fix the test, not the contract.

> The last two rows are separate on purpose, and the first version of this table conflated
> them. Replacing the whole hash with the bare digest is a sledgehammer: it destroys the
> typehash, the domain and the deadline at once, so recovery lands on a essentially random
> address and `test_a_deadline_swapped_after_signing_fails` passes **trivially** — its
> `assertFalse` holds for a reason unrelated to what it claims to pin. The narrow mutation
> keeps the EIP-712 wrapper and removes only `deadline`, so both sides compute the same
> deadline-free hash, the happy path still passes, and the swap test is the only thing that
> can catch it. That is what makes it the test's real mutation.

- [ ] **Step 6: Format and run the whole suite**

Run: `forge fmt && forge test`
Expected: the 170 existing tests still pass, plus the new ones; 1 skipped

- [ ] **Step 7: Commit**

```bash
git add src/WorldAttester.sol test/WorldAttester.t.sol
git commit -m "feat: WorldAttester - ECDSA over EIP-712 by the World RP signer

Replaces MockAttester's 'return true' with a signature check. The
attestation is 73 packed bytes (deadline, r, s, v) rather than
abi.encode(uint64, bytes), because abi.encode of a dynamic member
carries an offset/length header that must be validated first - the same
trap as hop three in resolvePolicy.

The signature covers an EIP-712 struct rather than the raw digest, for
two reasons: the RP signer key also signs rp_context for World, so
raw-signing an arbitrary 32-byte hash with it is the pattern to avoid;
and binding verifyingContract stops a signature carrying onto a later
deployment, which matters because rotating the signer means redeploying.

The deadline lives inside the signed struct, not merely beside it in the
blob. A test signs one deadline and ships another and expects false -
without that, whoever holds a blob could extend its own validity.

verify never reverts, which required tryRecover rather than recover and
a length check before any slicing. A fuzz test over arbitrary bytes
pins it.

Three guards mutation-checked: deleting the deadline comparison, signing
over the raw digest instead of the struct, and always returning true
each fail exactly the tests written for them."
```

---

## Task 2: `ruleDigest` and `restoreDigest`

**Files:**
- Modify: `src/LeashAccount.sol` — add two views next to `payeeDigest` (currently at line 487)
- Test: `test/LeashAccountDigests.t.sol`

**Interfaces:**
- Consumes: `LeashAccount`'s existing private `_digest(bytes32) view returns (bytes32)`, and the private constants `RULE_TYPEHASH`, `RESTORE_TYPEHASH`, `SELF`.
- Produces:
  - `function ruleDigest(bytes32 node, address token, LeashStorage.TokenRule calldata rule, uint256 nonce) public view returns (bytes32)`
  - `function restoreDigest(address agent, bytes32 node, string calldata label, uint256 nonce) public view returns (bytes32)`

**Why this task exists:** there are six widening TYPEHASHes and only four public digest getters. `setRule` and `restoreAgent` have none, so nothing outside the contract can compute what to sign. `MockAttester` hid this completely — it accepts any bytes, so no caller ever needed the correct digest. The defect only becomes reachable once the attester is real.

- [ ] **Step 1: Write the failing tests**

The test asserts the getter equals what the call site computes, by reproducing the call site's encoding independently. If they ever diverge, a signature will verify against the getter and be rejected by the consumer.

```solidity
// test/LeashAccountDigests.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";

contract Approvals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract LeashAccountDigestsTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    uint256 constant WALLET_PK = 0x8A11E7;

    bytes32 constant RULE_TYPEHASH = keccak256(
        "SetRule(address impl,bytes32 node,address token,bool allowed,uint256 txLimit,uint256 periodLimit,uint64 period,uint16 windowStart,uint16 windowEnd,uint256 nonce)"
    );
    bytes32 constant RESTORE_TYPEHASH =
        keccak256("RestoreAgent(address impl,address agent,bytes32 node,string label,uint256 nonce)");

    function setUp() public {
        impl = new LeashAccount(
            address(0xE45), IPolicyApprovals(address(new Approvals())), IAttester(address(new MockAttester()))
        );
        vm.signAndAttachDelegation(address(impl), WALLET_PK);
        acct = LeashAccount(payable(vm.addr(WALLET_PK)));
    }

    function _rule() internal pure returns (LeashStorage.TokenRule memory) {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: 500e6,
            periodLimit: 1000e6,
            period: 1 days,
            windowStart: 540,
            windowEnd: 1020,
            epoch: 0
        });
    }

    /// The digest a caller computes must equal the one `setRule` consumes. `epoch` is
    /// deliberately absent from `RULE_TYPEHASH` and so must be absent here too.
    function test_ruleDigest_matches_what_setRule_consumes() public view {
        bytes32 node = acct.nodeFor("vendors");
        address token = address(0x7ABC);
        LeashStorage.TokenRule memory r = _rule();

        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"1901",
                acct.domainSeparator(),
                keccak256(
                    abi.encode(
                        RULE_TYPEHASH,
                        acct.SELF(),
                        node,
                        token,
                        r.allowed,
                        r.txLimit,
                        r.periodLimit,
                        r.period,
                        r.windowStart,
                        r.windowEnd,
                        uint256(7)
                    )
                )
            )
        );
        assertEq(acct.ruleDigest(node, token, r, 7), expected);
    }

    function test_restoreDigest_matches_what_restoreAgent_consumes() public view {
        bytes32 node = acct.nodeFor("vendors");
        address agent = address(0xA6E7);

        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"1901",
                acct.domainSeparator(),
                keccak256(
                    abi.encode(
                        RESTORE_TYPEHASH, acct.SELF(), agent, node, keccak256(bytes("vendors")), uint256(3)
                    )
                )
            )
        );
        assertEq(acct.restoreDigest(agent, node, "vendors", 3), expected);
    }

    /// The nonce has to change the digest, or replay protection is decorative.
    function test_a_different_nonce_gives_a_different_digest() public view {
        bytes32 node = acct.nodeFor("vendors");
        assertTrue(acct.ruleDigest(node, address(1), _rule(), 1) != acct.ruleDigest(node, address(1), _rule(), 2));
    }

    /// Two wallets delegating to one impl must produce different digests, because
    /// `domainSeparator` binds `address(this)` — the EOA.
    function test_two_wallets_get_different_digests() public {
        uint256 otherPk = 0xB0B;
        vm.signAndAttachDelegation(address(impl), otherPk);
        LeashAccount other = LeashAccount(payable(vm.addr(otherPk)));
        bytes32 node = acct.nodeFor("vendors");
        assertTrue(
            acct.ruleDigest(node, address(1), _rule(), 1) != other.ruleDigest(node, address(1), _rule(), 1)
        );
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountDigestsTest`
Expected: a compile failure, `Member "ruleDigest" not found`

- [ ] **Step 3: Add the two views to `src/LeashAccount.sol`**

Place them immediately after `payeeDigest`, before `_digest`.

```solidity
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
            keccak256(abi.encode(RESTORE_TYPEHASH, SELF, agent, node, keccak256(bytes(label)), nonce))
        );
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountDigestsTest -vv`
Expected: 4 passed

- [ ] **Step 5: Mutation-check the encodings**

| Edit | Must fail |
|---|---|
| Drop `SELF` from `ruleDigest`'s `abi.encode` | `test_ruleDigest_matches_what_setRule_consumes` |
| Add `rule.epoch` after `rule.windowEnd` in `ruleDigest` | `test_ruleDigest_matches_what_setRule_consumes` |
| Use `bytes(label)` instead of `keccak256(bytes(label))` in `restoreDigest` | `test_restoreDigest_matches_what_restoreAgent_consumes` |

- [ ] **Step 6: Format and run the whole suite**

Run: `forge fmt && forge test`
Expected: 190 passed, 1 skipped (the pre-plan 170, plus 16 from Task 1, plus 4 here)

- [ ] **Step 7: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountDigests.t.sol
git commit -m "feat: ruleDigest and restoreDigest, the two getters MockAttester hid

Six widening TYPEHASHes existed and only four public digest getters.
setRule and restoreAgent had none, so nothing outside the contract could
compute what needs signing - and with a real attester there is nothing
to hand the backend.

MockAttester concealed this completely: it accepts any bytes, so no
caller ever needed a correct digest. The defect only becomes reachable
once the attester is real, which is why five days of tests never saw it.

The tests reproduce each call site's encoding independently rather than
calling the getter twice, so a divergence between getter and consumer
fails loudly instead of agreeing with itself. Three mutations checked,
including adding rule.epoch to the encoding - it is deliberately absent
from RULE_TYPEHASH."
```

---

## Task 3: `LeashAccount` with a real attester

**Files:**
- Test: `test/WorldAttesterIntegration.t.sol`

**Interfaces:**
- Consumes: `WorldAttester` (Task 1), `LeashAccount.payeeDigest` / `ruleDigest` (Task 2), `LeashAccount`'s errors `NotAttested()` and `AttestationReused(bytes32)`.
- Produces: nothing. This task adds only tests.

**Why a separate file:** the existing suites construct `LeashAccount` with `MockAttester` and 170 tests depend on that. This file is the only place where the attester is real.

- [ ] **Step 1: Write the failing tests**

> ⚠️ **`vm.prank` and `vm.expectRevert` are single-shot, and `_sign` spends them.** `_sign`
> makes a real staticcall to `att.attestationHash`, so writing `_sign(...)` inline as a call
> argument fires it AFTER the cheatcode and consumes the cheatcode on the wrong call — the
> widening then arrives from the test contract instead of `wallet` and the test fails with
> `NotSelf()`, which looks like an access-control bug in `src/` and is not one. Precompute
> `bytes memory blob = _sign(d, dl);` BEFORE every cheatcode. The reduction test can get away
> with inline calls only because `startPrank` is not single-shot.

```solidity
// test/WorldAttesterIntegration.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { WorldAttester } from "../src/WorldAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract WorldAttesterIntegrationTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint256 constant WALLET_PK = 0x8A11E7;
    uint256 constant WRONG_PK = 0xBAD;

    WorldAttester att;
    LeashAccount impl;
    LeashAccount acct;
    address wallet;
    bytes32 node;
    address constant TOKEN = address(0x7ABC);
    address constant PAYEE = address(0xBEEF);

    function setUp() public {
        vm.warp(1_800_000_000);
        att = new WorldAttester(vm.addr(SIGNER_PK));
        impl = new LeashAccount(
            address(0xE45), IPolicyApprovals(address(new YesApprovals())), IAttester(address(att))
        );
        vm.signAndAttachDelegation(address(impl), WALLET_PK);
        wallet = vm.addr(WALLET_PK);
        acct = LeashAccount(payable(wallet));
        node = acct.nodeFor("vendors");
    }

    function _sign(bytes32 digest, uint64 deadline) internal view returns (bytes memory) {
        return _signWith(SIGNER_PK, digest, deadline);
    }

    function _signWith(uint256 pk, bytes32 digest, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, att.attestationHash(digest, deadline));
        return abi.encodePacked(deadline, r, s, v);
    }

    /// 🔴 The whole chain, end to end: compute the digest, sign it as the RP signer, and
    /// the widening lands. This is act three of the demo.
    function test_allowPayee_with_a_real_signature_succeeds() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(wallet);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);

        assertTrue(acct.isPayeeAllowed(node, TOKEN, PAYEE));
    }

    /// The deadline has to reach the consumer, not merely exist in the attester.
    function test_allowPayee_with_an_expired_signature_reverts() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.warp(uint256(dl) + 1);
        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// The consumer's own replay protection still holds with a real signature.
    function test_the_same_attestation_twice_reverts() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(wallet);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(LeashAccount.AttestationReused.selector, d));
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// Widening is two-of-two. A valid signature is not enough if the caller is not the
    /// wallet — this is the C1 regression, now with a real attester behind it.
    function test_a_real_signature_does_not_help_an_outsider() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _sign(d, dl);

        vm.prank(address(0xDEAD));
        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// A well-shaped, correctly-packed 73-byte blob is not enough on its own — it has to
    /// be signed by the RP signer specifically. This is the claim the file's name makes;
    /// the other five tests exercise the wiring around it, but only this one pins the
    /// signature check itself against a real (wrong) key.
    function test_a_blob_signed_by_the_wrong_key_is_rejected() public {
        uint64 dl = uint64(block.timestamp + 900);
        bytes32 d = acct.payeeDigest(node, TOKEN, PAYEE, 1);
        bytes memory blob = _signWith(WRONG_PK, d, dl);

        vm.prank(wallet);
        vm.expectRevert(LeashAccount.NotAttested.selector);
        acct.allowPayee(node, TOKEN, PAYEE, 1, blob);
    }

    /// `setRule` is the other widening act three could show, and it is the one that had no
    /// digest getter until Task 2.
    function test_setRule_with_a_real_signature_succeeds() public {
        LeashStorage.TokenRule memory r = LeashStorage.TokenRule({
            allowed: true,
            txLimit: 500e6,
            periodLimit: 1000e6,
            period: 1 days,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
        uint64 dl = uint64(block.timestamp + 900);
        bytes memory blob = _sign(acct.ruleDigest(node, TOKEN, r, 1), dl);

        vm.prank(wallet);
        acct.setRule(node, TOKEN, r, 1, blob);

        assertEq(acct.ruleOf(node, TOKEN).periodLimit, 1000e6);
    }

    /// 🔴 **The most important test in this file.** The whole design rests on reductions
    /// being free. Making the attester real must not have quietly made any of them cost
    /// something — if it had, a compromised agent could not be stopped without a face scan.
    function test_every_reduction_is_still_free_with_a_real_attester() public {
        LeashStorage.TokenRule memory open_ = LeashStorage.TokenRule({
            allowed: true,
            txLimit: 0,
            periodLimit: 0,
            period: 0,
            windowStart: 0,
            windowEnd: 0,
            epoch: 0
        });
        uint64 dl = uint64(block.timestamp + 900);
        vm.startPrank(wallet);
        acct.setRule(node, TOKEN, open_, 1, _sign(acct.ruleDigest(node, TOKEN, open_, 1), dl));
        acct.allowPayee(node, TOKEN, PAYEE, 2, _sign(acct.payeeDigest(node, TOKEN, PAYEE, 2), dl));
        acct.bindAgent(address(0xA6E7), node, "vendors");

        // None of the following passes an attestation at all.
        acct.removePayee(node, TOKEN, PAYEE);
        LeashStorage.TokenRule memory tighter = open_;
        tighter.txLimit = 100;
        acct.tightenRule(node, TOKEN, tighter);
        acct.revokeAgent(address(0xA6E7));
        acct.pause();
        acct.unpause();
        vm.stopPrank();

        assertFalse(acct.isPayeeAllowed(node, TOKEN, PAYEE));
        assertEq(acct.ruleOf(node, TOKEN).txLimit, 100);
        assertFalse(acct.paused());
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `forge test --match-contract WorldAttesterIntegrationTest`
Expected: they fail only if Tasks 1 and 2 are incomplete. If both are done, these should pass on the first run — that is the point of an integration task, and it is not a TDD violation to discover the pieces already fit.

- [ ] **Step 3: Run the whole suite**

Run: `forge fmt && forge test`
Expected: 197 passed, 1 skipped (190 after Task 2, plus 7 here)

- [ ] **Step 4: Commit**

```bash
git add test/WorldAttesterIntegration.t.sol
git commit -m "test: LeashAccount with a real attester, and the asymmetry survives it

Six integration tests where ATTESTER is WorldAttester rather than the
mock: allowPayee and setRule land with a real RP-signer signature, an
expired one reverts NotAttested, the same attestation twice reverts
AttestationReused, and a valid signature still does not help a caller
that is not the wallet - widening stays two-of-two.

The last test is the one that matters most. The whole design rests on
reductions being free, so making the attester real must not have quietly
made any of them cost something: removePayee, tightenRule, revokeAgent,
pause and unpause all run with no attestation argument at all. If that
had regressed, a compromised agent could not be stopped without finding
a phone."
```

---

## Task 4: the attestation endpoint and the cross-check

**Files:**
- Create: `world/attest.mjs`
- Create: `world/crosscheck.mjs`
- Modify: `world/server.mjs` — add `POST /api/attest` beside the existing `/api/verify` (line 103)
- Modify: `world/package.json` — add `@noble/curves`

**Interfaces:**
- Consumes: `WorldAttester.attestationHash(bytes32,uint64)` (Task 1); the existing `json` and `readBody` helpers in `server.mjs`; `WORLD_RP_SIGNER_PK` from the environment.
- Produces:
  - `attest.mjs`: `attestationHash({ digest, deadline, chainId, verifyingContract }) -> "0x…"`, `signAttestation({ digest, deadline, chainId, verifyingContract, privKeyHex }) -> { attestation, hash }`, `hashSignal(signal) -> "0x…"`, and `buildVerifyPayload({ digest, proof, action }) -> payload` (moved here from `server.mjs`, and made the one place `signal_hash`/`action` are computed, so both `/api/verify`'s and `/api/attest`'s callers get it from the same source)
  - `POST /api/attest` accepting `{ digest, proof }` (note: **not** `action` — see Step 4) and returning `{ attestation, deadline, nullifier }`

- [ ] **Step 1: Install the dependencies**

**This worktree is a fresh checkout, so `world/node_modules` does not exist yet** — nothing
in `world/` runs until it does, including the existing `@noble/hashes` import at the top of
`server.mjs`. The install below brings in both: npm installs everything in `package.json`
plus the package you name.

```bash
cd world && npm i @noble/curves@2
```

Expected: `@noble/curves` at 2.x in `dependencies`, and
`node -e "import('@noble/hashes/sha3.js').then(()=>console.log('ok'))"` prints `ok`.

- [ ] **Step 2: Write `world/attest.mjs`**

```js
// The EIP-712 half of WorldAttester, in JavaScript. Kept out of server.mjs so
// crosscheck.mjs can import exactly the code the server signs with — a cross-check that
// exercised a copy would prove nothing.
//
// ⚠️ Two things here fail silently if wrong, with the identical symptom ("the signature
// does not verify") and nothing pointing at the cause:
//   1. `deadline` is a uint64 in the type but a full 32-byte word inside abi.encode.
//   2. @noble/curves returns `format: "recovered"` as [recovery(1) ‖ r(32) ‖ s(32)] —
//      recovery FIRST, valued 0 or 1 — while the blob wants r ‖ s ‖ v with v = 27 + recovery.
// crosscheck.mjs exists for exactly these.
//
// 🚫 This file computes the EIP-712 hash in JavaScript and must keep doing so. Do NOT
// "simplify" it by fetching the hash from the chain — not via eth_call to
// attestationHash(), not from a cached response, not for one field. Every Solidity test
// signs whatever att.attestationHash() returned, so no test in this repo can catch an
// encoding that is wrong the same way on both sides. This independent reimplementation is
// the only thing that can, and it stops being able to the moment it asks the contract.

import { keccak_256 } from "@noble/hashes/sha3.js";
import { secp256k1 } from "@noble/curves/secp256k1.js";

const strip = (h) => h.replace(/^0x/, "");
const buf = (h) => Buffer.from(strip(h), "hex");
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const keccak = (...parts) => keccak_256(Buffer.concat(parts.map((p) => Buffer.from(p))));

/// Left-pad to a 32-byte ABI word.
const word = (b) => {
  const x = Buffer.from(b);
  if (x.length > 32) throw new Error(`word too wide: ${x.length}`);
  return Buffer.concat([Buffer.alloc(32 - x.length), x]);
};

const u64be = (n) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
};

/// A uint256 as a 32-byte ABI word. `padStart(64, "0")` guarantees both an even number of
/// hex characters and exactly 32 bytes, so no odd-length special case is needed.
const u256 = (n) => Buffer.from(BigInt(n).toString(16).padStart(64, "0"), "hex");

const DOMAIN_TYPEHASH = keccak(
  Buffer.from("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
);
const ATTESTATION_TYPEHASH = keccak(Buffer.from("LeashAttestation(bytes32 digest,uint64 deadline)"));
const NAME_HASH = keccak(Buffer.from("Leash"));
const VERSION_HASH = keccak(Buffer.from("1"));

export function domainSeparator({ chainId, verifyingContract }) {
  return keccak(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, u256(chainId), word(buf(verifyingContract)));
}

export function attestationHash({ digest, deadline, chainId, verifyingContract }) {
  const d = buf(digest);
  if (d.length !== 32) throw new Error(`digest must be 32 bytes, got ${d.length}`);
  const structHash = keccak(ATTESTATION_TYPEHASH, d, word(u64be(deadline)));
  return hex(
    keccak(Buffer.from([0x19, 0x01]), domainSeparator({ chainId, verifyingContract }), structHash)
  );
}

export function signAttestation({ digest, deadline, chainId, verifyingContract, privKeyHex }) {
  const hash = attestationHash({ digest, deadline, chainId, verifyingContract });
  const rec = secp256k1.sign(buf(hash), buf(privKeyHex), { format: "recovered", prehash: false });
  const recovery = rec[0]; // 0 or 1
  const r = rec.slice(1, 33);
  const s = rec.slice(33, 65);
  const v = 27 + recovery;
  return {
    hash,
    attestation: hex(Buffer.concat([u64be(deadline), r, s, Buffer.from([v])])), // 73 bytes
  };
}

/**
 * World ID's signal hash: keccak256 of the signal's ENCODED BYTES, shifted right by 8
 * bits. The shift is because a proof has to land inside the field in the SNARK system,
 * and keccak's 256 bits would overflow it.
 *
 * @dev **Measured on 2026-09-07: the proof IDKit returns contains no `signal_hash`.**
 *      So this is not a fallback path, it is the only path — the backend has to compute
 *      it. Note you cannot use node's built-in `crypto.createHash("sha3-256")` — SHA3 and
 *      keccak256 pad differently, produce different values, and World will refuse it.
 *
 * @dev 🔴 **"encoded bytes" is two branches, not one, and this is not our choice to
 *      make** — it mirrors `hashToField` in `@worldcoin/idkit-standalone@2.2.5`: a
 *      `0x`-prefixed hex string (a digest, always) is **decoded to raw bytes** before
 *      hashing; anything else is **UTF-8-encoded** first. Hashing a hex string's
 *      *characters* as UTF-8 instead — the obvious one-branch implementation — produces
 *      a `signal_hash` that can never match the one baked into the proof: World refuses
 *      `/api/attest` on every call on the digest path, and each failed attempt spends
 *      the action's single face scan for nothing. See `world/README.md` for the
 *      per-branch known-answer baselines this must satisfy.
 */
export function hashSignal(signal) {
  const bytes = /^0x[0-9a-fA-F]*$/.test(signal) ? buf(signal) : Buffer.from(signal, "utf8");
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
}

/// Builds the v4-legacy verify payload that `/api/attest` sends to World, and signs only
/// if World answers 200.
///
/// `signal_hash` and `action` are computed here from `digest` and the caller-supplied
/// `action`, and **never** read from `proof` — even though a real IDKit proof has no
/// `signal_hash` or `action` field of its own.
///
/// **Why `signal_hash` cannot come from the caller:** `/api/attest` is raw JSON with no
/// trusted caller, so `proof` is attacker-controlled. One face scan is supposed to
/// authorise exactly one widening, because World binds the proof to
/// `signal_hash = hash(digest)`. If this function read `proof.signal_hash` instead of
/// recomputing it, an attacker who captured one genuine proof P — a real scan that
/// approved digest D1, carrying its own signal_hash S — could POST
/// `{ digest: D2, proof: { ...P, signal_hash: S } }`. World verifies P happily, because S
/// is exactly what's baked into it, and the server would then sign an attestation for D2,
/// a widening no human's face ever approved.
///
/// **Why `action` cannot come from the caller either:** a proof is bound to the action it
/// was generated for, and this app mints a fresh action per demo because
/// `max_verifications` is 1 per action and cannot be raised (`expand-policy` itself was
/// already consumed on 2026-09-07). If `action` came from the request body, a face scan
/// made for an already-retired action would still buy a widening today — quietly breaking
/// "every widening needs a real, current face scan." Pinning `action` to the value the
/// server passes in (its own configured `ACTION`, never the request body's) closes that
/// path the same way `signal_hash` does.
export function buildVerifyPayload({ digest, proof, action }) {
  return {
    protocol_version: "3.0",
    nonce: "0x" + randomBytes(16).toString("hex"),
    action,
    environment: "production",
    responses: [
      {
        identifier: proof.credential_type ?? proof.verification_level,
        signal_hash: hashSignal(digest),
        merkle_root: proof.merkle_root,
        nullifier: proof.nullifier_hash,
        proof: proof.proof,
      },
    ],
  };
}

/// The environment /api/attest needs before it can do anything, checked as a pure
/// function of an env-like object so it can be tested without starting the server or
/// touching the network.
///
/// `WORLD_ACTION` gets its own named failure rather than folding into a generic
/// "misconfigured" error, because its failure mode is worse than the other two: `ACTION`
/// in server.mjs falls back to `"expand-policy"` for the verification harness's other
/// routes (`/api/config`, `/api/precheck`, `/api/verify`), which is fine for those — but
/// that default was already consumed on 2026-09-07, and `max_verifications` cannot be
/// raised for a consumed action. If `/api/attest` reused that fallback, an unset
/// `WORLD_ACTION` would make it silently send a dead action to World on every call — a
/// failure that looks like "World is being weird" during a live demo, when it is really
/// a missing environment variable. Returning `null` here is what lets the caller use the
/// fallback-free `process.env.WORLD_ACTION` (never the module-level `ACTION` constant)
/// once this passes.
///
/// `WORLD_ATTESTER`'s shape is checked too, not just its presence, because `buf()` (this
/// file's `Buffer.from(hex, "hex")` helper, used in `domainSeparator`) truncates a
/// malformed hex string rather than throwing. A too-short or non-hex value would
/// otherwise silently mis-encode the EIP-712 domain separator with no error anywhere.
export function checkAttestEnv(env) {
  if (!env.WORLD_RP_SIGNER_PK) return "WORLD_RP_SIGNER_PK not set";
  if (!env.WORLD_ATTESTER) return "WORLD_ATTESTER not set";
  if (!/^0x[0-9a-fA-F]{40}$/.test(env.WORLD_ATTESTER)) {
    return `WORLD_ATTESTER is not a 20-byte address (0x + 40 hex chars): ${env.WORLD_ATTESTER}`;
  }
  if (!env.WORLD_ACTION) {
    return (
      'WORLD_ACTION not set: the built-in default ("expand-policy") was already consumed ' +
      "on 2026-09-07 and max_verifications cannot be raised for a consumed action. " +
      "Create a fresh action in the Portal and set WORLD_ACTION to it before running " +
      "/api/attest."
    );
  }
  return null;
}
```

Add `import { randomBytes } from "node:crypto";` alongside the other imports at the top of `attest.mjs` for `buildVerifyPayload`'s nonce.

- [ ] **Step 3: Write `world/crosscheck.mjs`**

```js
// 🔴 The single link between the two halves of this feature.
//
// A one-byte disagreement between the JS hash and the contract's produces exactly one
// symptom: the signature does not verify. Nothing says whether the encoding, the key, the
// deadline or v was at fault. That is a half-day bug, and this script is what turns it
// into a one-line failure.
//
// Usage: WORLD_ATTESTER=0x… SEPOLIA_RPC=… node crosscheck.mjs

import { keccak_256 } from "@noble/hashes/sha3.js";
import { attestationHash, signAttestation } from "./attest.mjs";

// attest.mjs keeps its own `strip` private, so this file defines its own.
const strip = (h) => h.replace(/^0x/, "");

const RPC = process.env.SEPOLIA_RPC;
const ATTESTER = process.env.WORLD_ATTESTER;
if (!RPC || !ATTESTER) {
  console.error("need SEPOLIA_RPC and WORLD_ATTESTER");
  process.exit(1);
}

/// Read the chain id from the RPC rather than hardcoding Sepolia's. The EIP-712 domain
/// binds it, so a hardcoded value would make this script compare a Sepolia-domain hash
/// against an anvil-domain one and always mismatch — and the local check in Task 4 Step 5
/// is exactly where it runs against anvil first.
async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
}
const CHAIN_ID = Number(await rpc("eth_chainId", []));
console.log(`chain id ${CHAIN_ID}, attester ${ATTESTER}`);

// attestationHash(bytes32,uint64) — selector computed rather than pasted.
const selector =
  "0x" +
  Buffer.from(keccak_256(Buffer.from("attestationHash(bytes32,uint64)"))).toString("hex").slice(0, 8);

async function onchain(digest, deadline) {
  const data =
    selector + digest.replace(/^0x/, "") + BigInt(deadline).toString(16).padStart(64, "0");
  return rpc("eth_call", [{ to: ATTESTER, data }, "latest"]);
}

const cases = [
  ["0x" + "00".repeat(32), 0],
  ["0x" + "00".repeat(32), 1],
  ["0x" + "ff".repeat(32), "18446744073709551615"], // type(uint64).max
  ["0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121", 1800000900],
];

let bad = 0;
for (const [digest, deadline] of cases) {
  const js = attestationHash({ digest, deadline, chainId: CHAIN_ID, verifyingContract: ATTESTER });
  const chain = await onchain(digest, deadline);
  const ok = js.toLowerCase() === chain.toLowerCase();
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"}  deadline=${deadline}\n      js    ${js}\n      chain ${chain}`);
}

// And prove a signature made here is one the CONTRACT accepts. This is the check that
// catches the recovery-byte ordering, and it has to go through `verify` to do it: a blob
// with @noble's [recovery ‖ r ‖ s] mistakenly packed as r ‖ s ‖ v is still exactly 73
// bytes, so a length check cannot see the bug at all. Only ecrecover can.
if (process.env.SIGNER_PK) {
  // Deliberately NOT cases[3][1] (1800000900 = 2027-01-15): fine for the hash-agreement
  // cases above, which must stay deterministic, but `verify` below checks
  // `block.timestamp > deadline` and would start failing on that date for a reason
  // unrelated to the encoding — a time bomb. Compute a fresh near-future deadline instead.
  const deadline = Math.floor(Date.now() / 1000) + 900;
  const { attestation } = signAttestation({
    digest: cases[3][0],
    deadline,
    chainId: CHAIN_ID,
    verifyingContract: ATTESTER,
    privKeyHex: process.env.SIGNER_PK,
  });
  const len = (attestation.length - 2) / 2;
  console.log(`${len === 73 ? "ok  " : "FAIL"}  blob is ${len} bytes (want 73)`);
  if (len !== 73) bad++;

  // verify(bytes32,bytes) — one static arg, then offset/length/data for the dynamic one.
  const vsel =
    "0x" +
    Buffer.from(keccak_256(Buffer.from("verify(bytes32,bytes)"))).toString("hex").slice(0, 8);
  const body = strip(attestation);
  const padded = body + "0".repeat((64 - (body.length % 64)) % 64);
  const data =
    vsel +
    strip(cases[3][0]) +
    (64).toString(16).padStart(64, "0") +
    len.toString(16).padStart(64, "0") +
    padded;
  const accepted = BigInt(await rpc("eth_call", [{ to: ATTESTER, data }, "latest"])) === 1n;
  console.log(`${accepted ? "ok  " : "FAIL"}  the contract accepts this signature`);
  if (!accepted) bad++;
} else {
  console.log("skip  signature checks (SIGNER_PK unset)");
}

console.log(bad === 0 ? "\nall cross-checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
```

- [ ] **Step 4: Add `POST /api/attest` to `world/server.mjs`**

Insert immediately after the `/api/verify` block closes (currently line 142), before the `json(res, 404, …)` line.

```js
    // Sprint item 11: verify a Selfie Check proof, then sign an attestation for exactly
    // the digest that proof was bound to.
    //
    // `signal = digest` is the security property, not a convenience: one face scan
    // authorises one widening, and an intercepted proof cannot be moved to another. That
    // was the documented intention in IAttester from day one; here it becomes real.
    //
    // `/api/attest` is raw JSON with no trusted caller, so `proof` (and the rest of the
    // body) is attacker-controlled. `signal_hash` and `action` are therefore pinned inside
    // buildVerifyPayload — from `digest` and `process.env.WORLD_ACTION`, never from the
    // request body — rather than trusted from the caller. See buildVerifyPayload's
    // docstring in attest.mjs for the two attacks that closes: a captured proof's own
    // signal_hash moving the same face scan to a different digest, and a proof from an
    // already-retired action (this app mints a fresh one per demo, since
    // max_verifications is 1 and cannot be raised) still buying a widening today. Note the
    // deliberate absence of `action` in the destructure below — the request body's
    // `action` field, if a caller sends one, is never read. And see checkAttestEnv's
    // docstring for why WORLD_ACTION has no fallback here even though the module-level
    // ACTION (used by the other routes) does.
    if (req.method === "POST" && req.url === "/api/attest") {
      const { digest, proof } = await readBody(req);
      if (!digest || !/^0x[0-9a-fA-F]{64}$/.test(digest)) {
        return json(res, 400, { error: "digest must be 0x + 64 hex chars" });
      }
      if (!proof) return json(res, 400, { error: "missing proof" });

      // checkAttestEnv also refuses to run without WORLD_ACTION set — the module-level
      // ACTION above falls back to "expand-policy" for the other routes, but that
      // default was consumed on 2026-09-07 and must never reach World from here. Use
      // process.env.WORLD_ACTION directly below, not ACTION, so the fallback stays
      // unreachable even if this guard is ever loosened.
      const attestEnvErr = checkAttestEnv(process.env);
      if (attestEnvErr) return json(res, 500, { error: attestEnvErr });

      const payload = buildVerifyPayload({ digest, proof, action: process.env.WORLD_ACTION });

      const r = await fetch(VERIFY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const body = await r.json().catch(() => ({ error: "non-JSON response" }));
      console.log("← HTTP", r.status, JSON.stringify(body));

      // Sign nothing unless World said yes. This is the only gate between a proof and a
      // signature the chain will accept.
      if (r.status !== 200) return json(res, r.status, { http_status: r.status, ...body });

      const deadline = Math.floor(Date.now() / 1000) + 900; // 15 minutes
      const { attestation } = signAttestation({
        digest,
        deadline,
        chainId: 11155111,
        verifyingContract: process.env.WORLD_ATTESTER,
        privKeyHex: process.env.WORLD_RP_SIGNER_PK,
      });

      return json(res, 200, {
        attestation,
        deadline,
        nullifier: proof.nullifier_hash,
      });
    }
```

Add the import at the top, beside the existing `@noble/hashes` import (and drop the old local
`hashSignal` definition — it now lives in `attest.mjs`, shared with `buildVerifyPayload`):

```js
import { signAttestation, buildVerifyPayload, hashSignal, checkAttestEnv } from "./attest.mjs";
```

- [ ] **Step 4b: Add `world/check-payload-binding.mjs` and mutation-check it**

A one-off Critical from review round 1: the code above originally read
`signal_hash: proof.signal_hash ?? hashSignal(digest)` and `action: action ?? ACTION`,
trusting two attacker-controlled fields that are the entire binding between a face scan
and the digest/action it approved. Fixed by moving payload construction into
`buildVerifyPayload` (Step 2) and never reading either field from the caller. This step
proves the fix and guards against it regressing, without touching World's live API:

```js
// Guards the property fixed in review round 1: buildVerifyPayload must never let a
// caller-supplied `proof.signal_hash` or `proof.action` leak into the payload /api/attest
// sends to World. Pure — no network, no chain, no anvil.
import { buildVerifyPayload, hashSignal } from "./attest.mjs";

const digest = "0x" + "42".repeat(32);
const serverAction = "expand-policy";
const hostileProof = {
  credential_type: "device",
  signal_hash: "0x" + "de".repeat(32),
  action: "old-retired-action",
  merkle_root: "0x" + "11".repeat(32),
  nullifier_hash: "0x" + "22".repeat(32),
  proof: "0x" + "33".repeat(8),
};
const payload = buildVerifyPayload({ digest, proof: hostileProof, action: serverAction });

let bad = 0;
const signalOk = payload.responses[0].signal_hash === hashSignal(digest);
console.log(`${signalOk ? "ok  " : "FAIL"}  signal_hash is hashSignal(digest), not proof.signal_hash`);
if (!signalOk) bad++;
const actionOk = payload.action === serverAction;
console.log(`${actionOk ? "ok  " : "FAIL"}  action is the server's configured action, not proof.action`);
if (!actionOk) bad++;
console.log(bad === 0 ? "\nall checks agree" : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
```

Mutation-check it: temporarily change `buildVerifyPayload` back to
`signal_hash: proof.signal_hash ?? hashSignal(digest)` and
`action: proof.action ?? action`, run `node check-payload-binding.mjs`, confirm both lines
print `FAIL` and the exit code is 1, then revert. If the mutated version still prints
`all checks agree`, the check is vacuous — fix the check, not the code.

- [ ] **Step 4c: Extend the same check for `checkAttestEnv` (review round 2)**

A small guard round 2 added: `/api/attest` must refuse to run without `WORLD_ACTION`
set, rather than silently falling back to the module-level `ACTION` — a consumed action —
the way the other routes do. Extend `check-payload-binding.mjs` (kept in the same file
rather than a sibling, since both are "does /api/attest trust something it must not"
checks over attest.mjs's exported functions, and one `node check-payload-binding.mjs`
tells the whole story for this endpoint's trust boundary) with:

```js
import { buildVerifyPayload, hashSignal, checkAttestEnv } from "./attest.mjs";
// ... existing checks above, unchanged ...

const fullEnv = {
  WORLD_RP_SIGNER_PK: "0x" + "11".repeat(32),
  WORLD_ATTESTER: "0x" + "22".repeat(20),
  WORLD_ACTION: "demo-2026-09-09",
};
const envCases = [
  ["all three vars set", fullEnv, false],
  ["WORLD_RP_SIGNER_PK missing", { ...fullEnv, WORLD_RP_SIGNER_PK: undefined }, true],
  ["WORLD_ATTESTER missing", { ...fullEnv, WORLD_ATTESTER: undefined }, true],
  ["WORLD_ACTION missing", { ...fullEnv, WORLD_ACTION: undefined }, true],
  // fix round 4 (I3): present but not a real address — buf() truncates malformed hex
  // rather than throwing, so this has to be checked explicitly or it fails silently.
  ["WORLD_ATTESTER too short", { ...fullEnv, WORLD_ATTESTER: "0x1234" }, true],
  ["WORLD_ATTESTER not hex", { ...fullEnv, WORLD_ATTESTER: "nope" }, true],
];
for (const [label, env, wantError] of envCases) {
  const err = checkAttestEnv(env);
  const ok = wantError ? typeof err === "string" && err.length > 0 : err === null;
  console.log(`${ok ? "ok  " : "FAIL"}  checkAttestEnv: ${label}${err ? ` -> ${err}` : ""}`);
  if (!ok) bad++;
}
const actionErr = checkAttestEnv({ ...fullEnv, WORLD_ACTION: undefined });
const namesTheVar = typeof actionErr === "string" && actionErr.includes("WORLD_ACTION");
console.log(`${namesTheVar ? "ok  " : "FAIL"}  the WORLD_ACTION error names the variable`);
if (!namesTheVar) bad++;
```

Mutation-check it: temporarily remove the `if (!env.WORLD_ACTION) { ... }` block from
`checkAttestEnv`, run `node check-payload-binding.mjs`, confirm the `WORLD_ACTION missing`
and `names the variable` lines print `FAIL` with exit code 1, then revert.

- [ ] **Step 4d: Pin `hashSignal`'s two-branch domain against IDKit, not against itself
  (final whole-branch review)**

The highest-stakes defect found in this plan: `hashSignal` originally UTF-8-encoded
whatever string it was given, including a `0x`-prefixed digest. IDKit's own
`hashToField` (`@worldcoin/idkit-standalone@2.2.5`) decodes a `0x`-prefixed hex string to
raw bytes instead — so the two never agreed on the digest path, `/api/attest` could never
succeed, and every failed attempt spent the action's single face scan. Nothing in Step 4b
or 4c could catch this: they assert properties of `buildVerifyPayload` and
`checkAttestEnv` against `hashSignal`'s own output, which agrees with itself no matter
how wrong the hashing domain is. Extend `check-payload-binding.mjs` with assertions whose
expected values are computed *without* calling `hashSignal`:

```js
import { keccak_256 } from "@noble/hashes/sha3.js";
// ... existing imports and checks above, unchanged ...

const toSignalHash = (bytes) => {
  const h = BigInt("0x" + Buffer.from(keccak_256(bytes)).toString("hex")) >> 8n;
  return "0x" + h.toString(16).padStart(64, "0");
};

const hashCases = [
  ["a zero digest is decoded as 32 raw bytes, not UTF-8", "0x" + "00".repeat(32), toSignalHash(Buffer.alloc(32))],
  [
    "a real digest is decoded as 32 raw bytes (measured against IDKit's own bundle)",
    "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
    "0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3", // hardcoded, measured
  ],
  [
    "the empty string still takes the UTF-8 branch (world/README.md baseline)",
    "",
    "0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4", // hardcoded baseline
  ],
  [
    "a plain (non-hex) string still takes the UTF-8 branch",
    "widen:vendors.acme.eth:5000",
    toSignalHash(Buffer.from("widen:vendors.acme.eth:5000", "utf8")),
  ],
];
for (const [label, signal, want] of hashCases) {
  const ok = hashSignal(signal) === want;
  console.log(`${ok ? "ok  " : "FAIL"}  hashSignal: ${label}`);
  if (!ok) bad++;
}
```

Mutation-check it: temporarily revert `hashSignal` to the always-UTF-8 form
(`keccak_256(signal)` on the raw string, no branch), run `node check-payload-binding.mjs`,
confirm the two digest cases print `FAIL` while the two string cases stay `ok`, then
revert. This is the one mutation in this plan a reader must not skip — it is the only
thing standing between this plan and rebuilding the exact bug it just fixed.

- [ ] **Step 5: Verify the JS hash against the contract, locally first**

Before anything is deployed, check the two implementations agree using a locally-deployed attester on anvil.

> ⚠️ Run this from **this branch's own checkout**, which during execution is the worktree, not
> `~/DEV/leash`. `src/WorldAttester.sol` exists only on the `world-attester` branch, so
> `forge create` from the main checkout fails with a source-file-not-found error that looks
> like a Foundry problem and is really a wrong-directory problem. The private key below is
> anvil's published account #0 test key — it holds nothing on any real network, and no real
> key belongs in this step.

```bash
anvil --port 8545 &
cd "$(git rev-parse --show-toplevel)"   # this branch's checkout, NOT ~/DEV/leash
# Deployed with anvil account #0 as the SIGNER, so the signature check below needs no
# real secret. Step 5 must never touch WORLD_RP_SIGNER_PK.
#
# --constructor-args MUST be the LAST flag. It is variadic, so anything after it is eaten
# as another constructor argument: put it first and forge swallows --rpc-url and the rest,
# then either reports "Constructor argument count mismatch: expected 1 but got 6" or - worse
# - silently falls back to the default RPC at localhost:8545 and fails to connect. Measured
# on forge 1.7.1.
forge create src/WorldAttester.sol:WorldAttester \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast \
  --constructor-args 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Take the deployed address, then — note anvil's chain id is 31337, not Sepolia's:

```bash
cd world && SEPOLIA_RPC=http://127.0.0.1:8545 WORLD_ATTESTER=<address> \
  SIGNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  node crosscheck.mjs
```

Expected: `chain id 31337`, **six** `ok` lines (four hash cases, the 73-byte length, and
the contract accepting the signature), and `all cross-checks agree`. The script reads
the chain id from the RPC, so the same script is what runs against Sepolia in Task 5 — no
separate local variant to drift out of sync.

If it mismatches, the fault is one of the two ⚠️ items in `attest.mjs`'s header. Check the
32-byte padding of `deadline` first.

Then kill anvil: `kill %1`

- [ ] **Step 6: Commit**

```bash
git add world/attest.mjs world/crosscheck.mjs world/server.mjs world/package.json world/package-lock.json
git commit -m "feat: sign an attestation only after a Selfie Check proof verifies

POST /api/attest takes a digest and an IDKit proof, sets signal = digest
so one face scan authorises exactly one widening, verifies the proof at
World's v4 endpoint, and signs only on HTTP 200. An intercepted proof
cannot be moved to a different widening.

The EIP-712 hashing lives in attest.mjs rather than server.mjs so
crosscheck.mjs can import the code the server actually signs with - a
cross-check against a copy would prove nothing.

Two things in here fail with an identical, uninformative symptom if they
are wrong: deadline is a uint64 in the type but a full 32-byte word
inside abi.encode, and @noble/curves 2.x returns format 'recovered' as
[recovery, r, s] with recovery FIRST and valued 0 or 1, while the blob
wants r, s, v with v = 27 + recovery. Both are noted at the top of
attest.mjs and both are what the cross-check catches."
```

---

## Task 5: deploy, re-delegate, document

**Files:**
- Create: `script/DeployWorldAttester.s.sol`
- Modify: `docs/deployments.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above; the existing deployed `PolicyApprovals` at `0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4` and `ETH_REGISTRY` at `0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2`.
- Produces: a deployed `WorldAttester` and a new `LeashAccount` impl; `WORLD_ATTESTER` in `.env`.

**Nothing in the control plane moves.** ENS is untouched and the subgraph is untouched. The existing `PolicyApprovals` list is reused deliberately: `PolicyApprovals.approve` and `LeashRegistry.register` keep `MockAttester`, per decision 1 of the spec.

- [ ] **Step 1: Write the deploy script**

```solidity
// script/DeployWorldAttester.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { WorldAttester } from "../src/WorldAttester.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title DeployWorldAttester — sprint item 8's second half
/// @notice Deploys `WorldAttester` and a new `LeashAccount` impl pointing at it. The
///         existing `PolicyApprovals` list is reused: only LeashAccount's widenings become
///         real, per decision 1 of the design.
///
/// @dev **Contains no `WALLET_PK`.** Re-delegation is an authorization WALLET signs for
///      itself and is sent by hand with `cast send --auth`. Same reasoning as
///      `script/DeployAccount.s.sol`.
contract DeployWorldAttester is Script {
    uint256 constant SEPOLIA = 11155111;
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    /// The address WORLD_RP_SIGNER_PK derives to, and the signer the Portal shows for
    /// rp_ef35d4e2d4f1a031. Verified 2026-09-09.
    address constant RP_SIGNER = 0x85b89D21DB13f220601430d48244B2AE06120969;

    function run() external {
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        WorldAttester att = new WorldAttester(RP_SIGNER);
        LeashAccount impl =
            new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(address(att)));
        vm.stopBroadcast();

        console.log("WorldAttester   ", address(att));
        console.log("LeashAccount    ", address(impl));
        console.log("  SIGNER        ", att.SIGNER());
        console.log("  impl ATTESTER ", address(impl.ATTESTER()));
        console.log("");
        console.log("Next, and WALLET signs it itself - do NOT put this key in a script:");
        console.log("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...");
    }
}
```

- [ ] **Step 2: Simulate**

> 🔑 **Extract single variables; never source `.env` wholesale.** That file also holds
> `WALLET_PK`, `AGENT_PK`, `WORLD_RP_SIGNER_PK`, `GRAPH_DEPLOY_KEY` and `LEASH_SECRET`, none
> of which this step needs, and `SEPOLIA_RPC` carries an API key that must never be echoed.
> Pull out exactly what the command uses:
>
> ```bash
> ENV=/home/ubuntu/DEV/ETHOnline2026/.env
> get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
> ```

```bash
ADMIN_PK=$(get ADMIN_PK) forge script script/DeployWorldAttester.s.sol:DeployWorldAttester \
  --rpc-url "$(get SEPOLIA_RPC)"
```

Expected: `SIMULATION COMPLETE`, no revert, and the printed `SIGNER` equals
`0x85b89D21DB13f220601430d48244B2AE06120969`. Note the RPC is substituted inline so its API
key never lands in a shell variable that a later command might print.

- [ ] **Step 3: Deploy — requires explicit human authorisation**

This changes onchain state. **Ask before running it**, and do not proceed on an earlier approval.

Run: the same command with `--broadcast --slow`
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`

Then put the attester's address in `.env` as `WORLD_ATTESTER=0x…`.

- [ ] **Step 4: Run the cross-check against the real deployment**

This step needs **no private key at all.** The four hash cases cover everything that is
chain-dependent — `chainId` and `verifyingContract` both feed the domain separator, so a wrong
domain fails the hash comparison. Signing and the recovery-byte order are chain-independent and
were already proven against anvil in Task 4 Step 5, so `SIGNER_PK` is deliberately left unset
here and the script prints `skip  signature checks`.

```bash
cd world && SEPOLIA_RPC="$(get SEPOLIA_RPC)" WORLD_ATTESTER="$(get WORLD_ATTESTER)" \
  node crosscheck.mjs
```

Expected: `chain id 11155111`, four `ok` lines, `skip  signature checks (SIGNER_PK unset)`,
and `all cross-checks agree`.

Then assert the deployed attester trusts the right signer — the one thing a Sepolia run can
check that anvil cannot, and it needs no key either:

```bash
cast call "$(get WORLD_ATTESTER)" 'SIGNER()(address)' --rpc-url "$(get SEPOLIA_RPC)"
```

Expected: `0x85b89D21DB13f220601430d48244B2AE06120969`. A mismatch means the constructor got
the wrong argument and every attestation the server signs will be rejected onchain.

**And assert the wallet actually trusts the attester the server is signing for.** This is the
one check that catches a *stale but valid* `WORLD_ATTESTER` — a previous deployment carries
the same `SIGNER`, so the check above passes and all four hash cases pass, and the mismatch
would first appear as `NotAttested` at `allowPayee` with the face scan already spent. Also
key-free and view-only; `ATTESTER()` is an immutable in the delegate's code, so this reads
through the 7702 wallet:

```bash
W="$(get WALLET_ADDR)"; RPC="$(get SEPOLIA_RPC)"
onchain=$(cast call "$W" 'ATTESTER()(address)' --rpc-url "$RPC")
configured="$(get WORLD_ATTESTER)"
[ "${onchain,,}" = "${configured,,}" ] \
  && echo "wallet trusts the configured attester" \
  || echo "MISMATCH: wallet trusts $onchain, server signs for $configured"
```

Run this **after** Step 5's re-delegation as well as here — before re-delegation it still
reports the old `MockAttester` (`0x268990a91B0727E80d38d5ED4Ab10d8889754124`), which is
correct and expected, not a failure.

**Do not proceed past this step on a mismatch.** Everything downstream fails identically and uninformatively if the two implementations disagree.

- [ ] **Step 5: Re-delegate WALLET — requires explicit human authorisation**

**First snapshot the wallet's state, so survival is measured rather than asserted.** All
three calls are `view` and need no key. `LENS` is not in `.env`; the deployed `LeashLens` is
`0xB6eB4C26AF866057920f7AB6fAFf69A914067B83`.

```bash
RPC="$(get SEPOLIA_RPC)"; W="$(get WALLET_ADDR)"; A="$(get AGENT_ADDR)"
LENS=0xB6eB4C26AF866057920f7AB6fAFf69A914067B83
USDC="$(get MOCK_USDC)"
NODE=$(cast call "$W" 'nodeFor(string)(bytes32)' vendors --rpc-url "$RPC")

before_binding=$(cast call "$W" 'bindingOf(address)(bytes32,string,bool)' "$A" --rpc-url "$RPC")
before_rule=$(cast call "$W" 'ruleOf(bytes32,address)((bool,uint256,uint256,uint64,uint16,uint16,uint32))' "$NODE" "$USDC" --rpc-url "$RPC")
printf 'binding: %s\nrule: %s\n' "$before_binding" "$before_rule"
```

Then re-delegate, and read the same two back:

```bash
cast send "$W" --auth <new impl> --private-key "$(get WALLET_PK)" --rpc-url "$RPC"
cast call "$LENS" 'delegateOf(address)(bool,address)' "$W" --rpc-url "$RPC"

after_binding=$(cast call "$W" 'bindingOf(address)(bytes32,string,bool)' "$A" --rpc-url "$RPC")
after_rule=$(cast call "$W" 'ruleOf(bytes32,address)((bool,uint256,uint256,uint64,uint16,uint16,uint32))' "$NODE" "$USDC" --rpc-url "$RPC")
[ "$before_binding" = "$after_binding" ] && [ "$before_rule" = "$after_rule" ] \
  && echo "state survived re-delegation" || echo "STATE CHANGED - stop and investigate"
```

Expected: `delegateOf` returns `(true, <new impl>)`, and `state survived re-delegation`.

**Why it survives, and why that is worth measuring.** The ERC-7201 slot derives from
`keccak256("leash.account.v1")`, the layout is unchanged and the EOA is the same, so
`bindings`, `rules`, `payees` and `spent` are all still there. No per-wallet setup is
repeated, and `bindAgent` would revert `AlreadyBound` — which is correct. That argument is
sound, but it is an argument: if the layout had drifted, or the slot constant had been
recomputed from a different string, the wallet would come back blank and the demo would
discover it live. Two `view` calls settle it beforehand.

`$WALLET_PK` appears here because **the wallet signs its own EIP-7702 authorization** — this
is the one command in the plan that needs it, it is run by a human, and it must never be put
in a script.

Old attestations cannot be replayed, because every `LeashAccount` digest includes `SELF`,
the impl's own deploy address, and that changed.

> ⚠️ **Every widening from here needs a real face scan, and `max_verifications` is 1 per
> World action and cannot be raised.** Create a fresh action in the Portal before the demo
> and before recording, and set `WORLD_ACTION` to it. `expand-policy` was consumed on
> 2026-09-07.

- [ ] **Step 6: Prove the demo beat works on chain**

Same single-variable extraction as Step 2 — never `set -a` or source `.env` wholesale:

```bash
ENV=/home/ubuntu/DEV/ETHOnline2026/.env
get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
```

Compute the digest `allowPayee` will consume. `nonce` is caller-chosen and only needs to be
unused for this `(node, token, payee)` triple — replay is prevented by
`attestationUsed[digest]`, so reusing a consumed digest reverts `AttestationReused`, not the
nonce itself:

```bash
RPC="$(get SEPOLIA_RPC)"; W="$(get WALLET_ADDR)"; TOKEN="$(get MOCK_USDC)"
NODE=$(cast call "$W" 'nodeFor(string)(bytes32)' vendors --rpc-url "$RPC")
PAYEE=<vendor address the demo is unblocking>
NONCE=1
DIGEST=$(cast call "$W" 'payeeDigest(bytes32,address,address,uint256)(bytes32)' "$NODE" "$TOKEN" "$PAYEE" "$NONCE" --rpc-url "$RPC")
echo "$DIGEST"
```

`NODE` is recomputed here rather than carried over from Step 5, so this step stands alone in
a fresh shell — do not rely on a variable set minutes ago in another terminal.

> ⏱️ **The attestation expires 15 minutes after it is signed** (`server.mjs` sets
> `deadline = now + 900`). The whole tail of this step — copy the attestation, run
> `cast send` — has to finish inside that window, and past it `allowPayee` reverts
> `NotAttested` with the face scan already spent and the action consumed. So **have the
> `cast send` line below typed out and ready, with everything but the attestation filled in,
> before you scan.** Paste, send. Do not go looking for the payee address or the token
> decimals after the scan.

Open `world/index.html` (`node world/server.mjs`, tunnel or browse to `localhost:8787`),
paste `$DIGEST` into the **Signal** field — the page detects the `0x…64-hex` shape and
switches to the attestation path (the badge under Verify will read
"/api/attest — attestation path") — and scan. **This is the one Selfie Check attempt this
action has; do not scan before the digest is in the field.** On success the page shows the
`attestation` bytes ready to copy, plus `deadline` and `nullifier`.

Send `allowPayee` **from the wallet itself** — the function is `onlySelf`, so it must come
from `WALLET_PK`, not `AGENT_PK` or `ADMIN_PK`:

```bash
cast send "$W" 'allowPayee(bytes32,address,address,uint256,bytes)' \
  "$NODE" "$TOKEN" "$PAYEE" "$NONCE" <attestation from the page> \
  --private-key "$(get WALLET_PK)" --rpc-url "$RPC"
```

Then have the agent retry the payment that was blocked with reason 6 and watch it succeed.

Record the transaction hashes for `docs/deployments.md`.

- [ ] **Step 7: Update the documentation**

In `docs/deployments.md`: add `WorldAttester` and the new `LeashAccount` impl to the
current addresses table, add the re-delegation transaction, and replace the
"⚠️ Currently wired to `MockAttester`" section with what is now true — that
`LeashAccount`'s widenings verify a real RP-signer signature, and that
`PolicyApprovals.approve` and `LeashRegistry.register` still use the mock, with the reason.

In `README.md`: rewrite the `MockAttester` callout under the asymmetry table. It currently
says nothing about World ID is enforced onchain. That sentence becomes false at Step 5 and
must not be left standing.

- [ ] **Step 8: Commit**

```bash
git add script/DeployWorldAttester.s.sol docs/deployments.md README.md
git commit -m "feat: deploy WorldAttester and re-delegate onto it

LeashAccount's widenings now verify a real ECDSA signature from the
World RP signer over an EIP-712 struct. The two conditions behind
'widening requires a live human' are both guarding for the first time:
msg.sender == address(this) and an attestation that only exists after a
Selfie Check proof verified.

Nothing in the control plane moved. The existing PolicyApprovals list is
reused, so ENS and the subgraph are untouched, and the wallet's
ERC-7201 state survived the re-delegation - no per-wallet setup was
repeated.

PolicyApprovals.approve and LeashRegistry.register still use
MockAttester. Switching them means redeploying three contracts, an ENS
re-wire and two more Portal actions, and they happen at deployment time
where no demo shows them. The mechanism they would use is the same
contract. README and deployments.md now say which half is enforced
onchain instead of saying none of it is."
```

---

## Self-Review

**Spec coverage** — section by section:

| Spec section | Task |
|---|---|
| Decision 1 (only `LeashAccount` switches) | 5 (reuses the existing APPROVALS) |
| Decision 2 (73 packed bytes) | 1 |
| Decision 3 (EIP-712, not the raw digest) | 1 |
| Decision 4 (deadline inside the struct) | 1 |
| Decision 5 (`SIGNER` immutable) | 1 |
| The attestation format table | 1 |
| `verify` never reverts | 1 (fuzz test) |
| `describe()` honesty | 1 |
| Six TYPEHASHes, four getters | 2 |
| `POST /api/attest`, `signal = digest`, 15-minute deadline | 4 |
| `@noble/curves` recovery-byte ordering | 4 (Global Constraints and `attest.mjs`'s header) |
| The cross-check | 4 (locally) and 5 (against the deployment) |
| Deployment sequence | 5 |
| Wallet state survives; `SELF` prevents replay | 5 |
| "What this does not claim" | 5 (Step 7 rewrites both documents) |
| Test plan, every row | 1 and 3 |
| Explicitly not doing | not built at any point |

**Placeholder scan:** no `TBD`, no `TODO`, no "add appropriate error handling", no "similar
to Task N". Every code step contains the code.

**Type consistency:** `attestationHash(bytes32,uint64)` has that signature in the contract
(Task 1), in `attest.mjs` (Task 4) and in `crosscheck.mjs`'s selector (Task 4).
`signAttestation` returns `{ hash, attestation }` in Task 4 Step 2 and is destructured as
`{ attestation }` in Step 4. `WorldAttester.ZeroSigner` is referenced by selector in Task 1's
test and declared in Task 1's contract. `ruleDigest` and `restoreDigest` have identical
parameter lists in Task 2's test, Task 2's implementation and Task 3's use.

**One gap found and closed while reviewing:** the spec's test plan has a row for
`attestationHash` matching "a hand-computed constant". Hand-computing a keccak chain is not
something to do by eye, so Task 1's version asserts determinism and non-zero, and the real
anchor is Task 4 Step 5 — comparing against the contract on anvil before anything is
deployed. That is a stronger check than a pasted constant, because a pasted constant can be
wrong in the same way twice.

---

## Execution Handoff

Two options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, with a review between
   tasks. Matches how tasks 1-7 of `LeashAccount` were built, and each task here has its own
   test cycle.
2. **Inline Execution** — executed in this session with checkpoints.

Task 5 needs a human at two steps regardless of choice: the broadcast, and the
re-delegation.

---

## Post-Execution: revoke-bypass fix (found on this branch)

Not part of the original plan above — recorded here because this branch is where it was
found and fixed.

`restoreAgent` was correctly gated on an attestation, but `revokeAgent` → `unbindAgent` →
`bindAgent` restored a revoked agent to fully active with **no attestation at all**:
`unbindAgent` deleted the binding (clearing `node` back to zero), so `bindAgent`'s
`AlreadyBound` guard — the guard `bindAgent`'s own comment names as the defense against
exactly this "rebind for free after a revocation" attack — never fired. The bypass needs
the WALLET key (`bindAgent` is `onlySelf`), so it is not agent privilege escalation, but it
defeats the point of attesting widenings: the wallet key alone should not be sufficient to
undo a revocation.

Fix: `unbindAgent` now refuses to unbind a binding that is currently `revoked`, reverting
with a new `RevokedNeedsRestore()` error. No storage layout change — the decision uses the
existing `revoked` flag that `revokeAgent` already keeps set. The only route out of
`revoked` is now `restoreAgent`, which is attested. Refusing costs nothing in capability:
a revoked agent is already powerless (`spend` blocks it at step 2b), so this only forfeits
storage cleanup on that one binding.

New regression tests in `test/LeashAccountBinding.t.sol`: `unbindAgent` reverts on a
revoked binding; the full `revoke → unbind → bind` sequence can no longer reach an active
binding; `restoreAgent` with a valid attestation still restores a revoked agent. The
pre-existing mis-binding remedy (`test_a_mis_binding_is_correctable_for_free` — bind,
unbind, rebind, no revocation involved) is untouched. `README.md`'s "Restore a revoked
agent" row is now true as written; a paragraph was added below the widening/reduction
table explaining the one exception to "unbind is free" — and a follow-up paragraph
states the claim precisely: only *re-activating that same revoked address* now needs an
attestation. Binding a **fresh** agent address to the same node is still free by design
(`bindAgent` grants authority starting from zero; the ENS side and approval list decide
its content), and the README says so explicitly rather than leaving a reader to
over-read the fix as "no agent on this node without a face scan."

### Follow-up: `restoreDigest` missing `restoreAgent`'s node/label check

A second, related gap surfaced in review: `restoreDigest` did not mirror `restoreAgent`'s
`node == nodeFor(label)` check, so it would hand back a digest for a mismatched pair that
`restoreAgent` can never consume (it reverts `NodeLabelMismatch` before reaching
`_consumeAttestation`). With World's `max_verifications: 1` per action, signing and
attesting that digest would burn a real face scan on an attestation that can never be
spent. `restoreDigest` now performs the same check and reverts `NodeLabelMismatch` up
front. `ruleDigest` and `payeeDigest` were checked against their consumers (`setRule`,
`allowPayee`) for an analogous omission — neither consumer performs any pre-attestation
validation beyond what its digest already encodes, so no equivalent gap exists there.
New test: `test_restoreDigest_rejects_a_node_label_mismatch` in
`test/LeashAccountDigests.t.sol`, alongside the other `restoreDigest`/`ruleDigest` tests.
