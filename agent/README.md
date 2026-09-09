# The agent decision loop

Sprint item 10. Reads the subgraph, decides whether each payment in `intents.json` will be
allowed, sends only the ones it believes will pass, and publishes its reasoning.

```bash
ENV=/home/ubuntu/DEV/ETHOnline2026/.env
get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
AGENT_PK="$(get AGENT_PK)" SEPOLIA_RPC="$(get SEPOLIA_RPC)" \
WALLET_ADDR="$(get WALLET_ADDR)" AGENT_ADDR="$(get AGENT_ADDR)" \
LEASH_NODE=0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121 \
  node loop.mjs

curl -s localhost:8788/api/agent/state | jq     # what it currently believes
curl -s -X POST localhost:8788/api/agent/tick   # run one cycle now, do not wait
```

Extract single variables as above. **Never source `.env` wholesale** — it also holds
`WALLET_PK` and `WORLD_RP_SIGNER_PK`, and this process must hold neither.

Startup validates more than presence: `WALLET_ADDR`/`AGENT_ADDR` must be a 20-byte hex
address and `LEASH_NODE` a 32-byte hex hash, after trimming whitespace and a trailing CR (the
`grep | cut` extraction above preserves both, and either flowing through unchanged produces
entity ids that match nothing — the demo would show `NO_POLICY`/`PAYEE_NOT_ALLOWED` for every
intent with no error at all). A quoted value (`"0x46C0…"` with the quotes) is refused by
name; a value with only a stray trailing CR is healed by the trim and accepted. `intents.json`
is validated the same way at load — unique ids, and `token`/`payee` as addresses and `amount`
as a base-unit integer string — because a duplicate id makes `advance` queue it twice and the
second send silently overwrites the first transaction's hash.

## Three things that surprise people

**A block is not a revert.** `LeashAccount` emits `SpendBlocked` and returns normally so the
subgraph can index it. A transaction that "succeeded" may have moved no money — the outcome
is in the logs.

**Restarting re-arms every payment.** Intents are one-shot and that state is in memory, so a
restart makes every executed intent eligible again. That is the intended reset before a
rehearsal, and it is also how you accidentally pay twice.

**A timed-out send leaves an intent `unconfirmed`, not retried.** `send.mjs` waits up to 120s
(ten Sepolia blocks) for a receipt; if that times out, the transaction hash is real but no
outcome was ever classified. The verdict becomes `unconfirmed`, the hash is in
`lastAction.tx`, and the agent will not send that intent again on its own — the payment may
still land, so guessing wrong risks paying it twice. Look the hash up and resolve it by
hand.

## What it cannot predict

Five reason codes are not in the index — 5 `TOKEN_NOT_ALLOWED`, 7 `OVER_TX_LIMIT`,
9 `OUTSIDE_TIME_WINDOW`, 10 `PAUSED`, 11 `OVER_SHARED_LIMIT` — plus 12 `POLICY_FAILED`. None
of those five produce `unknown` on their own: since pre-flight never re-derives the policy
logic that would predict them, they simply do not trigger a block, and if nothing else does
either the verdict is `will-pass`. `will-pass` means "I found nothing forbidding it", never
"this will succeed": `Payee.allowed` is not per-token, so the agent can be optimistic and the
contract is what stops it. When that happens the outcome reads `blocked-despite-green`.

`unknown` means something narrower: the index itself could not answer (no budget row yet for
this token, or the budget row is for a different token). **`advance` does not send on
`unknown`** — an earlier version of this document, the spec and the plan's self-review all
said it does; that was wrong. An intent stuck at `unknown` is not retried by the agent on its
own; it waits for the index to reach a state it can answer, which is the fail-closed
direction.
