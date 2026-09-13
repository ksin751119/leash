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

> [OPEN two windows: `?agent=payments` left, `?agent=subscriptions` right. Nothing to click]

AI agents can already move money.

The hard part is making sure they can only pay what they're allowed to pay.

That's what we built. A permission layer for AI agent wallets.

The rules don't live in the agent. They live on-chain.

> [pause — let the page sit]

A small studio, with two AI agents.

One pays invoices. The other handles subscriptions.

> [POINT at the ENS panel, then the budget beside it]

But we don't give each agent its own budget.

They share one, through an ENS name.

For every payment, the wallet resolves that name and finds the policy contract.

Two agents. One budget. Fifty dollars a day.

---

## One — let the agent do its job

> [TYPE, in the **payments** window: `Pay this month's studio retainer.`  ·  WAIT ~22s — keep talking]

It's the first of the month.

Claude is deciding what to pay.

But notice: it never touches a wallet address.

It picks a vendor by name, and those names are ENS records.

Our directory doesn't store addresses at all.

So a made-up vendor has nowhere to send money to.

> [SEE the card **DONE**, then the budget bar move ~6s later]

The retainer is paid. No approval. No human click.

---

## Two — and stop it when it isn't

> [STILL the **payments** window. TYPE `Bluefin Design finished the rebrand. Pay their first invoice.`  ·  WAIT ~10s  ·  SEE the red card, the amber button light, and the payee appear as **not on the list**]

Now a new contractor. Their first invoice.

The agent reads it correctly. It picks the right vendor.

But the payment doesn't happen.

This payee has never been approved.

> [POINT at the red card]

And notice where that "no" came from.

Not from our backend.

The agent asked the chain, and didn't even send the payment.

But the rule is not in the agent.

If it sent it anyway, the wallet would refuse — and that has happened.

> [POINT at **Refused by the chain** below the cards]

A refusal doesn't revert. It emits an event.

⟨cut⟩ So on Etherscan the transaction succeeded, and the payment didn't.

The Graph indexes those events.

So every refusal this wallet has made is here — who tried it, how much, and why.

We don't just audit what agents did. We audit what they tried to do.

> [PRESS **Approve this payee with a face scan**  ·  SCAN with World App — **the front camera must open**]

But this contractor is real.

To give the agent more permission, we require a person.

World ID Selfie Check. I scan my face, and prove a live human is here.

The wallet checks that proof against the one World ID registered to it.

No key can do this — not the agent's, not ours.

> [SEE `YOUR FACE APPROVED IT`  ·  WAIT one tick  ·  SEE the card turn **DONE**]

Nobody told the agent. It tried again, and the answer had changed.

---

## Three — one budget across many agents

> [MOVE to the **subscriptions** window  ·  TYPE `Renew our annual design-tools licence with Acme Studio — 48.00 USDC for the year.`  ·  WAIT ~10s]

Now the other agent. Different key, different process.

The vendor is approved. The amount is under the transaction limit.

Still refused.

Because the other agent already spent it.

Another forty-eight would break the daily budget.

> [POINT at the agent's third message — its own words]

And it worked that out from the chain. Nobody told it another agent exists.

> [POINT at the split under the budget bar]

The budget isn't attached to an agent. It's attached to the ENS name.

Two agents, or twenty — the chain adds it up.

And notice: my face added a payee. It didn't add a dollar.

---

## Four — policies are programmable

> [BACK to the **payments** window  ·  TYPE `Top up our inference API credits by 50 cents.`  ·  WAIT ~10s  ·  SEE `6 · PAYEE_NOT_ALLOWED` again]

One more. Fifty cents, to an API provider.

Refused, same reason. Nobody approved this payee.

But I'm not scanning my face for fifty cents.

⟨cut⟩ And I can't pre-approve every provider we might try once.

> [SCROLL the right column to **The admin key**]

So we don't change who we trust. We change the rule.

Here's a second policy a human already approved:

small payments to anyone — or the full original rules.

> [PRESS **point the name here**  ·  WAIT ~12–15s, one block]

Admin points the name at it.

And the wallet refuses any policy that isn't on the approved list.

> [WAIT one tick  ·  SEE the SAME card turn **DONE**, with a transaction link]

Now watch the payment we already tried.

I didn't retype it. I didn't touch the agent.

The rule changed, and the same fifty cents went through.

---

## Close

> [nothing to click. Let the finished page sit]

Nobody reviewed any of these payments.

The agents proposed. The wallet checked. The chain decided.

Even if an agent is compromised, it can't get past those rules.

That's the model. Agents get autonomy. Humans keep control.

And the rules live somewhere neither side can quietly change.

Every allowed payment is verifiable.

Every refusal the wallet made is visible.

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

`python3 docs/read-aloud.py` prints this file as a reading script and counts it. **That
script is the only source for these numbers.**

| | words | 150 wpm | 165 wpm |
|---|---|---|---|
| as written | **~600** | 4.0 | 3.6 |
| with both **⟨cut⟩** lines dropped | **572** | 3.8 | **3.5** |

**The cap is 4 minutes, and it is The Graph's** — verified on their prize page on
2026-09-13: *"a short demo video (two to four minutes)"*, on all three of their categories.
ENS asks for "a video or a live demo" with no length; World asks only for a working
application. We are submitting to The Graph, so four minutes binds.

### Why this is 572 words and not 711

An earlier version was 711 with every cut taken — **4.3 minutes of talking before a single
second of waiting**, which made a four-minute video arithmetically impossible. It got there
by accretion: each correctness fix added a clause, and none of them removed one.

The waits are real and measured (see *How long it actually takes*): about 80 seconds of
chain, plus the face scan. A raw take runs five to six minutes even when nothing goes
wrong, and the first real one ran nine. Cuts between shots are allowed and speed-ups are
not, so the edit has to remove two minutes or more — and it can only do that if the talking
leaves room for it.

Nothing load-bearing was dropped. What went was connective tissue: restatements, second
examples, and sentences whose point the screen was already making.

