# PolicySet — design

> Written 2026-09-11. The last feature before the rehearsal. Two contracts, no change to
> anything already deployed.

**Goal.** Make "the policy is swappable" something the demo *shows* rather than asserts, by
composing two policies into a rule that neither can express alone — and pick a rule people
actually have, not one invented to exercise the machinery.

---

## The rule, and why it needs OR

`StandardPolicy` ANDs every check, and one of them is `payeeAllowed`. So **every payment to
a payee that is not on the allow-list is refused, however small.** That is a real limitation
of the design as it stands: you cannot pre-approve the world, so an agent topping up an API
for 50 cents needs a human to find their phone and scan their face.

Every corporate card policy in the world already solves this, and the shape is an OR:

```
(amount ≤ CAP  AND  still inside the period budget)   OR   (the full StandardPolicy rules)
```

Small payments to anyone; anything larger only to a vetted payee. It cannot be written as a
single `StandardPolicy` because that contract has no way to make `payeeAllowed` conditional.

An alternative was considered and rejected: `(within business hours) OR (payee is a standing
one)` — a real rule, but it changes the reason code for the demo's blocked intent from 6 to
9, and a face scan does not fix reason 9. It would have cost the beat the whole project is
built to show. A third — `(within budget) OR (a human signed)` — is not expressible at all:
`SpendContext` carries no attestation, and that struct is frozen.

---

## `PolicySet`

Disjunctive normal form: AND inside a clause, OR between clauses. No nesting.

```solidity
function check(SpendContext calldata ctx) external view returns (uint8);
```

**Declared `view`, not just non-mutating.** `IPolicy` permits an implementation to tighten
the mutability, and doing so makes "this contract cannot write" a compiler guarantee rather
than a promise in a comment.

### Members are reached by `staticcall`

This is the load-bearing decision. `IPolicy` says:

> 🔴 A policy may only write to its ledger when it returns `Reason.OK`.

because the account **does not revert** when it blocks, so a write made on the way to a
refusal is never rolled back. Composition walks straight into it: a member returns `OK` and
writes, a later member in the same clause fails, and the composite returns a block — with
the first member's write still standing. `PolicySet` cannot undo it, because it may not
revert either; the account needs a reason code back.

`staticcall` removes the hazard by construction: a member that tries to write reverts, and
no correct member can write at all. `StandardPolicy` is already `pure`, so it composes today.

**The price, stated plainly:** a stateful policy can never be a member. A pooled budget kept
in a policy's own storage — the `SharedBudgetPolicy` shape the interface was widened for —
is outside what `PolicySet` can compose. That policy does not exist yet, and this trade is
worth making now rather than shipping a composer that can leak a shared budget.

### The member list is fixed at construction

Set in the constructor, with **no setter of any kind**. A different composition is a
different address, which is a different entry in the approval list, which costs a human.
That matches how every other rule change in this project works.

### A misbehaving member fails the whole set

A member that reverts, returns other than 32 bytes, or returns a value above `uint8` makes
`check` return **`12 POLICY_FAILED` immediately** — it does not fall through to another
clause that might have passed.

The account's own `_askPolicy` takes exactly this line, and code 12 already means "this
policy is broken" as distinct from "the rules said no", which sends the operator to replace
it rather than to a face scan. Letting a later clause rescue a set containing a broken member
would hide the breakage; failing closed and loudly is the safe direction.

### An empty clause would pass everything

A clause passes when all its members return `OK`, so a clause with **no** members passes
vacuously — and one vacuous clause makes the whole set return `OK` for every payment ever
submitted. The same is true of a set with no clauses at all.

The constructor therefore **reverts** on an empty clause list, on any empty clause, and on a
zero member address. This is a constructor check rather than a runtime one because the member
list cannot change after deployment: a `PolicySet` that exists is a `PolicySet` that is
well-formed, and the approval list never sees a broken one.

### Which reason code a refusal reports

Within a clause, members are evaluated in order and the clause's reason is **the first member
that fails**. Across clauses, when no clause passes, report **the last clause's reason**.

DNF here is written as *exception* `OR` *general rule*, so the last clause is the general
rule, and its reason is the one an operator can act on. Reporting the first clause's reason
would tell an agent "over the micro cap" when the thing to fix is "get this payee
allow-listed" — the wrong direction. This is the same principle `StandardPolicy` already
states for its own ordering: report the code that, once fixed, converges.

It also keeps the demo intact. For `newvendor`, clause 1 fails with `7 OVER_TX_LIMIT` and
clause 2 with `6 PAYEE_NOT_ALLOWED`; reporting the last gives **6**, which is what the demo
page's widen button requires (`reason === 6`). Reporting the first would silently break the
face-scan beat.

### Gas

The account caps the policy call at `POLICY_GAS = 200_000` (`LeashAccount.sol:61`).
`PolicySet` must cap each member below that and leave headroom for its own loop. The cap and
the maximum member count are to be **measured during implementation, not assumed**; if two
members plus overhead come close to 200k, that is a finding to surface rather than absorb.

---

## `MicroPaymentPolicy`

```
CAP — immutable, set in the constructor, no setter

tokenAllowed ?           no → 5 TOKEN_NOT_ALLOWED    a small payment in a strange token is still strange
amount ≤ CAP ?           no → 7 OVER_TX_LIMIT        it is a per-transaction cap, which is what 7 means
inside the period budget? no → 8 OVER_PERIOD_LIMIT
                                                     payeeAllowed is deliberately NOT checked
```

The budget check is not optional. Without it an agent drains a 50 USDC period budget in
0.9 USDC slices without ever meeting a human — the exception would swallow the rule.

`CAP` immutable for the same reason as the member list: a different cap is a different
address and a fresh approval.

---

## The demo composition

```
PolicySet(
  clause 1 = [ MicroPaymentPolicy(1 USDC) ]      small, to anyone, still inside the budget
  clause 2 = [ StandardPolicy ]                  the full rules
)
```

| intent | amount | payee | outcome |
|---|---|---|---|
| `retainer` | 5.00 | `0x…beef`, allow-listed | clause 1 fails (over cap) → clause 2 passes ✅ |
| `newvendor` | 5.00 | `0x…cafe0`, not listed | both fail → reason **6** → the face-scan beat ❌ |
| `apitopup` | 0.50 | `0x…f00d`, not listed | clause 1 passes; clause 2 never runs ✅ |

The third row carries the whole argument for OR without anyone having to explain disjunctive
normal form: **two payments to strangers, one refused and one allowed, and the only
difference is the size.**

**AND appears in the machinery and the tests, not on screen.** `MicroPaymentPolicy` does its
own budget check, so clause 1 has a single member. Showing AND in the demo would need a third
contract for no gain in a four-minute video; the README says AND is supported and the tests
prove it.

---

## What does not change

**No deployed contract changes.** `LeashAccount`, `LeashRegistry`, `LeashResolver`,
`PolicyApprovals`, `StandardPolicy`, `WorldAttester` and `LeashLens` are all untouched —
`PolicySet` is reached through the same `IPolicy` interface the account already calls, the
same ENS pointer it already resolves, and the same approval list it already checks.

The subgraph needs no change either: `PolicyPointerSet` is already indexed, so swapping the
pointer shows up in the demo page's POLICY panel on its own.

> ### Correction, 2026-09-11 — this section originally said "Nothing already deployed
> ### changes", and that was false
>
> The final review found the sentence wrong in the one place it mattered. **`agent/decide.mjs`
> encodes `StandardPolicy`'s rules in JavaScript** — the payee allow-list and the period
> budget — even though it opens by forbidding itself exactly that ("what this function must
> never do is re-derive policy logic"). Nothing in the interface makes that visible: the
> agent never reads `describe()` and never asks which policy is installed. Swapping the
> pointer to a `PolicySet` therefore left the agent refusing a payment the chain allows,
> which also inverts the module's own stated safety direction — `decide.mjs:4` claims it is
> "trustworthy when it refuses and not when it permits".
>
> The lesson is not about this one file. **"Nothing already deployed changes" is a statement
> about contracts, and it was used as though it were a statement about the system.** The
> offchain half had absorbed a copy of the onchain rules, so a change that was genuinely
> contract-local was not system-local. A spec that swaps an implementation behind an
> interface has to name every consumer that has learned more about that implementation than
> the interface promises.
>
> `decide` now takes the address of the policy whose rules it encodes and applies its
> policy-layer predictions only to that address; for any other policy it defers to the chain.
> The demo consequences of the swap, including why the ENS pointer moves to `PolicySet`
> only *after* the face-scan beat, are recorded in the plan's SDD ledger.

---

## Files

| Action | File |
|---|---|
| create | `src/PolicySet.sol` |
| create | `src/MicroPaymentPolicy.sol` |
| create | `test/PolicySet.t.sol` |
| create | `test/MicroPaymentPolicy.t.sol` |
| modify | `agent/intents.json` — add `apitopup` |
| modify | `docs/deployments.md` — the two addresses and the swap |
| unchanged | every other contract, the subgraph, `world/` |

---

## Testing

Foundry, matching `test/StandardPolicy.t.sol`'s shape: a `_ok()` baseline context, then one
test per deviation.

| What | Why it is not obvious |
|---|---|
| A clause of two members passes only when both pass | the AND that never reaches the screen |
| A later clause rescues an earlier failure | the OR itself |
| A passing first clause short-circuits | the second clause's members must not be called at all |
| All clauses failing reports the **last** clause's reason | the decision above; a wrong answer here breaks the demo silently |
| A member that reverts returns 12 | fail closed |
| A member returning 33 bytes returns 12 | length check, not just success |
| A member returning 256 returns 12 | the `uint8` clamp — the same mutation that was found load-bearing in `_askPolicy` |
| A member address with **no code** returns 12 | a `staticcall` to an address with no code *succeeds* and returns zero bytes; without the length check that reads as `OK` and allows the payment |
| The constructor reverts on an empty clause list, an empty clause, and a zero member | an empty clause passes vacuously, and one of those allows every payment ever submitted |
| **A member that writes storage returns 12** | proves the `staticcall`, with a deliberately stateful mock member |
| `MicroPaymentPolicy` refuses an over-budget micro payment | the slice-draining hole |
| `MicroPaymentPolicy` ignores `payeeAllowed` | its entire purpose |
| The three demo intents produce ✅ / 6 / ✅ against the real composition | the demo, pinned as a test |

Every test that pins a reason code must fail if that code changes — this project has shipped
seven tests that passed without exercising the property they named, so the reason-code tests
assert the exact number, not merely "not OK".

---

## Out of scope, recorded so it is not re-litigated

| Not doing | Why |
|---|---|
| Nested expressions | DNF covers every rule anyone has asked for; nesting needs a parser |
| A stateful member | `staticcall` forbids it, deliberately — see above |
| Making the account aware of composition | it already is not; that is the point |
| A new reason code for "no clause passed" | the codes are frozen, and the last clause's reason is more useful anyway |
| Changing `SpendContext` | frozen, and the one rule that would need it was rejected above |
