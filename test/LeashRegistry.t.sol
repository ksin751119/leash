// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashRegistry } from "../src/LeashRegistry.sol";
import { IRegistry, IERC1155Singleton } from "../src/IRegistry.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

/// @dev Always refuses — used to prove no subname can be issued without an attestation.
contract RejectingAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }

    function describe() external pure returns (string memory) {
        return "RejectingAttester";
    }
}

/// @dev Can be switched off part-way through — used to exercise the issue and renew paths
///      separately. The attester is immutable, so testing "renewal needs an attestation"
///      means making one attester accept and then refuse, rather than swapping it out.
contract ToggleAttester is IAttester {
    bool public accepting = true;

    function setAccepting(bool v) external {
        accepting = v;
    }

    function verify(bytes32, bytes calldata) external view returns (bool) {
        return accepting;
    }

    function describe() external pure returns (string memory) {
        return "ToggleAttester";
    }
}

contract LeashRegistryTest is Test {
    LeashRegistry reg;

    address constant ADMIN = address(0xAD31);
    address constant REGISTRAR = address(0x8E61);
    address constant HOLDER = address(0x0E11);
    address constant STRANGER = address(0x5721);
    address constant RESOLVER = address(0x0501);
    address constant RESOLVER2 = address(0x0502);
    address constant SUBREG = address(0x5B6E);

    uint64 constant DAY = 1 days;
    string constant LABEL = "vendors";
    bytes constant ATT = hex"c0ffee";

    /// namehash("leash.eth") — computed on 09-08 and cross-checked against
    /// docs/deployments.md
    bytes32 constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    MockAttester attester;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_757_000_000);
        attester = new MockAttester();
        reg = new LeashRegistry(ADMIN, attester, PARENT_NODE);
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, true);
    }

    /// @dev A fresh nonce each time — a spent attestation cannot be replayed (same
    ///      semantics as PolicyApprovals).
    function _register(uint64 duration) internal returns (uint256) {
        vm.prank(REGISTRAR);
        return reg.register(LABEL, HOLDER, address(0), RESOLVER, duration, ++nonce, ATT);
    }

    // --- tokenId derivation: against the rule measured onchain ---

    /// The measured tokenId for `leash.eth` is its labelhash with the low 32 bits zeroed.
    /// Transcribe this wrong and the parent will not recognise the names we issue.
    function test_canonical_id_matches_the_measured_ens_rule() public view {
        uint256 cid = reg.canonicalIdOf("leash");
        assertEq(cid, 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000);
        // The top 224 bits are the labelhash itself
        assertEq(cid >> 32, uint256(keccak256("leash")) >> 32);
        // The low 32 bits must be zero
        assertEq(cid & 0xffffffff, 0);
    }

    // --- issuing names ---

    function test_registers_a_name_and_resolves_it() public {
        uint256 tokenId = _register(30 * DAY);

        assertEq(reg.getResolver(LABEL), RESOLVER);
        assertEq(reg.ownerOf(tokenId), HOLDER);
        assertEq(reg.balanceOf(HOLDER, tokenId), 1, "singleton: supply 1");
        assertEq(reg.tokenIdOf(LABEL), tokenId);
    }

    function test_first_token_id_has_version_zero() public {
        uint256 tokenId = _register(30 * DAY);
        assertEq(tokenId, reg.canonicalIdOf(LABEL));
    }

    function test_unregistered_name_resolves_to_zero() public view {
        assertEq(reg.getResolver("never-issued"), address(0));
        assertEq(address(reg.getSubregistry("never-issued")), address(0));
        assertEq(reg.tokenIdOf("never-issued"), 0);
    }

    function test_live_name_cannot_be_taken_over() public {
        _register(30 * DAY);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);
    }

    function test_rejects_empty_label_and_zero_duration() public {
        vm.startPrank(REGISTRAR);
        vm.expectRevert(LeashRegistry.EmptyLabel.selector);
        reg.register("", HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
        vm.expectRevert(LeashRegistry.ZeroDuration.selector);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, 0, ++nonce, ATT);
        vm.expectRevert(LeashRegistry.ZeroOwner.selector);
        reg.register(LABEL, address(0), address(0), RESOLVER, DAY, ++nonce, ATT);
        vm.stopPrank();
    }

    // --- expiry: the free dead man's switch ---

    /// **This is the main reason the whole contract exists.** Nobody sends a transaction;
    /// the time passes and the resolver is gone, so the agent can resolve no policy
    /// (reason code 3) and no money moves.
    function test_expiry_kills_resolution_with_no_transaction() public {
        _register(DAY);
        assertEq(reg.getResolver(LABEL), RESOLVER);

        vm.warp(block.timestamp + DAY + 1);

        assertEq(reg.getResolver(LABEL), address(0), "resolver gone");
        assertEq(address(reg.getSubregistry(LABEL)), address(0));
        assertEq(reg.ownerOf(reg.canonicalIdOf(LABEL)), address(0), "ownerOf agrees");
    }

    /// Still alive at the expiry second, dead the second after — the boundary must not be
    /// off by one.
    function test_expiry_boundary_is_exclusive() public {
        _register(DAY);
        uint256 exp = block.timestamp + DAY;

        vm.warp(exp - 1);
        assertEq(reg.getResolver(LABEL), RESOLVER, "still live one second before");

        vm.warp(exp);
        assertEq(reg.getResolver(LABEL), address(0), "dead at expiry");
    }

    /// After expiry it can be re-registered, and **the old tokenId then points at
    /// nothing**.
    function test_expired_name_can_be_reissued_and_the_old_token_dies() public {
        uint256 oldId = _register(DAY);
        vm.warp(block.timestamp + DAY + 1);

        vm.prank(REGISTRAR);
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);

        assertTrue(newId != oldId, "version bumped");
        assertEq(newId, reg.canonicalIdOf(LABEL) | 1);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
        assertEq(reg.ownerOf(newId), STRANGER);
        assertEq(reg.ownerOf(oldId), address(0), "old token points at nothing");
        assertEq(reg.balanceOf(HOLDER, oldId), 0, "old token burned");
    }

    // --- renewal ---

    function test_renew_extends_the_leash() public {
        _register(DAY);
        vm.prank(REGISTRAR);
        reg.renew(LABEL, 30 * DAY, ++nonce, ATT);

        vm.warp(block.timestamp + DAY + 1);
        assertEq(reg.getResolver(LABEL), RESOLVER, "survived the original expiry");
    }

    /// Renewal points in the **widening direction** (it extends how long the agent lives),
    /// so it is registrar-only.
    function test_renew_is_registrar_only() public {
        _register(DAY);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(STRANGER);
        reg.renew(LABEL, DAY, ++nonce, ATT);
    }

    function test_cannot_renew_a_dead_name() public {
        _register(DAY);
        vm.warp(block.timestamp + DAY + 1);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, ++nonce, ATT);
    }

    // --- revocation: the middle of the three revocation layers ---

    /// Kills one agent, leaves the others alone, and **needs no attestation at all**.
    function test_admin_can_revoke_instantly_without_attestation() public {
        uint256 tokenId = _register(30 * DAY);
        vm.prank(REGISTRAR);
        reg.register("payroll", HOLDER, address(0), RESOLVER2, 30 * DAY, ++nonce, ATT);

        vm.prank(ADMIN);
        reg.revoke(LABEL);

        assertEq(reg.getResolver(LABEL), address(0), "this agent is dead");
        assertEq(reg.getResolver("payroll"), RESOLVER2, "the other agent is untouched");
        assertEq(reg.balanceOf(HOLDER, tokenId), 0, "token burned");
    }

    function test_name_owner_can_revoke_their_own_name() public {
        _register(30 * DAY);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0));
    }

    function test_stranger_cannot_revoke() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(STRANGER);
        reg.revoke(LABEL);
    }

    function test_revoked_name_can_be_reissued_under_a_new_token() public {
        uint256 oldId = _register(30 * DAY);
        vm.prank(ADMIN);
        reg.revoke(LABEL);

        vm.prank(REGISTRAR);
        uint256 newId = reg.register(LABEL, STRANGER, address(0), RESOLVER2, DAY, ++nonce, ATT);
        assertTrue(newId != oldId);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
    }

    // --- changing the resolver: the lightest of the three revocation layers ---

    function test_admin_can_repoint_a_name_without_touching_the_agent() public {
        _register(30 * DAY);
        vm.prank(ADMIN);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER2);
    }

    /// 🔴 #6 regression: **a name's holder cannot change its own resolver.**
    ///
    /// This deliberately departs from normal ENS practice — in standard ENS a holder can of
    /// course set its own resolver. In Leash's model **a name is a leash, not a
    /// possession**: it governs its holder rather than belonging to them.
    /// The first version accepted `msg.sender == e.owner`, which turned "issue the subname
    /// to WALLET" into "WALLET can change its own policy" — in direct contradiction with
    /// the measured `roles(WALLET) = 0`.
    function test_name_owner_cannot_repoint_their_own_leash() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(HOLDER);
        reg.setResolver(LABEL, RESOLVER2);
        assertEq(reg.getResolver(LABEL), RESOLVER, "unchanged");
    }

    function test_name_owner_cannot_repoint_subregistry_either() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(HOLDER);
        reg.setSubregistry(LABEL, SUBREG);
    }

    function test_stranger_cannot_repoint() public {
        _register(30 * DAY);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        vm.prank(STRANGER);
        reg.setResolver(LABEL, RESOLVER2);
    }

    /// But a holder can still **revoke** its own name — a reduction must never be blocked.
    /// This test pins that asymmetry: they cannot widen, but they can give it up.
    function test_name_owner_can_still_revoke_but_not_repoint() public {
        _register(30 * DAY);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0));
    }

    function test_subregistry_can_be_set_and_read() public {
        _register(30 * DAY);
        vm.prank(ADMIN);
        reg.setSubregistry(LABEL, SUBREG);
        assertEq(address(reg.getSubregistry(LABEL)), SUBREG);
    }

    // --- access control ---

    function test_only_registrar_or_owner_can_register() public {
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(STRANGER);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);

        // The owner does not have to add itself as a registrar first
        vm.prank(ADMIN);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
        assertEq(reg.getResolver(LABEL), RESOLVER);
    }

    function test_registrar_can_be_revoked() public {
        vm.prank(ADMIN);
        reg.setRegistrar(REGISTRAR, false);
        vm.expectRevert(LeashRegistry.NotRegistrar.selector);
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, ++nonce, ATT);
    }

    function test_only_owner_manages_registrars_and_parent() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.setRegistrar(STRANGER, true);
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.setParent(IRegistry(address(1)), "leash");
        vm.expectRevert(LeashRegistry.NotOwner.selector);
        reg.transferOwnership(STRANGER);
        vm.stopPrank();
    }

    function test_ownership_cannot_be_burned() public {
        vm.expectRevert(LeashRegistry.ZeroOwner.selector);
        vm.prank(ADMIN);
        reg.transferOwnership(address(0));
    }

    // --- the parent pointer ---

    function test_parent_is_reported_for_indexers() public {
        vm.prank(ADMIN);
        reg.setParent(IRegistry(address(0xBEEF)), "leash");
        (IRegistry p, string memory l) = reg.getParent();
        assertEq(address(p), address(0xBEEF));
        assertEq(l, "leash");
    }

    // --- ERC-1155 singleton semantics ---

    /// After a transfer, `ownerOf` and the token balance must tell the same story — the
    /// same fact lives in two places, and out of sync you get "A holds the token but the
    /// name belongs to B".
    function test_transfer_keeps_ownerOf_and_balance_in_sync() public {
        uint256 tokenId = _register(30 * DAY);

        vm.prank(HOLDER);
        reg.safeTransferFrom(HOLDER, STRANGER, tokenId, 1, "");

        assertEq(reg.ownerOf(tokenId), STRANGER, "ownerOf followed the token");
        assertEq(reg.balanceOf(STRANGER, tokenId), 1);
        assertEq(reg.balanceOf(HOLDER, tokenId), 0);

        // And the new holder really does hold the name's authority — verified with revoke,
        // because setResolver has been narrowed to the registry owner alone (see #6)
        vm.prank(STRANGER);
        reg.revoke(LABEL);
        assertEq(reg.getResolver(LABEL), address(0), "new holder could revoke");
    }

    /// After a transfer, the former holder can no longer revoke the name.
    function test_old_holder_loses_authority_after_transfer() public {
        uint256 tokenId = _register(30 * DAY);
        vm.prank(HOLDER);
        reg.safeTransferFrom(HOLDER, STRANGER, tokenId, 1, "");

        vm.expectRevert(LeashRegistry.NotNameOwner.selector);
        vm.prank(HOLDER);
        reg.revoke(LABEL);
    }

    function test_advertises_iregistry_and_erc1155() public view {
        assertTrue(reg.supportsInterface(type(IRegistry).interfaceId), "IRegistry");
        assertTrue(reg.supportsInterface(type(IERC1155Singleton).interfaceId), "singleton");
        assertTrue(reg.supportsInterface(0xd9b67a26), "ERC-1155");
        assertTrue(reg.supportsInterface(0x01ffc9a7), "ERC-165");
    }

    // --- entryOf: expired and never-issued must be distinguishable ---

    function test_entryOf_distinguishes_expired_from_never_issued() public {
        (address o,,,, bool live) = reg.entryOf(LABEL);
        assertEq(o, address(0));
        assertFalse(live);

        _register(DAY);
        vm.warp(block.timestamp + DAY + 1);

        (address o2, address r2,, uint64 exp, bool live2) = reg.entryOf(LABEL);
        assertEq(o2, HOLDER, "expired but we remember who had it");
        assertTrue(exp != 0, "expiry is visible");
        assertFalse(live2, "not usable");
        assertEq(r2, RESOLVER, "record kept; the live flag is the answer");
    }

    // --- 🔴 #5 regression: issuing and renewing both need an attestation ---

    /// `PLAN.md`'s asymmetry table says "issue a new agent subname → ✅ face scan
    /// required". In the first version **no path in the whole contract required an
    /// attestation** — that sentence was false at the time.
    function test_register_requires_an_attestation() public {
        LeashRegistry strict = new LeashRegistry(ADMIN, new RejectingAttester(), PARENT_NODE);
        vm.prank(ADMIN);
        strict.setRegistrar(REGISTRAR, true);

        vm.expectRevert(LeashRegistry.NotAttested.selector);
        vm.prank(REGISTRAR);
        strict.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);

        assertEq(strict.getResolver(LABEL), address(0), "nothing was issued");
    }

    /// Renewal extends the dead man's switch, which is a widening, so it needs an
    /// attestation too.
    ///
    /// The attester is immutable (the C1 fix), so this uses one that **can be switched off
    /// part-way**: let it accept and issue the name, then switch it off and show the
    /// renewal cannot pass.
    function test_renew_requires_an_attestation() public {
        ToggleAttester toggle = new ToggleAttester();
        LeashRegistry r = new LeashRegistry(ADMIN, toggle, PARENT_NODE);
        vm.prank(ADMIN);
        r.setRegistrar(REGISTRAR, true);

        vm.prank(REGISTRAR);
        r.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);
        assertEq(r.getResolver(LABEL), RESOLVER);

        toggle.setAccepting(false);

        vm.expectRevert(LeashRegistry.NotAttested.selector);
        vm.prank(REGISTRAR);
        r.renew(LABEL, DAY, 2, ATT);

        // And **revoking** must still work in the same situation — a reduction needs no
        // attestation
        vm.prank(ADMIN);
        r.revoke(LABEL);
        assertEq(r.getResolver(LABEL), address(0), "reduction never needs attestation");
    }

    /// A spent attestation cannot be replayed — the same semantics as `PolicyApprovals`.
    /// **The parameters must be identical**: the digest covers label / owner / resolver /
    /// duration / nonce, and changing any one of them makes it a different attestation.
    function test_renew_attestation_cannot_be_replayed() public {
        _register(DAY);
        bytes32 d = reg.renewDigest(LABEL, DAY, 42);

        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, 42, ATT);
        assertTrue(reg.attestationUsed(d), "digest recorded");

        vm.expectRevert(abi.encodeWithSelector(LeashRegistry.AttestationReused.selector, d));
        vm.prank(REGISTRAR);
        reg.renew(LABEL, DAY, 42, ATT);
    }

    /// Replay on issuance: issue → revoke → issue again with the **same nonce** must fail.
    /// (Re-issuing after a revocation requires an attestation with a fresh nonce.)
    function test_register_attestation_cannot_be_replayed_after_revoke() public {
        bytes32 d = reg.registerDigest(LABEL, HOLDER, RESOLVER, DAY, 7);

        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 7, ATT);
        assertTrue(reg.attestationUsed(d));

        vm.prank(ADMIN);
        reg.revoke(LABEL);

        vm.expectRevert(abi.encodeWithSelector(LeashRegistry.AttestationReused.selector, d));
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 7, ATT);

        // A fresh nonce works
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 8, ATT);
        assertEq(reg.getResolver(LABEL), RESOLVER);
    }

    function test_attestation_digest_is_standard_eip712() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                address(reg)
            )
        );
        assertEq(reg.domainSeparator(), domain);
    }

    // --- other guards ---

    /// Without a cap, a single `register(..., type(uint64).max)` would **silently switch
    /// off** the dead man's switch — the very reason this contract exists.
    function test_duration_is_capped() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashRegistry.DurationTooLong.selector, 400 days, reg.MAX_DURATION()
            )
        );
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, 400 days, 1, ATT);
    }

    /// Repeated renewals must not get around the cap either.
    function test_renew_cannot_exceed_the_cap() public {
        _register(300 days);
        vm.expectRevert();
        vm.prank(REGISTRAR);
        reg.renew(LABEL, 300 days, 99, ATT);
    }

    /// A `.` inside a label would issue a name that can never resolve — ENS walks one
    /// label at a time.
    function test_label_with_a_dot_is_rejected() public {
        vm.expectRevert(LeashRegistry.LabelHasDot.selector);
        vm.prank(REGISTRAR);
        reg.register("a.b", HOLDER, address(0), RESOLVER, DAY, 1, ATT);
    }

    function test_cannot_deploy_without_an_attester() public {
        vm.expectRevert(LeashRegistry.ZeroAttester.selector);
        new LeashRegistry(ADMIN, IAttester(address(0)), PARENT_NODE);
    }

    // --- 🔴 I3 regression: events must carry `node` for the subgraph to join on ---

    /// The frozen schema joins on `node` (a namehash). The first version emitted only a
    /// tokenId, leaving the subgraph unable to join against `PolicyPointerSet` /
    /// `SpendExecuted` / `AgentBound`.
    function test_events_carry_the_namehash_node() public {
        bytes32 node = reg.nodeOf(LABEL);
        assertEq(node, 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121);

        vm.expectEmit(true, true, false, false);
        emit LeashRegistry.SubnameRegistered(node, LABEL, HOLDER, 0, 0);
        vm.prank(REGISTRAR);
        reg.register(LABEL, HOLDER, address(0), RESOLVER, DAY, 1, ATT);
    }

    /// `nodeOf` must agree with the full namehash recursion — get it wrong and the
    /// resolver cannot find the records.
    function test_nodeOf_matches_full_namehash_recursion() public view {
        // namehash("payroll.leash.eth"), computed with cast on 09-08
        assertEq(
            reg.nodeOf("payroll"),
            0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8
        );
    }

    // --- fuzz ---

    /// For any duration, the behaviour before and after expiry must be consistent.
    function testFuzz_resolution_follows_expiry(uint32 duration, uint32 skip) public {
        duration = uint32(bound(duration, 1, 365 days));
        skip = uint32(bound(skip, 0, 2 * 365 days));

        uint256 start = block.timestamp;
        _register(duration);
        vm.warp(start + skip);

        bool shouldBeLive = start + duration > block.timestamp;
        assertEq(reg.getResolver(LABEL) != address(0), shouldBeLive);
    }
}
