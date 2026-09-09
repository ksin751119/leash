# LeashAccount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an EIP-7702 delegate implementation that forces a delegated EOA, before any ERC-20 transfer, through four gates: authorise the agent → resolve the policy through three ENS hops → check it against the approval list → call the policy.

**Architecture:** a single impl contract with zero per-instance state. The global configuration (ETH_REGISTRY / APPROVALS / SELF) is `immutable`, so there is **no `initialize () ` and nothing to front-run**. Per-EOA state lives in an ERC-7201 namespaced slot, executing against the EOA's own storage. A policy violation means no transfer plus an event (no revert) ; only an authorisation failure reverts. Widening requires both `msg.sender == address (this) ` **and** an attestation; reducing is always free.

**Tech stack:** Solidity 0.8.28, Foundry (`evm_version = "prague"`) , OpenZeppelin v5.1.0, `vm.signAndAttachDelegation` for 7702, and `vm.createSelectFork` against real Sepolia.

**Spec:** `docs/superpowers/specs/2026-09-08-leash-account-design.md`

## Global Constraints

Every item below is a **global** requirement, implicitly part of each task's acceptance
criteria. Copy the values from the spec; do not recompute them.

- **Solidity `0.8.28` with `evm_version = "prague"`** (7702 requires it) . Already in
  `foundry.toml`.
- **The ERC-7201 slot constant:** `0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800`
  = `keccak256 (abi.encode (uint256 (keccak256 ("leash.account.v1") ) - 1) ) & ~bytes32 (uint256 (0xff) ) `.
  **Task 1 must pin this value with a test.** Get it wrong and every piece of state lands
  in a different slot.
- **`namehash ("leash.eth") `** = `0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf`
- **`namehash ("vendors.leash.eth") `** = `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121`
- **The addresses already deployed on Sepolia** (`docs/deployments.md`, the 2026-09-08
  16:34 UTC set) :
  - `ETH_REGISTRY` = `0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2`
  - `LeashRegistry` = `0x6fB6CB4a789067b2283C4d4C657d3422ce742A51`
  - `LeashResolver` = `0x607a4d7363d9E7511a932F82eAE1e12FB609915b`
  - `PolicyApprovals` = `0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4`
  - `StandardPolicy` = `0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b`
  - `MockAttester` = `0x268990a91B0727E80d38d5ED4Ab10d8889754124`
  - `MockUSDC` = `0x768f42455a2d082e23ceef7d51e5787c82d67a39`
- **The three ENS hops return different lengths; do not share one constant:** hop1 `32`,
  hop2 `32`, **hop3 `96`** (`bytes` = offset 32 + length 32 + inner 32) . Check hop3 for
  `==32` and **the happy path never succeeds**.
- **`POLICY_GAS = 200_000`.** A policy exceeding it fails closed (reason code 12) .
- **Reason codes** follow `src/Reason.sol`, and **the numbers must never be renumbered**.
  The account decides 1, 2, 3, 4, 10 and 12; the policy decides 5-9 and 11.
- **Event signatures** follow `docs/events.md` (frozen) . Fields may be added; types, order
  and meaning may not change.
- **EIP-712 domain:** `name = "Leash"`, `version = "1"`, `chainId = block.chainid`,
  `verifyingContract = address (this) `, consistent with `PolicyApprovals` and `LeashRegistry`.
- **An attestation digest must include `SELF`** (the address the impl itself was deployed
  at) . Inside a delegate `address (this) ` is the EOA and stays the same after redelegating to
  a new impl — without `SELF`, an attestation can be replayed across versions.
- **Forbidden:** a general-purpose `execute (target, data) `, spending native ETH, batched
  spends, EIP-4337, an upgrade mechanism. (Redelegating **is** 7702's upgrade mechanism.)
- **Before each task ends:** `forge fmt` clean and `forge test` all green. None of the 99
  existing tests may go red.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/LeashStorage.sol` | **create** — the ERC-7201 namespaced slot, the three structs `AccountStorage` / `AgentBinding` / `TokenRule`, and `layout () ` to reach the slot | 1 |
| `src/LeashLens.sol` | **create** — `delegateOf (address) `, reading an EOA's code to tell whether the leash is still on. Pure view, touching no state | 1 |
| `src/LeashAccount.sol` | **create** — the main body, grown across tasks 2-6, ending at roughly 400 lines | 2,3,4,5,6 |
| `src/Reason.sol` | unchanged (reason code 12 was added 09-08) | — |
| `src/IPolicy.sol` | **modify** — add one interface-constraint comment: a policy may only write its ledger when it returns `OK` | 6 |
| `test/LeashStorage.t.sol` | **create** — pin the slot constant | 1 |
| `test/LeashLens.t.sol` | **create** — before and after 7702 delegation, code that is not 23 bytes, a mismatched prefix | 1 |
| `test/LeashAccountBinding.t.sol` | **create** — binding, pausing, 7702 semantics, front-running protection | 2,3 |
| `test/LeashAccountRules.t.sol` | **create** — `setRule` / `tightenRule` / `_isTighter` / window subsets / epoch | 4 |
| `test/LeashAccountSpend.t.sol` | **create** — the whole `spend` flow, every reason code, reentrancy, fake success | 5,6 |
| `test/LeashAccountFork.t.sol` | **create** — against real Sepolia: the happy path plus all four revocation levers | 7 |
| `test/mocks/` | **create** — `MockRegistry` (configurable return length) , `ReenteringToken`, `BadReturnToken`, `GasBurningPolicy` | 5 |
| `script/DeployAccount.s.sol` | **create** — deploy the impl and lens, delegate WALLET, bind the agent, set the rules | 7 |

**Why the files split this way:** `LeashAccount`'s tests are split into three files by
**concern** (binding / rules / spending) , not by unit versus integration. Tests for one
concern change together, so they live together; and the `spend` file will be the largest, so
keeping it separate stops it interfering with the rules tests.

---

## Task 1: `LeashStorage` + `LeashLens`

The smallest and most independent piece. Doing it first has two benefits: once the slot
constant is pinned, every later task builds on the correct foundation; and `LeashLens`
depends on `LeashAccount` not at all, so 7702's code layout can be verified immediately.

**Files:**
- Create: `src/LeashStorage.sol`
- Create: `src/LeashLens.sol`
- Test: `test/LeashStorage.t.sol`
- Test: `test/LeashLens.t.sol`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `library LeashStorage` containing `struct AccountStorage`, `struct AgentBinding` and `struct TokenRule`
  - `function layout () internal pure returns (AccountStorage storage $) `
  - `bytes32 internal constant SLOT`
  - `contract LeashLens` with `function delegateOf (address wallet) external view returns (bool leashed, address impl) `

- [ ] **Step 1: write the failing test — pin the slot constant**

```solidity
// test/LeashStorage.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashStorage } from "../src/LeashStorage.sol";

/// @dev Exposes the library's internal constants so they can be tested.
contract StorageProbe {
    function slot () external pure returns (bytes32) {
        return LeashStorage.SLOT;
    }

    /// Write a value, then read it back from that slot with `vm.load` — proving it
    /// really lives there.
    function setPaused (bool v) external {
        LeashStorage.layout () .paused = v;
    }

    function paused () external view returns (bool) {
        return LeashStorage.layout () .paused;
    }
}

contract LeashStorageTest is Test {
    StorageProbe probe;

    function setUp () public {
        probe = new StorageProbe () ;
    }

    /// Get this constant wrong and every piece of state lands in a different slot —
    /// with no error message of any kind. This test recomputes the ERC-7201 formula
    /// rather than copying the constant.
    function test_slot_matches_the_erc7201_formula () public view {
        bytes32 expected = keccak256 (abi.encode (uint256 (keccak256 ("leash.account.v1") ) - 1) )
            & ~bytes32 (uint256 (0xff) ) ;
        assertEq (probe.slot () , expected, "ERC-7201 derivation") ;
        assertEq (
            probe.slot () ,
            0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800,
            "the value recorded in the spec"
        ) ;
    }

    /// ERC-7201 requires the low 8 bits to be zero (reserved for future use, and to
    /// avoid colliding with the slot arithmetic of short arrays) .
    function test_slot_is_byte_aligned () public view {
        assertEq (uint256 (probe.slot () ) & 0xff, 0) ;
    }

    /// Proves the state actually lands at that slot, not merely that the constant is right.
    function test_state_actually_lives_at_that_slot () public {
        probe.setPaused (true) ;
        assertTrue (probe.paused () ) ;

        // `paused` is a bool field in the struct. Five mappings precede it, one slot
        // each, so `paused` lands at SLOT + 5 (see the field order in LeashStorage) .
        bytes32 raw = vm.load (address (probe) , bytes32 (uint256 (probe.slot () ) + 5) ) ;
        assertEq (uint256 (raw) & 0xff, 1, "paused is the low byte of SLOT+5") ;
    }
}
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashStorage -vv`
Expected: a compile failure, `Source "src/LeashStorage.sol" not found`

- [ ] **Step 3: write the minimal implementation**

```solidity
// src/LeashStorage.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashStorage — the per-EOA state layout for `LeashAccount`
/// @notice **This library exists because of a risk specific to EIP-7702.**
///
///         Delegated code executes against the **EOA's own storage**. If that EOA later
///         redelegates to **a different impl with a different layout**, the old data gets
///         reinterpreted under the new meaning — the kind of disaster where a budget is
///         read back as an admin address.
///
///         The fix is an ERC-7201 namespaced slot: the whole state goes into one struct,
///         parked at the slot derived from `keccak256 ("leash.account.v1") `. **The version
///         lives inside the string** — change the layout, change the string, and the old
///         slot can never be misread.
library LeashStorage {
    /// @dev One agent's binding. `node` and `label` are written together in `bindAgent`,
    ///      so a caller never gets the chance to submit an inconsistent pair — that is an
    ///      invariant established at bind time.
    struct AgentBinding {
        bytes32 node; // namehash ("<label>.leash.eth") , for reading resolver records
        string label; // "vendors", for LeashRegistry.getResolver (label)
        bool revoked;
    }

    /// @dev The rule for one (node, token) . **Five tunable fields** plus a monotonically
    ///      increasing epoch.
    struct TokenRule {
        bool allowed;
        uint256 txLimit; // 0 = unlimited
        uint256 periodLimit; // 0 = unlimited
        uint64 period; // period length in seconds. 0 = no period
        uint16 windowStart; // minute of the day, UTC
        uint16 windowEnd; // start == end means all day
        uint32 epoch; // **never decreases.** Any change to `period` must bump it by 1
    }

    /// @custom:storage-location erc7201:leash.account.v1
    /// @dev **Do not reorder these fields.** `test_state_actually_lives_at_that_slot`
    ///      relies on `paused` sitting at SLOT+5 (the five mappings above take one slot
    ///      each) .
    struct AccountStorage {
        mapping (address agent => AgentBinding) bindings; // SLOT + 0
        mapping (bytes32 node => mapping (address token => TokenRule) ) rules; // SLOT + 1
        mapping (bytes32 node => mapping (address token => mapping (address payee => bool) ) ) payees; // +2
        mapping (bytes32 node => mapping (address token => mapping (uint256 bucket => uint256) ) ) spent; // +3
        mapping (bytes32 digest => bool) attestationUsed; // SLOT + 4
        bool paused; // SLOT + 5
        bool entered; // SLOT + 5 (shares the slot with `paused`, one byte each)
        bool leashedEmitted; // SLOT + 5 - `Leashed` fires once; see LeashAccount.bindAgent
    }

    /// @dev ERC-7201:`keccak256 (abi.encode (uint256 (keccak256 (id) ) - 1) ) & ~0xff`
    ///      The resulting value is pinned by `test_slot_matches_the_erc7201_formula`.
    bytes32 internal constant SLOT =
        0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800;

    function layout () internal pure returns (AccountStorage storage $) {
        bytes32 s = SLOT;
        assembly {
            $.slot := s
        }
    }
}
```

- [ ] **Step 4: run the tests and confirm they pass**

Run: `forge test --match-contract LeashStorage -vv`
Expected: 3 passed

- [ ] **Step 5: write the failing tests for `LeashLens`**

```solidity
// test/LeashLens.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashLens } from "../src/LeashLens.sol";

contract Dummy {
    uint256 public x;
}

contract LeashLensTest is Test {
    LeashLens lens;
    uint256 pk = 0xA11CE;
    address alice;
    Dummy impl;

    function setUp () public {
        lens = new LeashLens () ;
        alice = vm.addr (pk) ;
        impl = new Dummy () ;
    }

    /// An undelegated EOA: its code is empty.
    function test_plain_eoa_is_not_leashed () public view {
 (bool leashed, address to) = lens.delegateOf (alice) ;
        assertFalse (leashed) ;
        assertEq (to, address (0) ) ;
    }

    /// After delegation the code is the 23 bytes `0xef0100 || address`.
    function test_delegated_eoa_reports_its_impl () public {
        vm.signAndAttachDelegation (address (impl) , pk) ;
 (bool leashed, address to) = lens.delegateOf (alice) ;
        assertTrue (leashed) ;
        assertEq (to, address (impl) ) ;
    }

    /// An ordinary contract is not a 7702 delegation — its code length is not 23.
    function test_a_normal_contract_is_not_a_delegation () public view {
 (bool leashed, address to) = lens.delegateOf (address (impl) ) ;
        assertFalse (leashed, "a contract is not a delegation") ;
        assertEq (to, address (0) ) ;
    }

    /// **An EIP-7702 delegation change emits no log**, so a subgraph cannot index
    /// "the leash came off" — this lens is the only way to observe it (the frontend
    /// checks once on load, a monitoring script polls) . This test proves it detects a
    /// delegation being removed.
    function test_detects_removal_of_the_delegation () public {
        vm.signAndAttachDelegation (address (impl) , pk) ;
 (bool leashed,) = lens.delegateOf (alice) ;
        assertTrue (leashed) ;

        vm.signAndAttachDelegation (address (0) , pk) ; // revoke the delegation
 (bool after_, address to) = lens.delegateOf (alice) ;
        assertFalse (after_, "leash is gone") ;
        assertEq (to, address (0) ) ;
    }
}
```

- [ ] **Step 6: run the tests and confirm they fail**

Run: `forge test --match-contract LeashLens -vv`
Expected: a compile failure, `Source "src/LeashLens.sol" not found`

- [ ] **Step 7: write `LeashLens`**

```solidity
// src/LeashLens.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeashLens — is the leash still on?
/// @notice **An EIP-7702 delegation change emits no log at all.** So "is this wallet
///         still governed by a policy?" cannot be indexed by a subgraph; it can only be
///         polled with `eth_call` — once when the frontend loads, periodically from a
///         monitoring script. This contract is that query.
///
/// @dev `PLAN.md` originally specified `isLeashed (bytes32 node) → (bool, address) `,
///      walking ENS → wallet → delegate. **That direction does not exist** — ENS records
///      node → policy, there is no node → wallet reverse index, and building one means
///      another contract and another thing to keep in sync. So it asks by wallet address
///      instead.
contract LeashLens {
    /// @notice Reads `wallet`'s code and decides whether it is an EIP-7702 delegation.
    /// @return leashed Whether it is a delegation
    /// @return impl What it delegates to; `address (0) ` when it is not a delegation
    ///
    /// @dev Delegated code is exactly the 23 bytes `0xef0100 || address` — a bijection,
    ///      which is why returning the address beats returning a codehash (the address
    ///      can go straight into the UI, whereas the codehash is just the keccak of those
    ///      23 bytes and carries identical information) .
    function delegateOf (address wallet) external view returns (bool leashed, address impl) {
        if (wallet.code.length != 23) return (false, address (0) ) ;
        bytes memory c = wallet.code;
        if (uint8 (c[0]) != 0xef || uint8 (c[1]) != 0x01 || uint8 (c[2]) != 0x00) {
            return (false, address (0) ) ;
        }
        // Skip the 3-byte prefix. `mload (add (c, 0x23) ) ` reads bytes 3..35 of c;
        // shifting right by 96 bits leaves the high 20 bytes.
        assembly {
            impl := shr (96, mload (add (c, 0x23) ) )
        }
        return (true, impl) ;
    }
}
```

- [ ] **Step 8: run the tests and confirm they pass**

Run: `forge test --match-contract LeashLens -vv`
Expected: 4 passed

- [ ] **Step 9: format and run the whole suite**

Run: `forge fmt && forge test`
Expected: 106 passed (the original 99 + 3 + 4) , 0 failed

- [ ] **Step 10: Commit**

```bash
git add src/LeashStorage.sol src/LeashLens.sol test/LeashStorage.t.sol test/LeashLens.t.sol
git commit -m "feat: LeashStorage (the ERC-7201 layout) + LeashLens (reading a 7702 delegation)

An ERC-7201 namespaced slot is necessary rather than fastidious:
delegated code executes against the EOA's own storage, so when that EOA
later redelegates to an impl with a different layout, the old data gets
reinterpreted under the new meaning. The version lives inside the string
 (leash.account.v1) - change the layout, change the string.

The test does not copy the constant; it recomputes the ERC-7201 formula
and uses vm.load to prove the state really lands at that slot - get it
wrong and everything lands elsewhere, with no error message of any kind.

LeashLens replaces the isLeashed (bytes32 node) the plan originally
specified: the node -> wallet direction does not exist, because ENS
records node -> policy. It asks by wallet address instead.
An EIP-7702 delegation change emits no log, so this is the only way to
observe whether the leash is still on."
```

---

## Task 2: the `LeashAccount` skeleton — 7702 semantics, `receive`, spending attestations

This task implements no business logic; it lays the **foundation**: the immutables, the
7702 call surface, and computing and spending EIP-712 digests. When it is done, two critical
things should be demonstrable: **a delegated EOA can receive ETH**, and **an attacker cannot
seize control**.

**Files:**
- Create: `src/LeashAccount.sol`
- Test: `test/LeashAccountBinding.t.sol`

**Interfaces:**
- Consumes: `LeashStorage.layout () ` and `LeashStorage.AccountStorage` (task 1)
- Produces:
  - `constructor (address ethRegistry_, IPolicyApprovals approvals_, IAttester attester_) `
  - `address public immutable ETH_REGISTRY` / `IPolicyApprovals public immutable APPROVALS`
    / `IAttester public immutable ATTESTER` / `address public immutable SELF`
  - `string public constant PARENT_LABEL = "leash"`
  - `bytes32 public constant PARENT_NODE`
  - `function domainSeparator () public view returns (bytes32) `
  - `receive () external payable` / `fallback () external payable`
  - `error NotSelf () ` / `error NotAttested () ` / `error AttestationReused (bytes32) ` / `error UnknownSelector () `
  - `modifier onlySelf () `
  - `function _consumeAttestation (bytes32 structHash, bytes calldata attestation) private`

- [ ] **Step 1: write the failing tests — 7702 semantics and front-running protection**

```solidity
// test/LeashAccountBinding.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract MockApprovals is IPolicyApprovals {
    mapping (address => bool) public approved;

    function set (address p, bool v) external {
        approved[p] = v;
    }

    function isApproved (address p) external view returns (bool) {
        return approved[p];
    }
}

contract LeashAccountBindingTest is Test {
    LeashAccount impl;
    MockApprovals approvals;
    MockAttester attester;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant AGENT = address (0xA6E17) ;
    address constant ATTACKER = address (0xBAD) ;
    address constant ETH_REGISTRY = address (0xE45) ;

    bytes constant ATT = hex"c0ffee";
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    /// The delegated EOA, addressed through LeashAccount's interface.
    LeashAccount acct;

    function setUp () public {
        approvals = new MockApprovals () ;
        attester = new MockAttester () ;
        impl = new LeashAccount (ETH_REGISTRY, approvals, attester) ;
        wallet = vm.addr (walletPk) ;
        vm.signAndAttachDelegation (address (impl) , walletPk) ;
        acct = LeashAccount (payable (wallet) ) ;
    }

    // --- 7702 semantics ---

    /// After delegation the EOA's code is the 23 bytes `0xef0100 || impl`.
    function test_delegation_layout () public view {
        assertEq (wallet.code.length, 23) ;
        assertEq (uint8 (wallet.code[0]) , 0xef) ;
        assertEq (uint8 (wallet.code[1]) , 0x01) ;
        assertEq (uint8 (wallet.code[2]) , 0x00) ;
    }

    /// 🔴 **C2 regression: a delegated wallet must still be able to receive ETH.**
    ///
    /// A plain ETH transfer is a call to the delegate with **empty calldata**. Without a
    /// `receive () `, Solidity's dispatcher reverts — which means faucets, exchanges and
    /// `cast send --value` all stop working, and the wallet can never be topped up with
    /// gas again after delegating.
    function test_delegated_wallet_can_still_receive_eth () public {
        deal (address (this) , 1 ether) ;
        uint256 before = wallet.balance;
 (bool ok,) = payable (wallet) .call{ value: 1 ether } ("") ;
        assertTrue (ok, "empty calldata must hit receive () ") ;
        assertEq (wallet.balance - before, 1 ether) ;
    }

    /// An unknown selector must revert explicitly rather than be swallowed — accepting it
    /// silently would make a mistyped selector look like success.
    function test_unknown_selector_reverts () public {
        vm.expectRevert (LeashAccount.UnknownSelector.selector) ;
 (bool ok,) = wallet.call (abi.encodeWithSignature ("notAFunction () ") ) ;
        ok; // judged by expectRevert
    }

    /// Inside a delegate, `address (this) ` is the **EOA**, while `SELF` is the impl's own
    /// address. They are different values, and an attestation digest needs **both**:
    /// `address (this) ` binds which wallet, `SELF` binds which impl version.
    function test_address_this_is_the_eoa_but_self_is_the_impl () public view {
        assertEq (acct.SELF () , address (impl) , "SELF is baked in at deploy time") ;
        // domainSeparator uses address (this) — inside a delegate, that is the wallet
        bytes32 expected = keccak256 (
            abi.encode (
                keccak256 (
                    "EIP712Domain (string name,string version,uint256 chainId,address verifyingContract) "
                ) ,
                keccak256 ("Leash") ,
                keccak256 ("1") ,
                block.chainid,
                wallet
            )
        ) ;
        assertEq (acct.domainSeparator () , expected, "verifyingContract is the EOA") ;
    }

    /// Two EOAs delegating to the same impl have entirely independent storage.
    function test_two_wallets_sharing_one_impl_are_independent () public {
        uint256 pk2 = 0xB0B;
        address w2 = vm.addr (pk2) ;
        vm.signAndAttachDelegation (address (impl) , pk2) ;

        vm.prank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;

 (bytes32 n1,,) = acct.bindingOf (AGENT) ;
 (bytes32 n2,,) = LeashAccount (payable (w2) ) .bindingOf (AGENT) ;
        assertEq (n1, NODE) ;
        assertEq (n2, bytes32 (0) , "the other wallet knows nothing about this agent") ;
    }

    // --- 🔴 decision 2 regression: no initialize, so nothing to front-run ---

    /// **Storage is empty right after delegation, and that is the attacker's only window.**
    ///
    /// A spike demonstrated it: with an `initialize () `, anyone can call it first and set
    /// themselves as admin. Our approach is to have **no initialisation step at all** —
    /// the global configuration is immutable, per-EOA authority is always
    /// `msg.sender == address (this) `, and only the wallet's private key can make that EOA
    /// send a transaction.
    ///
    /// This test walks through and shows an attacker can do nothing in that window.
    function test_attacker_cannot_seize_a_freshly_delegated_wallet () public {
        vm.startPrank (ATTACKER) ;

        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        acct.bindAgent (ATTACKER, NODE, LABEL) ;

        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        acct.allowPayee (NODE, address (0xDEAD) , ATTACKER, 1, ATT) ;

        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        acct.setRule (
            NODE,
            address (0xDEAD) ,
            LeashStorage.TokenRule (true, 0, 0, 0, 0, 0, 0) ,
            1,
            ATT
        ) ;

        vm.stopPrank () ;

 (bytes32 n,,) = acct.bindingOf (ATTACKER) ;
        assertEq (n, bytes32 (0) , "nothing was seized") ;
    }

    /// Calls to the **impl itself** must be inert. Nobody delegates to the impl, and its
    /// `address (this) ` is itself, so in principle it could give itself orders. That harms
    /// no wallet (the state lives in the impl's own storage and no EOA reads it) , but we
    /// still confirm an **outsider** cannot move it.
    function test_calling_the_impl_directly_does_nothing_for_an_outsider () public {
        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        vm.prank (ATTACKER) ;
        impl.bindAgent (ATTACKER, NODE, LABEL) ;
    }

    // --- attestation ---

    /// The digest must include `SELF`, otherwise an attestation can be replayed across
    /// versions after redelegating to a new impl.
    function test_attestation_digest_is_bound_to_the_impl_version () public {
        LeashAccount impl2 = new LeashAccount (ETH_REGISTRY, approvals, attester) ;
        bytes32 d1 = acct.payeeDigest (NODE, address (0xDEAD) , AGENT, 1) ;

        vm.signAndAttachDelegation (address (impl2) , walletPk) ;
        bytes32 d2 = LeashAccount (payable (wallet) ) .payeeDigest (NODE, address (0xDEAD) , AGENT, 1) ;

        assertTrue (d1 != d2, "same wallet, different impl version, different digest") ;
    }
}
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: a compile failure, `Source "src/LeashAccount.sol" not found`

- [ ] **Step 3: write the `LeashAccount` skeleton**

Only what this task needs. At this step `bindAgent` / `allowPayee` / `setRule` /
`bindingOf` / `payeeDigest` need only exist enough for the tests to compile and pass — the
full logic is tasks 3 and 4.

```solidity
// src/LeashAccount.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LeashStorage } from "./LeashStorage.sol";
import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";
import { Reason } from "./Reason.sol";

/// @title LeashAccount — the agent's only spending path
/// @notice An EIP-7702 delegate implementation. Before any agent-initiated transfer, the
///         delegated EOA must: authorise the agent → walk three ENS hops to a policy →
///         check it against the approval list → pass the policy.
///
/// @dev **Do not call it "the only spending path".** EIP-7702 constrains only calls to that
///      EOA; the WALLET private key can still sign `USDC.transfer` directly, and the policy
///      path never executes. This is both the boundary and the **escape hatch** — the
///      wallet's owner can always retrieve their own funds.
///
///      **There is no `initialize () `.** The global configuration is `immutable`, burned
///      into the bytecode, so the window after delegation where storage is still blank has
///      nothing to race for. Per-EOA authority is always `msg.sender == address (this) `, and
///      only the wallet's private key can make that EOA send a transaction.
contract LeashAccount {
    using LeashStorage for LeashStorage.AccountStorage;

    // --- burned into the bytecode ---

    /// @notice ENSv2's .eth registry. The start of resolution, and where the kill-everything
    ///         lever sits.
    address public immutable ETH_REGISTRY;

    /// @notice The approval list. **immutable** — see the C1 notes on `PolicyApprovals`.
    IPolicyApprovals public immutable APPROVALS;

    /// @notice The attestation source for widening. **immutable**.
    IAttester public immutable ATTESTER;

    /// @notice **The address the impl itself was deployed at.**
    /// @dev A small trap specific to 7702: inside one piece of code, `address (this) ` and
    ///      "where this code lives" are **two different values**. When the delegate runs,
    ///      `address (this) ` is the EOA, whereas an `immutable` was burned into the bytecode
    ///      at deploy time — so `SELF` remembers the impl's address.
    ///
    ///      An attestation digest needs **both**: `address (this) ` binds *which wallet*,
    ///      `SELF` binds *which impl version*. Without `SELF`, once a wallet redelegates to
    ///      a new version, an attestation from the old version could be replayed (the new
    ///      version may use a different ERC-7201 namespace and so cannot see the old
    ///      `attestationUsed` records) .
    address public immutable SELF;

    string public constant PARENT_LABEL = "leash";

    /// @notice `namehash ("leash.eth") `. `bindAgent` uses it to verify node and label agree.
    bytes32 public constant PARENT_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @notice The gas cap on calling a policy. Exceeding it fails closed (reason code 12) .
    /// @dev A deliberate cap: a policy that can burn all the gas is a DoS switch.
    uint256 public constant POLICY_GAS = 200_000;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256 (
        "EIP712Domain (string name,string version,uint256 chainId,address verifyingContract) "
    ) ;
    bytes32 private constant NAME_HASH = keccak256 ("Leash") ;
    bytes32 private constant VERSION_HASH = keccak256 ("1") ;
    bytes32 private constant PAYEE_TYPEHASH = keccak256 (
        "AllowPayee (address impl,bytes32 node,address token,address payee,uint256 nonce) "
    ) ;

    error NotSelf () ;
    error NotAttested () ;
    error AttestationReused (bytes32 digest) ;
    error UnknownSelector () ;

    /// @dev The only form of per-EOA authority. Inside a delegate, `address (this) ` is that
    ///      EOA, and only its private key can make it send a transaction — so this *is*
    ///      "the wallet itself".
    modifier onlySelf () {
        if (msg.sender != address (this) ) revert NotSelf () ;
        _;
    }

    constructor (address ethRegistry_, IPolicyApprovals approvals_, IAttester attester_) {
        ETH_REGISTRY = ethRegistry_;
        APPROVALS = approvals_;
        ATTESTER = attester_;
        SELF = address (this) ;
    }

    /// @notice **Mandatory.** A plain ETH transfer is a call to the delegate with empty
    ///         calldata; without this function, a delegated wallet can no longer receive
    ///         ETH or be topped up with gas.
    receive () external payable { }

    /// @notice An unknown selector reverts explicitly rather than being swallowed.
    /// @dev This account **does not** do general-purpose call forwarding (see the YAGNI
    ///      table in the spec) .
    fallback () external payable {
        revert UnknownSelector () ;
    }

    function domainSeparator () public view returns (bytes32) {
        return keccak256 (
            abi.encode (DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address (this) )
        ) ;
    }

    function bindingOf (address agent)
        external
        view
        returns (bytes32 node, string memory label, bool revoked)
    {
        LeashStorage.AgentBinding storage b = LeashStorage.layout () .bindings[agent];
        return (b.node, b.label, b.revoked) ;
    }

    /// @notice Binds an agent to an ENS name. **Points in the reducing direction, so no
    ///         attestation.**
    /// @dev The full checks arrive in task 3 (namehash agreement, revert if already bound) .
    function bindAgent (address agent, bytes32 node, string calldata label) external onlySelf {
        LeashStorage.AgentBinding storage b = LeashStorage.layout () .bindings[agent];
        b.node = node;
        b.label = label;
    }

    /// @notice Allow-lists a payee. **A widening — both conditions required.**
    function allowPayee (
        bytes32 node,
        address token,
        address payee,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation (
            keccak256 (abi.encode (PAYEE_TYPEHASH, SELF, node, token, payee, nonce) ) , attestation
        ) ;
        LeashStorage.layout () .payees[node][token][payee] = true;
    }

    /// @notice Sets a rule. **A widening — both conditions required.** Full logic in task 4.
    function setRule (
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        nonce;
        attestation;
        LeashStorage.layout () .rules[node][token] = rule;
    }

    function payeeDigest (bytes32 node, address token, address payee, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return _digest (keccak256 (abi.encode (PAYEE_TYPEHASH, SELF, node, token, payee, nonce) ) ) ;
    }

    function _digest (bytes32 structHash) private view returns (bytes32) {
        return keccak256 (abi.encodePacked (hex"1901", domainSeparator () , structHash) ) ;
    }

    /// @dev Where an attestation is spent. The digest binds both this wallet
    /// (`address (this) ` goes into the domain) and this impl version (`SELF` goes into
    ///      the structHash) . Marked permanently once used.
    function _consumeAttestation (bytes32 structHash, bytes calldata attestation) private {
        bytes32 d = _digest (structHash) ;
        LeashStorage.AccountStorage storage $ = LeashStorage.layout () ;
        if ($.attestationUsed[d]) revert AttestationReused (d) ;
        if (!ATTESTER.verify (d, attestation) ) revert NotAttested () ;
        $.attestationUsed[d] = true;
    }
}
```

- [ ] **Step 4: run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 8 passed

- [ ] **Step 5: format and run the whole suite**

Run: `forge fmt && forge test`
Expected: 114 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountBinding.t.sol
git commit -m "feat: LeashAccount skeleton - 7702 semantics, receive, spending attestations

No initialize () : the global configuration is immutable, burned into the
bytecode, so the window after delegation where storage is still blank has
nothing to race for. The tests walk through and show an attacker reaches
none of bindAgent / allowPayee / setRule in that window.

receive () is required rather than a courtesy: a plain ETH transfer is a
call to the delegate with empty calldata, and without it that reverts -
a delegated wallet could no longer receive ETH or be topped up with gas.
Measured.

SELF records the address the impl itself was deployed at. This is a trap
specific to 7702: inside one piece of code, address (this) and 'where this
code lives' are two different values. An attestation digest needs both -
address (this) binds which wallet, SELF binds which impl version -
otherwise an attestation can be replayed across versions after
redelegating."
```

---

## Task 3: agent binding and pausing — the asymmetry, implemented in full

**Files:**
- Modify: `src/LeashAccount.sol` (complete `bindAgent`; add `unbindAgent` / `revokeAgent` / `restoreAgent` / `pause` / `unpause`)
- Modify: `test/LeashAccountBinding.t.sol` (appended to)

**Interfaces:**
- Consumes: task 2's `onlySelf`, `_consumeAttestation` and `_digest`
- Produces:
  - `bindAgent (address agent, bytes32 node, string calldata label) `
  - `unbindAgent (address agent) ` / `revokeAgent (address agent) ` / `restoreAgent (address agent, bytes32 node, string calldata label, uint256 nonce, bytes calldata attestation) `
  - `pause () ` / `unpause () ` / `paused () `
  - `nodeFor (string memory label) public pure returns (bytes32) `
  - `error NodeLabelMismatch (bytes32 expected, bytes32 got) ` / `error AlreadyBound () ` / `error NotBoundAgent () ` / `error NotSelfOrAgent () `
  - The events `AgentBound` / `AgentRevoked` / `Paused` / `Unpaused`, per `docs/events.md`

- [ ] **Step 1: write the failing tests**

```solidity
    // appended to test/LeashAccountBinding.t.sol

    // --- 🔴 M2 regression: node and label must agree ---

    /// **`node` is not only the resolver's key — it is also the key for `rules` / `payees`
    /// / `spent`.**
    ///
    /// So `bindAgent (agentB, node=vendors, label="payroll") ` would let agentB spend
    /// **vendors' human-approved limits and budget** while being judged by **payroll's
    /// policy**. And since the `AgentBound (agent, node) ` event carries no label, that would
    /// be **completely invisible** offchain.
    ///
    /// Under a fixed parent, computing the namehash costs **two keccaks** (around 200 gas) ,
    /// which trades an invisible misconfiguration for a revert.
    function test_bind_rejects_a_node_label_mismatch () public {
        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        vm.expectRevert (
            abi.encodeWithSelector (
                LeashAccount.NodeLabelMismatch.selector, acct.nodeFor (LABEL) , payrollNode
            )
        ) ;
        vm.prank (wallet) ;
        acct.bindAgent (AGENT, payrollNode, LABEL) ;
    }

    function test_nodeFor_matches_the_recorded_namehashes () public view {
        assertEq (acct.nodeFor ("vendors") , NODE) ;
        assertEq (
            acct.nodeFor ("payroll") ,
            0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8
        ) ;
    }

    // --- 🔴 M4 regression: no free rebind after a revocation ---

    /// What the frozen document says about reason code 2 is "reductions need no face scan,
    /// **restoring does**". If `bindAgent` could overwrite an existing binding, a free
    /// rebind after a revocation would sidestep that rule.
    function test_bind_rejects_an_existing_binding () public {
        vm.startPrank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;
        vm.expectRevert (LeashAccount.AlreadyBound.selector) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;
        vm.stopPrank () ;
    }

    /// Restoring a revoked agent requires an attestation.
    function test_restore_requires_an_attestation () public {
        vm.startPrank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;
        acct.revokeAgent (AGENT) ;
 (,, bool revoked) = acct.bindingOf (AGENT) ;
        assertTrue (revoked) ;

        acct.restoreAgent (AGENT, NODE, LABEL, 1, ATT) ;
 (,, bool after_) = acct.bindingOf (AGENT) ;
        assertFalse (after_, "restored") ;
        vm.stopPrank () ;
    }

    /// **But binding to the wrong name must not be permanent.** `unbindAgent` is entirely
    /// free (unbinding is a reduction) , after which it can be bound to the correct name —
    /// both steps are reductions, and at no point in between does it hold more authority
    /// than before.
    function test_a_mis_binding_is_correctable_for_free () public {
        vm.startPrank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;

        acct.unbindAgent (AGENT) ;
 (bytes32 n,,) = acct.bindingOf (AGENT) ;
        assertEq (n, bytes32 (0) , "back to unbound") ;

        bytes32 payrollNode = 0x2686785985b68816fe9d6dde5bf58d194ff9991d3d9dc89c14daf6f8224ba9a8;
        acct.bindAgent (AGENT, payrollNode, "payroll") ;
 (bytes32 n2,,) = acct.bindingOf (AGENT) ;
        assertEq (n2, payrollNode, "rebound with no attestation") ;
        vm.stopPrank () ;
    }

    // --- reductions are always available ---

    /// An agent can revoke itself — a reduction should have no gate.
    function test_an_agent_can_revoke_itself () public {
        vm.prank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;

        vm.prank (AGENT) ;
        acct.revokeAgent (AGENT) ;
 (,, bool revoked) = acct.bindingOf (AGENT) ;
        assertTrue (revoked) ;
    }

    function test_a_stranger_cannot_revoke_someone_elses_agent () public {
        vm.prank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;

        vm.expectRevert (LeashAccount.NotSelfOrAgent.selector) ;
        vm.prank (ATTACKER) ;
        acct.revokeAgent (AGENT) ;
    }

    // --- 🔴 M6 regression: pause is free, so unpause must be free too ---

    /// Any bound agent that has not been revoked can hit the brake — hitting the brake can
    /// only make the system stricter.
    function test_any_bound_agent_can_pause () public {
        vm.prank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;

        vm.prank (AGENT) ;
        acct.pause () ;
        assertTrue (acct.paused () ) ;
    }

    function test_a_revoked_agent_cannot_pause () public {
        vm.startPrank (wallet) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;
        acct.revokeAgent (AGENT) ;
        vm.stopPrank () ;

        vm.expectRevert (LeashAccount.NotBoundAgent.selector) ;
        vm.prank (AGENT) ;
        acct.pause () ;
    }

    /// **`unpause` must not require an attestation.** Otherwise a compromised agent can
    /// `pause` for free and force the holder to scan their face over and over — a DoS. A
    /// free brake demands a free release. The frozen document also lists reason code 10 as
    /// "an ADMIN's routine operation", needing no scan.
    function test_unpause_is_free_and_only_the_wallet_can_do_it () public {
        vm.prank (wallet) ;
        acct.pause () ;

        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        vm.prank (AGENT) ;
        acct.unpause () ;

        vm.prank (wallet) ;
        acct.unpause () ;
        assertFalse (acct.paused () ) ;
    }
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: a compile failure, `Member "unbindAgent" not found`

- [ ] **Step 3: implement it**

```solidity
    // replaces task 2's placeholder bindAgent and adds the rest

    bytes32 private constant RESTORE_TYPEHASH = keccak256 (
        "RestoreAgent (address impl,address agent,bytes32 node,string label,uint256 nonce) "
    ) ;

    event AgentBound (address indexed agent, bytes32 indexed node) ;
    /// @dev Evidence that this EOA now delegates to LeashAccount. **The subgraph's
    ///      template trigger** — 7702 delegation emits no log, so this is the only way an
    ///      indexer learns which address to watch.
    event Leashed (bytes32 indexed node, address indexed wallet, address impl) ;
    event AgentRevoked (address indexed agent, address indexed by) ;
    event Paused (address indexed by) ;
    event Unpaused (address indexed by, bytes32 attestationHash) ;

    error NodeLabelMismatch (bytes32 expected, bytes32 got) ;
    error AlreadyBound () ;
    error NotBoundAgent () ;
    error NotSelfOrAgent () ;

    /// @notice `namehash ("<label>.leash.eth") `.
    /// @dev The parent is fixed, so one keccak against `PARENT_NODE` suffices — two keccaks
    ///      in total, not a loop.
    function nodeFor (string memory label) public pure returns (bytes32) {
        return keccak256 (abi.encodePacked (PARENT_NODE, keccak256 (bytes (label) ) ) ) ;
    }

    function paused () external view returns (bool) {
        return LeashStorage.layout () .paused;
    }

    /// @notice Binds an agent. **Points in the reducing direction, so no attestation** —
    ///         it grants authority starting from zero, and the *content* of that authority
    ///         is decided entirely by the ENS side (ADMIN) and the approval list (a human) .
    ///
    /// @dev `node` and `label` **must agree**. `node` is not only the resolver's key; it is
    ///      also the key for `rules` / `payees` / `spent` — a mismatch would let this agent
    ///      spend name A's budget while being judged by name B's policy, and since
    ///      `AgentBound` carries no label, that would be invisible offchain.
    function bindAgent (address agent, bytes32 node, string calldata label) external onlySelf {
        bytes32 expected = nodeFor (label) ;
        if (node != expected) revert NodeLabelMismatch (expected, node) ;

        LeashStorage.AccountStorage storage $ = LeashStorage.layout () ;
        LeashStorage.AgentBinding storage b = $.bindings[agent];
        // Revert if it already exists: otherwise "rebind for free after a revocation"
        // would sidestep what the frozen document says about reason code 2 (restoring
        // requires a face scan) . The remedy for a wrong bind is `unbindAgent` then
        // `bindAgent` — both of which are reductions.
        if (b.node != bytes32 (0) ) revert AlreadyBound () ;

        b.node = node;
        b.label = label;
        emit AgentBound (agent, node) ;

        // **Emit `Leashed` on the first bind.**
        //
        // EIP-7702 delegation **emits no log at all**, so a subgraph has no factory event
        // to trigger a template from — it does not know which EOA addresses to watch. This
        // is that trigger. (`Leashed` was already in the frozen schema; this gives it a
        // definite moment of emission.)
        // The demo additionally hardcodes the wallet address in subgraph.yaml as a
        // fallback; see sprint item 9.
        // The `b.node == 0` branch was already established above (otherwise AlreadyBound) ,
        // so anything reaching here is this agent's first bind.
        // But `Leashed` is a **wallet-level** fact and must not be re-emitted for every
        // agent bound — a separate flag remembers it.
        if (!$.leashedEmitted) {
            $.leashedEmitted = true;
            emit Leashed (node, address (this) , SELF) ;
        }
    }

    /// @notice Unbinds completely. **A reduction, entirely free.**
    /// @dev This is the remedy for "bound to the wrong name". Once unbound the agent can do
    ///      nothing, and it can be `bindAgent`-ed again to the correct name — at no point
    ///      in between does it hold more authority than before.
    function unbindAgent (address agent) external {
        _requireSelfOrAgent (agent) ;
        delete LeashStorage.layout () .bindings[agent];
        emit AgentRevoked (agent, msg.sender) ;
    }

    /// @notice Revokes an agent (the binding is kept and marked revoked) . **A reduction,
    ///         no attestation.**
    /// @dev How it differs from `unbindAgent`: node/label are kept, so `spend` reaches step
    ///      2b and emits an indexable `SpendBlocked (AGENT_REVOKED) ` — the agent can query
    ///      the subgraph and learn why it is stuck. `unbindAgent` instead makes it "never
    ///      bound", which reverts outright at 2a.
    function revokeAgent (address agent) external {
        _requireSelfOrAgent (agent) ;
        LeashStorage.layout () .bindings[agent].revoked = true;
        emit AgentRevoked (agent, msg.sender) ;
    }

    /// @notice Restores a revoked agent. **A widening — both conditions required.**
    /// @dev All three parameters go into the digest, so an attestation issued for one
    ///      restoration cannot be redirected to restore a different agent or to bind it to
    ///      a different name.
    function restoreAgent (
        address agent,
        bytes32 node,
        string calldata label,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        bytes32 expected = nodeFor (label) ;
        if (node != expected) revert NodeLabelMismatch (expected, node) ;
        _consumeAttestation (
            keccak256 (
                abi.encode (RESTORE_TYPEHASH, SELF, agent, node, keccak256 (bytes (label) ) , nonce)
            ) ,
            attestation
        ) ;

        LeashStorage.AgentBinding storage b = LeashStorage.layout () .bindings[agent];
        b.node = node;
        b.label = label;
        b.revoked = false;
        emit AgentBound (agent, node) ;
    }

    /// @notice Pauses everything. **The wallet itself, or any bound agent that has not
    ///         been revoked, can press it.**
    /// @dev Hitting the brake can only make the system stricter; requiring a permission for
    ///      it does the attacker a favour at exactly the moment things go wrong.
    function pause () external {
        if (msg.sender != address (this) ) {
            LeashStorage.AgentBinding storage b = LeashStorage.layout () .bindings[msg.sender];
            if (b.node == bytes32 (0) || b.revoked) revert NotBoundAgent () ;
        }
        LeashStorage.layout () .paused = true;
        emit Paused (msg.sender) ;
    }

    /// @notice Unpauses. **The wallet itself only, and no attestation.**
    /// @dev **It must not require an attestation.** Any agent can `pause` for free, so if
    ///      `unpause` cost a face scan, a compromised agent could force the holder to scan
    ///      their face over and over — that is a DoS. A free brake demands a free release,
    ///      both controlled by the wallet itself. The frozen document also lists reason
    ///      code 10 as "an ADMIN's routine operation", needing no scan.
    ///
    ///      The frozen signature of `Unpaused` has an `attestationHash` field — we send
    ///      `bytes32 (0) `, and the subgraph must read 0 as "an unpause that needs no
    ///      attestation", not as missing data.
    function unpause () external onlySelf {
        LeashStorage.layout () .paused = false;
        emit Unpaused (msg.sender, bytes32 (0) ) ;
    }

    function _requireSelfOrAgent (address agent) private view {
        if (msg.sender != address (this) && msg.sender != agent) revert NotSelfOrAgent () ;
        if (LeashStorage.layout () .bindings[agent].node == bytes32 (0) ) revert NotBoundAgent () ;
    }
```

- [ ] **Step 4: run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountBinding -vv`
Expected: 19 passed

- [ ] **Step 5: format and run the whole suite**

Run: `forge fmt && forge test`
Expected: 125 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountBinding.t.sol
git commit -m "feat: agent binding and pausing - the widening/reduction asymmetry

bindAgent checks node == namehash (label + '.leash.eth') . node is not only
the resolver's key, it is also the key for rules/payees/spent - a mismatch
would let an agent spend name A's budget while being judged by name B's
policy, and since AgentBound carries no label, that would be invisible
offchain. Under a fixed parent it takes two keccaks, about 200 gas.

bindAgent reverts on an existing binding (otherwise a free rebind after a
revocation would sidestep what the frozen document says about reason code
2: restoring requires a face scan) , but an entirely free unbindAgent
keeps a wrong bind from being permanent - unbind then rebind, both steps
reductions, with no moment in between holding more authority than before.

unpause deliberately requires no attestation: any agent can pause for
free, so if releasing cost a face scan, a compromised agent could force
the holder to scan over and over. A free brake demands a free release."
```

---

## Task 4: rules and payees — `setRule` / `tightenRule` / window subsets / epoch

**This is the task in the whole plan whose logic is easiest to get wrong.** Two places
**silently widen the rules** when written backwards: the inverted comparison of
`0 = unlimited`, and the subset test for windows that cross midnight. Both need dedicated
tests.

**Files:**
- Modify: `src/LeashAccount.sol`
- Test: `test/LeashAccountRules.t.sol`

**Interfaces:**
- Consumes: task 2's `onlySelf` / `_consumeAttestation`; `LeashStorage.TokenRule`
- Produces:
  - `setRule (bytes32 node, address token, LeashStorage.TokenRule calldata rule, uint256 nonce, bytes calldata attestation) `
  - `tightenRule (bytes32 node, address token, LeashStorage.TokenRule calldata rule) `
  - `removePayee (bytes32 node, address token, address payee) `
  - `ruleOf (bytes32 node, address token) external view returns (LeashStorage.TokenRule memory) `
  - `spentInCurrentPeriod (bytes32 node, address token) external view returns (uint256) `
  - `error NotTighter () `
  - The events `TokenAllowed` / `LimitRaised` / `TokenRemoved` / `LimitLowered` / `PayeeAllowed` / `PayeeRemoved`

- [ ] **Step 1: write the failing tests — start with the two easiest to get backwards**

```solidity
// test/LeashAccountRules.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract NoApprovals is IPolicyApprovals {
    function isApproved (address) external pure returns (bool) {
        return false;
    }
}

contract LeashAccountRulesTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    uint256 walletPk = 0x8A11E7;
    address wallet;

    address constant TOKEN = address (0x05DC) ;
    address constant PAYEE = address (0xBEEF) ;
    bytes constant ATT = hex"c0ffee";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;
    uint256 nonce;

    function setUp () public {
        vm.warp (1_757_000_000) ;
        impl = new LeashAccount (address (0xE45) , new NoApprovals () , new MockAttester () ) ;
        wallet = vm.addr (walletPk) ;
        vm.signAndAttachDelegation (address (impl) , walletPk) ;
        acct = LeashAccount (payable (wallet) ) ;
    }

    function _rule (uint256 txLimit, uint256 periodLimit, uint64 period, uint16 ws, uint16 we)
        internal
        pure
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.TokenRule ({
            allowed: true,
            txLimit: txLimit,
            periodLimit: periodLimit,
            period: period,
            windowStart: ws,
            windowEnd: we,
            epoch: 0
        }) ;
    }

    function _set (LeashStorage.TokenRule memory r) internal {
        vm.prank (wallet) ;
        acct.setRule (NODE, TOKEN, r, ++nonce, ATT) ;
    }

    // --- 🔴 the inverted comparison of `0 = unlimited` ---

    /// **This is the easiest line in the codebase to get backwards.** `0` means
    /// "unlimited", so:
    ///   0 → 100 **tightens** (unlimited becomes finite)
    ///   100 → 0 **widens** (finite becomes unlimited)
    /// A plain `<=` would call both of them tightenings.
    function test_zero_means_unlimited_so_the_comparison_inverts () public {
        _set (_rule (0, 0, 1 days, 0, 0) ) ; // unlimited

        // 0 → 100: tightens, allowed
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 0, 0) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .txLimit, 100) ;

        // 100 → 0: widens, refused
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (0, 0, 1 days, 0, 0) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .txLimit, 100, "unchanged") ;
    }

    function test_lowering_a_finite_limit_is_tightening () public {
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (50, 500, 1 days, 0, 0) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .txLimit, 50) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .periodLimit, 500) ;
    }

    function test_raising_a_finite_limit_is_not_tightening () public {
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (200, 1000, 1 days, 0, 0) ) ;
    }

    /// Switching it off is always a tightening, whatever the other fields say.
    function test_disabling_the_token_is_always_tightening () public {
        _set (_rule (100, 1000, 1 days, 9 * 60, 17 * 60) ) ;
        LeashStorage.TokenRule memory off = _rule (0, 0, 1 days, 0, 0) ;
        off.allowed = false;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, off) ;
        assertFalse (acct.ruleOf (NODE, TOKEN) .allowed) ;
    }

    // --- 🔴 overnight window subsets ---

    /// The semantics of `StandardPolicy._inWindow`: `start == end` is all day,
    /// `start < end` is a same-day interval, `start > end` **crosses midnight**.
    /// So "stricter" cannot be decided by comparing magnitudes.

    function test_all_day_to_a_finite_window_is_tightening () public {
        _set (_rule (100, 0, 1 days, 0, 0) ) ; // all day
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 9 * 60, 17 * 60) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .windowStart, 9 * 60) ;
    }

    function test_a_finite_window_to_all_day_is_widening () public {
        _set (_rule (100, 0, 1 days, 9 * 60, 17 * 60) ) ;
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 0, 0) ) ;
    }

    /// 22:00-06:00 ⊂ 21:00-07:00 — both cross midnight, and the new one is narrower.
    function test_a_narrower_overnight_window_is_tightening () public {
        _set (_rule (100, 0, 1 days, 21 * 60, 7 * 60) ) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 22 * 60, 6 * 60) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .windowStart, 22 * 60) ;
    }

    /// The other way round is a widening.
    function test_a_wider_overnight_window_is_widening () public {
        _set (_rule (100, 0, 1 days, 22 * 60, 6 * 60) ) ;
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 21 * 60, 7 * 60) ) ;
    }

    /// A same-day interval swapped for one crossing midnight: the minute set is not a
    /// subset, so it is refused.
    function test_switching_a_daytime_window_to_overnight_is_widening () public {
        _set (_rule (100, 0, 1 days, 9 * 60, 17 * 60) ) ;
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 0, 1 days, 22 * 60, 6 * 60) ) ;
    }

    // --- 🔴 M5 regression: changing `period` must not resurrect the budget ---

    /// **The first version only froze `period` in `tightenRule`, which was half a fix.**
    /// If `spent` is keyed on nothing but `timestamp / period`, then changing `period`
    /// changes the bucket number and the running total reads back as 0 — **"adjust the
    /// period" becomes a free wipe-the-ledger button.**
    ///
    /// The fix is `epoch`: monotonically increasing, occupying the high bits of the
    /// `spent` key.
    function test_tighten_cannot_touch_period_or_epoch () public {
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;

        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (100, 1000, 7 days, 0, 0) ) ;

        LeashStorage.TokenRule memory bumped = _rule (100, 1000, 1 days, 0, 0) ;
        bumped.epoch = 1;
        vm.expectRevert (LeashAccount.NotTighter.selector) ;
        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, bumped) ;
    }

    /// `epoch` must increment when `setRule` changes `period` — a new period means a new
    /// ledger, and since `epoch` never decreases, **wiping the ledger always costs an
    /// attestation**.
    function test_setRule_bumps_epoch_only_when_period_changes () public {
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .epoch, 0) ;

        _set (_rule (200, 2000, 1 days, 0, 0) ) ; // period unchanged
        assertEq (acct.ruleOf (NODE, TOKEN) .epoch, 0, "no bump") ;

        _set (_rule (200, 2000, 7 days, 0, 0) ) ; // period changed
        assertEq (acct.ruleOf (NODE, TOKEN) .epoch, 1, "bumped") ;
    }

    /// `period == 0` is an edge case that has to be handled: the `spent` key is
    /// `timestamp / period`, and dividing straight through would panic.
    /// The semantics are defined as "every spend accumulates into one bucket that never
    /// resets" — a lifetime allowance.
    function test_period_zero_is_a_lifetime_budget_not_a_panic () public {
        _set (_rule (100, 1000, 0, 0, 0) ) ;
        assertEq (acct.spentInCurrentPeriod (NODE, TOKEN) , 0, "no division by zero") ;

        // Push time far forward; the bucket is still the same one
        vm.warp (block.timestamp + 3650 days) ;
        assertEq (acct.spentInCurrentPeriod (NODE, TOKEN) , 0) ;
    }

    // --- events and payees ---

    /// `setRule` maps onto two frozen events, and which fires when must be stated.
    function test_setRule_emits_token_allowed_when_first_enabled () public {
        vm.expectEmit (true, true, false, false) ;
        emit LeashAccount.TokenAllowed (NODE, TOKEN, bytes32 (0) ) ;
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;
    }

    function test_payee_can_be_allowed_and_removed () public {
        vm.startPrank (wallet) ;
        acct.allowPayee (NODE, TOKEN, PAYEE, ++nonce, ATT) ;
        assertTrue (acct.isPayeeAllowed (NODE, TOKEN, PAYEE) ) ;

        acct.removePayee (NODE, TOKEN, PAYEE) ; // a reduction, no attestation
        assertFalse (acct.isPayeeAllowed (NODE, TOKEN, PAYEE) ) ;
        vm.stopPrank () ;
    }

    // --- both conditions required ---

    function test_expansion_needs_both_self_and_attestation () public {
        // not self
        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        vm.prank (address (0xBAD) ) ;
        acct.setRule (NODE, TOKEN, _rule (100, 0, 1 days, 0, 0) , 1, ATT) ;

        // self, but the attestation is a replay
        vm.startPrank (wallet) ;
        acct.setRule (NODE, TOKEN, _rule (100, 0, 1 days, 0, 0) , 99, ATT) ;
        vm.expectRevert () ;
        acct.setRule (NODE, TOKEN, _rule (100, 0, 1 days, 0, 0) , 99, ATT) ;
        vm.stopPrank () ;
    }

    /// A reduction needs **no** attestation, but is still the wallet's alone to do.
    function test_reduction_needs_self_but_no_attestation () public {
        _set (_rule (100, 1000, 1 days, 0, 0) ) ;

        vm.expectRevert (LeashAccount.NotSelf.selector) ;
        vm.prank (address (0xBAD) ) ;
        acct.tightenRule (NODE, TOKEN, _rule (50, 500, 1 days, 0, 0) ) ;

        vm.prank (wallet) ;
        acct.tightenRule (NODE, TOKEN, _rule (50, 500, 1 days, 0, 0) ) ;
        assertEq (acct.ruleOf (NODE, TOKEN) .txLimit, 50) ;
    }
}
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountRules -vv`
Expected: a compile failure, `Member "tightenRule" not found`

- [ ] **Step 3: implement — `_lteOrUnlimited` and `_windowIsSubset` are the crux**

```solidity
    bytes32 private constant RULE_TYPEHASH = keccak256 (
        "SetRule (address impl,bytes32 node,address token,bool allowed,uint256 txLimit,uint256 periodLimit,uint64 period,uint16 windowStart,uint16 windowEnd,uint256 nonce) "
    ) ;

    event TokenAllowed (bytes32 indexed node, address indexed token, bytes32 attestationHash) ;
    event LimitRaised (
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        uint64 period,
        bytes32 attestationHash
    ) ;
    event TokenRemoved (bytes32 indexed node, address indexed token, address indexed by) ;
    event LimitLowered (
        bytes32 indexed node,
        address indexed token,
        uint256 oldLimit,
        uint256 newLimit,
        address indexed by
    ) ;
    event PayeeAllowed (bytes32 indexed node, address indexed payee, bytes32 attestationHash) ;
    event PayeeRemoved (bytes32 indexed node, address indexed payee, address indexed by) ;

    error NotTighter () ;

    function ruleOf (bytes32 node, address token)
        external
        view
        returns (LeashStorage.TokenRule memory)
    {
        return LeashStorage.layout () .rules[node][token];
    }

    function isPayeeAllowed (bytes32 node, address token, address payee)
        external
        view
        returns (bool)
    {
        return LeashStorage.layout () .payees[node][token][payee];
    }

    function spentInCurrentPeriod (bytes32 node, address token) external view returns (uint256) {
        LeashStorage.TokenRule storage r = LeashStorage.layout () .rules[node][token];
        return LeashStorage.layout () .spent[node][token][_bucket (r) ];
    }

    /// @notice Sets a rule. **A widening — both conditions required.**
    /// @dev `epoch` increments automatically when `period` changes. **This is the only path
    ///      that can move `spent` to a different bucket**, and it requires an attestation —
    ///      so wiping the ledger always costs one.
    function setRule (
        bytes32 node,
        address token,
        LeashStorage.TokenRule calldata rule,
        uint256 nonce,
        bytes calldata attestation
    ) external onlySelf {
        _consumeAttestation (
            keccak256 (
                abi.encode (
                    RULE_TYPEHASH,
                    SELF,
                    node,
                    token,
                    rule.allowed,
                    rule.txLimit,
                    rule.periodLimit,
                    rule.period,
                    rule.windowStart,
                    rule.windowEnd,
                    nonce
                )
            ) ,
            attestation
        ) ;

        LeashStorage.TokenRule storage cur = LeashStorage.layout () .rules[node][token];
        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;
        uint32 epoch = cur.epoch;
        if (cur.period != rule.period) epoch += 1; // new period = a new ledger

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.period = rule.period;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        cur.epoch = epoch;

        bytes32 h = keccak256 (attestation) ;
        if (!wasAllowed && rule.allowed) emit TokenAllowed (node, token, h) ;
        emit LimitRaised (node, token, oldLimit, rule.periodLimit, rule.period, h) ;
    }

    /// @notice Tightens a rule. **A reduction — `address (this) ` only, no attestation.**
    /// @dev Requires that **every field is weakly monotonically tightened**. That turns
    ///      "stricter" into a checkable assertion, whereas a pair of raise/lower functions
    ///      would leave window and period uncovered — and precisely those omissions could
    ///      then be used to widen.
    function tightenRule (bytes32 node, address token, LeashStorage.TokenRule calldata rule)
        external
        onlySelf
    {
        LeashStorage.TokenRule storage cur = LeashStorage.layout () .rules[node][token];
        if (!_isTighter (cur, rule) ) revert NotTighter () ;

        bool wasAllowed = cur.allowed;
        uint256 oldLimit = cur.periodLimit;

        cur.allowed = rule.allowed;
        cur.txLimit = rule.txLimit;
        cur.periodLimit = rule.periodLimit;
        cur.windowStart = rule.windowStart;
        cur.windowEnd = rule.windowEnd;
        // `period` and `epoch` are deliberately left alone — see `_isTighter`

        if (wasAllowed && !rule.allowed) emit TokenRemoved (node, token, msg.sender) ;
        if (oldLimit != rule.periodLimit) {
            emit LimitLowered (node, token, oldLimit, rule.periodLimit, msg.sender) ;
        }
    }

    /// @notice Removes a payee. **A reduction, no attestation.**
    function removePayee (bytes32 node, address token, address payee) external onlySelf {
        LeashStorage.layout () .payees[node][token][payee] = false;
        emit PayeeRemoved (node, payee, msg.sender) ;
    }

    /// @dev The definition of **weakly monotonic tightening**. Each clause has its own
    ///      dedicated test.
    function _isTighter (LeashStorage.TokenRule storage old_, LeashStorage.TokenRule calldata new_)
        private
        view
        returns (bool)
    {
        if (old_.allowed && !new_.allowed) return true; // switching it off is always stricter
        if (!old_.allowed) return false; // already off; nothing stricter it could become
        // `period` and `epoch` must not move: changing `period` changes the bucket and
        // zeroes the running total — so "lower the cap" would actually increase what can be
        // spent. Wiping the ledger goes only through setRule, which needs an attestation.
        if (new_.period != old_.period || new_.epoch != old_.epoch) return false;
        return _lteOrUnlimited (new_.txLimit, old_.txLimit)
            && _lteOrUnlimited (new_.periodLimit, old_.periodLimit)
            && _windowIsSubset (new_.windowStart, new_.windowEnd, old_.windowStart, old_.windowEnd) ;
    }

    /// @dev `0 = unlimited`, so the comparison inverts:
    ///      `0 → 100` tightens (true) ; `100 → 0` widens (false) ; `100 → 50` tightens.
    ///      **This is the easiest line in the file to get backwards.**
    function _lteOrUnlimited (uint256 new_, uint256 old_) private pure returns (bool) {
        if (old_ == 0) return true; // was unlimited; no value (0 included) is wider
        if (new_ == 0) return false; // was finite, now unlimited = a widening
        return new_ <= old_;
    }

    /// @dev The new set of minutes must be a subset of the old one. Three cases:
    ///      - The old window is all day (`start == end`) → any new window tightens
    ///      - The new window is all day and the old one is not → a widening
    ///      - Both are bounded intervals → check the subset minute by minute
    ///
    ///      **The O (1440) loop is deliberate; no inequality juggling.** An inequality-based
    ///      overnight subset test is very easy to get backwards, and getting it backwards
    ///      **silently widens the rule**. Clear beats clever, and `tightenRule` runs a
    ///      handful of times a day at most.
    ///
    ///      ⚠️ The plan originally justified this with "it is a `view`, so gas does not
    ///      matter". That was wrong — `_windowIsSubset` is called from `tightenRule`, which
    ///      is external and state-changing, so the gas is really paid. Measured at about
    ///      480k gas worst case. The loop is still right; the reason is clarity.
    function _windowIsSubset (uint16 ns, uint16 ne, uint16 os, uint16 oe)
        private
        pure
        returns (bool)
    {
        if (os == oe) return true; // old window is all day
        if (ns == ne) return false; // new window is all day and the old one was not
        for (uint16 m = 0; m < 1440; ++m) {
            if (_inWindow (m, ns, ne) && !_inWindow (m, os, oe) ) return false;
        }
        return true;
    }

    /// @dev Same semantics as `StandardPolicy._inWindow`. `start > end` crosses midnight.
    function _inWindow (uint16 minuteOfDay, uint16 start, uint16 end)
        private
        pure
        returns (bool)
    {
        if (start == end) return true;
        if (start < end) return minuteOfDay >= start && minuteOfDay < end;
        return minuteOfDay >= start || minuteOfDay < end;
    }

    /// @dev The key into `spent`. `epoch` occupies the high bits and the period index the
    ///      low bits, so neither contaminates the other (`period` is at least 1 second, and
    ///      `timestamp / 1` is far below `2^224`) .
    ///      When `period == 0` every spend accumulates into one bucket = a lifetime
    ///      allowance that never resets.
    function _bucket (LeashStorage.TokenRule storage r) private view returns (uint256) {
        uint256 hi = uint256 (r.epoch) << 224;
        return r.period == 0 ? hi : hi | (block.timestamp / r.period) ;
    }
```

- [ ] **Step 4: run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountRules -vv`
Expected: 17 passed

- [ ] **Step 5: format and run the whole suite**

Run: `forge fmt && forge test`
Expected: 142 passed,0 failed

- [ ] **Step 6: Commit**

```bash
git add src/LeashAccount.sol test/LeashAccountRules.t.sol
git commit -m "feat: rules and payees - tightenRule turns 'stricter' into a checkable assertion

TokenRule has five tunable fields, and a pair of raise/lower functions
would leave window and period uncovered - and precisely those omissions
could then be used to widen. Replaced with a single entry point,
tightenRule, requiring every field to be weakly monotonically tightened.

The two places that silently widen the rules each get a dedicated test:
- 0 = unlimited inverts the comparison: 0->100 tightens, 100->0 widens. A
  plain <= gets both wrong
- Overnight window subsets: (21,7) -> (22,6) tightens, (22,6) -> (21,7)
  widens. An O (1440) loop rather than inequality juggling - getting it
  wrong silently widens

M5 properly fixed: spent is keyed on (epoch << 224 | periodIdx) , epoch
never decreases, and only setRule bumps it when period changes. So wiping
the ledger always costs an attestation, which the free tightenRule cannot
obtain. period == 0 is defined as a lifetime allowance that never resets."
```

---

## Task 5: three-hop ENS resolution — each hop returns a different length

**Files:**
- Modify: `src/LeashAccount.sol`
- Create: `test/mocks/MockRegistry.sol` (configurable return length and revert behaviour)
- Test: `test/LeashAccountSpend.t.sol` (created in this task, holding only the resolution tests)

**Interfaces:**
- Consumes: `ETH_REGISTRY`, `PARENT_LABEL`
- Produces:
  - `function resolvePolicy (bytes32 node, string memory label) public view returns (address) `
  - No `error` — failing to resolve returns `address (0) `, which `spend` turns into reason code 3

- [ ] **Step 1: write the failing tests**

```solidity
// test/mocks/MockRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Can be configured to return the wrong length and to revert — for exercising
///      fail-closed behaviour. ENS's contracts are still in their Immunefi audit window and
///      their behaviour may change; another contract breaking must not wedge the account.
contract MockRegistry {
    address public sub;
    address public res;
    bool public shouldRevert;
    uint256 public padBytes; // when >0, return extra bytes so the length is wrong

    function set (address sub_, address res_) external {
        sub = sub_;
        res = res_;
    }

    function setRevert (bool v) external {
        shouldRevert = v;
    }

    function setPad (uint256 n) external {
        padBytes = n;
    }

    function getSubregistry (string calldata) external view returns (address) {
        if (shouldRevert) revert ("boom") ;
        return sub;
    }

    function getResolver (string calldata) external view returns (address) {
        if (shouldRevert) revert ("boom") ;
        if (padBytes > 0) {
            // Return something other than 32 bytes — an arbitrary length in assembly
            assembly {
                let p := mload (0x40)
                mstore (p, 1)
                return (p, 8)
            }
        }
        return res;
    }
}

/// @dev Implements ENSIP-10 only, returning `bytes` (96 bytes of ABI encoding) .
contract MockResolver {
    address public policy;
    bool public shouldRevert;

    function set (address p) external {
        policy = p;
    }

    function setRevert (bool v) external {
        shouldRevert = v;
    }

    function resolve (bytes calldata, bytes calldata) external view returns (bytes memory) {
        if (shouldRevert) revert ("boom") ;
        return abi.encode (policy) ;
    }
}
```

```solidity
// test/LeashAccountSpend.t.sol - this task adds only the resolution tests
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { MockRegistry, MockResolver } from "./mocks/MockRegistry.sol";

contract YesApprovals is IPolicyApprovals {
    function isApproved (address) external pure returns (bool) {
        return true;
    }
}

contract LeashAccountSpendTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    MockRegistry ethRegistry;
    MockRegistry leashRegistry;
    MockResolver resolver;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant POLICY = address (0xB01C) ;
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    function setUp () public {
        ethRegistry = new MockRegistry () ;
        leashRegistry = new MockRegistry () ;
        resolver = new MockResolver () ;

        ethRegistry.set (address (leashRegistry) , address (0) ) ;
        leashRegistry.set (address (0) , address (resolver) ) ;
        resolver.set (POLICY) ;

        impl = new LeashAccount (address (ethRegistry) , new YesApprovals () , new MockAttester () ) ;
        wallet = vm.addr (walletPk) ;
        vm.signAndAttachDelegation (address (impl) , walletPk) ;
        acct = LeashAccount (payable (wallet) ) ;
    }

    /// The happy path: all three hops connect and a policy address comes out.
    function test_resolves_the_policy_through_three_hops () public view {
        assertEq (acct.resolvePolicy (NODE, LABEL) , POLICY) ;
    }

    /// Hop one returning 0 = the `leash.eth` subtree was taken back = **every agent halts
    /// at once**.
    function test_hop1_zero_is_the_kill_switch () public {
        ethRegistry.set (address (0) , address (0) ) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
    }

    /// Hop two returning 0 = the subname was revoked or expired = **that one agent dies**.
    function test_hop2_zero_kills_only_this_agent () public {
        leashRegistry.set (address (0) , address (0) ) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
    }

    /// Hop three returning 0 = the policy pointer was cleared = the swap-the-rules layer.
    function test_hop3_zero_means_no_policy () public {
        resolver.set (address (0) ) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
    }

    /// A revert on any hop must **fail closed** rather than take the whole transaction
    /// down. ENS's contracts are still in their audit window — another contract reverting
    /// must not wedge the account.
    function test_a_reverting_hop_fails_closed () public {
        ethRegistry.setRevert (true) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
        ethRegistry.setRevert (false) ;

        leashRegistry.setRevert (true) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
        leashRegistry.setRevert (false) ;

        resolver.setRevert (true) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
    }

    /// 🔴 **A wrong return length must fail closed too.**
    ///
    /// And note that each hop's expected length is **different**: hop1/hop2 are 32 (an
    /// address) , hop3 is **96** (`bytes` = offset 32 + length 32 + inner 32) .
    /// Check hop3 for `== 32` and the happy path never succeeds, while the reported reason
    /// says "ENS has no policy pointer" — sending you to debug entirely the wrong thing.
    function test_a_malformed_return_length_fails_closed () public {
        leashRegistry.setPad (1) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , address (0) ) ;
    }
}
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: a compile failure, `Member "resolvePolicy" not found`

- [ ] **Step 3: implement it**

```solidity
    /// @notice Resolves, from ENS, which policy this name must satisfy. Returns
    ///         `address (0) ` if it does not resolve.
    ///
    /// @dev **Three hops, and each returns a different number of bytes:**
    ///
    ///      | Hop | Call | Expected returndata |
    ///      |---|---|---|
    ///      | 1 | `ETH_REGISTRY.getSubregistry ("leash") ` | 32 |
    ///      | 2 | `LeashRegistry.getResolver (label) ` | 32 |
    ///      | 3 | `LeashResolver.resolve (dns, addr (node) ) ` | **96** |
    ///
    ///      Hop three returns `bytes`, whose ABI encoding is offset (32) + length (32) +
    ///      inner (32) . **Check it for `== 32` and the happy path never succeeds**, while
    ///      the reason code says `NO_POLICY` ("ENS has no policy pointer") — sending you to
    ///      debug entirely the wrong thing.
    ///
    ///      All three use low-level `staticcall` and each checks its own expected length:
    ///      ENS's contracts are still in their Immunefi audit window (through 09-14) , so
    ///      addresses may move and behaviour may change. Another contract reverting must not
    ///      wedge this account — failing to resolve is `NO_POLICY`, no money moves, and that
    ///      is the safe default.
    ///
    ///      This path is also the implementation of the three revocation layers: hop1
    ///      returning 0 = everything halts, hop2 returning 0 = this one agent dies (revoked
    ///      or `expiry` lapsed) , hop3 returning 0 = the swap-the-rules layer cleared the
    ///      pointer.
    function resolvePolicy (bytes32 node, string memory label) public view returns (address) {
        address reg = _staticAddress (
            ETH_REGISTRY, abi.encodeWithSignature ("getSubregistry (string) ", PARENT_LABEL)
        ) ;
        if (reg == address (0) ) return address (0) ;

        address res =
            _staticAddress (reg, abi.encodeWithSignature ("getResolver (string) ", label) ) ;
        if (res == address (0) ) return address (0) ;

        bytes memory inner = abi.encodeWithSignature ("addr (bytes32) ", node) ;
        bytes memory dnsName = _dnsEncode (label) ;
 (bool ok, bytes memory ret) = res.staticcall{ gas: HOP_GAS } (
            abi.encodeWithSignature ("resolve (bytes,bytes) ", dnsName, inner)
        ) ;
        // 96 = offset (32) + length (32) + inner (32)
        if (!ok || ret.length != 96) return address (0) ;
        bytes memory decoded = abi.decode (ret, (bytes) ) ;
        if (decoded.length != 32) return address (0) ;
        address policy = abi.decode (decoded, (address) ) ;
        // The policy must not be this account — the same authority-confusion problem; see
        // the BadTarget guards in `spend`
        if (policy == address (this) ) return address (0) ;
        return policy;
    }

    /// @dev The per-hop gas cap. Breakage on the ENS side must not drag us down with it.
    uint256 private constant HOP_GAS = 100_000;

    function _staticAddress (address target, bytes memory cd) private view returns (address) {
 (bool ok, bytes memory ret) = target.staticcall{ gas: HOP_GAS } (cd) ;
        if (!ok || ret.length != 32) return address (0) ;
        return abi.decode (ret, (address) ) ;
    }

    /// @dev DNS wire format:`<len><label>...<len>eth<0>`.
    ///      The parent is always `leash.eth`, so only the first segment varies.
    ///      Measured: `vendors.leash.eth` = `0x0776656e646f7273056c656173680365746800`
    function _dnsEncode (string memory label) private pure returns (bytes memory) {
        return abi.encodePacked (uint8 (bytes (label) .length) , label, hex"056c656173680365746800") ;
    }
```

- [ ] **Step 4: run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: 6 passed

- [ ] **Step 5: add a test for the DNS encoding (it is hardcoded, so it must be right) **

```solidity
    /// `_dnsEncode` uses a hardcoded `leash.eth` suffix. This test confirms what it
    /// assembles matches the measured value recorded in `docs/deployments.md` — get it wrong
    /// and the resolver receives a broken name.
    function test_dns_encoding_matches_the_measured_value () public view {
        // Verified indirectly through resolvePolicy: MockResolver ignores `name`, so this
        // swaps in a resolver that does check it
        NameCheckingResolver nc = new NameCheckingResolver (
            hex"0776656e646f7273056c656173680365746800", POLICY
        ) ;
        leashRegistry.set (address (0) , address (nc) ) ;
        assertEq (acct.resolvePolicy (NODE, LABEL) , POLICY, "dns name matched exactly") ;
    }
```

```solidity
// appended to test/mocks/MockRegistry.sol
/// @dev Returns the policy only when `name` matches exactly — for verifying the DNS encoding.
contract NameCheckingResolver {
    bytes public expected;
    address public policy;

    constructor (bytes memory expected_, address policy_) {
        expected = expected_;
        policy = policy_;
    }

    function resolve (bytes calldata name, bytes calldata) external view returns (bytes memory) {
        require (keccak256 (name) == keccak256 (expected) , "wrong dns name") ;
        return abi.encode (policy) ;
    }
}
```

- [ ] **Step 6: run the tests, format, run everything**

Run: `forge test --match-contract LeashAccountSpend -vv && forge fmt && forge test`
Expected: 7 passed; 149 passed overall

- [ ] **Step 7: Commit**

```bash
git add src/LeashAccount.sol test/mocks/MockRegistry.sol test/LeashAccountSpend.t.sol
git commit -m "feat: three-hop ENS resolution - each hop returns a different length

hop1/hop2 return 32 bytes (an address) ; hop3 returns **96** (a bytes
offset + length + inner word) . Measured on 09-08 with cast rpc eth_call
against the deployed contracts. Check hop3 for ==32 and the happy path
never succeeds, while the reason code says NO_POLICY (ENS has no policy
pointer) - which sends you to debug entirely the wrong thing and can burn
half a day.

All three hops use a low-level staticcall, each with its own gas cap and
its own expected length. ENS's contracts are still in their Immunefi
audit window, and another contract reverting must not wedge the account -
failing to resolve is NO_POLICY, no money moves, and that is the safe
default.

This path is also the implementation of the three revocation layers: hop1
returning 0 = everything halts, hop2 returning 0 = this one agent dies
 (revoked or expiry lapsed) , hop3 returning 0 = the pointer was cleared."
```

---

## Task 6: `spend () ` — stringing the four gates together

**Files:**
- Modify: `src/LeashAccount.sol`
- Modify: `src/IPolicy.sol` (add one interface-constraint comment)
- Create: `test/mocks/BadTokens.sol`
- Test: `test/LeashAccountSpend.t.sol` (appended to)

**Interfaces:**
- Consumes: task 3's binding and pausing, task 4's rules and `_bucket`, task 5's
  `resolvePolicy`.
  **`LeashAccount.sol` needs the import** `import { IPolicy, SpendContext } from "./IPolicy.sol";`
  — `SpendContext` is a top-level struct in `IPolicy.sol`, not a member of the interface.
- Produces:
  - `spend (address token, address payee, uint256 amount) external`
  - `error NotBoundAgent () ` (already exists) / `error Reentrant () ` / `error BadTarget () ` / `error ZeroAmount () ` / `error TransferFailed () `
  - The events `PolicyResolved` / `SpendExecuted` / `SpendBlocked`

- [ ] **Step 1: write the failing tests — start with the fake-success group, which is the most dangerous**

```solidity
// test/mocks/BadTokens.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev An ERC-20 that returns `false`. The account must revert rather than treat it as success.
contract FalseReturnToken {
    function transfer (address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev An old-style ERC-20 that returns nothing at all. The **strict** check must refuse it.
contract NoReturnToken {
    function transfer (address, uint256) external { }
}

/// @dev Calls `spend` again from inside `transfer` — exercising the reentrancy lock and the
///      ledger-before-transfer ordering.
contract ReenteringToken {
    address public target;
    bool public armed;

    function arm (address t) external {
        target = t;
        armed = true;
    }

    function transfer (address, uint256) external returns (bool) {
        if (armed) {
            armed = false;
 (bool ok,) = target.call (
                abi.encodeWithSignature ("spend (address,address,uint256) ", address (this) , msg.sender, 1)
            ) ;
            ok; // failure is expected
        }
        return true;
    }
}

/// @dev A policy that burns all the gas — exercising the `POLICY_GAS` cap and fail-closed.
contract GasBurningPolicy {
    function check (bytes calldata) external pure returns (uint8) {
        while (true) { }
        return 0;
    }

    function describe () external pure returns (string memory) {
        return "GasBurningPolicy";
    }
}

/// @dev A policy that returns the wrong length.
contract ShortReturnPolicy {
    function check (bytes calldata) external pure returns (bytes memory) {
        return hex"01";
    }

    function describe () external pure returns (string memory) {
        return "ShortReturnPolicy";
    }
}
```

```solidity
    // appended to test/LeashAccountSpend.t.sol

    // --- 🔴 C3 regression: fake success ---

    /// **`token` and `payee` are chosen by the agent, and could be `address (this) `.**
    ///
    /// When step 11's `token.transfer (...) ` goes out, `msg.sender == address (this) ` —
    /// exactly the authority `bindAgent` / `tightenRule` / `removePayee` accept.
    /// And with SafeERC20's permissive return check:
    ///   - `token == address (this) ` → hits our own fallback
    ///   - `token == address (0) ` → a call to an empty address always succeeds, returning
    ///     empty returndata
    /// Both cases mean **`spent` increases and `SpendExecuted` is emitted while not a cent
    /// moved.** The subgraph would record a payment that never happened.
    function test_rejects_targets_that_point_back_at_the_account () public {
        _bindAndAllow () ;
        vm.startPrank (AGENT) ;

        vm.expectRevert (LeashAccount.BadTarget.selector) ;
        acct.spend (wallet, PAYEE, 1) ;

        vm.expectRevert (LeashAccount.BadTarget.selector) ;
        acct.spend (address (token) , wallet, 1) ;

        vm.expectRevert (LeashAccount.BadTarget.selector) ;
        acct.spend (address (0) , PAYEE, 1) ;

        vm.expectRevert (LeashAccount.BadTarget.selector) ;
        acct.spend (address (token) , address (0) , 1) ;

        vm.stopPrank () ;
    }

    /// An address with no code cannot be a token.
    function test_rejects_a_token_with_no_code () public {
        _bindAndAllow () ;
        vm.expectRevert (LeashAccount.BadTarget.selector) ;
        vm.prank (AGENT) ;
        acct.spend (address (0xC0DE1E55) , PAYEE, 1) ;
    }

    /// **The return check is strict: exactly 32 bytes that decode to `true`.**
    /// Not SafeERC20's permissive variant — we only need to support the tokens our own demo
    /// uses, and the compatibility permissiveness buys is paid for here with a fake success.
    function test_rejects_tokens_that_do_not_return_true () public {
        _bindAndAllow () ;
        FalseReturnToken f = new FalseReturnToken () ;
        NoReturnToken n = new NoReturnToken () ;

        vm.startPrank (wallet) ;
        acct.setRule (NODE, address (f) , _openRule () , ++nonce, ATT) ;
        acct.allowPayee (NODE, address (f) , PAYEE, ++nonce, ATT) ;
        acct.setRule (NODE, address (n) , _openRule () , ++nonce, ATT) ;
        acct.allowPayee (NODE, address (n) , PAYEE, ++nonce, ATT) ;
        vm.stopPrank () ;

        vm.expectRevert (LeashAccount.TransferFailed.selector) ;
        vm.prank (AGENT) ;
        acct.spend (address (f) , PAYEE, 1) ;

        vm.expectRevert (LeashAccount.TransferFailed.selector) ;
        vm.prank (AGENT) ;
        acct.spend (address (n) , PAYEE, 1) ;
    }

    function test_zero_amount_reverts () public {
        _bindAndAllow () ;
        vm.expectRevert (LeashAccount.ZeroAmount.selector) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 0) ;
    }

    // --- 🔴 reentrancy ---

    /// The reentrancy lock is the first line of defence and **writing the ledger first is
    /// the second** — it takes both failing to cause harm.
    function test_reentrancy_is_blocked_and_the_ledger_is_already_updated () public {
        ReenteringToken rt = new ReenteringToken () ;
        vm.startPrank (wallet) ;
        acct.setRule (NODE, address (rt) , _openRule () , ++nonce, ATT) ;
        acct.allowPayee (NODE, address (rt) , PAYEE, ++nonce, ATT) ;
        acct.bindAgent (AGENT, NODE, LABEL) ;
        vm.stopPrank () ;

        rt.arm (wallet) ;
        vm.prank (AGENT) ;
        acct.spend (address (rt) , PAYEE, 100) ;

        // Booked once only — the inner spend was blocked by the lock
        assertEq (acct.spentInCurrentPeriod (NODE, address (rt) ) , 100) ;
    }

    // --- 🔴 full reason-code coverage: each needs an event AND an unchanged balance ---

    function test_blocked_paths_emit_and_do_not_move_money () public {
        _bindAndAllow () ;
        uint256 before = token.balanceOf (wallet) ;

        // 10 PAUSED
        vm.prank (wallet) ;
        acct.pause () ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "paused: no movement") ;
        vm.prank (wallet) ;
        acct.unpause () ;

        // 3 NO_POLICY
        resolver.set (address (0) ) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "no policy: no movement") ;
        resolver.set (POLICY) ;

        // 2 AGENT_REVOKED — **does not revert**; it must leave an indexable record
        vm.prank (wallet) ;
        acct.revokeAgent (AGENT) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "revoked: no movement") ;
    }

    /// **2a not bound → revert; 2b revoked → no revert.**
    /// The frozen document confines the revert exception to "the caller is **not** a bound
    /// agent at all", and a revoked agent *is* bound — revocation is an administrative act,
    /// and that agent should be able to look up why it is stuck (logs from a reverted call
    /// are discarded) .
    function test_unbound_reverts_but_revoked_does_not () public {
        _bindAndAllow () ;

        vm.expectRevert (LeashAccount.NotBoundAgent.selector) ;
        vm.prank (address (0xN07) ) ;
        acct.spend (address (token) , PAYEE, 1) ;

        vm.prank (wallet) ;
        acct.revokeAgent (AGENT) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ; // does not revert
    }

    /// 🔴 M8 regression: `PolicyResolved.approved` must carry the **real value**.
    /// The first version emitted the event after the approval check, where it could only
    /// ever be `true` — leaving that field in the frozen schema permanently dead. And "the
    /// pointer aims at an unapproved policy" is exactly the one onchain signal that the
    /// ADMIN key has been stolen.
    function test_policy_resolved_carries_the_real_approval_flag () public {
        _bindAndAllow () ;
        LeashAccount implNo =
            new LeashAccount (address (ethRegistry) , new NoApprovals2 () , new MockAttester () ) ;
        vm.signAndAttachDelegation (address (implNo) , walletPk) ;

        vm.expectEmit (true, true, false, true) ;
        emit LeashAccount.PolicyResolved (NODE, POLICY, false) ;
        vm.prank (AGENT) ;
        LeashAccount (payable (wallet) ) .spend (address (token) , PAYEE, 1) ;
    }

    /// The three ways to trigger 12 POLICY_FAILED.
    function test_policy_failure_modes_all_fail_closed () public {
        _bindAndAllow () ;
        uint256 before = token.balanceOf (wallet) ;

        resolver.set (address (new GasBurningPolicy () ) ) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "gas burner: no movement") ;

        resolver.set (address (new ShortReturnPolicy () ) ) ;
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "short return: no movement") ;

        resolver.set (address (0xDEAD) ) ; // no code
        vm.prank (AGENT) ;
        acct.spend (address (token) , PAYEE, 1) ;
        assertEq (token.balanceOf (wallet) , before, "no code: no movement") ;
    }

    // --- 🔴 C4 regression: the WALLET key is unconstrained, and that is the escape hatch ---

    /// **This test pins the boundary as a specification.**
    /// EIP-7702 constrains only calls to that EOA; the WALLET key can still sign
    /// `USDC.transfer` directly, and the policy path never executes.
    /// Saying "the only spending path" collapses under the first question a judge asks —
    /// the accurate claim is "**the agent's** only spending path", and the wallet being
    /// unconstrained is both the boundary and the escape hatch: the owner can always
    /// retrieve their own funds and can never be locked out by a policy they installed.
    function test_the_wallet_key_can_always_transfer_directly () public {
        _bindAndAllow () ;
        uint256 before = token.balanceOf (PAYEE) ;

        vm.recordLogs () ;
        vm.prank (wallet) ;
        token.transfer (PAYEE, 500) ; // never went through spend ()

        assertEq (token.balanceOf (PAYEE) - before, 500, "the money moved") ;
        // and no SpendExecuted was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs () ;
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue (
                logs[i].topics[0] != LeashAccount.SpendExecuted.selector,
                "no SpendExecuted for a direct transfer"
            ) ;
        }
    }
```

- [ ] **Step 2: run the tests and confirm they fail**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: a compile failure, `Member "spend" not found`

- [ ] **Step 3: implement `spend`**

```solidity
    event PolicyResolved (bytes32 indexed node, address indexed policy, bool approved) ;
    event SpendExecuted (
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        address policy,
        uint256 spentAfter,
        uint256 limit,
        uint64 periodEnd
    ) ;
    event SpendBlocked (
        bytes32 node,
        address indexed agent,
        address indexed payee,
        address indexed token,
        uint256 amount,
        uint8 reason,
        address policy,
        uint256 spentSoFar,
        uint256 limit
    ) ;

    error Reentrant () ;
    error BadTarget () ;
    error ZeroAmount () ;
    error TransferFailed () ;

    /// @notice **The agent's only spending path.**
    ///
    /// @dev `node` and `label` are not supplied by the caller; they are read from
    ///      `bindings[msg.sender]` — which eliminates an entire class of "node and label
    ///      disagree" validation.
    ///
    ///      **Blocked ≠ revert.** A policy violation means: no transfer, emit
    ///      `SpendBlocked`, return normally — because the subgraph has to be able to index
    ///      *why* it was blocked. Only **2a (the caller is not a bound agent at all) **
    ///      reverts; that is not a policy decision, it is an intrusion.
    function spend (address token, address payee, uint256 amount) external {
        LeashStorage.AccountStorage storage $ = LeashStorage.layout () ;

        // 1. The reentrancy lock
        if ($.entered) revert Reentrant () ;
        $.entered = true;

        // 2a. Is it bound? If not, revert
        LeashStorage.AgentBinding storage b = $.bindings[msg.sender];
        if (b.node == bytes32 (0) ) revert NotBoundAgent () ;
        bytes32 node = b.node;

        // Guards: token / payee must not point back at this account or at 0, and token
        // must have code. Placed after authorisation and before policy — these are
        // malformed inputs, not policy violations.
        if (amount == 0) revert ZeroAmount () ;
        if (token == address (this) || payee == address (this) ) revert BadTarget () ;
        if (token == address (0) || payee == address (0) ) revert BadTarget () ;
        if (token.code.length == 0) revert BadTarget () ;

        // 2b. Revoked? **Do not revert** — emit an indexable event
        if (b.revoked) {
            _blocked ($, node, payee, token, amount, Reason.AGENT_REVOKED, address (0) ) ;
            return;
        }

        // 3. Paused
        if ($.paused) {
            _blocked ($, node, payee, token, amount, Reason.PAUSED, address (0) ) ;
            return;
        }

        // 4. The three ENS hops
        address policy = resolvePolicy (node, b.label) ;
        if (policy == address (0) ) {
            _blocked ($, node, payee, token, amount, Reason.NO_POLICY, address (0) ) ;
            return;
        }

        // 5. The approval list — **the event is emitted here, carrying the real value**
        bool approved = APPROVALS.isApproved (policy) ;
        emit PolicyResolved (node, policy, approved) ;
        if (!approved) {
            _blocked ($, node, payee, token, amount, Reason.POLICY_NOT_APPROVED, policy) ;
            return;
        }

        // 6-7. Build the SpendContext
        LeashStorage.TokenRule storage r = $.rules[node][token];
        uint256 bucket = _bucket (r) ;
        uint256 spentSoFar = $.spent[node][token][bucket];

        SpendContext memory ctx = SpendContext ({
            agent: msg.sender,
            payee: payee,
            token: token,
            amount: amount,
            tokenAllowed: r.allowed,
            payeeAllowed: $.payees[node][token][payee],
            txLimit: r.txLimit,
            periodLimit: r.periodLimit,
            spentSoFar: spentSoFar,
            nowTs: uint64 (block.timestamp) ,
            windowStart: r.windowStart,
            windowEnd: r.windowEnd
        }) ;

        // 8. Call the policy: capped gas, checked return length, fail closed
        uint8 reason = _askPolicy (policy, ctx) ;

        // 9. Blocked
        if (reason != Reason.OK) {
            $.entered = false;
            emit SpendBlocked (
                node, msg.sender, payee, token, amount, reason, policy, spentSoFar, r.periodLimit
            ) ;
            return;
        }

        // 10. **Write the ledger first** — before the external call. The reentrancy lock
        //     is the first line of defence and this is the second.
        uint256 spentAfter = spentSoFar + amount;
        $.spent[node][token][bucket] = spentAfter;

        // 11. The transfer. **Strict: exactly 32 bytes, and it must be true.**
 (bool ok, bytes memory ret) =
            token.call (abi.encodeWithSignature ("transfer (address,uint256) ", payee, amount) ) ;
        if (!ok || ret.length != 32 || !abi.decode (ret, (bool) ) ) revert TransferFailed () ;

        // 12. Events
        uint64 periodEnd = r.period == 0
            ? 0
            : uint64 ( ( (block.timestamp / r.period) + 1) * r.period) ;
        emit SpendExecuted (
            node, msg.sender, payee, token, amount, policy, spentAfter, r.periodLimit, periodEnd
        ) ;

        // 13. Unlock
        $.entered = false;
    }

    /// @dev Calls the policy under a gas cap, treating any anomaly as reason code 12.
    ///      **A policy that can burn all the gas is a DoS switch**, so the cap is deliberate.
    function _askPolicy (address policy, SpendContext memory ctx) private returns (uint8) {
 (bool ok, bytes memory ret) =
            policy.call{ gas: POLICY_GAS } (abi.encodeCall (IPolicy.check, (ctx) ) ) ;
        if (!ok || ret.length != 32) return Reason.POLICY_FAILED;
        uint256 raw = abi.decode (ret, (uint256) ) ;
        if (raw > type (uint8) .max) return Reason.POLICY_FAILED;
        return uint8 (raw) ;
    }

    function _blocked (
        LeashStorage.AccountStorage storage $,
        bytes32 node,
        address payee,
        address token,
        uint256 amount,
        uint8 reason,
        address policy
    ) private {
        $.entered = false;
        LeashStorage.TokenRule storage r = $.rules[node][token];
        emit SpendBlocked (
            node,
            msg.sender,
            payee,
            token,
            amount,
            reason,
            policy,
            $.spent[node][token][_bucket (r) ],
            r.periodLimit
        ) ;
    }
```

- [ ] **Step 4: add the `IPolicy` interface constraint**

```solidity
    // appended to the `check` comments in src/IPolicy.sol
    ///
    ///      🔴 **A policy may only write to its ledger when it returns `Reason.OK`.**
    ///
    ///      Because the account **does not revert** when it blocks: if a policy debits the
    ///      shared budget and *then* returns "over limit", that debit is never rolled back
    ///      and the shared budget leaks. The way `SharedBudgetPolicy` is written happens to
    ///      be correct (check first, then accumulate) , but that was an accident rather than
    ///      a requirement. **It is a requirement now.**
```

- [ ] **Step 5: run the tests and confirm they pass**

Run: `forge test --match-contract LeashAccountSpend -vv`
Expected: all passed

- [ ] **Step 6: format and run the whole suite**

Run: `forge fmt && forge test`
Expected: all green

- [ ] **Step 7: Commit**

```bash
git add src/LeashAccount.sol src/IPolicy.sol test/mocks/BadTokens.sol test/LeashAccountSpend.t.sol
git commit -m "feat: spend () - stringing the four gates together

The flow: reentrancy lock -> 2a bound (revert if not) -> format guards ->
2b revoked (emit an event, do not revert) -> paused -> the three ENS hops
-> the approval list (the event carries the real value) -> build ctx ->
ask the policy under a gas cap -> write the ledger -> transfer -> events.

Three orderings that matter:
- 2a reverts while 2b does not: the frozen document confines the revert
  exception to 'not a bound agent at all', and a revoked agent is bound -
  it deserves to be able to look up why it is stuck
- Ledger before transfer: the reentrancy lock is the first line of
  defence and this is the second; it takes both failing to cause harm
- PolicyResolved is emitted at the approval check, carrying the real
  value. After the check that field could only ever be true, and 'the
  pointer aims at an unapproved policy' is exactly the one onchain signal
  that the ADMIN key has been stolen

C3 guards: token/payee must not be address (this) or address (0) , token
must have code, and the return value is checked strictly for exactly 32
bytes of true - a permissive check produces 'reported success,
transferred nothing' and the subgraph records a payment that never
happened.

C4's boundary written as a test: a WALLET-signed transfer succeeds and
emits no SpendExecuted."
```

---

## Task 7: fork tests and deployment

**Files:**
- Test: `test/LeashAccountFork.t.sol`
- Create: `script/DeployAccount.s.sol`
- Modify: `docs/deployments.md`

- [ ] **Step 1: write the fork tests**

Against real Sepolia, using the address set from 09-08 16:34 in `docs/deployments.md`.
**The happy path must be verified at this layer** — every test before this one uses a mock
registry, and only this layer shows that our assumptions about the real ENSv2 hold.

```solidity
// test/LeashAccountFork.t.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

/// @dev Requires `SEPOLIA_RPC`. Skipped without it (CI may have no RPC) .
contract LeashAccountForkTest is Test {
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;
    address constant STANDARD_POLICY = 0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b;
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    LeashAccount impl;

    function setUp () public {
        string memory rpc = vm.envOr ("SEPOLIA_RPC", string ("") ) ;
        if (bytes (rpc) .length == 0) return;
        vm.createSelectFork (rpc) ;
        impl = new LeashAccount (
            ETH_REGISTRY, IPolicyApprovals (APPROVALS) , IAttester (ATTESTER)
        ) ;
    }

    /// **This test is the proof of the entire ENS claim.**
    /// Three hops against the real ENSv2, resolving a real policy address.
    function test_resolves_the_real_policy_on_sepolia () public {
        if (address (impl) == address (0) ) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation (address (impl) , pk) ;
        LeashAccount acct = LeashAccount (payable (vm.addr (pk) ) ) ;
        assertEq (acct.resolvePolicy (NODE, "vendors") , STANDARD_POLICY) ;
    }

    /// That policy really is on the approval list.
    function test_the_real_policy_is_approved () public view {
        if (address (impl) == address (0) ) return;
        assertTrue (IPolicyApprovals (APPROVALS) .isApproved (STANDARD_POLICY) ) ;
    }

    /// **Remove ENS and nothing passes.** `vm.mockCall` makes hop one return 0 —
    /// equivalent to `ETHRegistry.setSubregistry (leash.eth, 0x0) `, the kill-everything lever.
    function test_removing_the_ens_subtree_stops_resolution () public {
        if (address (impl) == address (0) ) return;
        uint256 pk = 0x8A11E7;
        vm.signAndAttachDelegation (address (impl) , pk) ;
        LeashAccount acct = LeashAccount (payable (vm.addr (pk) ) ) ;

        vm.mockCall (
            ETH_REGISTRY,
            abi.encodeWithSignature ("getSubregistry (string) ", "leash") ,
            abi.encode (address (0) )
        ) ;
        assertEq (acct.resolvePolicy (NODE, "vendors") , address (0) , "no ENS, no policy") ;
    }
}
```

- [ ] **Step 2: run the fork tests**

Run: `set -a && . /home/ubuntu/DEV/ETHOnline2026/.env && set +a && forge test --match-contract Fork -vv`
Expected: 3 passed

- [ ] **Step 3: write the deploy script**

`script/DeployAccount.s.sol`: deploy the `LeashAccount` impl and `LeashLens`, broadcasting
with `ADMIN_PK`, and print the addresses. **Delegating WALLET is a separate transaction**
 (it needs `WALLET_PK` to sign an authorization) ; send it by hand with `cast send --auth`
rather than putting it in the script — that key has no business in a deployment flow.

```solidity
// script/DeployAccount.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashLens } from "../src/LeashLens.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";

contract DeployAccount is Script {
    uint256 constant SEPOLIA = 11155111;
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;
    address constant APPROVALS = 0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4;
    address constant ATTESTER = 0x268990a91B0727E80d38d5ED4Ab10d8889754124;

    function run () external {
        require (block.chainid == SEPOLIA, "wrong chain - Sepolia only") ;
        uint256 pk = vm.envUint ("ADMIN_PK") ;

        vm.startBroadcast (pk) ;
        LeashAccount impl =
            new LeashAccount (ETH_REGISTRY, IPolicyApprovals (APPROVALS) , IAttester (ATTESTER) ) ;
        LeashLens lens = new LeashLens () ;
        vm.stopBroadcast () ;

        console.log ("LeashAccount impl", address (impl) ) ;
        console.log ("LeashLens        ", address (lens) ) ;
        console.log ("") ;
        console.log ("Next (WALLET_PK signs its own delegation - do NOT put it in a script) :") ;
        console.log ("  cast send $WALLET_ADDR --auth <impl> --private-key $WALLET_PK ...") ;
    }
}
```

- [ ] **Step 4: simulate the deployment**

Run: `set -a && . /home/ubuntu/DEV/ETHOnline2026/.env && set +a && forge script script/DeployAccount.s.sol:DeployAccount --rpc-url "$SEPOLIA_RPC"`
Expected: `SIMULATION COMPLETE`, with no revert

- [ ] **Step 5: deploy for real (**requires explicit human authorisation** — this changes onchain state) **

Run: add `--broadcast --slow`
Expected: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`

- [ ] **Step 6: delegate WALLET and run one real spend**

```bash
# 1. delegate (WALLET signs its own authorization)
cast send $WALLET_ADDR --auth $IMPL --private-key $WALLET_PK --rpc-url $R
# 2. confirm the leash is on
cast call $LENS 'delegateOf (address) (bool,address) ' $WALLET_ADDR --rpc-url $R
# 3. bind the agent (WALLET sends a transaction to itself)
cast send $WALLET_ADDR 'bindAgent (address,bytes32,string) ' $AGENT_ADDR $NODE vendors \
  --private-key $WALLET_PK --rpc-url $R
```

- [ ] **Step 7: update `docs/deployments.md` with the impl and lens addresses and transactions**

- [ ] **Step 8: commit**

```bash
git add test/LeashAccountFork.t.sol script/DeployAccount.s.sol docs/deployments.md
git commit -m "feat: LeashAccount fork tests and deployment

The fork tests run against real Sepolia and are the proof of the entire
ENS claim - every test before this one uses a mock registry, and only
this layer verifies our assumptions about the real ENSv2.

That includes 'remove ENS and nothing passes': vm.mockCall makes hop one
return 0, equivalent to the kill-everything lever.

The deploy script deliberately contains no WALLET_PK. Delegation requires
WALLET to sign its own authorization, and that key has no business in a
deployment flow - send it by hand with cast send --auth."
```

---

## Self-review

**Spec coverage** — section by section:

| Spec section | Implemented by task |
|---|---|
| Architecture / one impl, zero instance state | 2 |
| Storage: ERC-7201 | 1 |
| The spending flow (13 steps) | 6 |
| Splitting 2a from 2b | 6 |
| `PolicyResolved` carrying the real value | 6 |
| Ledger before transfer | 6 |
| The period index / `period == 0` / epoch | 4 |
| The three ENS hops and their per-hop lengths | 5 |
| `bindAgent` checking the namehash | 3 |
| `receive () ` / `fallback () ` | 2 |
| The authority table (two-of-two) | 2 (`onlySelf`) , 3 (binding/pausing) , 4 (rules) |
| `tightenRule` / `_windowIsSubset` | 4 |
| `Unpaused` sending `bytes32 (0) ` / the `setRule` event mapping | 3, 4 |
| The attestation digest including `SELF` | 2 |
| Reason code 12 | 6 (`Reason.sol` was updated 09-08) |
| The `IPolicy` interface constraint | 6 |
| `AttesterGate` not existing | recorded in `events.md` (09-08) |
| The subgraph having nothing to listen to | **not in this plan** — sprint item 9; recorded in the spec |
| `LeashLens` | 1 |
| The error-handling table | 5 (resolution) , 6 (everything else) |
| The test plan | the test steps of each task |
| The YAGNI table | not built at any point |

**The one gap is what the subgraph listens to**, which belongs to sprint item 9; the spec
already records two fixes (hardcode the demo wallet address, or emit `Leashed` on the first
`bindAgent`) . **Task 3's `bindAgent` should emit `Leashed` while it is there** — added to
task 3's implementation.

**Placeholder scan:** no `TBD`, no `TODO`, no "add appropriate error handling", no "similar
to task N". Every code step has actual code.

**A type-consistency check found three things to fix:**
1. Task 2's placeholder `setRule` was missing the `epoch` field's position in `TokenRule` —
   task 1 defines 7 fields and task 2's test `LeashStorage.TokenRule (true, 0, 0, 0, 0, 0, 0) `
   passes 7, so they are consistent ✅
2. Task 6 uses `SpendContext`, which comes from `src/IPolicy.sol` — it needs
   `import { IPolicy, SpendContext }`. **Add that import to task 6.**
3. Task 3's `bindAgent` must emit `Leashed (node, wallet, impl) ` (see the gap above) .
   The event signature is
   `event Leashed (bytes32 indexed node, address indexed wallet, address impl) `, emitted on the
   **first** bind (the `b.node == 0` branch) , with the arguments ` (node, address (this) , SELF) `.
