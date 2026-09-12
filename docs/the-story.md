# The story

> The narration, to be read aloud over the demo. Stage directions in brackets; everything
> else is the script. Roughly 3½ minutes at speaking pace — the cap is four.
>
> **Each sponsor's technology is named at the moment it does its work**, not in a section of
> its own. A video that stops to explain its architecture has stopped being a demo; a video
> that never says what it is built on has failed the people judging it. The way through is to
> name the thing while it is happening.
>
> One rule behind every line: **nothing is claimed that the screen does not show.** Where the
> narration says the chain refused something, the chain refused it, and the transaction is on
> Sepolia.
>
> **Length, honestly: 660 spoken words.** At a brisk reading pace that is about 3.9 minutes
> and the cap is 4.0, so there is no margin. Cutting between shots is allowed — only
> speed-ups are not — so the twenty seconds of face scan and the five seconds of model
> latency come out in the edit rather than out of the script. If a rehearsal still runs long,
> the three paragraphs marked **⟨cut first⟩** come out in that order. They are the ones whose
> argument survives being made once instead of twice.

---

## Cold open — the job nobody wants

> [the page, idle]

First of the month, and somebody at this four-person studio has to do the payables. A design
studio on retainer, a contractor we signed last week, and an inference API that needs fifty
cents of credit twice a week.

Two hours, and nobody's favourite two. **All of us would hand this to an agent tomorrow.**

We don't — and not because an agent would be bad at it. Because **the way it goes wrong has
no ceiling.** An agent that reads invoices can be told, by an invoice, to pay someone else. A
key leaks. A model is confidently wrong about an address. None of it has an undo.

> [point at 03 THE RULE]

So the limit isn't a setting the agent reads. It's a contract, and the wallet finds it by
walking **ENS** — `leash.eth`, this agent's subname, then the policy address out of the
resolver record. Three hops, on every payment.

---

## One — the first of the month

> [type the instruction]

A month's payables, in a sentence.

> [the model runs]

**Claude** is deciding what to pay — and notice what it never does. It never writes an
address. It picks a vendor by name, and those are **ENS records too**: `acme.leash.eth`,
`bluefin.leash.eth`. Our vendor file has no addresses in it. **A hallucinated payee has
nowhere to appear.**

> [two payments; retainer paid]

Retainer's done. Five dollars, same as every month since March. **That's the part we wanted
automated, and it just happened.**

---

## Two — the payment you'd want to be asked about

> [second line turns red]

This one doesn't.

Fifty cents, to a provider we've never paid. The agent read the instruction correctly, chose
the right vendor — and the wallet refused it.

Notice what *didn't* happen. **Nobody caught it.** No filter, no review queue, nobody watching
a dashboard. The wallet asked the rule and the rule said no.

⟨cut first⟩ Every other way of doing this puts the limit where the agent can reach it.
Compromise the agent, you get the limit. **Here, what the agent believes it may do is
irrelevant.**

> [the agent's second message]

And now it finds out — the same way you did. It reads **a subgraph on The Graph** every few
seconds. A blocked payment here doesn't revert, it emits an event, so **the index is the only
place a refusal is visible at all.**

**The agent isn't the adversary.** It's an employee without the key to the safe.

> [press the button; scan]

But we do want to pay them. Loosening what an agent may do costs a live human — not a key, a
face. **World ID Selfie Check**: front camera, real liveness, and a proof this wallet checks
against **one specific World ID it has registered.** No key can change which one. ⟨cut third⟩ Steal
every key we own: you can spend inside the limits you find and tighten them. You cannot
loosen them.

> [widening lands; next tick]

Nobody told the agent. It asked again, and the answer had changed.

---

## Three — the payment you'd hate to be asked about

> [payment goes through; scroll to 05]

But look what my face bought. **One payee. Permanently.**

For a contractor's first invoice, that's right — I *want* interrupting for that. For fifty
cents twice a week from providers we try once? **That's a phone call at 2am about a coffee.**
⟨cut second⟩ And an agent that can only pay counterparties I listed in advance is a
scheduled script.

So don't widen the list. **Change the rule.**

> [read the second rule aloud]

A second rule, already approved by a human: *small payments to anyone, or the full original
rules.* Two policy contracts composed with an OR — every corporate card has worked this way
for fifty years.

> [press "point the name here"]

Admin moves the **ENS** pointer to it. Admin **cannot approve a rule** — so the worst a stolen
admin key does is pick between rules a human already agreed to.

> [next tick; payment goes through]

Same agent. Same payee — still not on the allow-list, look — and now it goes through.

**Two payments to strangers. One refused, one allowed. The only difference is the size.**

---

## Close

Nobody reviewed anything today. The agent proposed all of it, the chain decided all of it —
and it would have decided identically if the agent had been compromised, confused, or lying.

Every refusal is still on Sepolia. **A system that hides its refusals is only telling you
about the days it worked.**

That's the two hours back.

---

## Not spoken

### Why these three vendors

They are not arbitrary. Each is a different answer to *should a human look at this?*

| | the payment | interrupt a human? |
|---|---|---|
| **Acme Studio** | retainer, monthly, unchanged since March | no — this is the work you wanted automated |
| **Bluefin Design** | a new contractor's first invoice | **yes** — a new counterparty is exactly when to ask |
| **inference API** | fifty cents, twice a week, a provider you may drop | no — and asking is worse than not asking |

They sit at three points on one axis, and **a single allow-list cannot tell them apart.** That
is the argument for composing rules, and it is why beat three is a rule change rather than
another face scan.

### Where each sponsor lands, for the submission text

- **ENS** — twice, and load-bearing both times. The policy is resolved by a three-hop walk on
  every spend; every payee address is an ENS record, and `agent/vendors.json` holds names
  only. Break either walk and the agent cannot work out what it may do or who to pay. That
  stopped being hypothetical on 2026-09-12 — block numbers in `docs/deployments.md`.
- **The Graph** — the agent's only sense organ. A policy contract governs one transaction;
  only an index has the view across time, and since refusals are events rather than reverts,
  a blocked payment exists nowhere else.
- **World** — the asymmetry. Expansion costs a live human; reduction is free, because when
  something has gone wrong nobody should have to find their phone before pulling the brake.
