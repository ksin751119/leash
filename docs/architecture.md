# Leash — architecture

An onchain policy engine for AI agent wallets. Written for a reader who has ten
minutes and wants to know what is actually enforced, by what, and what is not.

This is the English summary of the design. The full working document, including
every decision that was later overturned, is [`PLAN.md`](PLAN.md).
Live addresses and a verification recipe you can paste are in
[`deployments.md`](deployments.md).

---

## The problem

You want an agent to pay for things. Today that means handing it a private key, and
a private key is all-or-nothing: it can spend everything, to anyone, forever, and the
only way to take it back is to move the funds first.

Every existing answer sits offchain. A wrapper API, a rate limit in the agent's own
code, a human clicking approve. All of them share one property: **the thing being
constrained is also the thing enforcing the constraint.** A compromised agent
edits its own rate limit.

## The answer

Put the rules onchain, in a place the agent cannot reach, and make the payment
path read them.

```
AGENT calls spend(token, payee, amount) on the WALLET
  │
  ├─ the wallet is an EOA delegated (EIP-7702) to LeashAccount
  │  so the wallet's own code runs this check
  │
  ├─ 1. is this caller a bound agent?              → reason 1 / 2
  ├─ 2. is the account paused?                     → reason 10
  ├─ 3. resolve the policy address through ENS     → reason 3
  ├─ 4. is that policy on the approval list?       → reason 4
  ├─ 5. ask the policy: check(SpendContext)        → reason 5-9, 11
  │     that policy may itself be a composition of policies
  │
  ├─ blocked → emit SpendBlocked, return normally, MOVE NO MONEY
  └─ OK      → write the ledger, transfer, emit SpendExecuted
```

The agent holds no funds and no permissions. It is a `msg.sender` that a policy
recognises, nothing more.

---

## Three planes

| Plane | Contracts | Who writes it |
|---|---|---|
| **Control** | `LeashRegistry`, `LeashResolver`, `PolicyApprovals` | ADMIN, plus a human attestation for anything that widens |
| **Execution** | `LeashAccount` (an EIP-7702 delegate impl) | The wallet itself, per-wallet, in the wallet's own storage |
| **Judgement** | `StandardPolicy`, `MicroPaymentPolicy`, `PolicySet`, and any other `IPolicy` | Nobody at runtime — all three deployed policies are `pure` or `view` and read only their inputs |

The separation is what makes the claim hold. The wallet has no control-plane
authority, so a compromised policy can at most drain that one wallet; it cannot
reach the rules. And the rules live under a name the wallet does not own.

## Three keys, deliberately separated

| Key | Holds | Can do | Deliberately cannot |
|---|---|---|---|
| **ADMIN** | `leash.eth` and its ENS roles | Repoint policies, issue and revoke agent subnames | **Approve a new policy.** That needs an attestation, and the attester is `immutable` with no setter |
| **WALLET** | The money; delegated to `LeashAccount` | Pay — every agent payment goes through the policy | Touch ENS. Its role bitmap is `0`, not because of a check but because it was never granted one |
| **AGENT** | Nothing | Call `spend` | Hold funds, hold permissions, or change any rule |

There can be **more than one AGENT**, and in the demo there are two. They are separate keys
in separate processes with no channel between them, and they draw on one budget — see below.

A stolen ADMIN key can move a name's pointer, but only to a policy that a human
already approved. The blast radius is bounded by "every approved policy", never by
"arbitrary code".

---

## A name is the unit of authority, not an agent

The ledger the account keeps has three keys, and an agent is not one of them:

```solidity
mapping(bytes32 node => mapping(address token => mapping(uint256 bucket => uint256))) spent;
```

`_bucket(r)` is `(uint256(r.epoch) << 224) | (block.timestamp / r.period)` — the high bits
isolate a key-space that only `setRule` may advance, the low bits roll the period over on
their own with no transaction from anyone.

So **every agent bound to the same node spends from the same number**, and the binding guard
permits exactly that:

```solidity
if (b.node != bytes32(0)) revert AlreadyBound();   // refuses a bound AGENT, not a used NODE
```

- **many agents → one node: allowed.** This is how a budget is shared, and it needs no
  coordination anywhere offchain — no shared database, no lock, no message. Atomicity comes
  from the chain.
- **one agent → two nodes: refused, deliberately.** An agent that could sit under two
  budgets would move to the second when the first ran out, which makes a limit a suggestion.

### The account keeps the ledger; the policy decides

This is the part to be precise about, because it bounds the guarantee:

```solidity
uint8 reason = _askPolicy(policy, SpendContext({
    agent: msg.sender, payee: payee, token: token, amount: amount,
    tokenAllowed: r.allowed, payeeAllowed: $.payees[node][token][payee],
    txLimit: r.txLimit, periodLimit: r.periodLimit, spentSoFar: spentSoFar,
    nowTs: uint64(block.timestamp), windowStart: r.windowStart, windowEnd: r.windowEnd
}));
```

The account hands the policy both the limit and the running total and honours whatever
reason code comes back. **A policy that ignores `periodLimit` has no period limit.** That is
why `MicroPaymentPolicy` checks it even though its own cap is 1.00 USDC — without that, an
agent empties a 50 USDC budget in ninety-cent slices and never meets a human. The
composition's spec states it as non-optional.

So the shared budget holds on two things: **the ledger is on chain and has no agent in its
key**, and **every approved policy respects it.** The second is what a human is agreeing to
when they approve a rule, which is why `describe()`'s sentence is shown at approval time and
again on the demo page.

### Attribution survives the sharing

`SpendExecuted` and `SpendBlocked` both carry `address indexed agent`. The limit belongs to
the name; each transaction is still filed under the key that sent it. The chain stores no
per-agent total, so the demo page reconstructs one from the spend log in
`agent/subgraph.mjs:buildCohort` — walking `spentAfter` back from the budget's current total
until it reaches zero, which locates the period boundary by arithmetic rather than by
assuming a period length.

---

## Why ENS is the skeleton, not decoration

The policy address is **resolved out of ENS on every single payment**. Three hops,
inside the transaction:

| Hop | Call | Returns |
|---|---|---|
| 1 | `ETHRegistry.getSubregistry("leash")` | our `LeashRegistry` |
| 2 | `LeashRegistry.getResolver("vendors")` | our `LeashResolver` |
| 3 | `LeashResolver.resolve(dnsName, addr(node))` | the policy address |

Then the approval list is checked, then the policy is called.

**Remove ENS and hop three has no answer, so no agent-initiated spend passes
(reason code 3).** That is not a slogan — point hop one at `0x0` and run the four
`cast` calls in [`deployments.md`](deployments.md); the walk stops resolving and
payments stop with it.

Two measured facts make this possible at all, and both were verified against live
ENSv2 on Sepolia (see [`ensv2-sepolia.md`](ensv2-sepolia.md)):

- ENSv2's minimal resolvers implement **only** ENSIP-10 `resolve(bytes,bytes)`.
  `addr()` and `text()` do not exist as external functions; calling them reverts.
- `resolve()` **returns data directly** — it does not revert with `OffchainLookup`.
  So a contract can complete the whole walk inside the transaction, with **no
  CCIP-read gateway**. Without this, the design does not exist.

### Three revocation layers, one transaction each

| Layer | Transaction | Effect |
|---|---|---|
| light | `LeashResolver.setPolicy(node, stricter)` | Swap the rules |
| medium | `LeashRegistry.revoke("vendors")` | **That one agent dies**; others untouched |
| **heavy** | `ETHRegistry.setSubregistry(leash.eth, 0x0)` | **Every agent halts at once** |

Plus a fourth that needs no transaction at all: an agent subname's `expiry`. Issue a
name for 24 hours and it lapses on its own — `getResolver` returns `0x0`, the policy
stops resolving, and renewal takes a human **and an attestation**. A dead man's
switch that costs nothing to arm. `MAX_DURATION` caps it at 365 days, so "a name
that never expires" is not expressible.

**None of the four touches the agent's account.**

---

## Expansion needs a human; reduction never does

This asymmetry is the core of the design, and it is enforced in code rather than
documented as a convention.

| Direction | Example | Requires |
|---|---|---|
| **Widening** | Approve a new policy, raise a limit, allow a payee, restore a revoked agent, renew a name | `msg.sender == address(this)` **and** a fresh attestation |
| **Reduction** | Tighten a rule, remove a payee, revoke an agent, pause, revoke a policy, clear a pointer | Authority only — **never an attestation** |

The reason a reduction must never need an attestation: when something has gone
wrong, hunting for your phone is the last thing you want to do. Requiring a
permission on the brake pedal does the attacker a favour at exactly the wrong
moment.

Two consequences worth stating precisely, because both are easy to overclaim:

- Reduction still requires `onlySelf`. The true claim is that it never requires an
  **attestation**, not that it requires nothing.
- `PolicyApprovals.revoke` is callable by **anyone**. That looks strange until you
  follow it through: revoking can only make the system stricter.

### Widening is replay-protected

Every attestation digest is EIP-712, bound to `chainId`, to the wallet
(`address(this)`), and to the impl version (`SELF`), and is marked spent
permanently once used. Without the nonce and the spent-marker, a public `revoke`
would let anyone copy an attestation out of the calldata, revoke, and re-approve
with the same blob — no new face scan from anyone.

`SELF` matters separately: inside a 7702 delegate, `address(this)` is the *EOA*,
while an `immutable` captured at construction is the *impl*. Both go into the digest
so that redelegating to a new impl version cannot replay the old version's
attestations.

---

## What the account judges, and what it delegates

The account never decides whether a spend is *reasonable*. It decides only whether
it should trust the policy at all. Every "does this spend satisfy the rules?"
question lives in the policy — and no special case for any individual requirement
is ever carved into the account.

| Codes | Decided by | Meaning |
|---|---|---|
| 1-4, 10, 12 | `LeashAccount` | Not bound, revoked, no policy, policy unapproved, paused, policy broken |
| 5-9, 11 | the policy | Token, payee, per-tx cap, period budget, time window, shared budget |

The numbers are frozen in [`events.md`](events.md) and must never be
renumbered; the subgraph, the frontend and the agent all depend on them.

The payoff of putting judgement in a separate contract: **"several agents share one
pooled budget" needs no account change at all.** Because a policy may keep its own
storage, that requirement collapses into a single contract holding the shared ledger,
with three agents' ENS records pointing at the same address. No new contract type, no
new account field, no new event — and reason code 11 is already reserved for it. Such
a `SharedBudgetPolicy` is a design consequence, not shipped code. The three policies that
are implemented and deployed — `StandardPolicy`, `MicroPaymentPolicy` and `PolicySet` — keep
no ledger at all.

The cost is stated in the interface: a policy with side effects **may only write its
ledger when it returns `OK`**. The account does not revert when it blocks, so a
policy that debits and *then* returns "over limit" leaks the shared budget forever.

### A policy may itself be a composition

`StandardPolicy` ANDs every check together, and the payee allow-list is one of them, so a
fifty-cent API top-up to an address nobody vetted is refused exactly as hard as a five-dollar
payment to a stranger. Every corporate card already answers that with an `OR`, and
`PolicySet` is that `OR` onchain: **AND inside a clause, OR between clauses**, in disjunctive
normal form with no nesting — `(A ∧ B) ∨ (C ∧ D)` covers every rule anyone has asked for,
and nesting would need a parser onchain.

Nothing else in the system changes to accommodate it, because `PolicySet` implements
`IPolicy` itself: the account calls it through the same interface, ENS points at it through
the same record, and the approval list gates it through the same single entry. The deployed
composition is two clauses:

```
clause 1 = [ MicroPaymentPolicy ]   0x0142BE41…19Df, CAP = 1.00 USDC
                OR
clause 2 = [ StandardPolicy ]       the full rules, payee allow-list included
```

`PolicySet` at `0xec45e967…2490`; the pointer at `vendors.leash.eth` was moved to it on
2026-09-11 and the payment path ran through it end to end that day.

Three properties are load-bearing, and each is documented in the contract itself rather than
only here:

- **Members are reached by `staticcall`, not `call`.** The paragraph above is the reason: a
  member may write its ledger when it returns `OK`, and under an `OR` a member can return
  `OK`, write, and then have a sibling clause fail — leaving the write standing, with no
  revert to roll it back and no way for the composer to undo it. `staticcall` removes the
  hazard by construction instead of warning about it. The price is stated plainly: a stateful
  policy can never be a member, so the `SharedBudgetPolicy` sketched above could not be
  composed this way.
- **When no clause passes, the *last* clause's reason is reported** — and within a clause,
  its first failing member's. Clauses read as *exception* `OR` *general rule*, so the last
  clause is the general rule and its code is the one an operator can act on. Reporting the
  first clause's code would tell an agent "over the micro cap" when the thing to fix is "get
  this payee vetted". One code is never routed around: a member answering `12 POLICY_FAILED`
  returns immediately, because letting a later clause rescue a set containing a broken member
  would hide the breakage.
- **The member list is fixed at construction, with no setter**, and a well-formed set is the
  only kind that can exist — an empty set or an empty clause is refused in the constructor,
  because a clause with no members passes vacuously and one vacuous clause returns `OK` for
  every payment ever submitted. A different composition is therefore a different address,
  which needs its own entry in the approval list — by design a fresh human attestation, and
  in this deployment a mocked one; see *What this does not claim*.

`_ask` deliberately does **not** consult `PolicyApprovals` for members: approving the set is
approving the whole composition once, with the members it was built with, and there is no
second thing to approve. The brake is unchanged and still permissionless — **revoke the
set**, and the account refuses it whatever its members say. Members are also called under a
60,000-gas ceiling, which is an eligibility limit rather than a defence: a policy costing
more than that works fine as the account's direct policy and reads as `POLICY_FAILED` inside
a set.

`MicroPaymentPolicy` is the exception half and **is not safe alone** — its own `describe()`
says `NOT SAFE ALONE` on chain, because alone it would allow any small payment to anyone. It
relaxes exactly one thing, the payee allow-list; the token allow-list, the period budget and
the time window are all still checked, and its `CAP` does not repeal the owner's own
per-transaction limit — both hold, so the effective ceiling is the lower of the two. Under an
`OR`, a check the exception omits is a check the composition no longer has for any sub-cap
payment, which is why the omission is one field and it is named.

### Two guarantees the account has to hold

**`resolvePolicy` never reverts.** ENS's contracts were in an audit window while this
was built; addresses may move and behaviour may change. Another contract reverting
must not wedge the account. Failing to resolve is reason code 3, no money moves, and
that is the safe default.

Holding it took more than `try/catch`. **No externally returned data is ever passed
to `abi.decode` anywhere in `LeashAccount`** — `abi.decode` reverts on a malformed
header or dirty address padding, which a broken or malicious resolver could use to
wedge the account. Every hop reads its words in assembly and validates structure and
padding itself. The three hops also return different lengths — 32, 32, and **96**,
because hop three returns `bytes` (offset + length + inner). Check hop three for
`== 32` and the happy path never succeeds, while the reported reason says "ENS has no
policy pointer" and sends you to debug the wiring, where nothing is wrong.

**A policy cannot DoS the account.** The policy call is capped at 200,000 gas and
each ENS hop at 100,000. Anything anomalous — revert, gas cap, wrong return length,
a value above `uint8` — is reason code 12, which deliberately is *not* code 4: "no
human approved this" is fixed by a face scan, "this policy is broken" is fixed by
replacing it, and an agent asking why it was blocked deserves the difference.

---

## Storage: why an ERC-7201 namespace

EIP-7702 delegated code runs against the **EOA's own storage**. If that EOA later
redelegates to a different impl with a different layout, the old data is
reinterpreted under the new meaning — the kind of failure where a budget is read
back as an admin address.

So the entire per-wallet state lives in one struct at the ERC-7201 slot derived from
`keccak256("leash.account.v1")`:

```
0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800
```

The version is inside the string. Change the layout, change the string, and the old
slot can never be misread. A test pins both the formula and the fact that state
really lives there.

There is no `initialize()`, and that is deliberate: the global configuration is
`immutable`, burned into the bytecode, so the window after delegation where storage
is still blank has nothing to race for.

---

## What this does *not* claim

Stated plainly, because a security claim that is quietly larger than the enforcement
is worse than no claim.

**EIP-7702 constrains only calls *to* the delegated EOA.** The WALLET private key can
still sign `USDC.transfer` directly, and the policy path never executes. The correct
claim is "**the agent's** only spending path" — never "the only spending path". That
the wallet is unconstrained is both the boundary and the **escape hatch**: the owner
can always retrieve their own funds. A test asserts it — a wallet-signed direct
transfer succeeds and emits no `SpendExecuted`.

**The two attestation gates are wired to different attesters, and only one of them is
real.** `WorldAttester` is deployed at `0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26` and
`LeashAccount.ATTESTER` points at it, so **widening a payee — the face-scan beat — is
gated by a real Selfie Check today**: both conditions, `msg.sender == address(this)` and a
live attestation, are guarding.

`PolicyApprovals.attester` is still `MockAttester` (`0x268990a91B0727E80d38d5ED4Ab10d8889754124`),
which returns `true` for any input. So **approving a new policy is not gated by a human
today** — the second lock is installed but not loaded. That field is `immutable` by design
(see the contract's own notes on why the mutability was removed rather than relocated), so
loading it means deploying a fresh `PolicyApprovals` and re-approving every policy through
it. Stated here rather than fixed, because the asymmetry is the honest state of the deploy:
the gate a judge will watch on camera is real, and the one behind it is not yet.

**A World ID proof does say which credential was exercised — and this document claimed the
opposite until 2026-09-11.** It said a successful proof returns `credential_type: "device"`
whatever happened in front of the camera, and concluded that the human-in-the-loop guarantee
was configuration-level rather than cryptographic. Measured: a World ID **4.0
`SelfieCheckLegacy`** request opens the front camera and comes back `identifier: "selfie"`,
and World's verify endpoint echoes that identifier. The old `device` reading came from asking
for a device credential — which was the only thing the widget in use could ask for. The
backend now refuses to sign an attestation for any other identifier, so "this widening was
approved by a face" is checked rather than assumed.

What stays narrow is the onchain half. `WorldAttester.verify` proves that the RP signer
signed this exact digest before its deadline, not that a human did anything; the link to a
face is the offchain sequence — Selfie Check → World's verify endpoint → the backend signs
only after that call returns HTTP 200.

**Gas is outside the policy's jurisdiction.** The rules govern token transfers, but
the wallet pays gas in ETH and no policy can see it. Strictly, "100 USDC per day" is
incomplete: an agent in a failure loop can burn the ETH. The mitigation here is
operational — the wallet holds only enough ETH for the demo. The real fix (gas and
spend in the same asset) is v2.

**A policy pointer is not a codehash.** The approval list is keyed by **address**.
Since EIP-6780 the address→code binding is permanent, so the old CREATE2-redeploy
objection no longer holds — but it is an address, and that is what "approved" means.

---

## Files

| Path | What it is |
|---|---|
| `src/LeashAccount.sol` | The EIP-7702 delegate impl. `spend`, the ENS walk, the widening/reduction gates |
| `src/LeashStorage.sol` | The ERC-7201 namespaced layout |
| `src/LeashRegistry.sol` | ENSv2 `IRegistry` + ERC-1155. Issues, renews and revokes agent subnames |
| `src/LeashResolver.sol` | ENSIP-10 resolver. Node → policy address |
| `src/PolicyApprovals.sol` | The approval list. No owner, `immutable` attester |
| `src/StandardPolicy.sol` | The default rules, `pure`, reproducible offchain |
| `src/Reason.sol` | The frozen reason codes |
| `src/LeashLens.sol` | "Is the leash still on?" — reads the 23-byte delegation |
| `src/IAttester.sol`, `src/MockAttester.sol`, `src/WorldAttester.sol` | The human-attestation gate; `WorldAttester` gates the account's widening, `MockAttester` still gates the approval list |
| `src/PolicySet.sol` | Composition: AND inside a clause, OR between clauses; members reached by `staticcall`, immutable member list, and the **last** clause's reason reported when none passes |
| `src/MicroPaymentPolicy.sol` | The exception half of `(small payment) OR (the full rules)` — relaxes the payee allow-list and nothing else; never safe alone |
| `subgraph/` | Indexes the control plane and every spend attempt, blocked ones included |
| `world/` | The Selfie Check backend, verified end-to-end offchain |

## Reading order for a judge

1. This file.
2. [`deployments.md`](deployments.md) — run the four `cast` calls; watch the walk
   resolve, then break it.
3. `src/LeashAccount.sol` — `spend` and `resolvePolicy`; then `src/PolicySet.sol` for the
   composition and why its members are reached by `staticcall`.
   While you are in `spend`, note what is **not** in the key of `$.spent` — that absence is
   the shared budget, and it is the one claim in this project you can check by reading a
   single line.
4. [`world-feedback.md`](world-feedback.md) — a dated running log of the World
   integration, written as it happened and not flattering.
