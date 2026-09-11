// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title DeployAccountV3 — the impl where a face outranks the wallet key
/// @notice Third `LeashAccount` impl. It adds `allowPayeeByFace` (no `onlySelf`; the
///         authorisation rides inside the attestation) and `setOwnerNullifier`, whose
///         first call costs the wallet key and whose every later call costs the face
///         already registered.
///
/// @dev **Deploys ONLY the impl.** `LeashLens` at `0xB6eB4C26…` reads a wallet's delegated
///      code and knows nothing about this contract's interface, so redeploying it would
///      produce a second address doing an identical job and invalidate a documented one.
///
///      **`ATTESTER` is `WorldAttester`, not `MockAttester`.** `script/DeployAccount.s.sol`
///      still names the mock — correct for the impl it deployed on 09-08, and a regression
///      if copied forward, since the wallet was re-delegated on 09-09 precisely to switch
///      to the real attester. Getting this wrong would deploy an impl where any bytes at
///      all pass as a face.
///
///      **Deliberately contains no `WALLET_PK`.** Delegation is an authorization the wallet
///      signs for itself; ADMIN cannot do it on the wallet's behalf and this script does not
///      pretend otherwise. The wallet's own storage is untouched by a re-delegation: the
///      layout is ERC-7201 and `ownerNullifier` was appended at an unused slot, so every
///      binding, rule, payee and budget reads back identically afterwards.
contract DeployAccountV3 is Script {
    uint256 internal constant SEPOLIA = 11155111;

    // Immutable constructor arguments, burned into the bytecode. These must match what the
    // live system uses — see docs/deployments.md.
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26; // WorldAttester

    function run() external {
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        require(ATTESTER.code.length > 0, "ATTESTER has no code on this chain");
        require(APPROVALS.code.length > 0, "APPROVALS has no code on this chain");

        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        LeashAccount impl =
            new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
        vm.stopBroadcast();

        console.log("LeashAccount impl (v3)", address(impl));
        console.log("  ETH_REGISTRY        ", ETH_REGISTRY);
        console.log("  APPROVALS           ", APPROVALS);
        console.log("  ATTESTER            ", ATTESTER, "(WorldAttester)");
        console.log("");
        console.log("Next, and neither is ADMIN's to do:");
        console.log("  1. WALLET re-authorises: an EIP-7702 authorization it signs itself");
        console.log("  2. WALLET calls setOwnerNullifier(n, 0, '') with a nullifier from a");
        console.log("     real scan. First registration only - after that the face rules.");
    }
}
