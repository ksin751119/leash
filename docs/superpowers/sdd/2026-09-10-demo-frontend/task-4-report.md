# Task 4 Report: Pure Render Module

## What was created

Created two files in `world/`:

1. **`world/demo-render.mjs`** — A pure module exporting five render functions:
   - `shortHex(h)` — Formats hex strings to show first 6 and last 5 chars with ellipsis
   - `formatUsdc(raw)` — Formats USDC amounts using BigInt arithmetic (dividing by 1e6)
   - `renderStatus(s)` — Transforms state status to display properties
   - `renderIntent(intent, payees)` — Transforms an intent object to display properties, with payee allowlist lookup
   - `renderRules(s)` — Transforms budget and payee rules to display properties, computing spend percentage

2. **`world/demo-render.test.mjs`** — Test suite with 11 tests covering all functions and edge cases

All code was transcribed exactly as specified in the brief. The module contains no imports and remains loadable as a browser ES module.

## Test command and output

Command: `cd world && node --test`

Full output:
```
✔ shortHex keeps both ends (2.03031ms)
✔ formatUsdc divides by 1e6 and keeps two places (0.32306ms)
✔ renderStatus reports the index lag (1.687948ms)
✔ renderStatus says the agent is blind on a read error (0.674478ms)
✔ a will-pass intent is toned positive (0.737688ms)
✔ a blocked intent carries its numbered reason (0.445165ms)
✔ an intent's payee is allowed only when the map says so (0.547023ms)
✔ the map is matched case-insensitively (0.532181ms)
✔ a done intent shows its transaction (0.579853ms)
✔ renderRules computes the spent percentage (0.888362ms)
✔ renderRules survives a null budget and a null policy (0.465335ms)
✔ checkWidenEnv names the first missing variable (2.010082ms)
✔ checkWidenEnv rejects a malformed address without echoing a secret (0.267442ms)
✔ the calldata is selector + four 32-byte words (0.674148ms)
✔ the command carries $WALLET_PK as a name, never a value (1.786719ms)
✔ redact removes the url and its hostname (0.787198ms)
✔ redact survives an unparseable url (0.596421ms)
✔ a malformed payee is 400 and makes no rpc call (0.540419ms)
✔ a malformed token is 400 (0.358315ms)
✔ a malformed nonce is 400 and makes no rpc call, for every bad shape (0.80053ms)
✔ a numeric-string nonce is accepted, same as a number (0.702116ms)
✔ encodePayeeDigestCall rejects an oversized word (0.83155ms)
✔ missing env is 500 before any rpc call (0.435286ms)
✔ a good call returns the digest, the nonce and the command (0.316984ms)
✔ an rpc error is 502 with the url redacted (0.5179ms)
✔ a JSON-RPC error object is 502, not a silent success (0.483061ms)
✔ a result that is not 32 bytes fails closed (0.411127ms)
ℹ tests 27
ℹ suites 0
ℹ pass 27
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 188.079577
```

All 27 tests pass (11 new + 16 existing from widen-plan.test.mjs).

## First-run test results

All 11 tests passed on the first run. No tests failed. The code was transcribed exactly as specified in the brief.

## Observations

- The module correctly handles case-insensitive payee address lookup by converting to lowercase before map access
- BigInt arithmetic safely handles USDC values that would overflow Number precision
- The percentage calculation in `renderRules` safely handles null/zero boundaries using try-catch
- The ellipsis character used is U+2026 (…), matching the brief exactly
- The em-dash character used is U+2014 (—) for null/missing values

## Commit

- SHA: a2ea3d9e6e98735c9a0ddeccf0bb625563f4de5e
- Message: "feat: pure render functions, so the layout is testable without a browser"
