// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { PolicyApprovals } from "../src/PolicyApprovals.sol";

/// @title ApprovePolicySet — puts the composed rule on the approval list
/// @notice The second of the two locks. `approve` takes an attestation, and the attestation
///         is what a stolen ADMIN key cannot produce — that is the whole reason the approval
///         list exists separately from the ENS pointer.
///
/// @dev ⚠️ **Read this before reading the transaction as a human approval.** The deployed
///      `PolicyApprovals` has `attester` set to `MockAttester`, which returns `true` for any
///      input, so the `attestation` argument below is empty and verifies anyway. ADMIN can
///      approve a policy in this deployment without a face scan, and this script is the
///      proof of that rather than a workaround of it.
///
///      The attester is `immutable` on purpose: the first version had `setAttester(onlyOwner)`
///      and one key opened both locks. Loading the real gate therefore means deploying a
///      fresh `PolicyApprovals` and re-approving every policy through it — the cost of
///      having removed the setter, and a cost worth paying.
///
///      The gate that IS real in this deployment is the other one: `LeashAccount.ATTESTER`
///      is `WorldAttester`, so widening a payee genuinely requires a Selfie Check.
///
///      `revoke` needs no attestation and no permission at all, so this is reversible by
///      anyone at any time. That asymmetry is deliberate: a brake is a brake.
contract ApprovePolicySet is Script {
    uint256 internal constant SEPOLIA = 11155111;

    PolicyApprovals internal constant APPROVALS =
        PolicyApprovals(0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4);

    address internal constant POLICY_SET = 0xec45e967F4e907B92bb1A9a8b4fcF9F041792490;

    /// @dev Shown in the frontend and on the demo page as "what this rule is", so it is
    ///      written for a person rather than as an identifier.
    string internal constant DESCRIPTION =
        "Under 1.00 USDC to any payee, or the full StandardPolicy rules";

    /// @dev Chosen by the issuer. The digest binds (policy, description, nonce) and is burned
    ///      on use, so re-approving after a revocation needs a fresh one.
    uint256 internal constant NONCE = 1;

    function run() external {
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        require(!APPROVALS.isApproved(POLICY_SET), "already approved");

        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        APPROVALS.approve(POLICY_SET, DESCRIPTION, NONCE, "");
        vm.stopBroadcast();

        console.log("approved   ", POLICY_SET);
        console.log("isApproved ", APPROVALS.isApproved(POLICY_SET));
        console.log("description", APPROVALS.descriptionOf(POLICY_SET));
        console.log("");
        console.log("The ENS pointer is NOT moved by this script. setPolicy is the demo");
        console.log("finale and runs AFTER the face-scan beat - see docs/deployments.md.");
    }
}
