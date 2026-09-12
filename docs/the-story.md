# The story

> The narration, to be read aloud over the demo. Stage directions in brackets; everything
> else is the script.
>
> **Each sponsor's technology is named at the moment it does its work**, not in a section of
> its own. A video that stops to explain its architecture has stopped being a demo; a video
> that never says what it is built on has failed the people judging it.
>
> One rule behind every line: **nothing is claimed that the screen does not show.** Where the
> narration says something was refused, it was refused, and the transaction is on Sepolia.
>
> **Length is measured, not estimated: run `python3 docs/read-aloud.py`.** It prints this
> file as a reading script and counts it; the table at the bottom is that script's output.
> As written it is over the cap, and so is the version with all three **⟨cut⟩** paragraphs
> dropped — so **read it aloud with a timer before you record.** Your pace is the only
> number that settles it, and a script that fits only on paper does not fit.

---

## Cold open — what this is

> [page idle, two windows side by side]

This is a permission system for AI agent wallets.

The rules for what an agent can spend, and who it can pay, live in a smart contract.

The wallet checks those rules on every payment an agent makes.

So we don't need to trust the AI agent to follow the rules itself.

Here's a simple example.

> [beat]

We have a small studio with four people and two AI agents.

One agent pays invoices.

The other handles subscriptions.

⟨cut⟩ Imagine this:
At 9 AM, the subscription agent renews a yearly license.
At 11, the invoice agent pays a contractor.
At noon, there's no money left for an important payment.
Both agents followed their own limits.
The problem is: we had two separate limits, but only one account.

> [point at the band — the name, then the budget beside it]

So instead of giving each agent its own budget, we attach the budget to an ENS name.

For every payment, the wallet looks up that name on ENS and finds the policy contract.

Both agents use the same name.

So they share one budget:

Fifty dollars per day.

---

## One — a normal payment

> [payments window; type the instruction]

It's the first of the month.

> [the model runs]

Claude is deciding what to pay.

But notice: Claude never enters an address.

It only chooses a vendor by name.

Those names are ENS records.

Our vendor directory doesn't store wallet addresses at all.

So if the AI makes up a vendor, it can't make up an address and send money there.

> [payment completes]

The retainer is paid.

We've used five dollars out of fifty.

---

## Two — a payment that gets blocked

> [Bluefin's first invoice; the line turns red]

Now we have a new contractor.

This is their first invoice.

The agent reads the invoice correctly.

It picks the right vendor.

But the payment doesn't happen.

⟨cut⟩ And nobody had to review it.
There's no filter and no approval queue.

This payee has never been approved.

> [point at where the "no" came from]

And notice where that "no" came from.

Not from our backend.

The agent asked the chain what the rule is, and didn't even send the payment.

But the rule is not in the agent.

If it sent it anyway, the wallet would refuse.

> [point at the agent's next message, then "Refused by the chain"]

That has happened, and we can show you.

The agent reads our subgraph on The Graph every few seconds.

A refused payment doesn't revert — it emits an event.

So every refusal the wallet has made is here: who tried it, how much, and why.

No contract can be asked that question.

> [press the button; scan]

But this contractor is real, and we do want to pay them.

To give the agent more permission, we require a real person.

We use World ID Selfie Check.

I scan my face, prove I'm a real live person, and the wallet checks that proof against the one World ID registered to it.

An API key or an agent key cannot do this.

> [the permission lands; next tick; paid]

And we don't need to tell the agent anything.

It tries again.

The answer has changed.

Now the payment goes through.

We've used ten dollars out of fifty.

---

## Three — two agents, one budget

> [switch to the subscriptions window]

Now let's look at the other agent.

⟨cut⟩ Different agent.
Different key.
But the same shared budget.

> [type: Renew our annual design-tools licence — forty-eight dollars for the year.]

The vendor is approved.

The amount is below the per-transaction limit.

But the payment is still refused.

Why?

Because we already spent ten dollars today.

Another forty-eight would go over the daily budget.

> [point at the agent's response]

And look at what the agent says.

It knows the budget needs to increase, or spending somewhere else needs to go down.

⟨cut⟩ Nobody told this agent that another agent exists.
It just reads the chain and sees the shared budget.

> [point at the split under the budget bar]

The budget isn't attached to an agent.

It's attached to the ENS name.

Both agents spend from the same fifty dollars, and the chain adds it up.

Also notice:

When I used my face earlier, I only approved a new payee.

I did not increase the budget.

---

## Four — switching policies

> [right column, "The admin key"]

We also have a second policy that a human already approved.

⟨cut⟩ The first one has our normal rules.
The second allows very small payments to anyone.

We combine them with an OR.

> [press "point the name here"]

The admin key can point the ENS name at a different policy.

But only at one that is already on the approved list — never at arbitrary code.

So a stolen admin key can only choose between rules a human already agreed to.

> [payments window; fifty cents to the inference API]

Now fifty cents, to a provider that is not on the allow-list.

> [payment succeeds]

And this time, it works.

Same unknown payee.

The earlier payment was blocked.

This one is allowed.

The difference is the amount.

---

## Close

So today, nobody reviewed any of these payments.

The agents proposed them, the wallet checked the rules, and the chain decided.

Even if an agent is compromised, it still can't get past those rules.

⟨cut⟩ And because the policy is itself a smart contract, the rules can be changed or combined without changing the wallet.
Today we check payees, transaction limits, daily budgets and time windows.
Tomorrow the policy could check something completely different.

And every payment the wallet refused is recorded on Sepolia.

So we don't only see the payments that worked.

We can see what the agents tried to do, and exactly why the wallet said no.

---

## Not spoken

### The scenario is a vehicle, not a claim — and the difference is load-bearing

**We did not build a finance tool.** We built a permission engine, and a studio's payables
is the shortest path to showing what it does. Say it the wrong way round and the judges
reach for the wrong ruler: an accounts-payable product with no approval queue, no nested
budgets and no dual control is an incomplete accounts-payable product. A permission engine
has none of those because **none of them are its job** — they are things an application
builds on top of it.

The cold open is the fuse. It states the general capability once, before any of the
studio's furniture arrives, so everything after it reads as an instance. If a judge asks
"where's the approval workflow?", the answer is a sentence, not an apology: that is
application-layer, and the rule this engine enforces is whatever contract you point the name
at.

### Why this scenario and not "an agent goes rogue"

A rogue agent is a story about a villain, and every viewer has already decided whether they
believe in it. **Two honest agents and one bank account** is a story about arithmetic, and
nobody argues with it. It is also the thing that actually happens: teams do not deploy one
agent, they deploy a few, and the second one is where per-agent limits stop adding up.

It has the useful side effect of making the demo's hardest claim easy to check. "The agent
cannot exceed its limit" needs you to trust our threat model. "This agent has spent one
dollar and is out of money" needs you to read two numbers.

### Two scenarios considered and rejected

| | why not |
|---|---|
| one person's own agents — shopping, subscriptions, travel — on one wallet | warmer, but "a fifty-cent API top-up" and "a new contractor's first invoice" have no force in a personal setting, and beats two and four lose their tension |
| an AI product where each customer's agents share a credit pool | closest to a real market, but you have to explain the product before the demo can start — forty seconds gone in the cold open |

The studio wins on one property: **it needs no explaining.**

### Why these vendors

Each is a different answer to *should a human look at this?*

| | the payment | interrupt a human? |
|---|---|---|
| **Acme Studio** | retainer, monthly, unchanged since March | no — this is the work you wanted automated |
| **Bluefin Design** | a new contractor's first invoice | **yes** — a new counterparty is exactly when to ask |
| **the annual licence** | 48.00, from a second agent | no — and the refusal is not about *this* payment at all |
| **inference API** | fifty cents, a provider you may drop | no — and asking is worse than not asking |

They sit at four points on one axis, and **a single allow-list cannot tell them apart.**

### Where each sponsor lands, for the submission text

- **ENS** — the unit of authority, and load-bearing three times over. The policy is resolved
  by a three-hop walk on every spend; every payee address is an ENS record, and
  `agent/vendors.json` holds names only; and **the shared budget is shared because it is
  keyed by the name**, which is what makes a second agent a colleague rather than a second
  wallet. Break the walk and neither agent can work out what it may do or who to pay. That
  stopped being hypothetical on 2026-09-12 — block numbers in `docs/deployments.md`.
- **The Graph** — the agents' only sense organ, and the only thing either of them knows
  about the other. A policy contract governs one transaction; only an index has the view
  across agents and across time. Since refusals are events rather than reverts, a blocked
  payment exists nowhere else — and `buildCohort` reconstructs who spent what from that log,
  because the chain itself keeps no per-agent total.
- **World** — the asymmetry. Expansion costs a live human; reduction is free, because when
  something has gone wrong nobody should have to find their phone before pulling the brake.
  And the beat-three line is the precise statement of what a face is *for*: it adds a payee,
  not a budget.

---

## The count

`python3 docs/read-aloud.py` prints this file as a reading script — what you say, with what
you do and what you type marked — and counts it. **That script is the only source for these
numbers.** Counting them a second way by hand produced a different answer twice, and the
difference was the difference between fitting and not.

| | words | 165 wpm | 175 wpm |
|---|---|---|---|
| as written | **826** | 5.0 min | 4.7 min |
| with all five **⟨cut⟩** blocks dropped | **684** | 4.1 min | **3.9 min** |

**The cap is 4 minutes.** The cut version fits only at a brisk pace, and short declarative
lines are read faster than a words-per-minute model predicts — which is an argument for
timing yourself, not for trusting either number.

Every ⟨cut⟩ block is one whose point the screen has already made:

| block | why it survives being dropped |
|---|---|
| the Tuesday (9 AM / 11 / noon) | the hook, but the budget bar makes the same point in one glance |
| "no filter and no approval queue" | the refusal card is on screen with nobody having touched it |
| "different agent / different key" | the tab strip shows both, with both addresses |
| "nobody told this agent another exists" | the agent's own message says it better than the narration does |
| the two policy descriptions | both are on screen, written by the human who approved them |

Drop them in that order until it fits.

