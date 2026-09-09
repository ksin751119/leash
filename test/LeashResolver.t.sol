// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashResolver } from "../src/LeashResolver.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";

contract MockApprovals is IPolicyApprovals {
    mapping(address => bool) public approved;

    function set(address policy, bool ok) external {
        approved[policy] = ok;
    }

    function isApproved(address policy) external view returns (bool) {
        return approved[policy];
    }
}

/// @dev A contract with no describe() — text("description") must return an empty string
///      rather than blow up.
contract NotAPolicy {
    // deliberately empty
}

contract LeashResolverTest is Test {
    LeashResolver resolver;
    MockApprovals approvals;
    StandardPolicy policy;

    address constant ADMIN = address(0xAD31);
    address constant STRANGER = address(0x5721);

    /// A stand-in for namehash("vendors.acme.eth") — the resolver never recomputes the
    /// node, so the actual value does not affect behaviour.
    bytes32 constant NODE = keccak256("vendors.acme.eth");
    bytes32 constant OTHER_NODE = keccak256("payroll.acme.eth");

    /// We do not use ENSIP-10's `name` parameter, but a plausible value still goes in.
    /// 0x07 "vendors" 0x04 "acme" 0x03 "eth" 0x00
    bytes constant DNS_NAME = hex"0776656e646f72730461636d650365746800";

    function setUp() public {
        approvals = new MockApprovals();
        policy = new StandardPolicy();
        vm.prank(ADMIN);
        resolver = new LeashResolver(ADMIN, approvals);
    }

    function _resolveAddr(bytes32 node) internal view returns (address) {
        bytes memory inner = abi.encodeWithSignature("addr(bytes32)", node);
        bytes memory out = resolver.resolve(DNS_NAME, inner);
        return abi.decode(out, (address));
    }

    function _resolveText(bytes32 node, string memory key) internal view returns (string memory) {
        bytes memory inner = abi.encodeWithSignature("text(bytes32,string)", node, key);
        return abi.decode(resolver.resolve(DNS_NAME, inner), (string));
    }

    // --- core: resolving the policy address ---

    function test_resolves_the_policy_address_via_ensip10() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveAddr(NODE), address(policy));
    }

    /// A name that was never set returns the zero address — the account layer reads 0 as
    /// reason code 3 (NO_POLICY) and no money moves.
    function test_unset_node_resolves_to_zero() public view {
        assertEq(_resolveAddr(NODE), address(0));
    }

    /// Clearing the pointer is a reduction and never needs a face scan. This is the
    /// "halt everything" button.
    function test_clearing_the_pointer_is_always_allowed() public {
        vm.startPrank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        resolver.setPolicy(NODE, address(0));
        vm.stopPrank();
        assertEq(_resolveAddr(NODE), address(0));
    }

    function test_nodes_are_independent() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveAddr(OTHER_NODE), address(0));
    }

    // --- the pointer and the approval are two separate layers ---

    /// A stolen ADMIN key can only move the pointer. "Has it been approved?" is a second
    /// lock, and the answer is recorded in the event.
    function test_pointer_can_be_set_to_an_unapproved_policy_but_is_reported_as_such() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));

        (address p, bool approved) = resolver.policyAndApproval(NODE);
        assertEq(p, address(policy));
        assertFalse(approved, "not on the approval list yet");

        approvals.set(address(policy), true);
        (, approved) = resolver.policyAndApproval(NODE);
        assertTrue(approved);
    }

    /// 🔴 C1 regression: the pointer to the approval list is **immutable, with no setter**.
    ///
    /// The first version had `setApprovalsSource(onlyOwner)`. Even with
    /// `PolicyApprovals.setAttester` locked shut, as long as this pointer is mutable a
    /// stolen ADMIN key can deploy its own list with its own attester and point at it —
    /// and both locks still open with the same key.
    function test_approvals_source_is_immutable_with_no_setter() public view {
        assertEq(address(resolver.approvals()), address(approvals));
        // setApprovalsSource does not exist on the interface — this fails to compile the
        // moment anyone adds the mutability back
    }

    /// The constructor rejects `address(0)`: there is no setter to recover with, so
    /// failing at deploy time is the better outcome.
    function test_cannot_deploy_without_an_approvals_source() public {
        vm.expectRevert(LeashResolver.ZeroApprovals.selector);
        new LeashResolver(ADMIN, IPolicyApprovals(address(0)));
    }

    function test_zero_policy_is_never_approved() public {
        approvals.set(address(0), true); // even if the list absurdly approves the zero address
        (, bool approved) = resolver.policyAndApproval(NODE);
        assertFalse(approved);
    }

    function test_emits_pointer_set_with_the_approval_state_at_that_moment() public {
        approvals.set(address(policy), true);
        vm.expectEmit(true, true, true, true);
        emit LeashResolver.PolicyPointerSet(NODE, address(policy), ADMIN, true);
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
    }

    // --- access control ---

    function test_only_owner_can_set_the_pointer() public {
        vm.expectRevert(LeashResolver.NotOwner.selector);
        vm.prank(STRANGER);
        resolver.setPolicy(NODE, address(policy));
    }

    function test_ownership_transfers() public {
        vm.prank(ADMIN);
        resolver.transferOwnership(STRANGER);
        assertEq(resolver.owner(), STRANGER);

        vm.expectRevert(LeashResolver.NotOwner.selector);
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
    }

    function test_ownership_cannot_be_burned() public {
        vm.expectRevert(LeashResolver.ZeroOwner.selector);
        vm.prank(ADMIN);
        resolver.transferOwnership(address(0));
    }

    // --- the rest of the ENSIP-10 surface ---

    function test_addr_with_coin_type_60_matches_plain_addr() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));

        bytes memory inner = abi.encodeWithSignature("addr(bytes32,uint256)", NODE, uint256(60));
        bytes memory raw = abi.decode(resolver.resolve(DNS_NAME, inner), (bytes));
        assertEq(raw, abi.encodePacked(address(policy)));
    }

    function test_rejects_other_coin_types() public {
        bytes memory inner = abi.encodeWithSignature("addr(bytes32,uint256)", NODE, uint256(0));
        vm.expectRevert(
            abi.encodeWithSelector(LeashResolver.UnsupportedCoinType.selector, uint256(0))
        );
        resolver.resolve(DNS_NAME, inner);
    }

    function test_text_policy_returns_the_lowercase_hex_address() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveText(NODE, "policy"), vm.toLowercase(vm.toString(address(policy))));
    }

    function test_text_policy_is_empty_when_unset() public view {
        assertEq(_resolveText(NODE, "policy"), "");
    }

    function test_text_description_comes_from_the_policy_itself() public {
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, address(policy));
        assertEq(_resolveText(NODE, "description"), policy.describe());
    }

    /// When the pointer aims at a contract with no describe(), the display path must
    /// degrade rather than blow up.
    function test_text_description_degrades_to_empty_for_a_non_policy() public {
        address junk = address(new NotAPolicy());
        vm.prank(ADMIN);
        resolver.setPolicy(NODE, junk);
        assertEq(_resolveText(NODE, "description"), "");
    }

    function test_text_leash_marks_the_name_as_governed() public view {
        assertEq(_resolveText(NODE, "leash"), "leash-v1");
    }

    /// An unknown text key returns the **empty string**; it does not revert.
    ///
    /// ENS UIs routinely batch-query `avatar` / `com.twitter` / `description` — one revert
    /// takes the whole batch down and the name looks broken in the ENS frontend.
    /// (An **unknown selector** in `resolve` still reverts: that is on the enforcement
    /// path, where failing closed means something.)
    function test_unknown_text_key_returns_empty_not_revert() public view {
        assertEq(_resolveText(NODE, "avatar"), "");
        assertEq(_resolveText(NODE, "com.twitter"), "");
    }

    /// An unrecognised inner call must revert rather than return empty — the caller has to
    /// be able to tell "unset" from "unsupported" for failing closed to be possible.
    function test_unsupported_inner_call_reverts() public {
        bytes memory inner = abi.encodeWithSignature("contenthash(bytes32)", NODE);
        vm.expectRevert(
            abi.encodeWithSelector(
                LeashResolver.UnsupportedResolverCall.selector,
                bytes4(keccak256("contenthash(bytes32)"))
            )
        );
        resolver.resolve(DNS_NAME, inner);
    }

    // --- ERC-165 ---

    function test_advertises_ensip10_and_erc165_only() public view {
        assertTrue(resolver.supportsInterface(0x9061b923), "ENSIP-10 resolve()");
        assertTrue(resolver.supportsInterface(0x01ffc9a7), "ERC-165");
        // The legacy interfaces are deliberately not advertised — we have neither of those
        // external functions
        assertFalse(resolver.supportsInterface(0x3b3b57de), "legacy addr()");
        assertFalse(resolver.supportsInterface(0x59d1d43c), "legacy text()");
    }

    /// The selectors transcribed from the live ENSv2 measurements must agree with what the
    /// compiler computes — transcribe one wrong and the entire resolution path fails.
    function test_selectors_match_the_measured_values() public pure {
        assertEq(bytes4(keccak256("resolve(bytes,bytes)")), bytes4(0x9061b923));
        assertEq(bytes4(keccak256("addr(bytes32)")), bytes4(0x3b3b57de));
        assertEq(bytes4(keccak256("text(bytes32,string)")), bytes4(0x59d1d43c));
    }
}
