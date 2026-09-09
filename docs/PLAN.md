# ETHOnline 2026 — project overview

> Status: planning. **No project code may be written before 2026-09-04** (the Start from
> Scratch rule). The documents in this directory are design and research notes, which are
> not "code" and are permitted by the rule.

---

## In one sentence

**Give an AI agent a corporate card — the limit lives on chain, the agent cannot change it,
and the company can cut the card at any moment.**

## The problem

AI agents are starting to be able to move money, and today there are only two ways to let
them, both bad:

1. **Hand the agent a private key** — it does whatever it likes, under no constraint
2. **Have a human sign every transaction** — at which point it is not automation

The existing middle grounds (session keys, allow-lists, Zodiac Roles, ERC-7579 modules) all
express permission as **configuration**: which addresses may be called, which selectors,
what the cap is. Configuration cannot carry a judgement like "should this particular spend
happen?".

## Our answer

**Express permission as code — policy as code — and enforce it on chain.**

- Every agent is bound to a **policy contract**
- When the agent sends a transaction, the EIP-7702 delegate `call`s that policy and asks it
  one question
- If the policy returns anything but OK → **no transfer**, emit `SpendBlocked(reason)`, and
  the transaction ends normally
- **The agent has no path around it**, because the check happens inside its own execution
  flow

A policy is a complete smart contract, not a settings table. It can judge however it likes —
on the amount, the counterparty, the time, the running total, even with a memory of its own
(see "Policy layer design decisions").

> **Why a block is not a revert:** the chain discards a reverted call's logs, so the
> subgraph cannot index blocked attempts and the agent can never ask "why was I blocked
> last time?" — which is exactly what The Graph's track wants to see.
> The evidence of a block is that **money did not move**, not that the transaction went red.
> Only an authorisation failure (the caller is not a bound agent) reverts.
> The full argument is in `events.md`.

## Why ENS is the skeleton, not decoration

A policy's **address is resolved out of ENS**. The 7702 delegate walks it on every
execution:

```
RootRegistry.getSubregistry("eth")
  → ETHRegistry.getSubregistry("acme")
    → AcmeRegistry.getResolver("vendors")
      → resolver.resolve(dnsName, text(node, "policy"))
        → the policy contract's address
          → check it against the approval list (by address)
            → call check(SpendContext)
```

**Remove ENS, the delegate cannot resolve a policy, and no spend can pass (reason code 3).**

That path also brings three layers of revocation, each a single transaction:

| Layer | Action | Effect |
|---|---|---|
| light | change the policy record on the resolver | swap in a stricter rule |
| medium | take back the `vendors.acme.eth` subname | that one agent dies |
| **heavy** | `ETHRegistry.setSubregistry("acme", a new registry)` | **every agent dies at once** |

Plus the `expiry` native to an ENSv2 `Entry` — an agent's name can be issued for just 24
hours, lapses on its own, and renewal takes a human. A dead man's switch that costs
nothing.

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │  ENSv2 (Sepolia)            │
                    │  acme.eth                   │
                    │   └─ our PermissionedRegistry │
                    │       ├─ vendors.acme.eth   │──┐
                    │       ├─ payroll.acme.eth   │  │ the policy address
                    │       └─ subs.acme.eth      │  │ lives in a resolver record
                    └─────────────────────────────┘  │
                                  ▲                  ▼
                     Selfie Check │          ┌───────────────┐
                     gates only   │          │ Policy        │
                     widening     │          │ may keep its  │
                                  │          │ own ledger    │
                    ┌─────────────┴───┐      └───────┬───────┘
                    │ human / org      │              │ call
                    └─────────────────┘              │
                                                     │
   ┌──────────┐   MCP    ┌──────────────┐   tx   ┌───┴────────────┐
   │ AI Agent │ ───────▶ │ MCP Server   │ ─────▶ │ EIP-7702       │
   └────┬─────┘          └──────┬───────┘        │ delegate (EOA) │
        │                       │                └────────────────┘
        │ query limits / history / │
        │ why it was blocked       │
        ▼                       ▼
   ┌─────────────────────────────────┐
   │  Subgraph (The Graph)           │
   │  indexes policy registration    │
   │  and every execution            │
   └─────────────────────────────────┘
```

### The key model (the crux) — three keys, not two

| Key | Holds | Can do | Deliberately cannot |
|---|---|---|---|
| **ADMIN** | `leash.eth` + its ENS EAC roles | change rules, issue subnames, revoke agents, approve policy addresses (with a signature) | **never makes a 7702 delegation**, and holds no operating funds |
| **WALLET** | the money; 7702-delegated to `LeashAccount` | pay (every payment goes through the policy) | **its ENS role bitmap is `0`** — not because of a check, but because it never had one |
| **AGENT** | nothing at all | initiate a spend request | hold funds or permissions; it is only a `msg.sender` the policy recognises |

**Why the split is mandatory:** when `LeashAccount` sends an outbound transaction,
`msg.sender` *is* WALLET. If WALLET also held ENS authority, a broken policy could use it
to call `ETHRegistry.setResolver` and **point the rules at itself**. We solve this by
separating, not by checking.

Verified onchain: under `cast call --from`, both WALLET and AGENT have ENS roles of `0`, and
every ENS change reverts.

> A broken policy can at most drain WALLET's funds. **It cannot reach the control plane,
> because WALLET never had any control-plane authority to lend it.**

---

## The demo (four acts, about 3 minutes)

| Act | Content | Sponsor it speaks to |
|---|---|---|
| **1 · normal** | the agent pays a vendor $200. It queries the subgraph: budget is fine, this payee has been paid before → the policy allows it → on chain | The Graph |
| **2 · blocked** | the agent tries to pay **$5,000 to a brand-new address**. The subgraph says it has never seen this payee and the monthly budget is exceeded. **Even if the agent's code is modified to force the transaction through, the chain blocks it anyway** | the core claim |
| **3 · a human allows it** | a human confirms the payment is genuine → **Selfie Check** → update the policy in ENS → the agent retries and succeeds | World |
| **4 · kill everything** | one `setSubregistry` transaction → **every agent in the company halts at once**, and the agent's account is never touched | ENS |

**Each sponsor owns one act.** A judge watching the video does not have to guess what we
are doing.

### The widening/reduction asymmetry (the design's crux)

| Action | Needs Selfie Check |
|---|---|
| issue a new agent subname | ✅ yes |
| raise a limit | ✅ yes |
| allow-list a new payee | ✅ yes |
| **revoke an agent / lower a limit** | ❌ **no** |

The first thing a compromised agent wants is to register more permissive rules for itself,
so widening has to be bound to a real human. But reduction must never be blocked — when
something has gone wrong, hunting for your phone is the last thing you want to do.

---

## Policy layer design decisions (settled 2026-09-07, overturning the 09-06 version)

> **This section was written once on 9/6 and rewritten entirely on 9/7.** The old version
> keyed the approval list by codehash, which forced policies to have no storage, and then
> designed two further mechanisms to make "a shared budget" work. Discussion established
> that this was picking a mechanism first and looking for a requirement afterwards.
> **Changed to addresses throughout, which deleted three mechanisms.** The old reasoning is
> preserved below under "why it was overturned", so nobody circles back to it later.

### What a policy is

One contract, one address, answering one question — "does this spend satisfy the rules?" —
and returning a `uint8`. **It never touches the money and cannot touch the account's
storage.** (It may have storage of its own; see below.)

Four reasons the rules are a separate contract rather than hardcoded in the wallet:

| Reason | Detail |
|---|---|
| **It can be pointed at** | Rules with an address can be written into an ENS record. **This is where the ENS track's argument lives** |
| Changing rules moves no money | The money stays in LeashAccount; all that changes is who it asks |
| One ruleset, many users | Different subnames can point at the same one, or at their own |
| Authority can be split | "Change the rules" and "move the money" become two things, held by two different keys |

### How it is called: an ordinary `call`

| Approach | Can the policy write the **account's** storage? | Can it write **its own**? |
|---|---|---|
| `delegatecall` | **Yes. The whole account is writable** ← never use this | No (there is no "own" to speak of) |
| `staticcall` | No | No |
| **`call` (adopted)** | **No** | **Yes** |

> ⚠️ **The core guarantee is "a policy cannot touch the account's storage", and only
> `delegatecall` breaks it.** `call` and `staticcall` are equally safe on that point — the
> only difference is whether the policy can remember anything.

**Why this loosened from `staticcall` to `call`:** "several agents share one pooled budget"
needs someone to keep the ledger. Letting the policy keep it is the only way that does not
carve a special case into the account (see the next section).

**Guards (must be implemented when writing `LeashAccount`):**

1. **A reentrancy lock** — a policy is an external contract and can call back into the
   account. Put a mutex around the whole of `execute`.
2. **A gas cap** — `call{gas: 200_000}`; a policy burning all the gas must not kill the
   transaction, and any failed return counts as a block (fail closed).
3. **A return-length check** — anything other than exactly 32 bytes counts as a block.
4. **Debit before paying** — the account's own bookkeeping completes before the transfer.

`delegatecall` plus a slot namespace (the ERC-7201 approach) is **never used** — a namespace
is a convention, not an enforcement. Under delegatecall there is no restriction on `SSTORE`
whatsoever, one line writes into the approval list, and the entire Selfie Check gate is
bypassed (**circular authority: the key to the lock is kept behind the door**).

### Key the allow-list by **address**

```solidity
mapping(address policy => bool) public approved;   // only a face scan adds; removal is always available
```

**Why an address: an address pins both the logic and the data; a codehash pins only the
logic.**

Deploy the same bytecode twice and the codehash is identical, yet the two can have entirely
different storage — measured: two contracts with the same codehash where
`lo.check(500) = false` and `hi.check(500) = true`. The moment a policy may have storage,
a codehash no longer determines behaviour and the guarantee it claims simply evaporates.

And the address → code binding is **permanent since EIP-6780** (selfdestruct only really
deletes code within the transaction that created it), so the textbook objection that
"CREATE2 plus selfdestruct can swap the code at an address" is dead. **Stop using it as a
reason to prefer codehash.**

#### Why codehash was overturned (recorded so nobody circles back)

The 9/6 version gave three reasons; each reconsidered:

| The reason at the time | The judgement now |
|---|---|
| "You can approve code that is not deployed yet" | Genuinely unique to codehash, but **we have no use for it** — see "a library of rules" below |
| "A human consents to logic, not to an address" | An address can be inspected just as well: look at what lives there before approving. And once a policy has storage, inspecting the logic alone is **not enough** |
| "A 7702-delegated EOA posing as a policy would be caught by the fingerprint" | An address allow-list only ever contains contracts we deployed; to guard against that, check `code.length` at approval time |

**The one situation where codehash is irreplaceable: the thing you need to verify has no
address at all** (not yet deployed, counterfactual, or comparing the same code across
chains). Leash has nothing of that kind anywhere — everything it verifies is a live onchain
instance.

> A "library of rules" **does not need codehash**: deploy five policies, approve five
> addresses with one face scan, and ADMIN can switch between them afterwards with no
> further scan. The demo's rhythm is identical, with one concept fewer.

### A shared budget: one policy, not a special case in the account

The requirement: each agent has **its own wallet**, but the sum of what all of them spend
must not exceed one pooled cap.

Because a policy may have storage, this collapses into a single contract and **the account
needs no change at all**:

```solidity
contract SharedBudgetPolicy is IPolicy {
    uint256 public immutable LIMIT;
    uint256 public immutable PERIOD;
    mapping(uint256 period => uint256) public spent;   // shared by everyone

    function check(SpendContext calldata ctx) external returns (uint8) {
        uint256 p = block.timestamp / PERIOD;
        if (spent[p] + ctx.amount > LIMIT) return Reason.OVER_SHARED_LIMIT;
        spent[p] += ctx.amount;                        // the policy keeps its own ledger
        return Reason.OK;
    }
}
```

Three agents' ENS records each point at **the same address**, and the shared budget works —
no new contract type, no extra field on the account, no new event.

> **This is what "the policy is the sole authority" concretely means:** every judgement of
> the form "should this spend pass?" lives in the policy. The account only judges "should I
> trust this policy?" (reason codes 1-4 and 10). **No special case is ever carved into the
> account for an individual requirement.**

`check` has side effects, so **the account calls it exactly once, and only when it genuinely
intends to pay**. Dry runs from the frontend and the agent go through `eth_call` (off chain,
leaving no trace).

### How to prove the leash is still on (`isLeashed`)

The five questions above are answered, but a sixth is missing: **"how do I know this wallet
is still governed right now?"**

Our wallet is a 7702-delegated EOA. Its behaviour depends entirely on what it delegates to,
and **the address is the same throughout**:

```
before delegating   0x46C0…  →  empty code; whoever has the key spends the money
after delegating    0x46C0…  →  LeashAccount; every payment goes through the policy
after tampering     0x46C0…  →  delegated elsewhere; the leash is gone
```

7702 code is exactly 23 bytes — `0xef0100 || address` — so the delegate can be read out
directly:

```solidity
function delegateOf(address wallet) internal view returns (address impl) {
    if (wallet.code.length != 23) return address(0);
    bytes memory c = wallet.code;
    if (c[0] != 0xef || c[1] != 0x01 || c[2] != 0x00) return address(0);
    assembly { impl := shr(96, mload(add(c, 0x23))) }   // skip the 3-byte prefix
}

function isLeashed(bytes32 node) external view returns (bool, address);  // ENS → wallet → delegate
```

**Anyone — a vendor, a monitor, a frontend — can confirm in one call that the leash is
still on before doing business with this agent**, without asking anybody and without taking
anyone's word for it. Once a subgraph indexes it, "the leash came off" becomes an alertable
event.

> A codehash could do this too (delegated code and its hash correspond one to one), but
> **the address is better**: a UI can show "currently delegated to `0x1234…`", whereas a
> codehash can only show "wrong".

> ⚠️ **Superseded during implementation.** ENS records node → policy; there is no
> node → wallet reverse index, so `isLeashed(bytes32 node)` as specified here does not
> exist. `LeashLens.delegateOf(address wallet)` asks by wallet address instead. The
> reasoning is in `src/LeashLens.sol`.

### What this version cut

| Cut | Why | Saves |
|---|---|---|
| the codehash approval list | an address is more precise (it pins the data too), and we have no addressless requirement | — |
| the "policies must have no storage" restriction | a side condition of codehash; with codehash gone there is no reason for it | — |
| the `Write[]` / `_scratch` write-on-behalf pipeline | entirely redundant once a policy can write its own storage | 1.0h |
| the standalone `SharedLedger` contract | folded into `SharedBudgetPolicy` | 1.0h |
| account-level `walletBudget` plus reason code 11 | the account should hold no special case for a spending rule | 0.7h |
| approving a whole bundle by Merkle root | answers no question any user actually asks | — |
| scanning a policy's bytecode for SLOAD before approving | as above | — |
| **added** `SharedBudgetPolicy` | replaces two of the above; one contract does it | −1.0h |
| **added** `isLeashed` | answers "is the leash still on?", a question people really ask | −1.0h |
| | | **net saving 0.7h** |

### Kept but demoted to a stretch goal: disjunctive normal form across policies

`(A ∧ B) ∨ (C ∧ D)` — AND within a clause, OR between clauses. **No nested expressions.**
`PolicySet` itself implements `IPolicy`, so the account, ENS, the approval gate, the events
and the subgraph all need no change.

OR is a common shape in real spending rules ("per transaction ≤ 500" **OR** "a human
signature"), but it appears in none of the four demo acts. **Revisit after the main line is
green on 9/11.**

---

## Tracks and prizes

**Start from Scratch** (chosen at registration and **cannot be changed**).

Because the deliverable is 100% new code. `tx-approver` (`/home/ubuntu/DEV/tx-mcp`) is
motivation and prior art only — **no code is reused** — and its commits are all dated
2026-07-15, which would not have qualified for Classic anyway.

Three partner prizes are targeted (three is the maximum), all on **Sepolia**, so one chain
covers everything:

| Sponsor | Amount | Places |
|---|---|---|
| ENS — Best Use of ENSv2 | $4,500 | 4 (including a $500 runner-up) |
| The Graph — Best AI Tooling (From Scratch) | 1st $2,500 / 2nd $1,500 / 3rd $1,000 | 3 (ranked) |
| World — Selfie Check | $3,500 | 3 (at $1,166 each) |

**Ruled out:**
- **Hedera x402** ($6,000) — its exact scheme requires the payer to sign a native
  `TransferTransaction`, and a Hedera contract account has no key that can sign native
  transactions → **our policy wallet cannot be the payer**, and the policy layer would
  vanish from its own demo. Hedera also has no EIP-7702, and The Graph has no hosted service
  there.
- **Arc** ($2,500 and up, split evenly) — all three of its tracks mandate a frontend, a
  backend, an architecture diagram and a slide deck, plus a second chain and the Circle
  Agent Stack. **The only prize that would require building something extra**, with the
  award diluted on top.

Details in `prizes.md`.

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| ENSv2 redeploys during its audit window (8/18-9/14) and addresses change | medium | keep addresses in one config, never scattered |
| ENSv2 is beta and may have bugs | medium | that is itself the feedback material ENS wants |
| the 7702 delegate is entirely new ground | high | do it first, and leave it the most time |
| three sponsor integrations plus a video and a feedback document | medium | features must freeze on day 8 |

### Risks already ruled out

- ~~ENSv2 resolution needs CCIP-read, so a contract cannot read it~~ → **ruled out by
  measurement**; see `ensv2-sepolia.md`

---

## Schedule (work starts 9/4)

| Day | Content |
|---|---|
| 1-2 | PolicyRegistry + the policy contract interface + the first policy (limits/allow-lists) |
| 3-4 | **the EIP-7702 delegate**, resolving the policy via the ENS walk (highest risk, done first) |
| 5 | the subgraph: indexing registration events and every execution |
| 6 | the MCP server: the agent side, querying the subgraph to make decisions |
| 7 | Selfie Check plus a minimal frontend (two things only: face scan and change a limit) |
| 8 | **freeze features**. Record the video, the README, the World feedback document |
| 9 | buffer / submission |

---

## Open questions

- [x] ~~which ENS name to register~~ → **`leash.eth`**, 8.000021 USDC/yr, still available as of 2026-09-02
- [x] ~~which token to pay in~~ → **MockUSDC** (ENS registration needs it anyway, so nothing new is introduced)
- [x] ~~the actual flow of World's Selfie Check Sandbox App~~ → researched; see step 4 of `prep-checklist.md`
- [x] ~~how far the frontend goes~~ → **one page, and no second page** (settled 2026-09-02)

### Frontend scope (settled; it does not grow)

A single page with three sections:

| Section | Content |
|---|---|
| **current policy** | read from the subgraph: the limit, what is spent, allow-listed payees, the agent list |
| **raise privileges** | change a limit / add a payee / create an agent → **always through Selfie Check first** |
| **rule library** | the list of approved policy addresses, each showing its `describe()` and who currently uses it |
| **lower privileges** | revoke an agent / lower a limit → **no face scan, one click** |

**Not doing:** a login system, multiple accounts, a transaction history page, a settings
page, or mobile optimisation (desktop plus scanning a QR code with a phone is enough).

**Why it is compressed to one page:**

1. This one page makes the demo's central contrast completely — widening needs a face scan,
   reduction does not. A second page only dilutes it.
2. World is currently blocked on external approval. If it never lands before the demo, **a
   one-page frontend is the easiest to swap for a degraded version** (a mock attester):
   change the behaviour of one button.
3. Across the three tracks' scoring, only World needs a visible screen. ENS and The Graph
   look at the chain and the subgraph.

## A v2 direction: separating the control plane from the execution plane (out of scope here)

> Conclusion of a 2026-09-04 discussion. **Not being done this time**; it goes into the
> README and the demo's closing slide only.

### The observation

Leash does two things at once, and their requirements of a chain are opposites:

| Layer | What it does | What it wants from a chain |
|---|---|---|
| **control plane** | where the rules live, who can change them, human sign-off | needs ENS (a name as a pointer) and World ID. **Only Ethereum has both** |
| **execution plane** | where the money is, and every transfer being checked | needs to be cheap, fast, deterministically final, and its traffic is payments already |

When we split the keys into ADMIN / WALLET / AGENT, **the line between ADMIN and WALLET is
exactly the cut between these two planes**. The architecture already has that shape; both
sides merely happen to run on Sepolia today.

### What a payment chain (Circle Arc, say) would bring

1. **Gas is USDC** → closes the hole described below (see "a known gap"). One spend cap then
   really does bound all outflow, fees included.
2. **Deterministic finality** → the "spent today = X" accumulator never has to handle
   double-counting or under-counting from a reorg.
3. **The chain's traffic is payments already** → a policy engine's value scales with the
   fraction of transactions that are transfers.

### Why not move the whole thing there

A payment chain has **no ENSv2 registry** and no World ID. Moving there means deleting the
control plane, and what is left is "a contract that blocks oversized transfers" — which is
not remarkable, while half of Leash's value is in the control plane.

The right shape is not a migration but **each plane where it belongs**: names, permissions
and human sign-off stay on Ethereum; the money and the high-frequency checks go to the
payment chain.

### A known gap: gas is outside the policy's jurisdiction

**The current design governs USDC transfers, but WALLET pays gas in ETH and no policy can
see it.** Strictly, "100 USDC per day" is incomplete — an agent in a failure loop can burn
the ETH.

**What we do about it this time (worth doing, and nearly free):** put only enough ETH in
WALLET for the demo rather than filling it up; state the boundary honestly in the README and
point at the v2 fix (gas and spend in the same asset).

### Why it is not being done now

`prizes.md` (2026-09-01) already assessed the Arc prize: all three of its tracks mandate a
frontend, track 2 needs the whole Circle Agent Stack, and the award is split evenly with no
floor. **It is the only candidate that would require building something extra.** Ten days
from the deadline, a second chain is overload.

Revisit after the event — Circle runs its own hackathons and grants, and there is no rush
then.

---

## A v2 direction: one-shot batch authorisation (ephemeral code)

> Conclusion of a 2026-09-06 discussion. **Not being done this time**; it goes into the
> README's what's-next.

The pattern "carry the code into the transaction, verify its hash, run it, then destroy it"
is **wrong for rules and right for one-shot operations**.

| | a rule (policy) | a one-shot batch |
|---|---|---|
| Times used | repeatedly | **once** |
| Suits | living on chain | **ephemeral** |

The shape: "this run is a batch of 20 unusual payments. A human face-scans to approve **the
hash of the whole batch**; at execution the code is carried in, its hash verified, it runs,
it is destroyed, and the nonce is burned. That batch can only ever run once, and nothing
callable is left behind on chain."

**Why not for policies (measured figures):**

```
StandardPolicy  runtime 957 bytes · initcode 985 bytes

per payment, if it went through ephemeral code:
  CREATE                 32,000
  code deposit  957×200  191,400
  calldata ~985 bytes    ~15,800
  execute + destroy      ~20,000
  ─────────────────────────────
                        ~260,000 gas

for comparison: calling a deployed policy   ~3,600 gas   →  about 70x
```

And `selfdestruct`'s deletion **only takes effect at the end of the transaction** (measured:
`code gone in same tx? false`) — the code is present for the whole transaction, so
"disappears after use" disappears after everything has already happened.

On top of which a policy holds no assets and cannot touch the account's storage, so **there
is no attack surface to reduce**. The real risk is "the pointer aims somewhere it should
not", which the address approval list blocks and which has nothing to do with whether the
policy lives on chain.

## Blockers

| Item | Submitted | What it blocks | Fallback |
|---|---|---|---|
| ~~World Selfie Check feature flag~~ | 2026-09-02 | — | ✅ **cleared 9/7** — the precheck API returns `enable_face_check: true`; the flag had been on the whole time |
| World Sandbox access (a form) | 2026-09-02 | the Sandbox App only | very likely unnecessary: the app is production and Selfie Check needs no Orb |

> **Checked 2026-09-07: the documentation's wording changed.**
> `docs.world.org/world-id/sandbox/testing-selfie-check` now reads
> "To enable the feature flag, **request access through your World point of contact**."
> (The credentials page still carries the `developers@toolsforhumanity.com` mailto.)
>
> **For a hackathon, "your World point of contact" is the World sponsor rep in ETHGlobal's
> Discord.** That is faster than email, and we had already waited 5 days. **Ask in Discord
> today; stop waiting for a reply.**
>
> **Established 2026-09-07, after watching the official workshop recording:**
> - The flag was **handed out to attendees live at the 9/5 workshop** (03:00 Taipei time; we
>   were not there)
> - The contact is **Mateo Sauton** (Tools for Humanity), Discord handle approximately
>   `mrsauton`; in the recording he says explicitly "reach out to me on Discord"
> - He says Selfie Check opens **to everyone** "probably next week" — and that next week is
>   this week
> - The **request access to sandbox** button in the Developer Portal (sidebar
>   `World ID Sandbox` → `Install World ID Sandbox`, with iOS and Android tabs) **was
>   already clicked on 9/2 and is pending**. It governs **Sandbox App installation**, not
>   the Selfie Check flag — the flag has no entry point anywhere in the Portal and can only
>   come through the contact. Do not conflate the two gates.
> - Selfie Check needs no Orb to begin with, so **the Sandbox App is very likely
>   unnecessary** (Sandbox exists to simulate Orb verification state) — confirm this with
>   Mateo too; if it holds, the whole TestFlight/Firebase dependency can be cut

**What can be finished without World:** the contracts, the ENS wiring, the subgraph.
Build in that order and leave World until last, so a reply's arrival time is off the
critical path.

The full pre-work preparation steps are in **`prep-checklist.md`**.
