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

Every agent is bound to a **policy contract**. Before any agent-initiated transfer, the
wallet resolves that policy's address **through ENS**, checks it against a
**human-approved list**, and asks it one question. If the answer is not `OK`, no money
moves.

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
| `LeashAccount` (EIP-7702 delegate impl) | [`0x55528C70…7f23`](https://sepolia.etherscan.io/address/0x55528C707Bff43175CC7d7fCe6D9767060C67f23) |
| `LeashRegistry` (ENSv2 `IRegistry`) | [`0x6fB6CB4a…2A51`](https://sepolia.etherscan.io/address/0x6fB6CB4a789067b2283C4d4C657d3422ce742A51) |
| `LeashResolver` (ENSIP-10) | [`0x607a4d73…915b`](https://sepolia.etherscan.io/address/0x607a4d7363d9E7511a932F82eAE1e12FB609915b) |
| `PolicyApprovals` | [`0x7CB9d4Ac…25B4`](https://sepolia.etherscan.io/address/0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4) |
| `StandardPolicy` | [`0x88F2bfF0…75cc`](https://sepolia.etherscan.io/address/0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b) |
| `LeashLens` | [`0xB6eB4C26…7B83`](https://sepolia.etherscan.io/address/0xB6eB4C26AF866057920f7AB6fAFf69A914067B83) |
| `WorldAttester` | [`0xa4E208dA…5F26`](https://sepolia.etherscan.io/address/0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26) |

The `LeashAccount` impl above is the **current** one — it was redeployed the same day to
switch its attester; the superseded impl and the full history are in
[`docs/deployments.md`](docs/deployments.md).

Verify the central claim yourself in four `cast` calls — the recipe is in
`docs/deployments.md`. It walks `leash.eth` down to a policy address; point the first
hop at `0x0` and the same walk returns nothing, which is exactly what stops a payment.

## Three keys, deliberately separated

| Key | Holds | Can do | Deliberately cannot |
|---|---|---|---|
| **ADMIN** | `leash.eth`, ENS roles | Repoint policies, issue and revoke agent subnames | **Approve a new policy** — that needs an attestation, and the attester is `immutable` |
| **WALLET** | The money; delegated to `LeashAccount` | Pay — every **agent-initiated** payment goes through the policy; the wallet's own key is not constrained (see above) | Touch ENS — its role bitmap is `0`, not by a check but because it never had one |
| **AGENT** | Nothing | Initiate a spend request | Hold funds or permissions; it is only a `msg.sender` the policy recognises |

A broken policy can at most drain the wallet. It cannot reach the control plane,
because the wallet has no control-plane authority to lend it.

## Expansion needs a human; reduction never does

| Action | `msg.sender == address(this)` | Attestation |
|---|---|---|
| Issue a new agent subname | — | ✅ |
| Raise a limit, allow a token or payee | ✅ | ✅ |
| Restore a revoked agent | ✅ | ✅ |
| **Tighten a rule, remove a payee** | ✅ | ❌ |
| **Revoke or unbind an agent** | self **or that agent** | ❌ |
| **Pause the whole wallet** | any bound agent | ❌ |

Expansion is two-of-two: the wallet itself **and** a human. Reduction is free, because
when something has gone wrong nobody should have to find their phone and scan their
face before pulling the brake.

One exception to "unbind is free": `unbindAgent` refuses a binding that is currently
revoked (`RevokedNeedsRestore`), rather than deleting it for free. Deleting a revoked
binding would clear its `node` back to zero, and `bindAgent`'s guard against rebinding
an existing agent only fires while `node` is non-zero — so a free delete would let
`revoke → unbind → bind` reactivate **that same agent address** with no attestation,
sidestepping the "Restore a revoked agent" row above entirely. Refusing costs nothing in
capability: a revoked agent is already powerless, so this only forfeits storage cleanup.
The one route back to an active binding for that address is `restoreAgent`, attested as
the table says.

**What this does and does not claim:** it is re-activating *that revoked address* that
now needs an attestation — not "getting a working agent on this node needs a face scan."
The wallet key alone can still bind a **fresh** agent address to the same node for free,
with no attestation, the moment after a revoke. That is by design, not a gap:
`bindAgent` grants authority starting from zero, and the *content* of that authority
comes entirely from the ENS side and the approval list, neither of which the new address
can touch on its own — see `bindAgent`'s own note on why binding points in the reducing
direction.

`PolicyApprovals.revoke` goes further and is callable by **anyone**. Revoking only ever
makes the system stricter; gating the brake is how you help an attacker at the worst
possible moment.

> **The Attestation column above is now real for `LeashAccount`, and still a mock for two
> other contracts — the two claims are separate, so here they are separately.**
>
> [`WorldAttester`](src/WorldAttester.sol) is deployed, and `LeashAccount`'s current impl is
> wired to it. `setRule`, `allowToken`, `allowPayee` and `restoreAgent` each now require a
> valid EIP-712 signature from the World RP signer over that exact call's digest and
> deadline, checked onchain — not just any bytes. Proved with free static calls against the
> re-delegated wallet: `allowPayee` with 73 junk bytes, and separately with no bytes at all,
> both revert `NotAttested()`; under the old `MockAttester` wiring both would have been
> accepted. Addresses, the re-delegation transaction, and the readback that confirms nothing
> else moved are in [`docs/deployments.md`](docs/deployments.md).
>
> **`MockAttester`** — which returns `true` for **any** input — **is still deployed and
> still used**, by `PolicyApprovals.approve` and `LeashRegistry.register`. That is a
> deliberate scoping decision, not an oversight: only `LeashAccount`'s widening paths became
> real. So "approve a new policy" and "issue a new agent subname" in the table above still
> accept any input; `describe()` on each contract says which it is wired to, and a UI reading
> it cannot pretend otherwise.
>
> **The digest path has never been exercised against World's live API.** The World action
> behind this deployment allows exactly one verification, and it was still unspent at
> deployment time — reserved for the demo, because `max_verifications` cannot be raised. So
> "widening needs a live human" currently rests on code correctness plus a hardcoded
> measurement against IDKit's own bundle, not an end-to-end run. The first live proof of the
> full chain will be the demo itself.
>
> **What `WorldAttester.verify` proves, stated exactly:** the RP signer signed this precise
> digest before its deadline — not "a human approved this." The link to an actual human is
> offchain: World App runs Selfie Check → World's v4 endpoint verifies the proof → the
> backend signs only after that call returns HTTP 200. See the World section below for what a
> proof does and does not establish about who was in front of the camera.

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

**Live on Subgraph Studio, indexing real Sepolia events:**

```
https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.5
```

One query answers all four of the agent's questions; the copy-pasteable version and what it
returns against the run above are in [`docs/deployments.md`](docs/deployments.md).

The subgraph in [`subgraph/`](subgraph) indexes the control plane and every spend
attempt, executed and blocked alike. Its eight entities are shaped by the four questions
the agent actually asks, not by a generic data model — the arithmetic lives in the
mappings, because an untrusted agent that has to sum events itself is an agent that can
get the sum wrong in its own favour.

Blocked attempts are indexable because a policy violation is a **no-op plus an event**,
never a revert. The chain discards a reverted transaction's logs, and the agent could
then never answer *why was I blocked last time?*

Deploying it found a defect no test existed to catch: `Payee` was keyed by
(node, token, payee) while `PayeeAllowed` and `PayeeRemoved` — the only authority for
whether a payee is allowed — carry no token. That produced **two rows for one payee that
disagreed**, and after a removal the row an agent would naturally read still said
`allowed: true`. Wrong in the permissive direction. The chain still blocked the spend, so
nothing was at risk, but the agent's decision was wrong. Now keyed by (node, payee), with
the residual imprecision stated in the schema rather than papered over.

The honest version of that sentence is that **there were no subgraph tests at all** — code
review pointed out that one matchstick case over
`PayeeAllowed → SpendExecuted → PayeeRemoved` would have caught it directly. There are
eight now, and every mutation was run to prove they are not vacuous: restoring the old
(node, token, payee) key fails four of them with exactly the original symptom
(`Expected value was '1' but actual value was '2'` — one payee, two rows), and removing
the one guard in `handleSpendExecuted` fails precisely the one test written for it.

The review's last note turned out to be the same defect one layer down, and wider than it
was reported. `AgentBudget`, `Payee` and `Agent` were all keyed without the wallet — but
`rules`, `payees`, `spent` and `bindings` **all live in the delegated EOA's own storage**,
so two wallets binding an agent to the same ENS node have separate budgets and allow-lists
on chain and were being merged into one row off chain. `AgentBudget` is the worst of the
three: "how much is left" is the number the agent trusts most. Invisible with one wallet,
silently wrong with two — the same shape as the defect above, which is why it is fixed
rather than noted. Dropping the wallet from the ids again fails six of the eight tests.

### World

Selfie Check gates privilege **expansion** only: raising a limit, whitelisting a payee,
issuing a new agent. Reduction is never gated — see the asymmetry above.

Verified end-to-end on **2026-09-07** with the production World App and a real selfie —
no Sandbox App was needed, because Sandbox exists to simulate the Orb and Selfie Check
does not use one. That verification exercised the **offchain** half: the backend in
`world/` receives the proof and verifies it against World's v4 endpoint. The onchain
`IAttester` behind `LeashAccount`'s widening paths is now `WorldAttester`, not the mock —
see the callout above — but the digest path from a live proof through to an onchain
`verify()` call has not itself been run end to end: the action reserved for that allows
exactly one verification, and it is being saved for the demo rather than spent here.

One limit worth stating rather than glossing: **a proof cannot prove it came from Selfie
Check.** A successful verification returns `credential_type: "device"`, identical to the
deprecated `deviceLegacy`. "A real human's face was checked" lives only in the app's
`enable_face_check` setting, not in the proof. Leash's human-in-the-loop guarantee is
therefore a configuration-level guarantee, not a cryptographic one.

The feedback document the prize asks for is
[`docs/world-feedback.md`](docs/world-feedback.md). It is a dated running log written as
things happened, not reconstructed afterwards, and it is not flattering: five days were
lost to a feature flag that had been enabled the whole time, with no surface anywhere in
the product able to say so.

## Tests

201 unit and fuzz tests, plus 3 fork tests against live Sepolia, plus 8 matchstick tests
for the subgraph mappings. The fork tests call
`vm.skip` in `setUp` when `SEPOLIA_RPC` is unset, so `forge test` prints
`201 passed, 0 failed, 1 skipped (202 total)` — one skip for the suite, not three. They
are reported as SKIPPED rather than quietly PASSED, which is the point of using
`vm.skip` over a bare `return`.

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

**Running the subgraph tests takes one workaround.** `graph test` only ships matchstick
binaries for Ubuntu 22 and 24, so on 25.04 it refuses with
`Unsupported platform: Linux x64 25`. The `binary-linux-22` release from
`LimeChain/matchstick` runs fine once `libpq.so.5` is on the library path:

```bash
curl -sL -o matchstick \
  https://github.com/LimeChain/matchstick/releases/download/0.6.0/binary-linux-22
chmod +x matchstick && (cd subgraph && ../matchstick)   # 8 passed
```

On Ubuntu 22 or 24, `cd subgraph && npm test` is enough.

## Documentation

| | |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | **Start here.** What is enforced, by what, and what is not claimed |
| [`docs/deployments.md`](docs/deployments.md) | Addresses, transactions, and a verification recipe you can paste |
| [`docs/PLAN.md`](docs/PLAN.md) | The full working document, including every overturned decision |
| [`docs/events.md`](docs/events.md) | **Event schema — frozen before any contract was written** |
| [`docs/world-feedback.md`](docs/world-feedback.md) | Developer feedback for the World track |
| [`docs/ensv2-sepolia.md`](docs/ensv2-sepolia.md) | Onchain measurements of live ENSv2 |
| [`docs/superpowers/specs/`](docs/superpowers/specs) | Design documents, approved before implementation started, with every overturned decision recorded |
| [`docs/superpowers/plans/`](docs/superpowers/plans) | The task-by-task implementation plans those specs became |
| [`docs/superpowers/sdd/`](docs/superpowers/sdd) | The working ledgers — every dispatch, review and ruling, uncleaned |

## Start from Scratch

What exists under `docs/` from before the event is planning, prize requirements, and
onchain probing of ENSv2's already-deployed contracts on Sepolia. No project code
predates the event.

**Every line under `src/`, `test/`, `script/` and `subgraph/` was written from scratch
starting 2026-09-05.** The commit history is the record, and it is cross-checked by
timestamps nobody can forge: the deployment transactions on Sepolia, the World
verification's server-side `created_at`, and the GitHub push events.

## How AI was used

This project was built by one person working with Claude Code (Claude Opus 5) in a
spec-driven workflow. Stated plainly, because the rules ask for it and because a vague
answer here would be worse than an honest one.

### Where AI assisted

| Area | Lines | How it was produced |
|---|---|---|
| `src/` — the contracts | 2,454 | Written by Claude Code from an approved spec, then reviewed |
| `test/` — the Foundry tests | 3,371 | Same |
| `agent/`, `world/` — the offchain services | 2,374 | Same |
| `subgraph/` — schema, mappings, tests | 886 | Same |
| `script/` | 261 | Same |
| `docs/` | 4,022 | Drafted by Claude Code, corrected against onchain measurements |

There is no file in this repository that Claude Code did not touch. Presenting any part of
it as hand-written would be false.

### What the human did

- **Every design decision, including the ones that were overturned.** The specs record the
  arguments; the choices in them were made by the human rather than proposed and accepted
  wholesale. `docs/PLAN.md` keeps the superseded reasoning visible for exactly this reason.
- **Approved each spec before implementation began** — the gate the whole workflow is built
  around.
- **Held every key.** No private key was ever placed in an AI context: the wallet signed its
  own EIP-7702 authorisation, and each deployment was run by the human.
- **Did the World integration by hand** — the Developer Portal application, both access
  gates, and every face scan.
- **Rejected work.** Several reviews were overruled and several proposals cut; those rulings
  are in the ledgers, including the ones that later proved wrong.

### The artifacts that workflow produced

The rules ask that spec-driven workflows submit their specs and prompts. They are here,
unedited:

| | Lines | |
|---|---|---|
| [`docs/superpowers/specs/`](docs/superpowers/specs) | 8,120 | Design documents, approved before implementation started |
| [`docs/superpowers/plans/`](docs/superpowers/plans) | *(counted above)* | Task-by-task implementation plans |
| [`docs/superpowers/sdd/`](docs/superpowers/sdd) | 4,791 | The working ledgers: every dispatch, every review, every ruling |

100 of the 106 commits carry `Co-Authored-By: Claude Opus 5`. The six that do not are the
first `.gitignore` commit and five documentation commits from 2026-09-09, made while the
trailer format was being changed mid-session — an omission, not a claim of authorship.

### What that workflow actually caught

The reviews are adversarial by construction — a fresh reviewer sees the diff and nothing
else. Two that landed, both written up in [`docs/superpowers/sdd/`](docs/superpowers/sdd):

- `hashSignal()` hashed a hex digest as UTF-8, so `POST /api/attest` could never have
  succeeded on the digest path. Every existing test missed it, because the test pinned the
  server against itself.
- Four separate paths through the agent loop could pay the same intent twice.

A third came from mutation testing rather than review, and predates the ledgers: the
`uint8` clamp in `_askPolicy` turned out to be load-bearing. A policy returning `256`
truncates to `0`, which is `Reason.OK`, and the transfer executes — and deleting that line
left every test green. It is now pinned by
`test_policy_return_over_uint8_max_is_clamped_to_policy_failed`, which fails when the clamp
is removed. The reasoning is in the comment above `_askPolicy` in `src/LeashAccount.sol`.
