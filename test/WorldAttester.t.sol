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
    function test_an_expired_deadline_fails() public view {
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
        assertFalse(att.verify(digest, abi.encodePacked(ok, hex"00"))); // 74
        assertFalse(att.verify(digest, _slice(ok, 72))); // 72
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

    /// The fuzz above almost never produces a 73-byte blob, so it only ever exercises the
    /// length gate. This one is shaped correctly by construction, so arbitrary r/s/v reach
    /// `tryRecover` — which is the only part of `verify` that could plausibly revert.
    function testFuzz_a_well_shaped_blob_never_reverts(
        bytes32 d,
        uint64 deadline,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) public view {
        att.verify(d, abi.encodePacked(deadline, r, s, v));
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
        assertTrue(
            att.attestationHash(keccak256("other"), 1000) != base, "digest must reach the hash"
        );
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
