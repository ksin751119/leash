// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashRegistry } from "../src/LeashRegistry.sol";
import { LeashResolver } from "../src/LeashResolver.sol";
import { PolicyApprovals } from "../src/PolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { IRegistry } from "../src/IRegistry.sol";

/// @dev The functions we need on the ENSv2 `PermissionedRegistry`.
///      The selectors were checked against live Sepolia: `0x341ec559` / `0xbc7b6d62`.
interface IEnsV2Registry {
    function setSubregistry(uint256 tokenId, address subregistry) external;
    function setResolver(uint256 tokenId, address resolver) external;
    function getSubregistry(string calldata label) external view returns (address);
    function getResolver(string calldata label) external view returns (address);
    /// @dev As `docs/ensv2-sepolia.md` recommends: one view call gets the tokenId, so do
    ///      not hardcode it.
    function findTokenId(string calldata label) external view returns (uint256);
}

/// @title Deploy — hangs Leash off ENSv2 on Sepolia
/// @notice Five contracts, three wiring transactions, two settings. After it runs, the
///         onchain resolution should walk end to end:
///
///         RootRegistry.getSubregistry("eth")
///           → ETHRegistry.getSubregistry("leash")   ← this step points at our registry
///             → LeashRegistry.getResolver("vendors") ← the agent subname we issued
///               → LeashResolver.resolve(dnsName, addr(node))
///                 → the StandardPolicy address
///
/// @dev **Run the simulation without `--broadcast` first** and confirm no step reverts
///      before sending anything for real. `setSubregistry` requires ADMIN to hold EAC role
///      bit 20 on `leash.eth` — confirmed workable with `cast call --from` on 2026-09-03.
contract Deploy is Script {
    // Sepolia ENSv2 (addresses measured 2026-09-01; they may move during the audit
    // window, and this line has to change with them)
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;

    /// @dev Sepolia's chain id. **A deploy script must have this guard** — the wrong RPC
    ///      deploys the entire control plane to a different chain, and because the
    ///      addresses are deterministic, it looks afterwards as though it worked.
    uint256 constant SEPOLIA = 11155111;

    /// @dev `namehash("leash.eth")`. `LeashRegistry` derives subname nodes from it.
    bytes32 constant LEASH_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @dev namehash("vendors.leash.eth"). Resolver records are keyed by node.
    bytes32 constant VENDORS_NODE =
        0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    string constant AGENT_LABEL = "vendors";

    /// @dev 30 days for the demo. A real deployment would use 24 hours and lean on
    ///      renewal as the dead man's switch.
    uint64 constant AGENT_DURATION = 30 days;

    function run() external {
        address admin = vm.envAddress("ADMIN_ADDR");
        uint256 pk = vm.envUint("ADMIN_PK");

        require(block.chainid == SEPOLIA, "wrong chain - this script is Sepolia only");

        // Do not hardcode it — look it up, as docs/ensv2-sepolia.md recommends
        uint256 leashTokenId = IEnsV2Registry(ETH_REGISTRY).findTokenId("leash");
        require(leashTokenId != 0, "leash.eth not registered on this chain");

        console.log("=== Leash deploy ===");
        console.log("admin        ", admin);
        console.log("chain id     ", block.chainid);
        console.log("eth registry ", ETH_REGISTRY);

        vm.startBroadcast(pk);

        // --- 1. The five contracts ---
        //     The attester is immutable in both PolicyApprovals and LeashRegistry — no
        //     setter, so a stolen ADMIN key cannot open the second lock.
        MockAttester attester = new MockAttester();
        PolicyApprovals approvals = new PolicyApprovals(IAttester(address(attester)));
        StandardPolicy policy = new StandardPolicy();
        LeashResolver resolver = new LeashResolver(admin, IPolicyApprovals(address(approvals)));
        LeashRegistry registry = new LeashRegistry(admin, IAttester(address(attester)), LEASH_NODE);

        // --- 2. Approve that policy. Needs an attestation and an unused nonce ---
        //     MockAttester accepts anything; production swaps in WorldAttester, whose
        //     backend signs with EIP-712.
        approvals.approve(address(policy), policy.describe(), 1, hex"00");

        // --- 3. Issue the agent subname. **This step needs an attestation too** ---
        //     PLAN's asymmetry table says "issue a new agent subname → face scan
        //     required", and the code now really does that.
        registry.register(
            AGENT_LABEL, admin, address(0), address(resolver), AGENT_DURATION, 1, hex"00"
        );

        // --- 4. Which policy that agent must satisfy ---
        resolver.setPolicy(VENDORS_NODE, address(policy));

        // --- 5. Hand the leash.eth subtree to our registry ---
        //     This transaction is act four's lever in the demo: point it at any other
        //     address and every agent halts at once
        IEnsV2Registry(ETH_REGISTRY).setSubregistry(leashTokenId, address(registry));

        // --- 6. Leave leash.eth itself **without** a resolver ---
        //
        //     The first version set LeashResolver as leash.eth's own resolver, so the demo
        //     could query that name directly. That made it a **wildcard resolver** for the
        //     entire subtree: when a subname has no resolver, ENS's UniversalResolver
        //     walks up and finds it, and LeashResolver deliberately ignores `name` and
        //     reads only the node — so **neither `revoke(label)` nor `expiry` stopped
        //     resolution through the official tooling.**
        //
        //     Measured onchain with ghost.leash.eth, a subname that was never issued:
        //       LeashRegistry.getResolver("ghost") = 0x0
        //       yet UniversalResolverV2 still found LeashResolver
        //
        //     Our own three hops stop at hop two (NO_POLICY, no money moves), so **the
        //     enforcement path was correct**; what was broken was the path the demo
        //     pointed at — after a revocation that command still printed a policy.
        //
        //     The fix: leave leash.eth without a resolver. Resolution is then *forced*
        //     through our registry, with no side road.
        IEnsV2Registry(ETH_REGISTRY).setResolver(leashTokenId, address(0));

        // --- 7. Tell the registry where it hangs (affects indexing only, not resolution) ---
        registry.setParent(IRegistry(ETH_REGISTRY), "leash");

        vm.stopBroadcast();

        console.log("");
        console.log("MockAttester    ", address(attester));
        console.log("PolicyApprovals ", address(approvals));
        console.log("StandardPolicy  ", address(policy));
        console.log("LeashResolver   ", address(resolver));
        console.log("LeashRegistry   ", address(registry));
        console.log("");

        // --- Verification: does the onchain resolution actually walk? ---
        address sub = IEnsV2Registry(ETH_REGISTRY).getSubregistry("leash");
        console.log("ETHRegistry.getSubregistry('leash')  ", sub);
        require(sub == address(registry), "subregistry not wired");

        address agentResolver = registry.getResolver(AGENT_LABEL);
        console.log("LeashRegistry.getResolver('vendors') ", agentResolver);
        require(agentResolver == address(resolver), "agent resolver not wired");

        (address p, bool approved) = resolver.policyAndApproval(VENDORS_NODE);
        console.log("policy resolved                     ", p);
        console.log("policy approved                     ", approved);
        require(p == address(policy), "policy pointer wrong");
        require(approved, "policy not approved");

        console.log("");
        console.log("OK - vendors.leash.eth resolves to an approved policy onchain");
    }
}
