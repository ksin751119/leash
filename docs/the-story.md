# The story

> The narration, written to be read aloud over the demo. Roughly three minutes at speaking
> pace. Stage directions are in brackets; everything else is the script.
>
> There is one rule behind every line here: **nothing is claimed that the screen does not
> show.** Where the narration says the chain refused something, the chain refused it, and
> the transaction is on Sepolia.

---

## Cold open

> [the page, idle]

Here is a company, an AI agent that works for it, and a wallet that agent can spend from.

We gave a machine our money. That is the part everyone is nervous about, and they are right
to be — so the interesting question is not whether you trust the agent. It is **what happens
when you shouldn't.**

> [point at 03 THE RULE]

This agent's permissions are not in a config file it reads. They are a contract, found by
walking an ENS name, every single time it tries to spend. Whatever the agent believes about
what it may do, this is the thing that decides.

---

## One — the ordinary month

> [type the first instruction]

So let's give it a month's work.

> [the model runs; four or five seconds]

A language model is reading that and deciding what to pay. It never writes an address — it
picks a vendor by name, and the address comes off the chain.

> [two payments appear; the retainer is paid]

The studio retainer goes through. Five dollars, to a vendor we've paid every month since
March. Nothing remarkable, and that is the point: **this is the system working.**

---

## Two — the refusal

> [the second payment is red]

And this one doesn't.

The agent wanted to top up our inference credits. Fifty cents. It read the instruction
correctly, it picked the right vendor, and it was refused — because that payee has never
been approved, and this wallet does not pay strangers.

Notice what did **not** happen. Nobody caught the agent. No filter, no review queue, no human
in the loop. The wallet asked the rule, the rule said no, and no money moved.

> [the agent's second message appears]

And now the agent finds out — the same way you did, by asking the chain.

That is worth sitting with. **The agent is not the adversary here.** It is an employee who
does not have the key to the safe. You don't get security by hoping it behaves. You get it
because the safe is a safe.

> [press the face scan button; scan]

Now — we do want to pay them. And loosening what an agent may do costs a live human being.
Not a key. A face.

This wallet has one World ID registered against it, and **no key can change which one** — not
ADMIN's, not even the wallet's own. Someone who steals every private key we own can spend
inside the limits they find, and can make them tighter. They cannot make them looser.

> [the widening lands; the next tick runs]

Nobody told the agent. It asked again, and the answer had changed.

---

## Three — the shape of loosening

> [the payment goes through; scroll to 05]

But look at what my face actually bought: **one payee, permanently.**

That is the right price for a new contractor's first invoice. It is an absurd price for fifty
cents of API credit from a provider we may use exactly once.

And there is a deeper problem. **You cannot pre-approve the world.** An agent that only ever
meets counterparties you listed in advance is a scheduled script — it is most of the reason
to have an agent at all that it meets people you did not plan for.

So don't widen the list. **Change what the rule is.**

> [read the second rule's description]

Here is a second rule a human has already approved: *small payments to anyone, or the full
original rules.* A corporate card has said this for fifty years.

> [press "point the name here"]

ADMIN can point the name at it. ADMIN **cannot approve a rule** — that needs an attestation,
and the attester can never be changed. So the worst a stolen admin key does is choose between
rules a human already agreed to.

> [the next tick; the payment goes through]

Same agent. Same payee — still not on the allow-list, look — and now it goes through, because
the rule now says a small enough payment doesn't need to be on a list.

**Two payments to strangers. One refused, one allowed. The only difference is the size.**

---

## Close

The agent proposed all of this. The chain decided all of it.

And every refusal you saw is on Sepolia, permanently, because a blocked payment here emits an
event instead of reverting. **A system that hides its refusals is only telling you about the
days it worked.** This one shows you both.

---

## Why the parts are the parts

For anyone asking what each piece is doing — one line each, and none of them decorative:

**ENS** is the lookup path, twice over. The policy is found by walking a name, and so is
every payee: `agent/vendors.json` contains no addresses at all. Break either walk and the
agent cannot work out who to pay or what it is allowed to do. That is not a claim — it
happened by accident on 2026-09-12 and the block numbers are in `docs/deployments.md`.

**The Graph** is how the agent knows anything. A policy contract governs one transaction;
only an index has the view across time. And because a refusal is an event rather than a
revert, the index is the only reason a blocked payment is visible at all.

**World** is the asymmetry. Expansion costs a live human; reduction is free, because when
something has gone wrong nobody should have to find their phone before pulling the brake.
