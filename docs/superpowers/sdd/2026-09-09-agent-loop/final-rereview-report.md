# Scoped re-review — final fix wave (`a339335..1ae319b`)

Branch `agent-loop`, worktree `/home/ubuntu/DEV/leash/.worktrees/agent-loop`. Scope: the fix
diff only, 1 commit / 10 files. Nothing was modified, committed, or dispatched. The loop was
never started; no transaction was sent; `developer.worldcoin.org` was not contacted; `.env`
was not opened.

## Verification run

- `cd agent && node --test` → **64 pass / 0 fail / 0 skipped**
- `node check-reason-table.mjs` → all 13 codes agree between Solidity and JS
- `forge test` → **201 passed / 1 skipped / 0 failed** (13 suites)
- `fetchSnapshot` run read-only against the live `leash-sepolia/v0.0.4` index: `ok: true`,
  `agent.node` and `budget.remaining` both populated (`remaining: "700000000"`, byte-identical
  to the new test fixture), `budget.limit: "1000000000"`.
- Node in this environment: **v24.14.1**

## Finding-by-finding

| # | Verdict | Evidence |
|---|---|---|
| **C1** | **ADDRESSED, with a hole** | Both guards exist and are independent: `validateIntents` rejects a repeat id (`agent/loop.mjs:38`, exits at `:319-323`), and `advance`'s `queued` Set independently caps `toSend` at one per id (`:92,139`). Independence confirmed by probing a `__proto__` duplicate, which `queued` alone stopped. **The fourth path is open — Important 1 and 2 below.** |
| **I7** | **ADDRESSED** | `validateEnvVar` trims then shape-checks (`:67-72`); a quoted `"0x46C0…"` fails the pattern because `trim()` does not strip quotes; a trailing `\r` is healed. The healed value is what runs: module vars declared at `:203`, assigned from `envValues` at `:312-316`, read by `tick()` at `:234-237,254-256`. `grep process.env agent/*.mjs` leaves only `PORT`, `AGENT_TICK_MS`, `SUBGRAPH_URL` and the `validateEnvVar` call site — no direct read of the five validated vars survives. |
| **I2** | **ADDRESSED; residual is latent, not live** | Per-intent try/catch → `invalid` (`:121-134`). Probed `[good, {amount:"5.5"}]` → `toSend === ["good"]`, `state.intents.bad.verdict === "invalid"`. `""`, `null`, `undefined`, `"1e6"`, `" 5 "` all refused at load by `/^[0-9]+$/`. See "The `limit: \"0\"` branch" below for the one branch the new test does not exercise. |
| **I5** | **ADDRESSED** | `pass()` now names the per-tx cap, allow-list, window and pause (`agent/decide.mjs:37-43`); the test asserts non-null and matches `/not indexed\|only the chain/`. |
| **I3** | **ADDRESSED; amending the spec was the right call** | `publicState` keys now match the amended spec exactly, and the two new fields are real onchain rather than fixture-only (live query above). Reshaping the code to the old merged `agent` object would have been wrong: `Agent` and `Subname` are genuinely separate entities (`subgraph/schema.graphql:163`), and the spec's own "Each tick" note already said where `label` lives. |
| **I4** | **ADDRESSED** | Grep across `*.md`/`*.mjs`/`*.tsx` finds no live "sends and lets the chain answer"; the only occurrence is the correction sentence at `docs/superpowers/specs/2026-09-09-agent-loop-design.md:182`. Plan line 1887 now states `advance` never sends on `unknown`, matching `agent/loop.mjs:139`. |
| **I6** | **ADDRESSED, and it introduced a crash** | CORS header + OPTIONS preflight (`:328-334`); `?t=` probed → 200. But see Important 3. |
| **`err.cause`** | **ADDRESSED, and it widened one error string** | The estimation detail now surfaces instead of `"HTTP request failed."`. See Minor 1 for exactly what that string contains. |

## New problems

### Important 1 — the fourth duplicate-payment path: a non-string id defeats both C1 guards

`agent/loop.mjs:38` and `:139` key on the raw `id` (a `Set`, SameValueZero), while the record
store keys on its string coercion (`:94,144`). Probed `[{id: 1, …}, {id: "1", …}]`:

- `validateIntents` returns **no error** — `1` and `"1"` are distinct Set members
- `toSend` is `[1, "1"]` — `queued.has("1")` is false after `queued.add(1)`
- `Object.keys(state.intents)` is `["1"]` — and `state.intents[1] === state.intents["1"]`

So `tick` calls `sendAndRecord` twice on the *same record object*, `inFlight` is cleared by the
`finally` between the two awaits, and the second `lastAction` write drops the first
transaction's hash. That is C1's exact mechanism, reproduced against the fixed code.

Fix, one line in `validateIntents`: require `typeof intent.id === "string"`.

### Important 2 — `__proto__` as an id is sent every tick and never appears in the published state

`next.intents["__proto__"] = rec` (`:144`) hits `Object.prototype`'s `__proto__` setter, so no
own property is ever created. Probed with a single intent named `__proto__`:

- it is queued and sent — `state.intents["__proto__"]` resolves through the prototype chain,
  so `tick`'s lookup at `:253` finds the record and sends
- `Object.keys(state.intents)` is `[]`, so it is invisible in `GET /api/agent/state` (`:217`)
  and in the "not sent" console line (`:270`)
- `{ ...state.intents }` (`:86`) copies no own property, so every guard resets each tick: I set
  `lastAction.outcome = "executed"` and tick 2 still returned `toSend: ["__proto__"]`, verdict
  `will-pass`

An unbounded repeat payment, invisible on the endpoint. `constructor` and `toString` are benign
(ordinary own data properties; probed). `validateIntents` does not reject `__proto__`.

Fix, same one line as Important 1 plus a reserved-name check — or build the store as
`Object.assign(Object.create(null), state.intents)`.

### Important 3 — the I6 routing fix kills the process on `GET //`

`new URL(req.url, "http://x")` (`:341`) throws `Invalid URL` for request targets `//` and `/\`.
It sits *outside* the POST try/catch and before any `json()` call, inside an async handler Node
does not await, so the rejection is unhandled.

Reproduced with a byte-for-byte copy of the handler shape on Node v24.14.1, with no
`unhandledRejection` handler registered:

```
before: HTTP/1.1 200 OK
crasher: TypeError: Invalid URL … code: 'ERR_INVALID_URL', input: '//', base: 'http://x'
process exit code = 1        # the follow-up request never ran — the process was gone
```

It **kills the process**, it does not merely fail the request. With
`Access-Control-Allow-Origin: *` now set, any page open in the operator's browser can
`fetch("http://localhost:8788//")` and take the agent down mid-run.

Related and non-fatal: `//api/agent/state` — the classic `base + "/path"` join the frontend is
most likely to produce — resolves to host `api`, pathname `/agent/state`, and 404s.

Fix: `req.url.split("?")[0]` instead of `new URL(...)`. Closes both.

## The `limit: "0"` branch in I2 — latent, not live

`agent/decide.mjs:89-97` only evaluates `BigInt(intent.amount)` inside `if (limit !== 0n)`.
Probed with `limit: "0"`: `"5.5"`, `""`, `null`, `undefined`, `"1e6"` and `" 5 "` all return
`will-pass` and are queued — no `invalid` verdict, because nothing throws. The new test uses
`limit: "1000000000"`, so it passes without exercising that branch.

It is closed in practice, for two independent reasons:

1. **There is no other way in.** The only non-test caller of `advance` is `tick()` at
   `agent/loop.mjs:249`, and the only source of `intents` is `:318` (`intents.json`), followed
   immediately by `validateIntents` and `process.exit(1)`. No HTTP route accepts intents;
   `world/server.mjs`'s `JSON.parse` is a different process and does not feed `decide`.
   `/^[0-9]+$/` therefore stops every malformed amount before the process serves a request.
2. **The demo's budget is not unlimited.** The live index reports `limit: "1000000000"`, so
   the `limit === 0n` branch is not reachable in the deployed configuration at all.

So this is a latent hole that opens only for a future caller that skips `validateIntents` —
sprint item 12 POSTing intents, say. A ledger line, not a fix. If it is ever cheap, the
durable form is to validate the amount inside `decide` rather than only at load.

## Minor

1. **The `err.cause` string is verbose, and it discloses nothing that is not already public —
   with one conditional exception.** With a well-formed `https://` RPC URL, what now reaches
   `lastAction.error`, the console and the JSON response is: `"HTTP request failed."` twice
   (top `shortMessage` plus the cause's), `details` (`"fetch failed"`), and the `metaMessages`
   block — `URL: <rpc>` (redacted), `Request body: {"method":"eth_getTransactionCount",…}`, the
   `Request Arguments` (`from` = agent EOA, `to` = wallet, `data` = calldata) and the
   `Contract Call` block (wallet address, `spend(address,address,uint256)`, `args: (token,
   payee, amount)`, `sender` = agent EOA). Every one of those is already public: `agent.address`
   and `budget.token` are published by this same endpoint, `payee` and `amount` are committed
   in `agent/intents.json`, and the spend is broadcast to Sepolia. **No private key**: probed a
   malformed `AGENT_PK` and noble returns `"invalid private key, expected hex or 32 bytes, got
   string"` with no key material, and a signed raw transaction in a `Request body` carries a
   signature, not a key. So: verbose and ugly, a ledger line.
   The exception: `redactUrls` matches only `/https?:\/\/\S+/` (`agent/send.mjs:30`). Probed
   `rpcUrl = "eth-sepolia.g.example.com/v2/SUPERSECRETKEY123"` (no scheme) and the key appears
   verbatim twice — once via `err.details` (`"Failed to parse URL from …"`), once via
   `metaMessages` (`"URL: …"`). Pre-change the same call produced only `"HTTP request failed."`,
   so the exposure is new. But viem's http transport cannot make a single request against a
   scheme-less URL, so in that configuration nothing is ever sent and the demo is visibly dead
   — the key leaks into a local endpoint whose agent does not work. `SEPOLIA_RPC` is the one
   validated var with `pattern: null` (`:298`); giving it `/^https:\/\//` refuses the broken
   config at startup and removes the leak in the same line. Worth doing while the file is open;
   not a stop-and-fix.
2. **`agent/send.mjs`'s new aggregation has no test.** `git diff a339335..1ae319b -- send.test.mjs`
   is empty; only `redactUrls` itself is covered. The module comment at `send.mjs:23-28` warns
   that "an untested redaction on a secret-bearing string is the defect Task 3 shipped" — which
   is the shape of Minor 1. The joined message also keeps embedded newlines, since
   `.split("\n")[0]` applies only to `top`, so `lastAction.error` is now a ~10-line blob in the
   JSON.
3. **Spec verdict count is off by one.** `docs/superpowers/specs/2026-09-09-agent-loop-design.md:253`
   says "three more values" then lists four (`in-flight`, `unconfirmed`, `done`, `invalid`). The
   code has 8 verdicts: 4 from `decide` (`will-pass`, `will-be-blocked`, `unknown`,
   `unknown-read-failed`) and 4 from the lifecycle. All 8 are named in the spec; only the number
   word is wrong. Same class as I3. The spec's `intents[]` example also omits `note`, which
   `publicState` always emits (`agent/loop.mjs:219`).
4. **Ids differing only by case or trailing space** (`"retainer"` vs `"retainer "`) pass
   validation as two separate intents and are each paid once. No lost hash, but it reads as one
   intent to a human.
5. **`loop.test.mjs`'s `okSnap()` fixture** (`:11-18`) lacks the `agent.node` and
   `budget.remaining` that `fetchSnapshot` now produces. Harmless today — `decide` reads
   neither — but it is drift from the real shape.

## Tests sampled

Checked for mechanism, not just for passing:

- the duplicate-id test — without `queued`, `toSend` would be `["retainer","retainer"]`; I
  confirmed `queued` is what stops it by probing a `__proto__` duplicate
- `validateIntents` empty-amount, duplicate-id and bad-address tests — all call the function
  directly, all non-vacuous
- the CR-trim test — asserts `result.value` is the *healed* string, not merely the absence of
  an error, which is the property that matters for I7
- the `remaining` fixture — cross-checked against the live index; it matches byte for byte
- the weak one: "a malformed amount does not crash advance" passes, but only on the
  `limit !== 0` branch (see the `limit: "0"` section)

## Verdict

**Not ready as-is. Three one-line fixes, then merge.**

- `agent/loop.mjs:38` — require `typeof intent.id === "string"` and reject `__proto__`
  (closes Important 1 and 2; C1 is a Critical that is not fully closed, and money is this
  branch's central risk)
- `agent/loop.mjs:341` — `req.url.split("?")[0]` (closes Important 3; a regression introduced
  by this wave that kills the process, confirmed exit 1)
- `agent/loop.mjs:298` — `/^https:\/\//` on `SEPOLIA_RPC` (Minor 1; cheap while the file is
  open, and the same class as the I7 fix)

Everything else is a ledger line. With those three in, and given 64 + 201 green and the live
index check, this branch is ready.
