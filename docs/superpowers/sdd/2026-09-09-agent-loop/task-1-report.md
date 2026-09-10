# Task 1 Report: The reason table, pinned to Solidity

## Status: DONE

### Commit SHA
```
e402e11 feat: the agent's reason table, pinned to src/Reason.sol
```

### Test Results

#### `node --test reason.test.mjs`
```
✔ the codes match src/Reason.sol exactly (2.135353ms)
✔ reasonName round-trips every code (0.427441ms)
✔ an unknown code does not throw (0.313534ms)
ℹ tests 3
ℹ suites 0
ℹ pass 3
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 145.306103
```

#### `node check-reason-table.mjs` (Initial - All Match)
```
ok    AGENT_NOT_BOUND      solidity=1 js=1
ok    AGENT_REVOKED        solidity=2 js=2
ok    NO_POLICY            solidity=3 js=3
ok    OK                   solidity=0 js=0
ok    OUTSIDE_TIME_WINDOW  solidity=9 js=9
ok    OVER_PERIOD_LIMIT    solidity=8 js=8
ok    OVER_SHARED_LIMIT    solidity=11 js=11
ok    OVER_TX_LIMIT        solidity=7 js=7
ok    PAUSED               solidity=10 js=10
ok    PAYEE_NOT_ALLOWED    solidity=6 js=6
ok    POLICY_FAILED        solidity=12 js=12
ok    POLICY_NOT_APPROVED  solidity=4 js=4
ok    TOKEN_NOT_ALLOWED    solidity=5 js=5

all 13 codes agree
```

### Step 8: Mutation Test

#### Failing Run (PAUSED mutated to 99)
```
ok    AGENT_NOT_BOUND      solidity=1 js=1
ok    AGENT_REVOKED        solidity=2 js=2
ok    NO_POLICY            solidity=3 js=3
ok    OK                   solidity=0 js=0
ok    OUTSIDE_TIME_WINDOW  solidity=9 js=9
ok    OVER_PERIOD_LIMIT    solidity=8 js=8
ok    OVER_SHARED_LIMIT    solidity=11 js=11
ok    OVER_TX_LIMIT        solidity=7 js=7
FAIL  PAUSED               solidity=10 js=99
ok    PAYEE_NOT_ALLOWED    solidity=6 js=6
ok    POLICY_FAILED        solidity=12 js=12
ok    POLICY_NOT_APPROVED  solidity=4 js=4
ok    TOKEN_NOT_ALLOWED    solidity=5 js=5

1 MISMATCH
```

#### Restored Run (PAUSED reverted to 10)
```
ok    AGENT_NOT_BOUND      solidity=1 js=1
ok    AGENT_REVOKED        solidity=2 js=2
ok    NO_POLICY            solidity=3 js=3
ok    OK                   solidity=0 js=0
ok    OUTSIDE_TIME_WINDOW  solidity=9 js=9
ok    OVER_PERIOD_LIMIT    solidity=8 js=8
ok    OVER_SHARED_LIMIT    solidity=11 js=11
ok    OVER_TX_LIMIT        solidity=7 js=7
ok    PAUSED               solidity=10 js=10
ok    PAYEE_NOT_ALLOWED    solidity=6 js=6
ok    POLICY_FAILED        solidity=12 js=12
ok    POLICY_NOT_APPROVED  solidity=4 js=4
ok    TOKEN_NOT_ALLOWED    solidity=5 js=5

all 13 codes agree
```

### Forge Test Results
```
Ran 13 test suites in 69.57ms: 201 tests passed, 0 failed, 1 skipped
```

## Summary

All 9 steps completed successfully:
1. ✅ Created `agent/package.json` with viem 2.56.3 dependency
2. ✅ Created `agent/reason.test.mjs` with three test cases
3. ✅ Confirmed initial test failure (missing reason.mjs)
4. ✅ Created `agent/reason.mjs` with all 13 reason codes
5. ✅ Confirmed tests now pass (3/3)
6. ✅ Created `agent/check-reason-table.mjs` pinning check
7. ✅ Confirmed all 13 codes agree with src/Reason.sol
8. ✅ Demonstrated mutation detection (PAUSED: 99 → FAIL; revert → PASS)
9. ✅ Committed to branch with proper attribution

The pinning check successfully proves that any renumbering in Solidity would be caught immediately.

### No Concerns
All requirements met. No modifications to src/, test/, script/, subgraph/, or world/ directories. Solidity tests remain at baseline (201 passed / 1 skipped / 0 failed).

---

## Fix Round 1: Structural Improvements

**Commit SHA:** 2bde03e fix: align REASON_NAMES by explicit index; guard pinning check against partial regex match

### Issue 1: REASON_NAMES alignment (Important)

**Problem:** The original implementation built REASON_NAMES by sorting entries and compacting into an array. While correct today (codes 0-12 with no gaps), if a code is ever deprecated without renumbering (which the spec forbids changing numbers), a hole would be left. This would cause `REASON_NAMES[5]` to silently become the name for code 6 instead of index 5.

**Fix:** Build REASON_NAMES by explicit index assignment:
```javascript
export function buildNames(map) {
  const names = [];
  for (const [name, code] of Object.entries(map)) names[code] = name;
  return Object.freeze(names);
}
export const REASON_NAMES = buildNames(REASON);
```

A sparse array with undefined gaps now correctly returns "UNKNOWN" for deprecated codes rather than a neighbor's name.

### Issue 2: Partial regex match guard (Minor)

**Problem:** The check-reason-table.mjs only guarded against total parse failure (0 constants matched). If the regex were to drift and match only a subset, it would silently pass on a partial table.

**Fix:** Add count guard comparing parsed constants to total `internal constant` declarations:
```javascript
const constantCount = (sol.match(/internal\s+constant/g) || []).length;
if (solNames.length !== constantCount) {
  console.log(`FAIL  parsed ${solNames.length} constants but found ${constantCount} internal constant declarations...`);
  process.exit(1);
}
```

### Test Results After Fix

#### `node --test reason.test.mjs`
```
✔ the codes match src/Reason.sol exactly
✔ reasonName round-trips every code
✔ an unknown code does not throw
✔ buildNames preserves gaps in the code sequence
ℹ tests 4
ℹ pass 4
ℹ fail 0
```

#### `node check-reason-table.mjs`
```
all 13 codes agree
```

#### Mutation Test - Count Guard

**Broken regex** (matches only constants with suffixes APPROVED/ALLOWED/LIMIT/WINDOW):
```
FAIL  parsed 7 constants but found 13 internal constant declarations - the regex has fallen behind the Solidity formatting
Exit code: 1
```

**Restored regex**:
```
all 13 codes agree
Exit code: 0
```

#### Forge Test
```
Ran 13 test suites: 201 tests passed, 0 failed, 1 skipped
```

### Summary of Fixes

1. ✅ Extracted `buildNames()` function to build REASON_NAMES by explicit index
2. ✅ Added test case for gap handling in buildNames
3. ✅ Added count guard in check-reason-table.mjs to catch partial regex matches
4. ✅ Verified all 4 tests pass
5. ✅ Verified mutation test confirms count guard works
6. ✅ Verified forge test baseline maintained

The two structural changes eliminate silent failure modes: gap misalignment in REASON_NAMES and partial regex matches in the pinning check.
