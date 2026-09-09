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
        // Printed so the impl-to-attester linkage lands in the deploy log: Step 4 asserts
        // this equals what the server has in WORLD_ATTESTER, which is the only check that
        // catches a stale-but-valid address before a face scan is spent on it.
        console.log("  impl ATTESTER ", address(impl.ATTESTER()));
        console.log("");
        console.log("Next, and WALLET signs it itself - do NOT put this key in a script:");
        console.log("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...");
    }
}
