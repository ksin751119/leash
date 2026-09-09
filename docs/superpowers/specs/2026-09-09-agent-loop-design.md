# The agent decision loop — design

**Sprint item 10.** Depends on item 9 (the subgraph, live at
`https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4`). Feeds item 12 (the
single-page frontend) and item 13 (the end-to-end rehearsal).

**Goal.** A process that acts as the AI agent: it reads the policy state from the subgraph,
decides whether each payment it wants to make will be allowed, sends only the ones it
believes will pass, and exposes its reasoning over HTTP so the frontend can render it.

---

## The fact that shapes everything

**A policy block does not revert.** `src/LeashAccount.sol:802` states the reason in the
code itself: emit `SpendBlocked`, return normally, *"because the subgraph has to be able to
index"*. The transaction succeeds and carries a reason code. This is what makes the subgraph
load-bearing rather than decorative — the agent's answer to "why am I stuck" comes from the
index, not from a revert string.

`src/Reason.sol:8` names the agent as a required consumer of the codes: *"The numbers must
never be renumbered: the subgraph, the frontend and the agent all depend on them."*

---

## Five decisions

### 1. Where reads come from: receipts for the immediate result, the subgraph for state

A transaction receipt answers "what happened to the call I just made". The subgraph answers
"what do I know about the world" — allow-lists, budgets, and the approval overlay that spans
two contracts. Those are different questions and they get different sources.

Rejected: reading everything from receipts, which would reduce the subgraph to "we deployed
one" rather than "the agent cannot decide without it". Also rejected: reading everything
from the subgraph, because waiting for an index to confirm a transaction you already hold a
receipt for is latency bought for nothing.

### 2. The agent pre-flights: it decides before sending

Given a payment intent, the agent reads the state, predicts whether the chain will allow it,
and sends only if it believes it will pass. When it believes it will not, it reports the
reason and does not send.

Rejected: attempt-and-learn (send blindly, read the block reason afterwards). It produces a
live `SpendBlocked` event, which is a nice demo artefact, but an agent that could have known
and sent anyway is not exercising judgement.

Also rejected, more firmly: pre-flighting and *then sending anyway* to leave an audit trail.
Paying gas to record an event whose answer you already hold is not an audit trail, it is
theatre, and the first question it invites is "why did it send?"

### 3. The loop is autonomous, with visible per-tick reasoning and a manual trigger

The loop polls every 5 seconds. After a human authorises a widening, the agent notices on
its own and completes the payment — nobody types a command.

Measured 2026-09-09: the subgraph runs **0-1 blocks behind chain head** (about 0-12s), so
autonomy is viable on stage. That wait is only acceptable because every tick prints its
current verdict, which turns twelve seconds of silence into visible reasoning. A manual
`POST /api/agent/tick` exists as the safety valve, so a stalled index does not mean
restarting a process in front of an audience.

### 4. The frontend reads one endpoint; it does not query the subgraph itself

`GET /api/agent/state` is the single source of truth for item 12.

Rejected: the frontend querying the subgraph independently. Two readers with different
latencies produce a screen that contradicts itself — the page saying "allowed" while the
agent still says "I am not sending" — and that failure appears only under demo conditions.

### 5. A separate process holding only `AGENT_PK`

`docs/architecture.md:68` says AGENT *"holds nothing"*, can only call `spend`, and
deliberately cannot hold permissions or change any rule. `world/server.mjs` holds
`WORLD_RP_SIGNER_PK`, which can authorise **any** widening.

Putting the loop in that process would give one process both keys, so a bug in the agent
could reach the key that signs widenings. That inverts the security model the project is
built to demonstrate: asked "what happens if the agent is compromised", the separated answer
is "it can call `spend`, and `spend` always goes through the policy". The combined answer is
"it can sign an arbitrary widening."

One more terminal window is a cheap price for that.

---

## Architecture

`agent/loop.mjs`, its own process, port **8788** (the attestation harness owns 8787). Reads
exactly three environment variables — `AGENT_PK`, `SEPOLIA_RPC`, and `SUBGRAPH_URL`
(defaulting to the live endpoint above) — plus `AGENT_TICK_MS`, default 5000. It never reads
`WORLD_RP_SIGNER_PK`, `WALLET_PK`, or `ADMIN_PK`, and must never be started by sourcing
`.env` wholesale.

Each tick:

1. **One GraphQL query** for everything the decision needs — `Agent.revoked`,
   `PolicyPointer` (policy address and whether a human approved it), `Payee.allowed`,
   `AgentBudget` (`remaining`, `limit`, `periodEnd`), `Subname` (for `label` and `live`), and
   `_meta.block.number`.

   Note the `label` in the state shape below comes from `Subname`, **not** from `Agent` —
   the `Agent` entity carries only `agent`, `node`, `wallet` and `revoked`. `Subname` is
   keyed by node and holds `label`, `live` and `expiry`.
2. **Pre-flight** each intent against that snapshot.
3. **Send** the intents predicted to pass, and read each result from its receipt.
4. **Publish** the whole snapshot, verdicts and outcomes at `GET /api/agent/state`.

Intents come from `agent/intents.json` — a plain list, no queue and no scheduling. Amounts
are **base units as decimal strings, never numbers**: MockUSDC has 6 decimals (verified
onchain 2026-09-09), so `"100000000"` is 100 USDC. Strings because a `uint256` does not
survive JSON's float, and base units because the deployed rule is expressed in them —
`txLimit` 500000000 and `periodLimit` 1000000000, i.e. 500 and 1000 USDC.

---

## Pre-flight: what it predicts, and what it deliberately does not

The subgraph states these as facts, so pre-flight uses them:

| Reason | Source |
|---|---|
| 2 `AGENT_REVOKED` | `Agent.revoked` |
| 3 `NO_POLICY` | `PolicyPointer.policy` missing |
| 4 `POLICY_NOT_APPROVED` | `PolicyPointer.approved` |
| 6 `PAYEE_NOT_ALLOWED` | `Payee.allowed` |
| 8 `OVER_PERIOD_LIMIT` | `AgentBudget.remaining`, `periodEnd` |

These are **not** indexed and pre-flight returns `unknown` for them: 5 `TOKEN_NOT_ALLOWED`,
7 `OVER_TX_LIMIT`, 9 `OUTSIDE_TIME_WINDOW`, 10 `PAUSED` (none of `txLimit`, `paused` or the
time window appear in the schema), 11 `OVER_SHARED_LIMIT` (kept in the policy's own ledger),
and 12 `POLICY_FAILED` (unpredictable by nature).

**Pre-flight must not close that gap by re-deriving policy logic.** Completing it would mean
reimplementing `StandardPolicy` in JavaScript — per-transaction limits, time windows, period
alignment. On 2026-09-09 this project shipped and then caught a Critical of exactly that
shape: `hashSignal` reimplemented a hashing rule in JavaScript, diverged from the real one,
and **no test could see it** because both sides were self-consistent. Copying policy logic
into a second language four days from a deadline repeats the mistake deliberately.

So pre-flight stays shallow: it reads conclusions the index already states, never derives
them. What it cannot see, it sends and lets the chain answer.

### Pre-flight is trustworthy when it refuses, not when it permits

`subgraph/schema.graphql` documents that `Payee.allowed` is keyed by `(node, payee)` and not
by token, because the frozen `PayeeAllowed` event carries no token. An agent reading
`allowed: true` may therefore be **optimistic for a second token**, and the account is what
stops it.

Combined with the `unknown` rows above, this fixes the contract of the whole component:

- pre-flight says **will be blocked** → do not send. Safe, saves gas, and this is the beat
  the demo shows.
- pre-flight says **will pass** → send, and handle the case where the chain blocks anyway.

That case is recorded as `blocked-despite-green` rather than treated as a bug, because it is
the project's own thesis in miniature: **the agent's optimism is bounded by the contract.**
Even when the agent is wrong, no money moves.

---

## The state endpoint

`GET /api/agent/state` returns the current snapshot:

```json
{
  "tick": 42,
  "at": "2026-09-09T12:00:00Z",
  "source": { "subgraphBlock": 11667861, "chainBlock": 11667862, "lagBlocks": 1 },
  "agent": { "address": "0x…", "revoked": false, "node": "0x…", "label": "vendors" },
  "policy": { "address": "0x…", "approved": true },
  "budget": { "token": "0x…", "limit": "1000000000", "spent": "…", "remaining": "…", "periodEnd": 0 },
  "intents": [
    {
      "id": "newvendor",
      "verdict": "will-be-blocked",
      "reason": 6,
      "reasonName": "PAYEE_NOT_ALLOWED",
      "explain": "this payee is not on the allow-list; widening it needs a face scan",
      "lastAction": null
    }
  ]
}
```

Three deliberate choices:

- **`source` carries both block numbers and the lag.** The twelve-second wait becomes a
  number on screen instead of silence.
- **`verdict` is three-valued** — `will-pass`, `will-be-blocked`, `unknown` — so the five
  reasons the index cannot see are visibly "I do not know, I have to ask the chain" rather
  than silently optimistic.
- **`lastAction.outcome` can be `blocked-despite-green`**, which is where the honesty above
  becomes something the frontend can point at.

`POST /api/agent/tick` takes no arguments and runs one cycle immediately.

---

## Error handling

**Duplicate payments are the dangerous failure, and they only appear live.** The tick is 5s
and Sepolia blocks are ~12s, so a naive loop sends the same intent two or three times before
the first confirms. Each intent therefore holds an in-flight lock from send until its receipt
arrives or it times out; while locked its verdict reads `in-flight` and it is not
re-evaluated.

**Fail closed on a read failure.** If the subgraph is unreachable, returns GraphQL errors, or
omits `_meta`, every verdict for that tick is `unknown-read-failed` and **nothing is sent**.
The endpoint still answers, carrying the error. The agent's default under uncertainty is to
do nothing.

**Stale data, by direction:**

- **Stale-restrictive** (the index has not yet seen a widening) — harmless; the agent waits
  one more block. This is the demo's twelve seconds.
- **Stale-permissive** (the index has not yet seen a `removePayee`) — the agent sends and the
  chain blocks it. Recorded as `blocked-despite-green`; not a bug to fix.

**A failed send is not retried.** It is recorded in `lastAction.error` and re-evaluated next
tick. Retry logic is another way to produce duplicate payments.

---

## Testing

**`decide(snapshot, intent) → { verdict, reason }` is a pure function.** Fixture-driven, no
network: one case per predicted reason (2, 3, 4, 6, 8), plus one per `unknown` reason.

**Pin the reason numbers across all three tables.** `src/Reason.sol` is the authority;
`subgraph/src/reason.ts` is the second table and the agent's is the third. A check reads the
Solidity constants and asserts the JavaScript table matches, so a renumbering fails loudly
instead of silently mislabelling what the agent tells a judge. This is the right use of the
2026-09-09 lesson: anchor what can be anchored independently, and do not reimplement what
cannot.

**The in-flight lock gets its own test** — the same intent evaluated twice in a row while
locked must produce one send, not two.

**Deliberately not tested:** an anvil end-to-end check that pre-flight's predictions match
the contract. It would require rebuilding the wallet, policy and ENS wiring locally, and it
buys little, because pre-flight holds no derived logic that could drift.

---

## Out of scope

Intent scheduling or a persistent queue. Multiple agents. Retry and backoff strategies.
Reading `ruleOf` from the chain to complete pre-flight (see above — that is the point).
Any write other than `spend`: the agent cannot widen, approve, or bind, and nothing in this
component should make that look possible.
