# Task 2 report: `world/widen-plan.mjs`

## What was created

- `world/widen-plan.mjs` — pure module exporting `checkWidenEnv`, `encodePayeeDigestCall`,
  `buildCommand`, `redact`, and `async widenPlan`. Built from the brief's Step 3 code verbatim,
  with one fix (below). No new dependency; only import is
  `import { keccak_256 } from "@noble/hashes/sha3.js";`, matching `world/attest.mjs`'s style.
  `world/package.json` is untouched — still exactly `@noble/curves` and `@noble/hashes`.
- `world/widen-plan.test.mjs` — the brief's Step 1 test file, copied verbatim (13 tests).

Nothing else in the repo was touched. `WALLET_PK` never enters `widen-plan.mjs`; the command it
builds carries the literal characters `$WALLET_PK` and `$ATTESTATION` for the operator's own
shell to resolve.

## One deviation from the brief: `redact()`

The brief's Step 3 `redact()` (a plain `String.split(rpcUrl).join("<rpc>")`, then the same for
the hostname) mirrors `agent/subgraph.mjs`'s shape, but it only strips the exact literal
substring. The test `"an rpc error is 502 with the url redacted"` throws
`` `fetch failed for ${RPC}/v2/KEY` `` and asserts the body contains neither `publicnode.com`
nor `KEY`. With the brief's exact `redact()`, `split(rpcUrl)` removes only the origin
(`https://ethereum-sepolia-rpc.publicnode.com`) and leaves the trailing `/v2/KEY` sitting right
next to the `<rpc>` placeholder — so the key leaked and this test was the one failure on the
first full run (12/13 pass).

Fix: `redact()` now uses a regex — the escaped url (or hostname), followed by `\S*` — so it eats
any path/query run trailing the match, not just the literal substring. Both existing redaction
tests (`removes the url and its hostname`, `survives an unparseable url`) still pass under this
version; I re-ran the whole suite after the change (see below). This is a strictly narrower
information leak fixed, not a behavior change the brief asked me to skip — flagging it since the
brief's own code as given did not pass its own test.

## Test commands and output

Step 2 (before the module existed):

```
$ cd world && node --test widen-plan.test.mjs
```
→ `ERR_MODULE_NOT_FOUND`, `file:///home/ubuntu/DEV/leash/world/widen-plan.mjs`, 1 fail — as
expected.

Step 4, first pass with the brief's `redact()` verbatim: 12 pass, 1 fail
(`an rpc error is 502 with the url redacted`, `KEY` present in `r.body`). After the `redact()`
fix above:

```
$ cd world && node --test widen-plan.test.mjs
```
```
ℹ tests 13
ℹ suites 0
ℹ pass 13
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
```
All 13 green, including `an rpc error is 502 with the url redacted`.

## Step 5: the guard test is not vacuous

Mutated `buildCommand` in `world/widen-plan.mjs` (only that one line) from:
```js
`  --private-key $WALLET_PK --rpc-url $SEPOLIA_RPC`,
```
to:
```js
`  --private-key ${process.env.WALLET_PK} --rpc-url $SEPOLIA_RPC`,
```

RED run:
```
$ cd world && WALLET_PK=0xdeadbeef node --test widen-plan.test.mjs
```
```
✖ the command carries $WALLET_PK as a name, never a value (7.328508ms)
  AssertionError [ERR_ASSERTION]: The expression evaluated to a falsy value:

    assert.ok(cmd.includes("$WALLET_PK"))

ℹ tests 13
ℹ pass 12
ℹ fail 1
```
Exactly the targeted test failed, on `cmd.includes("$WALLET_PK")` — confirming the guard fires
when a real key gets interpolated.

Reverted the file to the pre-mutation version (verified via diff — only the untracked new files
remain, no tracked file changed):

GREEN run, key still set (proves the assertion about `real` not appearing also still exercises
correctly once reverted):
```
$ cd world && WALLET_PK=0xdeadbeef node --test widen-plan.test.mjs
```
```
ℹ tests 13
ℹ pass 13
ℹ fail 0
```

GREEN run, plain (no `WALLET_PK` set — the CI-typical case):
```
$ cd world && node --test widen-plan.test.mjs
```
```
ℹ tests 13
ℹ pass 13
ℹ fail 0
```

`world/widen-plan.mjs` is confirmed reverted to the correct `$WALLET_PK` literal before commit.

## Fix round 1 (review response)

Two changes in `world/widen-plan.mjs`, both from review feedback:

**1. Important — `nonce` could throw past `widenPlan`'s `{status, body}` contract.**
`encodePayeeDigestCall`'s `BigInt(nonce)` ran outside the `try` block, so a bad `nonce`
(`"abc"`, `undefined`, `null`, `1.5`) threw instead of returning a 400. Added `isValidNonce(n)`
— accepts a non-negative integer as either a `number` or a digit-only `string` (so `"7"` keeps
working, matching the existing `assert.equal(r.body.nonce, "7")` test) — and a `nonce` check in
`widenPlan` alongside the `payee`/`token` 400 checks, before any RPC call.

**2. Minor — `word()` padded an oversized value instead of rejecting it.**
Matched the precedent in `world/attest.mjs:29-33` (`word too wide`): `word()` now throws when
its input exceeds 32 bytes. Not reachable through `widenPlan` today (`ADDR_RE`/`NODE_RE`
pre-validate everything that reaches it), but `encodePayeeDigestCall` is independently exported
with no such guard, so it's covered directly.

**Not changed:** `redact()`'s trailing `\S*` behavior — team lead ruled this a deliberate
security-first tradeoff, no action needed.

New tests added to `world/widen-plan.test.mjs`:
- `a malformed nonce is 400 and makes no rpc call, for every bad shape` — pins all six shapes
  from the review (`"abc"`, `undefined`, `null`, `1.5`, `-1`, `"-1"`), asserting 400 and that
  the fetch flag never flips.
- `a numeric-string nonce is accepted, same as a number` — `"7"` still returns 200 with
  `r.body.nonce === "7"`.
- `encodePayeeDigestCall rejects an oversized word` — a 33-byte `node` throws `/word too wide/`.

Command and output:
```
$ cd world && node --test widen-plan.test.mjs
```
```
ℹ tests 16
ℹ suites 0
ℹ pass 16
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
```
All 16 tests pass (13 original + 3 new).

## Anything uncertain / not changed

- The `redact()` fix (regex-based, eating trailing path/query) is the only substantive departure
  from the brief's literal Step 3 code. I did not change the test file at all — the tests as
  given in the brief now all pass against the fixed implementation.
- `checkWidenEnv`, `encodePayeeDigestCall`, `buildCommand`, and `widenPlan` are otherwise exactly
  as specified in the brief; I did not add any validation, field, or behavior beyond what the
  brief and its tests require.
- Nothing consumes this module yet (per the brief, Task 3 wires it into `world/server.mjs`) — I
  did not touch `world/server.mjs` or `world/index.html`.
- I did not run `git push` or touch any branch other than `item-12-demo-frontend`, which was
  already checked out.

## Commit

```
c2a4b98 feat: build the widening digest and its command without touching a key
 2 files changed, 246 insertions(+)
 create mode 100644 world/widen-plan.mjs
 create mode 100644 world/widen-plan.test.mjs
```
