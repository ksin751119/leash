// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";

/// @title DeployPolicySet — the composed rule: a small payment to anyone, or the full rules
/// @notice Deploys `MicroPaymentPolicy(1 USDC)` and a `PolicySet` whose two clauses are
///
///             clause 1 = [ MicroPaymentPolicy ]   the exception
///             clause 2 = [ StandardPolicy ]       the general rule
///
///         and stops there. **It does not approve anything and it does not move the ENS
///         pointer**, because neither is ADMIN's to do:
///
///         - `PolicyApprovals.approve` needs a World face scan. That is the second lock,
///           and the whole design rests on ADMIN being unable to open it.
///         - `setPolicy` is run separately and deliberately, as the demo's finale, AFTER
///           the face-scan beat has completed — see the SDD ledger for why the ordering
///           matters (`world/demo.html` gates the widen button on an agent-side refusal,
///           so swapping the pointer early would cost the face-scan beat).
///
/// @dev **Contains no `WALLET_PK`.** Nothing here is signed by the wallet.
///
///      Run the simulation without `--broadcast` first and read both addresses out of the
///      log before sending anything for real.
contract DeployPolicySet is Script {
    /// @dev MockUSDC has 6 decimals, so 1 USDC is 1e6. The cap is what a human is
    ///      consenting to when they approve this set: "anything under a dollar, to anyone."
    ///      A different cap is a different address and a fresh face scan — `CAP` is
    ///      immutable with no setter.
    uint256 internal constant CAP = 1_000_000;

    function run() external {
        address standard = vm.envAddress("STANDARD_POLICY");
        require(standard.code.length > 0, "STANDARD_POLICY has no code on this chain");

        vm.startBroadcast();

        MicroPaymentPolicy micro = new MicroPaymentPolicy(CAP);

        // Disjunctive normal form: AND inside a clause, OR between clauses. The exception
        // goes first and the general rule last, because `PolicySet` reports the LAST
        // clause's reason when nothing passes — and for a payment to an unknown payee that
        // is `6 PAYEE_NOT_ALLOWED`, the one code a face scan actually fixes.
        address[][] memory clauses = new address[][](2);

        clauses[0] = new address[](1);
        clauses[0][0] = address(micro);

        clauses[1] = new address[](1);
        clauses[1][0] = standard;

        PolicySet set = new PolicySet(clauses);

        vm.stopBroadcast();

        console.log("MicroPaymentPolicy", address(micro));
        console.log("  CAP              ", CAP);
        console.log("PolicySet         ", address(set));
        console.log("  clause 1 member  ", address(micro));
        console.log("  clause 2 member  ", standard);
        console.log("");
        console.log("Next, and neither is ADMIN's to do:");
        console.log("  1. approve the PolicySet with a real face scan");
        console.log("  2. setPolicy to it, as the demo finale, AFTER the face-scan beat");
    }
}
