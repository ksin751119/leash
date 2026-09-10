# Task 4 report: the sender

## Status
Complete. Created `agent/send.mjs` and `agent/send.test.mjs` verbatim per the brief. All 9 tests
pass. `forge test`: 201 passed, 1 skipped, 0 failed (unchanged from baseline).

## Verification of the event topics
Before trusting the two topic hashes given in the brief, I cross-checked them independently with
`cast keccak` against the actual event signatures in `src/LeashAccount.sol:111-132`:

```
cast keccak "SpendExecuted(bytes32,address,address,address,uint256,address,uint256,uint256,uint64)"
-> 0xf0b4af7bfd5a13b5eff4d2de508be60041b405cee18bf6f135c692be137d1381
cast keccak "SpendBlocked(bytes32,address,address,address,uint256,uint8,address,uint256,uint256)"
-> 0x8ab53b1df82e8bdff7dad3143040ff0efb1d94506ab3e47853c38b5925c50828
```

Both match the brief exactly, and the non-indexed word order in `SpendBlocked` (`node`, `amount`,
`reason`, `policy`, `spentSoFar`, `limit`) matches the Solidity declaration order at
`src/LeashAccount.sol:122-132`.

## Commit
`d46b460aa828dc81c0fa28c0ee763359fe0ae6eb` — "feat: send a spend, and read what the chain said
about it"

## `node --test send.test.mjs` result
```
ℹ tests 9
ℹ suites 0
ℹ pass 9
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
```

## Step 5 mutation
Changed `hex.slice(64 * 2, 64 * 3)` to `hex.slice(64 * 1, 64 * 2)` (reading `amount` instead of
`reason`). Result: exactly the named test went RED, as predicted:

```
✖ a SpendBlocked log yields its reason code (1.754931ms)
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
  0 !== 6
      at TestContext.<anonymous> (file:///.../agent/send.test.mjs:31:10)
  ...
  actual: 0,
  expected: 6,
  operator: 'strictEqual'
```

8 other tests stayed green (`pass 8, fail 1`). Reverted via a saved copy of the file made before
mutating; confirmed byte-identity with sha256 before and after:
`0b04f497c234d7e9757234ca9fe4d4171e35ddf3d7fcd713183815b9be3039d9` (both times). Re-ran the suite
after reverting: 9/9 pass again.

## Test non-vacuity check (all 9)

1. **"a SpendExecuted log is executed"** — fails under any implementation that doesn't recognize
   `TOPIC_EXECUTED` or defaults to some other outcome. Non-vacuous.
2. **"a SpendBlocked log yields its reason code"** — proven non-vacuous by Step 5: it is exactly
   the test that catches a wrong-word-offset bug.
3. **"logs from another address are ignored"** — fails if the address filter is missing or wrong;
   a naive implementation that doesn't check `l.address` would report `"executed"` instead of
   `"no-event"`. Non-vacuous.
4. **"address comparison is case-insensitive"** — fails if comparison used `===` on raw strings
   instead of lowercasing both sides; mixed-case input here would then not match. Non-vacuous.
5. **"no logs at all is no-event, not a crash"** — the `{}` (no `logs` key at all) case would
   throw a `TypeError` under a naive `receipt.logs.filter(...)` instead of the `receipt?.logs ??
   []` guard. This test kills that whole bug class, not just the empty-array case. Non-vacuous.
6. **"SpendBlocked wins if both appear..."** — fails if an implementation checks
   `TOPIC_EXECUTED` before `TOPIC_BLOCKED`, which would report `"executed"` instead. Non-vacuous.
7. **"redactUrls removes an rpc url carrying an api key"** — fails under a no-op or a redaction
   that doesn't remove the full URL run. Non-vacuous.
8. **"redactUrls keeps the non-url detail"** — I specifically checked this one: the ` 443` after
   the URL survives because `/https?:\/\/\S+/` stops at whitespace, not because of any special
   casing in the implementation. This test would fail against a plausible over-eager
   implementation such as `text.replace(/https?:\/\/.*/, "<rpc>")` (a `.` that swallows the rest
   of the line, including ` 443`), or one that just returns a constant generic message. Non-
   vacuous — it is the one test in the suite that guards specifically against over-redaction.
9. **"a truncated SpendBlocked data field does not throw"** — `"0x1234"` has hex length 4, far
   short of the `64*3` needed to reach the reason word. Without the `hex.length < 64 * 3` guard,
   `hex.slice(64*2, 64*3)` on a 4-char string yields `""`, and `BigInt("0x")` throws. This test
   would fail (by throwing, not just by a wrong assertion) under an implementation that omits the
   length guard. Non-vacuous.

All 9 tests distinguish their named behavior from at least one plausible wrong implementation. I
found no vacuous test in this set.

## Concerns
None. One observation, not a defect: the `WALLET` test constant
(`0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6`) is not EIP-55 checksum-valid, but `classifyReceipt`
never runs addresses through viem's checksum validation — it only lowercases and compares — so
this has no effect on correctness of the implementation or the tests. Given verbatim in the brief,
so I did not change it.

No network requests were made, `SEPOLIA_RPC`/`AGENT_PK`/`WALLET_PK`/`WORLD_RP_SIGNER_PK` were
never read or echoed, `/home/ubuntu/DEV/ETHOnline2026/.env` was never opened, `sendSpend` was not
exercised, and only `agent/send.mjs` and `agent/send.test.mjs` were created — no other files in
`agent/`, `src/`, `test/`, `script/`, `subgraph/`, or `world/` were touched. No subagents were
dispatched.
