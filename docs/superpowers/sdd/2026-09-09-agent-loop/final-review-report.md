# Final whole-branch review — `agent-loop` (781720b..a339335)

Reviewer: al-final-review (opus). Read-only review; the only file written is this report,
at the team lead's explicit request.

**Verification I ran myself:** `node --test` → **51 pass / 0 fail** (12 subgraph, 16 decide,
9 send, 10 loop, 4 reason); `node check-reason-table.mjs` → `all 13 codes agree`;
`forge test` → **201 passed / 1 skipped / 0 failed**; `node --check` clean on all 11 `.mjs`;
working tree clean, `node_modules` correctly ignored. Plus a **live** end-to-end read against
`api.studio.thegraph.com` (block 11669283, lag 0) feeding the real `intents.json` into
`decide` — `retainer → will-pass`, `newvendor → will-be-blocked (6, PAYEE_NOT_ALLOWED)`.
Every field name, id format and type in the GraphQL query is correct against the deployed
index; the stubbed tests cannot see that, so it was worth doing again.

---

## Critical

### C1 — A repeated `id` in `intents.json` pays twice, and the first tx hash is lost

`agent/loop.mjs:37` / `:70` / `:172-177`

`advance` reads `prev` from `next.intents` (the record it is currently building), not from
`state.intents`. With two entries carrying the same `id`, the second iteration sees a record
with `inFlight: false` and `lastAction: null`, so `decide` runs again and the id is pushed to
`toSend` **twice**. `tick`'s send loop then calls `sendAndRecord(state.intents[intent.id], …)`
on the *same record object* twice and submits two spends. The second write to `rec.lastAction`
overwrites the first, so the first transaction hash never reaches state, the log, or
`/api/agent/state`.

Proven, not inferred — with a two-entry list both named `retainer` and a counting fake
`sendImpl`:

```
toSend ids: [ 'retainer', 'retainer' ]
real spends submitted: 2 | lastAction: {"kind":"sent","tx":"0xhash2",…}
```

This walks around all three existing guards: the executed check hasn't happened yet,
`inFlight` is cleared between the two awaited sends, and the unconfirmed check needs a
`lastAction` that doesn't exist yet. It is exactly the failure the ledger rated Critical for
the timeout path — "an agent that pays twice destroys the thesis, because it looks like the
system has no idea what it did" — and the hash loss makes it unrecoverable by inspection. The
trigger is a hand-edited demo file: copy an intent block, change the amount, forget the id.
No error, no warning.

**Fix:** validate at load (`loop.mjs:213`) and fail before the server starts — unique ids,
plus `/^[0-9]+$/` on `amount` and `/^0x[0-9a-fA-F]{40}$/` on `token`/`payee`. Belt and braces:
dedupe `toSend` by id in `advance`. The load-time validation also closes I2.

---

## Important

### I2 — `tick()` has no error boundary; one throw kills the agent process

`agent/loop.mjs:149-198`, `:229-230`, `:222`

`decide` calls `BigInt(intent.amount)` (`decide.mjs:88`) with no validation. Measured:

```
amount "5.5"        -> THROWS SyntaxError: Cannot convert 5.5 to a BigInt
amount "5_000_000"  -> THROWS SyntaxError
amount null         -> THROWS TypeError
amount ""           -> will-pass   (BigInt("") === 0n, then the chain reverts ZeroAmount)
```

`tick`'s `try` has only a `finally`, so the rejection escapes into
`setInterval(tick, TICK_MS)` and the bare `tick()` at `:229`. Node 24 kills the process on an
unhandled rejection — confirmed with a harness mirroring those two lines exactly: `exit=1`.
The same throw inside `POST /api/agent/tick` (`:222`, an async handler with no catch) kills
the process *and* leaves the request hanging.

`amount: ""` is worse than a crash: it pre-flights `will-pass`, so the demo's headline intent
silently degrades to a reverting call every tick — which reads as a policy failure rather
than a typo.

**Fix:** wrap `tick`'s body in `try/catch`, record the message into state (a `tickError`
beside `readError`) and keep ticking; wrap the POST handler too. With C1's load-time
validation the reachable triggers go to near zero — but a process that dies on stage is worth
two `catch` blocks.

### I3 — The published state does not match the spec's `GET /api/agent/state` contract

`agent/loop.mjs:126-147`, `agent/subgraph.mjs:30`, `:104-110`

Spec lines 202-219 are the contract item 12 will be built against. Four divergences:

| Spec | Built |
|---|---|
| `budget.remaining` | absent — never queried, never published |
| `agent.node`, `agent.label` | absent; `label` lives under a separate `subname` key |
| `verdict` three-valued | seven values reach the wire: `will-pass`, `will-be-blocked`, `unknown`, `unknown-read-failed`, `done`, `in-flight`, `unconfirmed` |

`remaining` is the sharpest one. `subgraph/schema.graphql:5` names it as the answer to agent
question 1, and lines 11-15 say why the arithmetic was put in the mapping: *"If 'how much is
left' required the agent to sum events and decide for itself… that logic would live in the one
place we do not trust."* `decide.mjs:88` computes `spent + amount > limit` — the agent
re-deriving `remaining` in JavaScript, which is the thing the schema was shaped to prevent.
The rollover case does justify *not* trusting `remaining` blindly (spec 122-137), so the
computation isn't wrong; but not querying the field at all, and not publishing it, silently
drops the subgraph's own answer and breaks the documented JSON.

**Fix:** add `remaining` to the query and the snapshot, publish it, and reconcile
`agent`/`subname` and the verdict list — either in the code or by amending the spec's JSON
block. Cheapest while item 12 does not exist yet.

### I4 — Three documents say `unknown` means "send and let the chain answer". The code never sends on `unknown`.

`agent/loop.mjs:68`

`advance` pushes to `toSend` only when `d.verdict === "will-pass"`. So an `unknown` intent is
never sent — ever. But:

- spec:176 — *"What it cannot see, it sends and lets the chain answer."*
- `agent/README.md:42` — *"For those the verdict is `unknown` and the agent sends, letting the
  chain answer."*
- plan self-review (~line 1644) — *"`decide` returns `unknown` for any intent whose token
  differs from the budget's — so a mixed-token list degrades to 'ask the chain' rather than
  deciding wrongly."*

As built, a mixed-token list degrades to **"silently never pays, with no reason code and no
error"** — on stage that is indistinguishable from a broken agent. The ledger's "known gap,
deliberate" ruling justifies the gap with behaviour the code does not have. Not live today
(both intents use MockUSDC), but the reasoning behind the ruling is wrong, so I am flagging it
rather than the gap.

**Fix:** keep the code (not sending is the fail-closed direction and I would defend it) and
correct all three documents to say `unknown` → not sent, awaiting a state the index can
answer. Related: the spec's claim that the five unindexed reasons produce `unknown` is also
false — they produce `will-pass`, which is I5.

### I5 — `will-pass` is silently optimistic, which is the one thing spec decision 3 said not to be

`agent/decide.mjs:34`

`pass()` returns `explain: null`. Confirmed live:
`retainer -> {"verdict":"will-pass","reason":null,"reasonName":null,"explain":null}`.
Spec 226-228 chose a three-valued verdict *"so the five reasons the index cannot see are
visibly 'I do not know, I have to ask the chain' rather than silently optimistic."* The per-tx
cap, token allow-list, time window and pause are invisible to pre-flight, and the endpoint
says nothing about it — the honesty the spec built the verdict around exists only in
`decide.mjs`'s header comment, where no judge will read it.

**Fix:** one line — give `pass()` an `explain` like `"found nothing that forbids it; the
per-tx cap, token allow-list, time window and pause are not indexed, so only the chain can
confirm"`. Highest demo value per character on this branch.

### I6 — The frontend cannot read this endpoint from a browser

`agent/loop.mjs:215-226`

No `Access-Control-Allow-Origin` header, so item 12 served from any other origin (a Vite dev
server, `file://`) gets blocked by CORS on `GET /api/agent/state`. Routing is exact string
match on `req.url`, so `/api/agent/state?t=1699…` — the reflex cache-buster — returns 404.
Both are minutes to fix now and a confusing hour to diagnose while wiring the demo.

**Fix:** `res.setHeader("Access-Control-Allow-Origin", "*")` (plus a 204 for `OPTIONS`), and
route on `new URL(req.url, "http://x").pathname`.

### I7 — Startup checks that the addresses are *present*, never that they are *addresses* (Step 9 safety)

`agent/loop.mjs:207-212`, `agent/README.md:8`

The guard tests `!process.env[v]` only. The README's own extraction —
`grep -m1 "^$1=" "$ENV" | cut -d= -f2-` — preserves surrounding quotes, trailing whitespace
and a CR if the file has any. A `WALLET_ADDR` of `"0x46C0…"` (quotes included) or
`0x46C0…\r` flows through `buildIds` into entity ids that match nothing; `fetchSnapshot`
returns `ok: true` with `policy: null` and `payees: {}`, and the demo shows **`NO_POLICY` /
`PAYEE_NOT_ALLOWED` for every intent** — a plausible-looking, completely wrong screen instead
of an error. Same for `LEASH_NODE`.

**Fix:** validate shape at startup — `/^0x[0-9a-fA-F]{40}$/` for `WALLET_ADDR`/`AGENT_ADDR`,
`/^0x[0-9a-fA-F]{64}$/` for `LEASH_NODE`, and `trim()` everything. This is the failure most
likely to burn the live run.

---

## Minor

- **M1** `agent/send.mjs:75` — the 120 s receipt wait is inside the serialized tick, so one
  slow send freezes *all* ticks (two eligible intents → up to 240 s) and the endpoint stops
  updating, breaking the spec's "twelve seconds of silence becomes visible reasoning".
  Consider 60 s.
- **M2** `agent/loop.mjs:150` — `POST /api/agent/tick` during a tick returns 200 with the
  pre-tick state and silently does nothing. The spec calls this the safety valve for a stalled
  index; it should say `{ "ran": false, "reason": "a tick was already running" }`.
- **M3** `agent/loop.mjs:31` — a single failed read nulls `snapshot`, so `agent`/`policy`/
  `budget` all go null in the response and the demo panel blanks for a tick. Retaining the
  last-known snapshot alongside `readError` would be strictly better on stage.
- **M4** `agent/loop.mjs:33` — records for intents deleted from `intents.json` persist in
  `next.intents` and keep appearing in the endpoint.
- **M5** `agent/subgraph.mjs:91` — `lastToken` is lowercased (the Task 3 Important) but no test
  asserts it and nothing consumes it: not in `decide`, not in `publicState`. Dead field.
- **M6** `agent/decide.mjs:49` — `d.agent` being absent (agent not bound, or ids wrong) is
  indistinguishable from "bound and not revoked": `subgraph.mjs:98` builds `agent`
  unconditionally. Money-safe (the chain reverts) but it discards a fact the index holds. See
  also I7 — the same symptom.
- **M7** `agent/loop.mjs:226` — `listen(PORT)` binds `0.0.0.0` and `POST /api/agent/tick` is
  unauthenticated. Bounded (one-shot intents cap the damage at one payment per intent), but
  `listen(PORT, "127.0.0.1")` costs nothing.
- **M8** `agent/loop.mjs:16` — `AGENT_TICK_MS=abc` → `NaN` → `setInterval` clamps to 1 ms. The
  `ticking` guard means no duplicate payments, but it becomes a busy poll of the subgraph.
- **M9** `README.md` (root) — `agent/` appears nowhere; line 309's provenance claim covers
  `src/`, `test/`, `script/`, `subgraph/` only. Possibly item 13's job, but worth not
  forgetting.
- **M10** `agent/send.mjs:79` — noble echoes the value for an out-of-range key
  (`expected valid private key: … got 0`), which would land in `lastAction.error` and the HTTP
  response. Only reachable for keys that are already invalid, so theoretical; noted for
  completeness. I probed four malformed `AGENT_PK` shapes and **no usable key material
  leaked** in any of them.

---

## Test audit — what I actually checked, and what I found

I treated "there is a test for it" as a claim. Checked individually:

**Non-vacuous, premise verified against something outside the test:**

- `decide.test:85` *"limit 0 means unlimited"* — verified against `src/StandardPolicy.sol:28`
  (`if (ctx.periodLimit != 0)`) and `schema.graphql:35` (`limit == 0 means unlimited`). Real,
  not a self-consistent invention.
- `decide.test:69` *"exactly the remaining budget still passes"* — matches the contract's
  strict `amount > periodLimit - spentSoFar` (`StandardPolicy.sol:31`). Correct.
- `subgraph.test:57` *periodEnd must be a Number* — fixture passes the string `"1788998400"`,
  and the live index really does return strings. Real type check.
- `send.test:81` *truncated `SpendBlocked` data* — load-bearing: `BigInt("0x")` throws, the
  length guard is what prevents it.
- `send.test:53` *block wins over executed* — real; two logs, asserts `blocked`.
- `loop.test:101` *inFlight cleared via `finally`* — real (`assert.rejects` plus the
  post-condition).
- `loop.test:77` / `:90` — the timeout and pre-send-failure shapes both match what `tick`
  actually writes (`kind: res.tx ? "sent" : "error"`). The ledger's own mis-probe on this is
  correctly recorded and correctly resolved.
- `subgraph.test:110-148` — all three redaction tests drive the throw path, not the safe 500
  path. The Task 3 defect is genuinely closed.

**One gap worth naming:** `sendSpend` itself has **no test**, and the entire fix for the second
duplicate-payment Critical depends on its producer contract — that a receipt timeout returns
`{ tx, error }` rather than `{ error }`. `loop.test:79` hand-builds that shape; nothing
verifies `sendSpend` emits it. I verified it by reading viem:
`waitForTransactionReceipt.js:37` rejects with `WaitForTransactionReceiptTimeoutError`
**after** `tx` is assigned, so `send.mjs:80`'s `tx ? {tx, error} : {error}` does return the
hash. So the guard is correct — but it rests on a fixture whose producer is untested, which is
the branch's own recurring defect class pointed at itself. Cheap close: make the two viem
clients injectable in `sendSpend` the way `sendImpl` is injectable in `sendAndRecord`, and add
one test for the timeout shape. Not a blocker given the source reading; worth a line in the
ledger so the next reader does not have to re-derive it.

**One overstated claim:** spec 273 says *"The in-flight lock gets its own test — the same
intent evaluated twice in a row while locked must produce one send, not two."* The test
(`loop.test:26`) is real and its fixture is reachable, **but the lock it tests can never fire
in production**: `tick` awaits every send inside the `ticking` window, so `advance` never
observes `inFlight === true`. What actually prevents duplicates in this implementation is
`ticking` + awaited sends + the executed/unconfirmed terminal checks. The in-flight lock is
defence in depth, correctly built and correctly tested — the spec just credits it with the
load-bearing role it does not have. No code change; worth knowing which guard is holding the
weight.

---

## Ledger triage

| Deferred item | My ruling |
|---|---|
| T4 Minor 1 — `shortMessage` never carries a url, `redactUrls` is a net | Agree, no action. I re-checked viem's error classes on the reachable paths. |
| **T4 Minor 2 — `send.mjs` ignores `err.cause`; deferred to "let Step 9 decide"** | **Disagree — fix before Step 9, not after.** viem prepares the request with `eth_estimateGas` and a chain-id assert for local accounts, so the Step-9 failures that actually happen (short MockUSDC balance, no Sepolia ETH, an RPC that 401s) surface as an *estimation* error whose useful detail sits in `err.cause` / `details` / `metaMessages` — precisely what `send.mjs:79` discards, leaving `"HTTP request failed."` or a bare "execution reverted". Step 9 is one supervised run against a finite budget, in front of a person; walking into it with a good error string is the cheap direction. Three lines, mirrors `subgraph.mjs:62`, and `redactUrls` already covers whatever comes out. |
| T5 Minor — `console.log` branches on `a.error` rather than `a.kind` | Agree, cosmetic, leave it. |
| T5 ruling — skipped the round-2 re-review | Fine in outcome; a339335 is inside the whole-branch range and I read every line of it. |
| T3/T5 rulings on the two duplicate-payment Criticals | Both correct, and the fixes are right. Ruling out receipt polling and retry-with-same-nonce four days out was the right call: a stuck intent an operator can look up beats a second payment. |
| Plan's "known gap, deliberate" on `cfg.token = intents[0].token` | **Disagree with the reasoning, not the deferral** — see I4. The gap is fine; the justification describes behaviour the code does not have. |

**Must be fixed before merge:** C1, I2, I7 (one load-time-validation round in one file), I5
(one line), and T4 Minor 2 (before Step 9). **Should land before item 12 is written against
the endpoint:** I3, I4, I6. **Ledger, not the loop:** M1-M10, and the `sendSpend` test gap.

---

## Assessment and verdict

The fail-closed property is **total**, and I pushed on it: `fetchSnapshot` returns `ok: true`
only after `_meta.block.number` type-checks; `decide` returns `unknown-read-failed` on
anything else; `advance` sends only on the literal string `will-pass`; and a partial snapshot
(null `policy`, empty `payees`, null `budget`) yields a block or an `unknown`, never a
`will-pass`. Secrets hold up too: I probed four malformed `AGENT_PK` shapes with no leak, the
`chainBlock` catch (`loop.mjs:164`) swallows everything so no RPC url escapes there,
`lastAction.error` is pre-redacted at source, and `publicState` carries nothing but addresses,
block numbers and already-redacted strings. No file in `agent/` reads `WORLD_RP_SIGNER_PK`,
`WALLET_PK` or `ADMIN_PK` — grep-verified across all eleven files. The module chain agrees end
to end, and I confirmed that against the live index rather than against fixtures.

The duplicate-payment surface is now genuinely well defended on the paths the ledger
identified. C1 is the third path, and it is the one no task-scoped review could have seen,
because it lives in the interaction between an unvalidated input file, `advance`'s use of
`next.intents` as its own lookup, and `tick`'s send loop keying off `intent.id` — three files,
none wrong alone.

**Not ready to finish yet — one Critical.** Fix **C1** (which also closes most of I2's
reachable triggers), and I would do **I2** and **I7** in the same round since all three are
load-time validation in one file and all three bear on Step 9's safety. **I5** is one line and
buys the most demo credibility of anything on this branch. **I3**, **I4** and **I6** should
land before item 12 is written against the endpoint, not after. The Minors can all go to the
ledger; my one disagreement worth acting on is T4 Minor 2, before the live run rather than
after it.

Nothing I found makes the Step 9 live run *unsafe* in the money sense: `intents.json` today
has unique ids and well-formed amounts, gas estimation stops a would-be-reverting spend before
it broadcasts, and the chain-id assert means a wrong-network RPC fails loudly. Before running
it, check the wallet's MockUSDC balance and AGENT's Sepolia ETH, and confirm the extracted env
values have no stray quotes — I7 is the failure most likely to produce a convincing-looking
wrong demo.
