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

## Cold open — AI can move money. But who sets the rules?

> [page idle, two windows side by side]

AI agents can already move money.

The hard part is not making them pay.

The hard part is making sure they can only pay what they're allowed to pay.

That's what we built.

A permission layer for AI agent wallets.

⟨cut⟩ The agent proposes a payment.
The wallet checks the rules.
And the chain decides.

The agent cannot bypass those rules — because the rules don't live in the agent.

They live on-chain.

Here's what that looks like.

> [beat]

We have a small studio with two AI agents.

One pays invoices.

The other handles subscriptions.

> [point at the name, then the budget]

But we don't give each agent its own budget.

They share one budget through an ENS name.

For every payment, the wallet resolves that name and finds the policy contract.

Two agents.

One account.

One shared budget.

Fifty dollars per day.

---

## One — let the agent do its job

> [payments window; type the instruction]

It's the first of the month.

> [the model runs]

Claude is deciding what to pay.

But notice something:

Claude never touches a wallet address.

It only chooses a vendor by name.

Those names are ENS records.

Our vendor directory doesn't even store wallet addresses.

So if the AI makes up a vendor, it can't just make up an address and send money there.

> [payment completes]

The retainer is paid.

No approval.

No human click.

Five dollars out of fifty.

⟨cut⟩ This is what we want:
let the agent work when it's inside the rules.

---

## Two — and stop it when it isn't

> [Bluefin's first invoice; the line turns red]

Now, a new contractor.

The agent reads the invoice correctly.

It finds the right vendor.

But the payment doesn't happen.

Why?

This payee has never been approved.

> [point at where the "no" came from]

And this is the important part:

the agent is not the security boundary.

The rule doesn't live in its prompt.

It doesn't live in a config file.

It lives on-chain.

The agent can disagree with the rule.

It can ignore it.

It can even be compromised.

Here, it didn't even send the payment — it read the rule and knew it would fail.

But if it sent it anyway, the wallet would still refuse.

And that has happened.

> [point at the agent's next message, then "Refused by the chain"]

The wallet emits an event when it blocks a payment.

The Graph indexes those events.

So here we can see every refusal the wallet actually made:

who tried it,

how much,

and why.

We don't just audit what agents did.

We can audit what they tried to do.

> [press the button; scan]

But this contractor is real.

So now we want to change the permission.

And this is where the human comes back in.

We use World ID Selfie Check.

I scan my face.

I prove that a real, live human is here.

And the wallet checks that proof against the World ID registered to it.

No key can do this — not the agent's, not ours.

> [the permission lands; next tick; paid]

We don't message the agent.

We don't restart it.

It tries again.

The on-chain permission has changed.

And the payment goes through.

Ten dollars out of fifty.

---

## Three — one budget across many agents

> [switch to the subscriptions window]

Now let's switch agents.

> [type: **Renew our annual design-tools licence — forty-eight dollars for the year.**]

This vendor is approved.

The payment itself is under the transaction limit.

But it's still refused.

Because the other agent already spent ten dollars.

Another forty-eight would break the daily budget.

> [point at the agent's response]

And the agent understands that from the chain.

> [point at the split under the budget bar]

This is why the budget doesn't belong to an agent.

It belongs to the ENS name.

You can have two agents.

Or twenty.

⟨cut⟩ They can use different models and different keys.
But they all share the same on-chain policy.

And when I approved that contractor earlier, I only added a payee.

I didn't add a single dollar to the budget.

---

## Four — policies are programmable

> [right column, "The admin key"]

⟨cut⟩ And these rules aren't hard-coded into the wallet.
They're policies.

Here we have another policy that a human already approved.

It allows very small payments to anyone.

We can combine policies with an OR.

> [press "point the name here"]

The admin key can switch between approved policies.

But it cannot introduce arbitrary code.

So even if the admin key is stolen, it can only choose rules a human already agreed to.

> [payments window; fifty cents to the inference API]

Now let's try fifty cents to a provider that isn't on the allow-list.

> [payment succeeds]

This time, it works.

Same unknown payee.

The large payment was blocked.

The small payment is allowed.

That's not a special case in our wallet.

That's just another policy.

---

## Close

Today, no human reviewed these payments.

The agents proposed.

The wallet checked.

The chain decided.

⟨cut⟩ When the agents stayed inside the rules, they worked automatically.
When they went outside the rules, the wallet stopped them.
And when the rules needed to change, a human came back into the loop.

That's the model:

Agents get autonomy.

Humans keep control.

And the rules live somewhere neither side can quietly change —

on-chain.

Every allowed payment is verifiable.

Every refusal the wallet made is visible.

And even if the agent is compromised, the rules stay the same.

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

`python3 docs/read-aloud.py` prints this file as a reading script; `--md` writes it to
`docs/narration.md`, which is git-ignored on purpose — it is a rendering of this file, and
tracking it would mean two copies that can disagree, with the hand-edited one being the one
that gets regenerated over. It — what you say, with what
you do and what you type marked — and counts it. **That script is the only source for these
numbers.**

| | words | 165 wpm | 175 wpm | 185 wpm |
|---|---|---|---|---|
| as written | **772** | 4.7 min | 4.4 min | 4.2 min |
| with all five **⟨cut⟩** blocks dropped | **683** | 4.1 min | **3.9 min** | 3.7 min |

**The cap is 4 minutes.** This version is built from short declarative lines with hard
stops, which are genuinely read faster than a words-per-minute model predicts — so the real
number is likely better than the table. It is still a reason to time yourself rather than to
trust the table.

Every ⟨cut⟩ block is one whose point something else already makes:

| block | why it survives being dropped |
|---|---|
| "The agent proposes / the wallet checks / the chain decides" | the close repeats it word for word, where it lands as a callback |
| "This is what we want: let the agent work inside the rules" | "No approval. No human click." just said it |
| "different models and different keys" | true and good, but "two agents or twenty" carries the point |
| "these rules aren't hard-coded, they're policies" | the next three lines demonstrate it |
| the close's three-line recap | the video has just shown all three |

Drop them in that order until it fits.

