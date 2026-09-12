# The demo — story, run of show, and what can go wrong

> Written 2026-09-12 for the ETHOnline submission video (2–4 minutes, no AI voiceover, no
> speed-ups, no phone recordings). Everything below has been run end to end on Sepolia.

---

## The one sentence

**A person asks an AI to send money, the AI agrees, and the chain says no.**

Everything else in this project exists to make that sentence true rather than asserted.

### What this is, and what it is not

Leash is **a permission engine for AI agent wallets**: what an agent may spend and who it
may pay lives in a contract, and the wallet enforces it on every transaction.

A studio's payables is the demo's **vehicle**, not its claim, and getting that round the
wrong way is expensive. Framed as a finance tool, the obvious questions are "where is the
approval queue, the nested budget, the second signature?" — and an accounts-payable product
missing those is an incomplete accounts-payable product. Framed correctly, none of them are
this layer's job; they are what an application builds on top. **The cold open states the
general capability once, before any of the studio's furniture arrives**, so everything after
it reads as an instance of it.

If a judge asks where the approval workflow is, the answer is one sentence, not an apology:
that is application-layer, and the rule this engine enforces is whatever contract you point
the name at.

## The argument, in three moves

**The problem.** An AI agent that can spend money needs a spending limit, and every existing
answer puts that limit somewhere the agent can reach: a config file it reads, an API key it
holds, a session key whose cap the agent itself enforces. Compromise the agent and the limit
goes with it.

**The answer.** Put the rule in a contract, find it through ENS, and make the wallet itself
ask it before every agent-initiated transfer. The agent has no way around this because the
check happens *inside its own execution path* rather than beside it.

**The consequence, which is the part worth filming.** The agent can be as wrong as it likes.
It can be persuaded, confused, or compromised, and the money still does not move. So the
demo is not "watch our agent behave well" — it is **watch our agent try something and fail**.

---

## Before you record

### The state the page must start in

| | |
|---|---|
| ENS pointer | `StandardPolicy` (`0x88F2…bc33b`) — **not** PolicySet |
| `bluefin.leash.eth`'s address | on the allow-list? **no**, and never was |
| `api.leash.eth`'s address | on the allow-list? **no**, and never was |
| `acme.leash.eth`'s address | **yes** — the retainer has to succeed |
| Agents | **both** started, each with an empty intent list |
| `AGENT2` bound? | yes — `bindingOf(0x2160…9F8a)` returns the same node as `AGENT` |
| Budget | 50.00 USDC/day, and **under 2.00 already spent** — see below |
| Owner's face | registered — `ownerNullifier()` is non-zero |

### 🔴 The budget has to start low, and there is only one way to lower it

Beat 3 needs the 48.00 renewal to be refused *by the day's spending*, not by the day's
spending plus yesterday's. `tightenRule` deliberately leaves `period` and `epoch` alone, so
**no reduction can clear the ledger** — clearing it is a widening, and `setRule`'s
attestation is the price. There is no cheap reset.

So the budget resets on its own or not at all. `period` is 86400, and
`spent[node][token][block.timestamp / 86400]` rolls to a fresh key at **00:00 UTC — 08:00
Taipei**. Record after that and the day starts near zero by itself.

If you must record on a day already spent, the beats still work: every amount above is
chosen so the refusal holds from any starting point under 2.00, and beat 3's 48 holds from
any starting point at all.

### 🔴 The two that will quietly spoil the story

Both come from having rehearsed, and neither is visible until you look at the payee panel.

**1. A payee you have already widened reads `revoked`, not `not on the list`.** The panel has
four states and it is telling the truth: `everAllowed` is set the moment `PayeeAllowed` fires
and it is never cleared, so a payee that was approved and then removed says so. For beat 2
you want a vendor nobody has ever approved — "we just hired them" — not one that was approved
and dropped, which is a different and less flattering story.

**2. A payee you have already paid reads `paid, never listed` before you have paid it.** That
is the punchline of beat 3 sitting on screen from the first frame.

**The fix uses the indirection ENS is for.** Do not touch `agent/vendors.json` — point the
names at fresh addresses:

```
LeashResolver.setPolicy(namehash("bluefin.leash.eth"), <a fresh address>)
LeashResolver.setPolicy(namehash("api.leash.eth"),     <a fresh address>)
```

The directory still says `bluefin.leash.eth`, the agent still resolves it off the chain, and
the payee panel resets because it is keyed by address. Two transactions from ADMIN.

### 🔴 The subgraph will rate-limit you

The Graph's Studio limits **per deployment**, and a 15-second tick left running overnight
will exhaust it. When it does, the page says `subgraph is rate-limiting us; retrying in Ns`
and the agent backs off — correct behaviour, terrible footage.

**Deploy a fresh version the morning you record.** `graph deploy --version-label v0.0.N`
with identical code gets a fresh allowance; that is measured, not assumed (v0.0.5 and v0.0.6
answered 200 while v0.0.7 was throttled). Then start the agent only when you are ready.

### 🔴 The World action, and the advice that used to be here

**`WORLD_ACTION` must be `leash-owner`, and must not be rotated.**

This file previously said the opposite — "use an action this person has not verified
before" — which was true before the wallet had a face registered and is now a way to lose a
take. A nullifier is `hash(person, action)`. `allowPayeeByFace` refuses anything that is not
the registered `ownerNullifier`, so a *fresh* action produces a *different* number and the
widening is refused by design. The scan is spent either way.

The binding is checkable rather than remembered:

```
ownerNullifier()                    0x180f9ee1…b49e881   (on chain, right now)
a leash-owner scan, 2026-09-11      0x180f9ee1…b49e881   (getDebugReport, evidence E9)
```

Re-verifying an action that has already been used succeeds — World answers *"Proof verified
successfully (nullifier reuse)"* — so the same action works for every take and every
rehearsal. Nothing needs rotating between them.

`precheck` does mint actions on demand, so the Portal is not involved either way; that part
of the old advice still holds. It is only the *choice* of action that was wrong.

### What is on screen

One browser at 1440px or wider, and your phone mirrored beside it. The QR lives inside the
page, so both surfaces show something the whole time. No terminal is needed at any point.

---

## Run of show

Two agents, four beats. Aim for 3 minutes; the cap is 4.

**The page is open twice**, side by side: `localhost:8787/?agent=payments` and
`localhost:8787/?agent=subscriptions`. Same wallet, same budget panel, different agent —
which is the whole argument, visible before a word is spoken. One window works too; the
tabs at the top of **01 THE AGENTS** switch between them.

### Opening — 0:00

Say what this is **before** the scenario. One sentence, once, and never again:

> "A permission engine for AI agent wallets. What an agent may spend and who it may pay
> lives in a contract on chain, and the wallet enforces it on every transaction — instead of
> the agent enforcing it on itself. Here is the example that makes that legible."

Then read the masthead aloud: `leash.eth › vendors.leash.eth · 0x46C0…8eba6`.

> "A company, a wallet, and two AI agents that can spend from it. One pays invoices, one
> handles renewals. Their permissions are not in a config file — they are on chain, under
> that name."

Point at **03 THE RULE**: the name resolves, every tick, to a policy contract, and the
sentence under it is what a human wrote when they approved that address. Then the budget:
**50 USDC a day, and both agents are listed under it.**

### Beat 1 — the agent is real — 0:20

On the **payments** window:

> **Pay this month's studio retainer.**

The model takes four or five seconds.

> "A language model is deciding what to pay. It never writes an address — it picks a vendor
> from a directory of ENS names, and the address comes off the chain."

5.00 USDC to `acme.leash.eth`. Paid. The budget moves to 5.00 of 50.

### Beat 2 — a face is the only way past a refusal — 0:50

Still on **payments**:

> **Bluefin Design finished the rebrand. Pay their first invoice.**

Refused, in red, `6 · PAYEE_NOT_ALLOWED`, with the dashed line pointing at the allow-list.
Then the agent comes back and says so in its own words.

Point at **Refused by the chain**, directly below:

> "And that is why we can show you this — every payment this wallet has refused, who asked
> for it, and why. **No contract can be asked that question.** A refusal is a no-op plus an
> event, not a revert, so the index is the only place it exists."

Four things on the page carry a `from the index` note for the same reason: this list, the
payee allow-list, the list of approved rules, and the per-agent split of the budget. None of
them can be read back from a contract.

**Do not say the refusal on screen "is in that list" — it is not, and a judge may check.**
The red card is a prediction: the agent read the rule off the index and declined to spend
gas on a payment it could see would fail, so no transaction exists and there is nothing to
index. The list holds only refusals the chain actually issued. The page says so in a line
under it. If asked, that is a better answer than a worse one: an agent that burns gas
proving what it already knows is a worse agent, and the case that *does* land in the list —
the pre-flight being wrong and the contract catching it — is on chain twice already
(`docs/deployments.md`).

> "Nothing the agent could have said would have changed that. The rule is not in the agent."

Press **Approve this payee with a face scan**. Scan with World App — the front camera opens.

> "Widening what an agent may do costs a live human. Not a key — a face. The wallet has one
> World ID registered, and no key, not even its own, can change which one."

The widening relays itself; on the next tick the payment goes through. Budget: 10.00 of 50.

### Beat 3 — one budget, two agents — 1:50

**This is the beat the second window is for.** Switch to **subscriptions**:

> **Renew our annual design-tools licence with Acme — 48.00 USDC for the year.**

The vendor is on the allow-list. The amount is under the per-transaction cap. It is refused
anyway: `8 · OVER_PERIOD_LIMIT`.

> "This agent has spent one dollar all day. It has never met the other one — different key,
> different process, no shared database, no message between them. And it is out of money,
> because a colleague spent it."

Point at the split under the budget bar: two names, one track.

> "The ledger on chain is keyed by the name, the token and the day. **There is no agent in
> that key.** So the budget is not a property of an agent — it is a property of the company,
> and the chain is what adds it up."

Then the line that connects it back to beat 2:

> "And notice what my face bought a minute ago. It added a payee. It did not add a penny."

### Beat 4 — the rule itself is swappable — 2:40

Scroll to **05 THE ADMIN KEY**. Two approved rules; one is live. Read the second one aloud —
a human wrote it at approval time:

> **"Under 1.00 USDC to any payee, or the full StandardPolicy rules."**

Press **point the name here**, then on the **payments** window:

> **Top up our inference API credits by 50 cents.**

> "ADMIN can move this pointer. ADMIN cannot approve a rule — that needs an attestation, and
> the attester is immutable. So the worst a stolen admin key does is pick between rules a
> human already approved."

The payment goes through and the payee panel reads **`paid, never listed`**.

> "That address was never approved by anybody. It was paid because the rule now says a small
> enough payment doesn't need approval. Two payments to strangers: one refused, one allowed,
> and the only difference is the size."

### Close — 3:20

> "Nobody reviewed anything today. Two agents proposed all of it, the chain decided all of
> it — and it would have decided identically if either agent had been compromised, confused,
> or lying."

Then close on the boundary, stated as a capability rather than a missing feature:

> "And the rule is a contract. Today's reads a payee, a cap, a budget, a time window — swap
> it and it reads something else, with no change to how the wallet enforces it. **This
> governs who may move money. It is not an opinion about your books.**"

> "Every refusal is on Sepolia, because a blocked payment emits an event rather than
> reverting, which is the only reason you can see it at all."

---

## Why the numbers are these numbers

| | amount | why that one |
|---|---|---|
| retainer | 5.00 | unchanged since March; the payment nobody wants to make by hand |
| Bluefin's first invoice | 5.00 | a new counterparty — the one case where interrupting a human is right |
| annual licence | **48.00** | chosen so the refusal survives a skipped face scan: 5 + 48 and 10 + 48 both exceed 50 |
| API top-up | 0.50 | under `MicroPaymentPolicy`'s 1.00 cap, which is the only reason beat 4 lands |

The 48 is not cosmetic. If beat 2's scan fails and you carry on, the budget is at 5.00
rather than 10.00 — and a 45 would then pass, turning the demo's best beat into nothing at
all. 48 refuses in both worlds.

---

## If something goes wrong

| What you see | What it is | What to do |
|---|---|---|
| `subgraph is rate-limiting us` | Studio quota for this deployment | Stop. Deploy a fresh version label, restart, re-record |
| The scan fails, World App says "try again" | Happens; nothing reaches our server, so nothing is diagnosable | Retry once. It worked on the second attempt on 2026-09-12 |
| The QR never appears | The request threw before rendering | Check the browser console; `/facetest` isolates the World half |
| The widening relays but the agent does not pay | The index is behind | Wait one more tick. The counter under the button is the honest answer |
| The relay fails after a successful scan | The attestation is signed and valid for 15 minutes | The calldata on screen is valid **from any sender** — `allowPayeeByFace` has no `onlySelf` |
| Everything blocks with `3 NO_POLICY` | The ENS pointer is not set | `setPolicy(node, StandardPolicy)`. This is also the proof that ENS is load-bearing |
| A tab says `offline` | That agent's process is not running | Start it; the page recovers on its own within a tick. The tab keeps its name and address, and the other agent keeps working — which is why this is easy to miss until beat 3 |
| `this agent's process is not answering` | The agent you are *looking at* died | Everything below that banner is the last thing it said, and is marked as such. The chain is unaffected; restart the process and the banner clears itself |
| Beat 3's 48.00 goes **through** | The day started at zero and 48 < 50 | Nothing is wrong with the system; the budget was emptier than the script assumed. Ask the payments agent for one more payment and try again |
| The split under the budget shows one agent | `AGENT2` is not bound, or the index has not caught up | `bindingOf(AGENT2)` should return the vendors node. The parts always sum to the total — if they do not, the walk ran off the end of the fetched page |

**Do not restart an agent mid-take.** Intent state is in memory, so a restart re-proposes
everything and pays the retainer a second time. This is per process: restarting the
subscriptions agent does not touch what the payments agent has done, and vice versa.

---

## After the take

Reset for the next one:

1. `setPolicy(node, StandardPolicy)` — put the pointer back
2. Point `bluefin.leash.eth` and `api.leash.eth` at fresh addresses
3. **Leave `WORLD_ACTION` alone** — it is `leash-owner` and rotating it breaks the scan
4. Restart **both** agents with an empty intent list

The budget is the one thing a reset cannot undo — see the note above. A second take on the
same day starts from wherever the first one left it.

`removePayee` also exists and needs no attestation — but it leaves `everAllowed` set, so the
payee reads `revoked` afterwards. Moving the ENS record is the cleaner reset, and it is the
better demonstration of what a name indirection is for.
