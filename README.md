# Leash

> An onchain policy engine for AI agent wallets. Spending rules live under an ENS name
> where the agent cannot reach them. Loosening a rule requires a live human face;
> tightening one is always free.

**ETHGlobal ETHOnline 2026** · Sepolia · solo entry · [ENS](#ens) · [The Graph](#the-graph) · [World](#world)

---

## The problem

An AI agent that can spend money needs a spending limit. Every existing answer puts
that limit somewhere the agent can reach: a config file it reads, an API key it holds,
a session key with a cap the agent itself enforces. Compromise the agent and the limit
goes with it.

Session keys and allowance lists express *who* and *how much*, but not *whether this
particular payment makes sense*. A settings table cannot answer that.

## The answer

**Express the permission as code, and enforce it onchain.**

Every agent is bound to a **policy contract**. Before any transfer, the wallet resolves
that policy's address **through ENS**, checks it against a **human-approved list**, and
asks it one question. If the answer is not `OK`, no money moves.

The agent has no way around this, because the check happens inside its own execution
path rather than beside it.

```
agent ──▶ EOA.spend(token, payee, amount)
             │
             │  1. authorise the caller from per-wallet storage
             │  2. walk ENS three hops to find the policy      ◀── remove ENS, nothing passes
             │  3. check it against the human-approved list
             │  4. ask the policy; honour the reason code
             ▼
          ERC-20 transfer, or SpendBlocked(reason) and no movement
```

> **What this does not claim.** EIP-7702 constrains only calls *to* the delegated EOA.
> The wallet's own private key can always sign a direct `transfer`, and the policy path
> never runs. That is both the boundary and the escape hatch: the owner can always
> retrieve their own funds and can never be locked out by a policy they installed.
> Leash is the agent's only spending path, not the wallet's.

## Live on Sepolia

Everything below is deployed and was exercised end to end with real tokens on
2026-09-09. Addresses, transaction hashes and a copy-pasteable verification recipe are
in [`docs/deployments.md`](docs/deployments.md).

| Contract | Address |
|---|---|
| `LeashAccount` (EIP-7702 delegate impl) | [`0x136b33c6…B83C`](https://sepolia.etherscan.io/address/0x136b33c68439C1ee8649048bb86E3a98ACd9B83C) |
| `LeashRegistry` (ENSv2 `IRegistry`) | [`0x6fB6CB4a…2A51`](https://sepolia.etherscan.io/address/0x6fB6CB4a789067b2283C4d4C657d3422ce742A51) |
| `LeashResolver` (ENSIP-10) | [`0x607a4d73…915b`](https://sepolia.etherscan.io/address/0x607a4d7363d9E7511a932F82eAE1e12FB609915b) |
| `PolicyApprovals` | [`0x7CB9d4Ac…25B4`](https://sepolia.etherscan.io/address/0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4) |
| `StandardPolicy` | [`0x88F2bfF0…75cc`](https://sepolia.etherscan.io/address/0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b) |
| `LeashLens` | [`0xB6eB4C26…7B83`](https://sepolia.etherscan.io/address/0xB6eB4C26AF866057920f7AB6fAFf69A914067B83) |

Verify the central claim yourself in four `cast` calls — the recipe is in
`docs/deployments.md`. It walks `leash.eth` down to a policy address; point the first
hop at `0x0` and the same walk returns nothing, which is exactly what stops a payment.

## Three keys, deliberately separated

| Key | Holds | Can do | Deliberately cannot |
|---|---|---|---|
| **ADMIN** | `leash.eth`, ENS roles | Repoint policies, issue and revoke agent subnames | **Approve a new policy** — that needs an attestation, and the attester is `immutable` |
| **WALLET** | The money; delegated to `LeashAccount` | Pay (every payment goes through the policy) | Touch ENS — its role bitmap is `0`, not by a check but because it never had one |
| **AGENT** | Nothing | Initiate a spend request | Hold funds or permissions; it is only a `msg.sender` the policy recognises |

A broken policy can at most drain the wallet. It cannot reach the control plane,
because the wallet has no control-plane authority to lend it.

## Expansion needs a human; reduction never does

| Action | `msg.sender == address(this)` | Attestation |
|---|---|---|
| Issue a new agent subname | — | ✅ |
| Raise a limit, allow a token or payee | ✅ | ✅ |
| Restore a revoked agent | ✅ | ✅ |
| **Revoke an agent, tighten a rule, remove a payee** | ✅ | ❌ |
| **Pause the whole wallet** | any bound agent | ❌ |

Expansion is two-of-two: the wallet itself **and** a human. Reduction is free, because
when something has gone wrong nobody should have to find their phone and scan their
face before pulling the brake.

`PolicyApprovals.revoke` goes further and is callable by **anyone**. Revoking only ever
makes the system stricter; gating the brake is how you help an attacker at the worst
possible moment.

## Four ways to stop an agent

| Layer | One transaction | Effect |
|---|---|---|
| light | `LeashResolver.setPolicy(node, stricter)` | Swap the rules |
| medium | `LeashRegistry.revoke(label)` | **That one agent** dies; others untouched |
| **heavy** | `ETHRegistry.setSubregistry(leash.eth, 0x0)` | **Every agent halts at once** |
| — | the subname's `expiry` lapses | **No transaction at all.** Renewal needs a human |

None of the four touches the agent's account. All four were run on Sepolia; the medium
one cost 39,083 gas and the loop is repeatable, so the demo does not consume itself.

## Tracks

### ENS

ENS is load-bearing, not decorative. `LeashRegistry` implements the ENSv2 `IRegistry`
interface (`getSubregistry` / `getResolver` / `getParent`, plus `IERC1155Singleton`) and
is mounted under `leash.eth`, so resolution is forced to pass through it. `LeashResolver`
implements only ENSIP-10 `resolve(bytes,bytes)` — measured fact: minimal ENSv2 resolvers
have no `addr()` or `text()` at all, and a compatibility layer is wasted work.

**ENS's own UniversalResolverV2 resolves our names**, which means `LeashRegistry` is a
first-class citizen of ENS's resolution infrastructure rather than a parallel system.

One permission is deliberately narrowed against ENS convention: a subname holder cannot
set its own resolver. In this model **a name is a leash, not a possession** — it governs
the holder rather than belonging to them.

### The Graph

The subgraph in [`subgraph/`](subgraph) indexes the control plane and every spend
attempt, executed and blocked alike. Its eight entities are shaped by the four questions
the agent actually asks, not by a generic data model — the arithmetic lives in the
mappings, because an untrusted agent that has to sum events itself is an agent that can
get the sum wrong in its own favour.

Blocked attempts are indexable because a policy violation is a **no-op plus an event**,
never a revert. The chain discards a reverted transaction's logs, and the agent could
then never answer *why was I blocked last time?*

### World

Selfie Check gates privilege **expansion** only: raising a limit, whitelisting a payee,
issuing a new agent. Reduction is never gated — see the asymmetry above. Verified
end-to-end on 2026-09-08.

The feedback document the prize asks for is
[`docs/world-feedback.md`](docs/world-feedback.md). It is a dated running log written as
things happened, not reconstructed afterwards, and it is not flattering: five days were
lost to a feature flag that had been enabled the whole time, with no surface anywhere in
the product able to say so.

## Tests

170 unit and fuzz tests, plus 3 fork tests against live Sepolia (skipped when
`SEPOLIA_RPC` is unset, reported as SKIPPED rather than PASSED).

```bash
git clone --recurse-submodules https://github.com/ksin751119/leash
cd leash
cp .env.example .env    # fill in your own three keys
forge test
```

A mutation sweep over the finished branch found **five guards that survived deletion
with every test still green** — including one that was fail-*open*: a policy returning
`256` truncated to `0`, which is `OK`, and the transfer executed. All five are now
pinned by tests that fail when their guard is removed. "The guard exists" and "the guard
is guarded" turned out to be different claims.

## Documentation

| | |
|---|---|
| [`docs/deployments.md`](docs/deployments.md) | Addresses, transactions, and a verification recipe you can paste |
| [`docs/PLAN.md`](docs/PLAN.md) | Architecture, key model, demo script *(Chinese)* |
| [`docs/events.md`](docs/events.md) | **Event schema — frozen before any contract was written** *(Chinese)* |
| [`docs/world-feedback.md`](docs/world-feedback.md) | Developer feedback for the World track |
| [`docs/ensv2-sepolia.md`](docs/ensv2-sepolia.md) | Onchain measurements of live ENSv2 *(Chinese)* |
| [`docs/superpowers/specs/`](docs/superpowers/specs) | `LeashAccount` design, with every overturned decision recorded *(Chinese)* |

## Start from Scratch

Documents under `docs/` written before the event covers planning, prize requirements,
and onchain probing of ENSv2's existing contracts on Sepolia. No project code predates
it.

**Every line under `src/`, `test/`, `script/` and `subgraph/` was written from scratch
starting 2026-09-05.** The commit history is the record, and it is cross-checked by
timestamps nobody can forge: the deployment transactions on Sepolia, the World
verification's server-side `created_at`, and the GitHub push events.
