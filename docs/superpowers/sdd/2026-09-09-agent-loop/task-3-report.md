# Task 3: The subgraph reader — Report

## Status
**Complete.** All 9 unit tests pass. Live index validation successful. Forge test suite remains at 201 passed / 1 skipped / 0 failed.

## Commit
```
827fc29 feat: the agent's subgraph read, failing closed
```

## Test Result
```
✔ ids are lowercased, because the index stores them that way
✔ a good response becomes a snapshot
✔ payee keys are lowercased so decide() can look them up
✔ GraphQL errors fail closed
✔ a non-200 fails closed
✔ a thrown fetch fails closed instead of propagating
✔ a missing _meta fails closed - we must never decide on an unknown block
✔ absent optional rows are null, not an error
✔ the error sentence never contains the url, which may carry a key

ℹ tests 9
ℹ pass 9
ℹ fail 0
```

## Step 5: Live Index Validation

Full output of the live query against `https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4`:

```json
{
  "ok": true,
  "block": {
    "subgraph": 11668936,
    "chain": 11668936,
    "lag": 0
  },
  "agent": {
    "address": "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0",
    "revoked": false
  },
  "subname": {
    "label": "vendors",
    "live": true
  },
  "policy": {
    "address": "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b",
    "approved": true
  },
  "budget": {
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "limit": "1000000000",
    "spent": "300000000",
    "periodEnd": 1788998400
  },
  "payees": {
    "0x000000000000000000000000000000000000beef": {
      "allowed": true,
      "lastToken": "0x768f42455a2d082e23ceef7d51e5787c82d67a39"
    }
  }
}
```

✓ `ok: true`  
✓ `subgraph` block number 11668936 in the 11.6M range  
✓ `agent.revoked: false`  
✓ `policy.approved: true`  
✓ `budget.limit: "1000000000"` (string)  
✓ `payees["0x000000000000000000000000000000000000beef"].allowed: true`  
✓ All addresses lowercased  
✓ `periodEnd: 1788998400` (number, not string)  

## Notes
- `buildIds` correctly lowercases all inputs: checksummed wallet and agent produce lowercase ids
- `fetchSnapshot` returns snapshot with exact field shapes required by `decide()`: `budget.periodEnd` as Number, `budget.limit` and `spent` as strings, payee keys lowercase
- Error handling covers all paths: GraphQL errors, HTTP non-200, fetch throw, missing _meta
- Error messages never include the subgraph URL
- Payees filtered on `wallet` and `node` **fields** (Bytes!), not id prefix — verified against live index
- No network requests outside Step 5

---

## Fix Round 1

**Commit SHA:** `f12c98e`

**Critical — URL leak in the throw path:** The catch block was exposing `cfg.url` through `err.message`. Node's fetch puts the full URL (including API key) into exception messages on connection failures, while the non-200 path was already safe. Fixed by redacting `cfg.url` with a simple split-replace, keeping other diagnostic details like `ECONNREFUSED`.

**Important — lastToken not lowercased:** Was inconsistent with other addresses in the snapshot. Now `lastToken: p.lastToken ? lower(p.lastToken) : null`.

**Test result with fix:**
```
✔ ids are lowercased, because the index stores them that way
✔ a good response becomes a snapshot
✔ payee keys are lowercased so decide() can look them up
✔ GraphQL errors fail closed
✔ a non-200 fails closed
✔ a thrown fetch fails closed instead of propagating
✔ a missing _meta fails closed - we must never decide on an unknown block
✔ absent optional rows are null, not an error
✔ the error sentence never contains the url on the non-200 path
✔ the error sentence never contains the url on the throw path
✔ non-url error details like ECONNREFUSED survive redaction

ℹ tests 11
ℹ pass 11
ℹ fail 0
```

**Mutation test output (without redaction):**
```
✖ the error sentence never contains the url on the throw path
  AssertionError: the secret key must not appear
  (error message includes SECRET-KEY-abc123)

✖ non-url error details like ECONNREFUSED survive redaction
  AssertionError: url must be redacted
  (error message includes https://hidden.example.com)
```

This proves the new tests catch the leak that the original test missed. The original test only exercised the non-200 path (which was safe), not the throw path (which was leaking).

**Forge tests:** Still at 201 passed / 1 skipped / 0 failed.

**Plan updated:** Both the catch block implementation and the test listing in Task 3 were updated with:
- The redaction logic and comment explaining why the exception path needs it
- Two new tests (`the error sentence never contains the url on the throw path` and `non-url error details like ECONNREFUSED survive redaction`)
- Test count updated from 9 to 11

---

## Fix Round 2: Real connection diagnostics via err.cause

**Commit SHA:** `0c1764e`

**Finding:** The new test "non-url error details like ECONNREFUSED survive redaction" was illustrative but not real. Real Node behavior for connection failures differs from the test premise: `err.message` is just "fetch failed", and the actual diagnostic (ECONNREFUSED, ENOTFOUND, etc.) lives in `err.cause.message`.

**Fix:**
1. **Read err.cause.message** when present and include it in the error string so real diagnostics flow through
2. **Redact the hostname** in addition to the full URL, because DNS errors report only the hostname: `getaddrinfo ENOTFOUND api.example.com` contains the domain but no path/API key, yet the domain alone should not appear in logs

**Test result with cause-reading and hostname redaction:**
```
✔ ids are lowercased, because the index stores them that way
✔ a good response becomes a snapshot
✔ payee keys are lowercased so decide() can look them up
✔ GraphQL errors fail closed
✔ a non-200 fails closed
✔ a thrown fetch fails closed instead of propagating
✔ a missing _meta fails closed - we must never decide on an unknown block
✔ absent optional rows are null, not an error
✔ the error sentence never contains the url on the non-200 path
✔ the error sentence never contains the url on the throw path (malformed URL)
✔ real connection failures put the detail in err.cause, not err.message
✔ hostname in err.cause does not leak through redaction

ℹ tests 12
ℹ pass 12
ℹ fail 0
```

**Mutation test output (without cause-reading and hostname redaction):**
```
✖ real connection failures put the detail in err.cause, not err.message
  AssertionError: the real diagnostic from err.cause must be present
  (error message shows only "fetch failed", ECONNREFUSED is absent)

✖ hostname in err.cause does not leak through redaction
  AssertionError: the error reason must be present
  (error message shows only "fetch failed", ENOTFOUND is absent)
```

**Hostname exposure analysis:** The hostname does not leak through the redaction when extracted via `new URL(cfg.url).hostname` and split-replaced. Verified with test case that DNS error contains hostname and asserts it's redacted while ENOTFOUND survives.

**Why this matters:** When the read fails, the agent silently sends nothing. The only clue an operator gets during a demo (or debugging) is the error message. "fetch failed" provides zero diagnostic value; "fetch failed (getaddrinfo ENOTFOUND api.example.com)" tells you exactly what happened. The fix widens the diagnostic without widening what can leak, because:
- `err.cause.message` for real failures carries only the hostname (no path/query)
- Hostname is redacted by the second split-replace
- Secret API keys live in paths and query parameters, which are not in `err.cause`

**Forge tests:** Still at 201 passed / 1 skipped / 0 failed.

**Plan updated:** Task 3 catch block now includes cause-reading and hostname redaction logic. Tests updated to reflect real Node behavior and verify hostname doesn't leak. Test count updated from 11 to 12.
