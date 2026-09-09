// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicy, SpendContext } from "../../src/IPolicy.sol";
import { LeashAccount } from "../../src/LeashAccount.sol";

/// @dev An ERC-20 that returns `false`. The account must revert rather than treat it as
///      success.
contract FalseReturnToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev An old-style ERC-20 that returns nothing at all. The **strict** check must refuse it.
contract NoReturnToken {
    function transfer(address, uint256) external { }
}

/// @dev Calls `spend` again from inside `transfer` — exercising the reentrancy lock and
///      the ledger-before-transfer ordering.
///
///      **`payee` is a settable parameter, not a hardcoded `msg.sender`.** The original
///      design used the caller (the wallet) as the reentrant call's payee, and `BadTarget`
///      rejects `payee == address(this)` — so that reentrant call was blocked by
///      `BadTarget` whether or not the lock existed, the test stayed green either way, and
///      it **could not detect the reentrancy lock being removed** (a mutation check walked
///      straight into this). Taking a legitimate payee from outside leaves the reentrant
///      call with **no reason to be blocked other than the lock itself**, which is what
///      makes the mutation check able to catch it.
///
///      **It also observes the second line of defence: the ledger is written first.** The
///      lock stopping the inner call here does not prove the account really writes the
///      ledger before transferring — move the `$.spent` write after `_transferAndEmit` and
///      the lock still works, so a test that only asserts the lock blocked the inner call
///      cannot detect that reordering. So at the moment `transfer` is called (mid-transfer,
///      the point at which the ledger should already be written) it reads
///      `spentInCurrentPeriod` back and stores the result: with the right ordering it sees
///      the amount already booked, and with the ordering swapped it sees 0.
contract ReenteringToken {
    address public target;
    address public reentrantPayee;
    bytes32 public node;
    bool public armed;
    uint256 public observedSpent;

    function arm(address t, address payee_, bytes32 node_) external {
        target = t;
        reentrantPayee = payee_;
        node = node_;
        armed = true;
    }

    function transfer(address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
            // The observation point for ledger-before-transfer: by the time this line
            // runs the transfer call is already in flight (we *are* the token being
            // transferred), so if the account writes `$.spent` before transferring, what
            // is read here is already the post-booking amount.
            observedSpent = LeashAccount(payable(target)).spentInCurrentPeriod(node, address(this));
            (bool ok,) = target.call(
                abi.encodeWithSignature(
                    "spend(address,address,uint256)", address(this), reentrantPayee, 1
                )
            );
            ok; // failure is expected here (the reentrancy lock blocks it)
        }
        return true;
    }
}

/// @dev A token returning exactly 32 bytes that are neither 0 nor 1 — exercising that a
///      return value `abi.decode(ret, (bool))` cannot accept must not make `spend` throw a
///      bare `Panic` and bury the real reason for the failure. `TransferFailed()` is the
///      correct way to fail.
contract GarbageReturnToken {
    function transfer(address, uint256) external pure returns (uint256) {
        return 2;
    }
}

/// @dev A policy that burns all the gas — exercising the `POLICY_GAS` cap and
///      fail-closed behaviour.
/// @notice **The signature must match `IPolicy.check` exactly** (`SpendContext
///         calldata`); a `bytes calldata` approximation will not do — the selector would
///         not match, the account could never reach the `while (true) {}`, and what got
///         exercised would only be "calling a function that does not exist", leaving the
///         `POLICY_GAS` DoS defence entirely untouched.
contract GasBurningPolicy is IPolicy {
    function check(SpendContext calldata) external pure returns (uint8) {
        while (true) { }
        return 0;
    }

    function describe() external pure returns (string memory) {
        return "GasBurningPolicy";
    }
}

/// @dev A policy that returns 256 — exercising the `uint8` clamp in `_askPolicy`.
/// @notice `check`'s interface return type is `uint8`, but an external contract's return
///         data is constrained only by the calldata encoding, not by the compiler's type
///         checking — so declaring `uint256` is enough to put 256 into a 32-byte return.
///         Without the clamp, `_askPolicy` truncates with a bare `uint8(raw)`, 256 becomes
///         0, which is `Reason.OK`, and a misbehaving policy is read as an allow and the
///         money really does move (the one fail-*open* path in the whole branch).
///         Deliberately not `is IPolicy`, for the same reason as `ShortReturnPolicy`: a
///         mismatched return type would refuse to compile, while the selector depends only
///         on the function name and parameter types and is unaffected.
contract OverflowingPolicy {
    function check(SpendContext calldata) external pure returns (uint256) {
        return 256;
    }

    function describe() external pure returns (string memory) {
        return "OverflowingPolicy";
    }
}

/// @dev A policy that returns the wrong length. **Deliberately not `is IPolicy`**: the
///      selector depends only on the function name and parameter types, so a mismatched
///      return type does not affect whether `abi.encodeCall(IPolicy.check, ctx)` can reach
///      it — but declaring `is IPolicy` would refuse to compile, because the return type
///      (`bytes memory` against the interface's `uint8`) does not match.
///      The parameter types must still match `IPolicy.check` exactly; see
///      `GasBurningPolicy` for why.
contract ShortReturnPolicy {
    function check(SpendContext calldata) external pure returns (bytes memory) {
        return hex"01";
    }

    function describe() external pure returns (string memory) {
        return "ShortReturnPolicy";
    }
}
