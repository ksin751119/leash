// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashLens } from "../src/LeashLens.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @title DeployAccount — deploys the LeashAccount impl and LeashLens
/// @notice It does exactly two things: deploy one `LeashAccount` (global configuration is
///         immutable and there is zero per-instance state, so every WALLET that delegates
///         uses this same impl) and one `LeashLens`.
///
/// @dev **Deliberately contains no `WALLET_PK`.** Delegation
///      (`cast send $WALLET --auth $impl`) is an authorization WALLET signs for itself;
///      it is not something ADMIN can do on its behalf. That private key has no business
///      in a deploy script — delegation is sent by hand with `cast send --auth`.
///      Same reasoning as the chainid guard in `script/Deploy.s.sol`: the keys a deploy
///      script can touch should be exactly the ones deploying requires, and one more key
///      is one more exposure surface.
contract DeployAccount is Script {
    uint256 constant SEPOLIA = 11155111;

    // The address set from 09-08 16:34 UTC; see docs/deployments.md. These must match
    // LeashAccount's immutable constructor arguments exactly — once the three values are
    // burned into the impl's bytecode they can never be changed, and getting one wrong
    // means redeploying the whole thing.
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;

    function run() external {
        // The wrong RPC deploys the impl to a different chain, and since the address is
        // deterministic, that looks like success. Same reasoning as
        // `script/Deploy.s.sol`.
        require(block.chainid == SEPOLIA, "wrong chain - Sepolia only");
        uint256 pk = vm.envUint("ADMIN_PK");

        vm.startBroadcast(pk);
        LeashAccount impl =
            new LeashAccount(ETH_REGISTRY, IPolicyApprovals(APPROVALS), IAttester(ATTESTER));
        LeashLens lens = new LeashLens();
        vm.stopBroadcast();

        console.log("LeashAccount impl", address(impl));
        console.log("LeashLens        ", address(lens));
        console.log("");
        console.log("Next (WALLET_PK signs its own delegation - do NOT put it in a script):");
        console.log("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...");
    }
}
