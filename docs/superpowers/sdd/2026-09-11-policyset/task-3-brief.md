### Task 3: The demo composition, its gas, and the third intent

**Files:**
- Create: `test/PolicySetDemo.t.sol`
- Modify: `agent/intents.json`

**Interfaces:**
- Consumes: `PolicySet` and `MicroPaymentPolicy` from Tasks 1-2, plus the deployed `StandardPolicy`
- Produces: nothing further tasks rely on

- [ ] **Step 1: Write the failing test**

Create `test/PolicySetDemo.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PolicySet } from "../src/PolicySet.sol";
import { MicroPaymentPolicy } from "../src/MicroPaymentPolicy.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { IPolicy, SpendContext } from "../src/IPolicy.sol";
import { Reason } from "../src/Reason.sol";

/// The composition the demo actually runs, pinned so that a change to any of the three
/// contracts that would alter what a judge sees on screen fails here first.
contract PolicySetDemoTest is Test {
    PolicySet set;

    address constant BEEF = address(0xBEEF); // allow-listed
    address constant CAFE = address(0xCAFE0); // not allow-listed, 5 USDC
    address constant FOOD = address(0xF00D); // not allow-listed, 0.50 USDC
    address constant USDC = address(0x768F);

    uint256 constant CAP = 1e6; // 1 USDC
    uint256 constant PERIOD_LIMIT = 50e6; // 50 USDC, as tightened on chain 2026-09-11
    uint256 constant SPENT = 5e6; // 5 USDC already spent this period

    /// `LeashAccount.POLICY_GAS` — the ceiling the account puts on this whole call.
    uint256 constant POLICY_GAS = 200_000;

    function setUp() public {
        address[][] memory clauses = new address[][](2);
        address[] memory micro = new address[](1);
        micro[0] = address(new MicroPaymentPolicy(CAP));
        address[] memory standard = new address[](1);
        standard[0] = address(new StandardPolicy());
        clauses[0] = micro;
        clauses[1] = standard;
        set = new PolicySet(clauses);
    }

    function _intent(address payee, uint256 amount, bool payeeAllowed)
        internal pure returns (SpendContext memory c)
    {
        c = SpendContext({
            agent: address(0xA6E17),
            payee: payee,
            token: USDC,
            amount: amount,
            tokenAllowed: true,
            payeeAllowed: payeeAllowed,
            txLimit: 500e6,
            periodLimit: PERIOD_LIMIT,
            spentSoFar: SPENT,
            nowTs: 1_757_000_000,
            windowStart: 0,
            windowEnd: 0
        });
    }

    /// Over the micro cap, so clause 1 fails; allow-listed, so clause 2 carries it.
    function test_retainer_passes_through_the_standard_clause() public view {
        assertEq(set.check(_intent(BEEF, 5e6, true)), Reason.OK);
    }

    /// Over the cap AND not allow-listed. The reported reason must be 6, because that is
    /// what the demo page's widen button keys on — reporting clause 1's 7 would leave the
    /// button disabled and the face-scan beat dead.
    function test_newvendor_is_blocked_with_exactly_reason_6() public view {
        assertEq(set.check(_intent(CAFE, 5e6, false)), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The whole argument for OR: same unknown payee situation, allowed because it is small.
    function test_apitopup_passes_through_the_micro_clause_with_no_human() public view {
        assertEq(set.check(_intent(FOOD, 5e5, false)), Reason.OK);
    }

    /// Two payments to strangers, one refused and one allowed, and the only difference is
    /// the size. If this ever stops holding, the demo has lost its point.
    function test_the_only_difference_between_the_two_strangers_is_the_amount() public view {
        SpendContext memory big = _intent(CAFE, 5e6, false);
        SpendContext memory small = _intent(CAFE, 5e5, false); // same payee, smaller
        assertEq(set.check(big), Reason.PAYEE_NOT_ALLOWED);
        assertEq(set.check(small), Reason.OK);
    }

    /// The exception must not be able to swallow the rule.
    function test_a_micro_payment_over_the_period_budget_is_still_refused() public view {
        SpendContext memory c = _intent(FOOD, 5e5, false);
        c.spentSoFar = PERIOD_LIMIT; // nothing left
        // clause 1 fails on the budget, clause 2 fails on the payee — last clause reported
        assertEq(set.check(c), Reason.PAYEE_NOT_ALLOWED);
    }

    /// The account gives this call 200,000 gas and treats anything else as reason 12. Two
    /// members plus the loop must fit, with room to spare.
    function test_it_fits_inside_the_account_s_gas_cap() public view {
        SpendContext memory c = _intent(CAFE, 5e6, false);
        uint256 before = gasleft();
        set.check(c);
        uint256 used = before - gasleft();
        emit log_named_uint("PolicySet.check gas (worst case: both clauses evaluated)", used);
        assertLt(used, POLICY_GAS, "over the account's cap");
        assertLt(used, POLICY_GAS / 2, "less than half the cap, so there is headroom");
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /home/ubuntu/DEV/leash && forge test --match-contract PolicySetDemoTest`
Expected: FAIL at compile if Tasks 1-2 are not committed; otherwise all six run. If `test_it_fits_inside_the_account_s_gas_cap` fails, **stop and report the measured number** — the plan's `MEMBER_GAS = 60_000` may need lowering, and that is a finding for the controller, not something to adjust silently.

- [ ] **Step 3: Run the whole suite**

Run: `cd /home/ubuntu/DEV/leash && forge test`
Expected: PASS — 201 tests before this plan, plus 12 (Task 1) + 15 (Task 2) + 6 (Task 3) = **234 passing, 0 failed, 1 skipped**. Report the actual numbers; do not adjust a test to reach them.

- [ ] **Step 4: Add the third intent**

Edit `agent/intents.json` to exactly this, appending the third entry and leaving the first two untouched:

```json
[
  {
    "id": "retainer",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x000000000000000000000000000000000000beef",
    "amount": "5000000",
    "note": "monthly retainer, already allow-listed"
  },
  {
    "id": "newvendor",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x00000000000000000000000000000000000cafe0",
    "amount": "5000000",
    "note": "a vendor the policy has never seen"
  },
  {
    "id": "apitopup",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x000000000000000000000000000000000000f00d",
    "amount": "500000",
    "note": "50 cents, under the micro cap"
  }
]
```

The payee is `0x` plus exactly 40 hex digits — 36 zeros then `f00d`. `validateIntents` refuses to start on a malformed address, and its error names the field rather than the character count, so a miscount here reads as a confusing startup failure rather than an obvious typo. Step 5 checks it before anything else runs.

- [ ] **Step 5: Verify the agent accepts it**

```bash
cd /home/ubuntu/DEV/leash/agent
node --input-type=module -e '
import { validateIntents } from "./loop.mjs";
import { readFile } from "node:fs/promises";
const intents = JSON.parse(await readFile("./intents.json", "utf8"));
const errors = validateIntents(intents);
console.log(errors.length ? errors : `ok — ${intents.length} intents`);
'
node --test
```

Expected: `ok — 3 intents`, then 78 passing.

**Do not start `agent/loop.mjs`.** It has no read-only mode: a tick reads, decides and SENDS, and it would pay the retainer. That has already cost 5 test USDC twice on this project.

- [ ] **Step 6: Commit**

```bash
cd /home/ubuntu/DEV/leash
git add test/PolicySetDemo.t.sol agent/intents.json
git commit -m "test: pin the demo composition, and add the intent that only OR allows"
```

---

## Self-Review

**1. Spec coverage.**

| Spec requirement | Task |
|---|---|
| DNF: AND in a clause, OR between | 2 (`test_a_clause_of_two_passes_only_when_both_pass`, `test_a_later_clause_rescues_an_earlier_failure`) |
| `check` declared `view` | 1, 2 (both signatures) |
| Members reached by `staticcall` | 2 (`test_a_member_that_writes_storage_cannot_be_a_member`) |
| Member list fixed at construction, no setter | 2 (contract has no setter; `test_the_shape_is_readable` reads it) |
| Any member anomaly → 12, no fall-through | 2 (five tests: revert, wrong length, 256, no code, gas burn) |
| Last clause's reason when nothing passes | 2 (`test_when_nothing_passes_the_last_clauses_reason_is_reported`, both orders) |
| First failing member within a clause | 2 (`test_a_clause_reports_its_first_failing_member`) |
| Constructor refuses empty set / empty clause / zero member | 2 (three tests) |
| `MicroPaymentPolicy`: cap, token, budget; payee ignored | 1 (all of it) |
| `CAP` immutable, no setter, zero refused | 1 |
| Gas fits under `POLICY_GAS` | 3 (`test_it_fits_inside_the_account_s_gas_cap`) |
| The three demo intents produce ✅ / 6 / ✅ | 3 |
| Reason-code tests assert the exact number | every one of them uses `assertEq` against a `Reason.` constant |

**2. Placeholder scan.** No "TBD", no "add validation", no "similar to Task N". Every step carries the code it needs. Every address in this plan was checked to be `0x` plus exactly 40 hex digits — an earlier draft of Task 3 carried a malformed one with a warning attached, which an implementer would have copied verbatim.

**3. Type consistency.** `PolicySet(address[][] memory clauses)` in Task 2 is constructed the same way in Task 3. `MicroPaymentPolicy(uint256 cap_)` with `CAP()` in Task 1 is read as `CAP` in Task 3's `setUp`. `Reason.PAYEE_NOT_ALLOWED` / `OVER_TX_LIMIT` / `OVER_PERIOD_LIMIT` / `TOKEN_NOT_ALLOWED` / `POLICY_FAILED` / `OK` are the names in `src/Reason.sol`. `MEMBER_GAS` is referenced only inside `PolicySet`; Task 3 refers to the account's `POLICY_GAS` as its own local constant rather than importing `LeashAccount`.

**4. Not in this plan, deliberately.** Deploying the two contracts, approving `PolicySet` and repointing ENS are onchain actions needing the ADMIN and WALLET keys, so they stay with the operator. The recipe and the resulting addresses go into `docs/deployments.md` after the deployment, not before it.
