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
> **Length, measured rather than estimated.** As written it is over the cap; the three
> paragraphs marked **⟨cut⟩** are there to come out, in the order they appear, and the count
> with all three gone is printed at the bottom of this file. Even that leaves no margin at
> 165 words a minute, so **read it aloud with a timer before you record** — your pace is the
> only number that settles it, and a script that fits only on paper does not fit.
>
> Cutting between shots is allowed — only speed-ups are not — so the twenty seconds of face
> scan and the five seconds of model latency come out in the edit rather than out of the
> script.

---

## Cold open — what this is, then the example

> [the page, idle, two windows side by side]

A permission engine for AI agent wallets. **What an agent may spend, and who it may pay,
lives in a contract on chain, and the wallet enforces it on every transaction — instead of
the agent enforcing it on itself.**

Here is the example that makes that legible.

> [beat]

A four-person studio, and two AI agents already working here: one pays invoices, one
handles renewals.

At nine, the renewals agent puts through an annual licence. At eleven, the invoices agent
pays a contractor. At noon the account is empty, and the payment that mattered is the one
that fails.

**Neither agent did anything wrong.** Each stayed inside its limit. There were two limits
and one bank account.

> [point at 03 THE RULE]

So we stopped giving limits to agents. The limit belongs to a **name**, and the wallet
finds the rule by walking **ENS** on every payment: registry, subname, then the policy
address out of the resolver record.

Both agents work under that name. **One budget. Fifty dollars a day.**

---

## One — the part you wanted automated

> [payments window; type the instruction]

First of the month.

> [the model runs]

**Claude** is deciding what to pay — and notice what it never does. It never writes an
address. It picks a vendor by name, and those are **ENS records**. Our directory holds no
addresses at all. **A hallucinated payee has nowhere to appear.**

Retainer's done. Budget: five of fifty.

---

## Two — the payment you'd want to be asked about

> [same window; Bluefin's first invoice; the line turns red]

New contractor, first invoice. The agent read it correctly, picked the right vendor — and
the wallet refused it.

**Nobody caught it.** No filter, no review queue, no dashboard. The wallet asked the rule,
and the rule said: I have never heard of this payee.

⟨cut⟩ Every other way of doing this puts the limit somewhere the agent can reach —
a config file, an API key, a session key whose cap the agent enforces on itself. Compromise
the agent, you get the limit. **Here, what the agent believes it may do is irrelevant.**

> [the agent's next message]

And it finds out the same way you did — it reads **a subgraph on The Graph** every few
seconds. A blocked payment doesn't revert, it emits an event, so **the index is the only
place a refusal is visible.**

> [point at "what this wallet has turned away"]

And it's why we can show you this: **every payment this wallet has refused**, who asked,
and why. No contract can be asked that question.

> [press the button; scan]

But we do want to pay them. Loosening what an agent may do costs a live human — not a key, a
face. **World ID Selfie Check**: front camera, real liveness, and a proof this wallet checks
against **the one World ID it has registered.** No key can change which one.

⟨cut⟩ Steal every key we own: you can spend inside the limits you find. You cannot raise
them.

> [widening lands; next tick; paid]

Nobody told the agent. It asked again, and the answer had changed. Budget: ten of fifty.

---

## Three — the Tuesday, solved

> [switch to the subscriptions window]

The other agent. Different key, different process, one dollar spent all day.

> **Renew our annual design-tools licence — forty-eight dollars for the year.**

Vendor is on the allow-list. Amount is under the per-transaction cap. **Refused anyway** —
eight, over the period limit.

> [read its own words off the screen]

Listen to how it explains itself: *we'd need the budget increased, or expenses in other
categories reduced.* **Nobody told it another agent existed.** It read the chain and worked
out it has a colleague.

> [point at the split under the budget bar]

Two names, one track. The ledger on chain is keyed by the name, the token and the day —
**there is no agent in that key.** The budget was never an agent's. The chain is what adds
it up.

And notice what my face bought a minute ago. **It added a payee. It did not add a penny.**

---

## Four — the rule itself is a choice somebody made

> [scroll to 05; read the second rule aloud]

A second rule, already approved by a human: *small payments to anyone, or the full original
rules.* Two policy contracts composed with an OR.

> [press "point the name here"; then the payments window]

⟨cut⟩ Admin moves the **ENS** pointer. Admin **cannot approve a rule** — so a stolen admin
key picks between rules a human already agreed to, and nothing else.

Fifty cents to a provider still not on the allow-list, and it goes through.

**Two payments to strangers. One refused, one allowed. The only difference is the size.**

---

## Close

Nobody reviewed anything today. Two agents proposed all of it, the chain decided all of it —
and would have decided identically if either one were compromised or lying.

And the rule is a contract. Today's reads a payee, a cap, a budget, a window — **swap it
and it reads something else**, with no change to how the wallet enforces it. **This governs
who may move money. It is not an opinion about your books.**

And every refusal is on Sepolia — the list you saw is read back out of it. **A system that
hides its refusals is only telling you about the days it worked.**

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

## The count, so nobody has to trust an estimate

| | words | at 165 wpm |
|---|---|---|
| as written | **777** | 4.7 min |
| with all three **⟨cut⟩** paragraphs dropped | **682** | **4.1 min** |

Both are over the 4.0 cap. **This is not a script you can read at leisure** — it needs either
a faster delivery (180 wpm puts the cut version at 3.8) or one more paragraph out, and which
one depends on what your rehearsal shows is already obvious from the screen.

Regenerate these numbers after any edit:

```bash
python3 - <<'PY'
import re
t = open("docs/the-story.md").read().split("## Not spoken")[0]
para, cur = [], []
for l in t.splitlines():
    if l.startswith((">", "#", "---")):
        if cur: para.append(" ".join(cur)); cur = []
        continue
    if not l.strip():
        if cur: para.append(" ".join(cur)); cur = []
    else: cur.append(l.strip())
if cur: para.append(" ".join(cur))
n = lambda p: len(re.sub(r"[*`\[\]⟨⟩]", " ", p).split())
tot = sum(n(p) for p in para)
cut = sum(n(p) for p in para if p.startswith("⟨cut⟩"))
print(f"as written {tot} ({tot/165:.1f} min) | with cuts {tot-cut} ({(tot-cut)/165:.1f} min)")
PY
```
