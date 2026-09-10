# The demo frontend — design

> Sprint item 12. Written 2026-09-10, after the classification and the decisions recorded
> below. Feeds item 13 (rehearsal) and item 15 (the video).

**Goal.** One page that shows the agent's reasoning live and hosts the face scan, so the
demo's central beat — a machine is refused, a human's face changes the rule, the machine
notices on its own — happens **on a single screen** without cutting away.

---

## Why this page exists at all

The judging that matters for our three partner prizes is **asynchronous**: judges watch the
2–4 minute video and read the repo. Only the top 20% reach live judging. So the page's real
audience is a 720p screen recording, watched once, at speed.

Two ETHOnline rules bind the design directly:

- **No speed-ups in the video.** A Sepolia block is ~12s and the agent ticks every 5s, so
  roughly 15–20 seconds of wall clock will sit in the recording uncut. That time has to
  *show* something.
- **Usability (UI/UX/DX) is one of five judging criteria.** This page is a fifth of the
  score, not a garnish.

## Scope

| In | Out |
|---|---|
| Rendering `GET /api/agent/state` | Any judgement of its own — see the constraint below |
| Hosting IDKit and calling `POST /api/attest` | Sending `allowPayee` from the browser |
| Producing a paste-ready `cast send` command | Holding or touching `WALLET_PK` |
| Showing the policy pointer as a first-class fact | Anything to do with `PolicySet` (sprint item, lands 9/11) |
| **Widening `publicState()` — see below** | Changing any decision the agent makes |

**The wallet's key never enters the browser or the server.** `allowPayee` stays a terminal
command the operator runs. Putting a funded key behind a web page would contradict the
security claim the whole project is making — and a judge asking "so where does `WALLET_PK`
live?" would end the conversation.

---

## Constraint: the page computes nothing

The page renders what the agent already decided. It never derives a verdict, never
re-implements `decide()`, never reads the chain to second-guess a reason code.

This is not tidiness. The demo's claim is **"the agent worked this out for itself"** — if the
verdict shown on screen were computed in the browser, the demo would be staged, and the one
thing being demonstrated would be the thing that was faked.

Everything on screen therefore traces to a field of `publicState()`.

### `publicState()` is short of two things, and both must be added

Today it returns:

```
tick, at, source, readError, tickError,
agent, subname, policy, budget,
intents[{ id, note, verdict, reason, reasonName, explain, lastAction }]
```

Two facts the layout needs are missing, and neither can be reconstructed in the browser
without the page computing something — which the constraint above forbids:

| Missing | Where it exists today | Why the page needs it |
|---|---|---|
| `payee`, `token`, `amount` per intent | only in the input `intents` array; `advance()` copies `id` and `note` into the record and drops the rest | the page cannot say who an intent pays, or how much |
| `payees` — the allow-list map | `fetchSnapshot()` returns it and `decide()` uses it, but `publicState()` does not forward it | the RULES column is the allow-list; without it there is nothing to draw the connector to |

**Both changes are additive.** `advance()` copies three more fields onto the record it
already builds; `publicState()` forwards two values it already holds. **No branch in
`advance()` changes**, and in particular none of the four duplicate-payment guards is
touched. The plan must treat that as a hard boundary — this is the module where four
separate double-pay paths were found.

A payee that was never allowed has **no `Payee` entity in the subgraph at all**, so it is
absent from the map rather than present with `allowed: false`. The page renders the payee of
each intent and marks it allowed only when the map says so; absence reads as "not allowed",
which is also how `decide()` treats it.

---

## Where it lives

| Decision | Why |
|---|---|
| Served by `world/server.mjs` on **:8787** | Same origin as `/api/config` and `/api/attest`, which IDKit needs |
| Polls `http://localhost:8788/api/agent/state` | `agent/loop.mjs` already sends `Access-Control-Allow-Origin: *`, so no routing or CORS change is needed — only the payload widens, as set out above |
| `GET /` serves the demo page; the existing harness moves to `GET /harness` | The demo is the front door during judging; the harness stays reachable because it is the tool you need when the demo misbehaves |
| One static HTML file, no build step, no framework | Matches `world/index.html`. A build step is one more thing to fail at 3am on 9/13 |

`world/index.html` is otherwise **unchanged**. It is a debugging harness — its own `<h1>`
says so — and rewriting it would cost the fallback.

### Files

| Action | File | What |
|---|---|---|
| create | `world/demo.html` | The page: markup, styles, render functions, polling |
| create | `world/widen-plan.mjs` | Digest lookup and command construction, so it is testable without a server |
| create | `world/widen-plan.test.mjs` | Tests for the above |
| modify | `world/server.mjs` | `GET /` → demo, `GET /harness` → the old page, `GET /api/widen-plan`, startup env guard |
| modify | `agent/loop.mjs` | `advance()` copies `payee`/`token`/`amount`; `publicState()` forwards them and `payees` |
| modify | `agent/loop.test.mjs` | New assertions only; **no existing test edited** |
| unchanged | `world/index.html`, `agent/decide.mjs`, `agent/subgraph.mjs`, `agent/send.mjs`, all contracts, `subgraph/` | |

---

## New endpoint: `GET /api/widen-plan`

The IDKit `signal` must be the EIP-712 digest that `allowPayee` will consume. Today the
harness has the operator paste `$DIGEST` from a shell; `world/index.html:105` already warns
about that pattern.

**Request**

```
GET /api/widen-plan?payee=0x00000000000000000000000000000000000cafe0
```

**Response 200**

```json
{
  "digest":  "0x…64 hex",
  "nonce":   "1757500000",
  "node":    "0x9b4cc576…",
  "token":   "0x768f4245…",
  "payee":   "0x…cafe0",
  "command": "cast send $LEASH_WALLET \"allowPayee(bytes32,address,address,uint256,bytes)\" …"
}
```

**Behaviour**

1. Validate `payee` against `/^0x[0-9a-fA-F]{40}$/`; anything else is `400`.
2. `nonce = Math.floor(Date.now() / 1000)`.
3. `eth_call` `payeeDigest(bytes32,address,address,uint256)` on `LEASH_WALLET` via
   `SEPOLIA_RPC`.
4. Build the `cast send` string with **`$WALLET_PK` as a literal shell variable name**, never
   a value. The operator's own shell resolves it.
5. Any RPC failure returns `502` with the URL redacted, reusing `redactUrls()`'s approach.

**New env**, guarded at startup the way `checkAttestEnv` guards the attest route:
`SEPOLIA_RPC`, `LEASH_WALLET`, `LEASH_NODE`, `LEASH_TOKEN`.

**A limit, stated because it is real.** `LeashAccount` exposes no getter for
`attestationUsed`, so this endpoint cannot prove the digest is unspent. A second-resolution
nonce makes a collision implausible within one demo, and a replayed digest fails on chain
with `AttestationReused` rather than doing damage. Not worth a contract change on 9/10.

---

## Layout

Two fixed columns. Nothing scrolls, nothing reflows, and **the verdict flips where the
viewer is already looking**.

```
┌───────────────────────────────┬────────────────────────────────┐
│  AGENT                        │  RULES                         │
│  tick 47 · read the subgraph  │  policy   0x88F2…   ✓ approved │
│                               │  budget   310 / 1000 USDC      │
│  ▸ retainer      will-pass    │  payees   0x…beef   ✓          │
│    0x…beef  5 USDC            │           0x…cafe0  ✗          │
│                               │                                │
│  ▸ newvendor     BLOCKED   ───┼──▶ ┌──────────────────────────┐│
│    0x…cafe0 5 USDC            │    │  Widening needs a human  ││
│    6 PAYEE_NOT_ALLOWED        │    │  [ Approve this payee ]  ││
│                               │    └──────────────────────────┘│
└───────────────────────────────┴────────────────────────────────┘
```

A single-column timeline was considered and rejected: a log scrolls, so at 720p the line
that matters moves off the spot the viewer is watching.

The blocked intent is joined to the rule that blocks it by a drawn connector. That link is
the demo's whole argument in one glyph — *this* refusal comes from *that* rule.

**Legibility target: readable in a 720p full-screen recording.** Body text no smaller than
16px at a 1280×720 viewport; reason codes and addresses in mono; verdicts carried by colour
**and** by a word, never colour alone.

---

## The wait, made legible

Between the `allowPayee` transaction and the verdict flipping there are three distinct
waits. Showing them separately turns dead air into the mechanism:

| Stage | Source | Shown as |
|---|---|---|
| Attestation signed, command not yet run | the `/api/attest` response | `signed · valid for 15 min · run the command` |
| Chain ahead of the index | `source.chainBlock`, `source.subgraphBlock`, `source.lagBlocks` | `subgraph is N blocks behind` |
| Next tick | `tick` and `at`, against `TICK_MS` | `next tick in 3… 2… 1` |

**The page never polls the RPC and never asks the operator to paste a transaction hash.**
Both were considered; both were rejected. Polling the chain would put chain-reading in the
browser, which is the "page computes nothing" constraint again, and a pasted hash is one
more thing to fumble on camera. `source` already carries both block numbers, so the lag is
observable without either.

`AGENT_TICK_MS=2000` is the documented setting for recording. The default stays 5000.

---

## Error states are shown, never swallowed

`readError` and `tickError` render as a banner. When the agent cannot read the subgraph it
fails closed and stops proposing anything — the page must say **"the agent is blind"** rather
than showing a stale-but-calm screen.

This is worth screen time rather than hiding: a system whose failure direction is safe is
the claim, and the page is where it becomes visible.

---

## Testing

Node's built-in runner, matching `agent/*.test.mjs`.

| What | How |
|---|---|
| `/api/widen-plan` rejects a malformed payee | `400`, no RPC call made |
| It never emits a key | assert the command contains `$WALLET_PK` and **not** the value of `WALLET_PK` |
| RPC failure redacts the URL | stub a failing fetch; assert the URL is absent from the body |
| Startup guard | missing `LEASH_WALLET` refuses at boot, like `checkAttestEnv` |
| `advance()` carries the new fields | a record for a fresh intent has `payee`, `token`, `amount` matching the input |
| **`advance()`'s behaviour is unchanged** | the existing `loop.test.mjs` suite passes untouched — no test may be edited to accommodate the new fields |
| `publicState()` forwards `payees` | with a snapshot, the map is present; with `readError`, it is `{}` and not stale |
| Rendering | pure render functions take a `publicState()` fixture and return strings/DOM; fixtures cover will-pass, will-be-blocked, unknown, `readError`, and a null budget |

The render functions are separated from the DOM wiring precisely so they can be tested
without a browser. **There is no Chrome on the build machine**, so no test may depend on one,
and the visual result is verified by a human opening the page.

---

## Out of scope, recorded so it is not re-litigated

| Not doing | Why |
|---|---|
| Sending any transaction from the page | `WALLET_PK` in a browser contradicts the project |
| A framework or bundler | One file, no build step, matches the rest of `world/` |
| WebSocket / SSE | A 1s poll against localhost is simpler and fails more obviously |
| Mobile layout | The audience is a 720p desktop recording |
| Showing `PolicySet` | Lands 9/11; the policy pointer is already first-class, so it needs no layout change |
| Authentication | Loopback-bound, single operator |
