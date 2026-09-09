// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAttester } from "./IAttester.sol";

/// @title MockAttester — for demos and tests; **performs no verification whatsoever**
/// @notice ⚠️ This contract returns `true` for any input. It exists for two reasons:
///         1. Recording a video and running tests should not cost a real face scan each
///            time
///         2. If something breaks on World's side, the whole pipeline still runs (it is
///            a one-address swap)
///
/// @dev **Never deploy this anywhere that touches real money.** `describe()` deliberately
///      spells that out in its return string so it shows up in the UI — we do not want a
///      demo screen pretending a human is in the loop when none is.
contract MockAttester is IAttester {
    function verify(bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }

    function describe() external pure returns (string memory) {
        return "MockAttester (NO verification - testing only)";
    }
}
