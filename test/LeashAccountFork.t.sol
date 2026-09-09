// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title LeashAccountFork — against real Sepolia, not mocks
/// @notice Every test before this one (`LeashAccountBinding`, `LeashAccountRules`,
///         `LeashAccountSpend`, …) uses a mock ENS registry. **This is the only suite that
///         runs against the real ENSv2 contracts** — it alone can show that our
///         assumptions about the three hops, each hop's returndata length, and the
///         resolved address really being on the approval list also hold on the real chain.
///
/// @dev Requires `SEPOLIA_RPC`. Without it the whole suite is skipped with `vm.skip` (CI
///      may have no network). **In forge's output, skip and pass are two different
///      states** — using skip rather than a bare `return` is what keeps a run that had no
///      RPC and verified nothing from looking as green as one where the three hops really
///      resolved.
contract LeashAccountForkTest is Test {
    // The address set from 09-08 16:34 UTC; see docs/deployments.md.
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;
    address constant STANDARD_POLICY = 0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b;
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    LeashAccount impl;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            // `vm.skip` rather than a bare `return`: the per-test
            // `if (address(impl) == address(0)) return;` only guards against "this test
            // did nothing yet reported PASS". It does not guard against "the entire fork
            // suite never touched the chain, yet looks as green in the CI report as a run
            // that really verified" — and that is the real risk.
            // `vm.skip` makes forge mark these SKIPPED, listed separately from PASSED.
            vm.skip(true, "SEPOLIA_RPC not set - skipping live Sepolia fork test");
            return;
        }
        vm.createSelectFork(rpc);
        impl = new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
    }

    /// **This test is the proof of the entire ENS claim.**
    /// Three hops against the real ENSv2, resolving a real policy address — not a value
    /// invented by a mock registry, but the state that genuinely exists on chain after the
    /// real deployment of 2026-09-08 16:34 UTC and the real `setSubregistry` / `register` /
    /// `setPolicy` wiring.
    function test_resolves_the_real_policy_on_sepolia() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));
        assertEq(acct.resolvePolicy(NODE, "vendors"), STANDARD_POLICY);
    }

    /// That policy really is on the approval list — not merely "resolvePolicy happened to
    /// return a nonzero address", but that address having genuinely passed through
    /// `PolicyApprovals.approve`.
    function test_the_real_policy_is_approved() public view {
        if (address(impl) == address(0)) return;
        assertTrue(IPolicyApprovals(APPROVALS).isApproved(STANDARD_POLICY));
    }

    /// **Remove ENS and nothing passes.** `vm.mockCall` makes hop one return 0 —
    /// equivalent to `ETHRegistry.setSubregistry(leash.eth, 0x0)`, the kill-everything
    /// lever (the heaviest row of the three-revocation-layers table in
    /// `docs/deployments.md`).
    function test_removing_the_ens_subtree_stops_resolution() public {
        if (address(impl) == address(0)) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation(address(impl), pk);
        LeashAccount acct = LeashAccount(payable(vm.addr(pk)));

        vm.mockCall(
            ETH_REGISTRY,
            abi.encodeWithSignature("getSubregistry(string)", "leash"),
            abi.encode(address(0))
        );
        assertEq(acct.resolvePolicy(NODE, "vendors"), address(0), "no ENS, no policy");
    }
}
