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

We gave a machine our money. The interesting question isn't whether you trust it — it's
**what happens when you shouldn't.**

> [point at 03 THE RULE]

Its permissions aren't in a config file. They're a contract, found by walking an ENS name,
every time it tries to spend.

---

## One — the ordinary month

> [type the first instruction]

So let's give it a month's work.

> [the model runs; four or five seconds]

A language model is deciding what to pay. It never writes an address — it picks a vendor by
name, and the address comes off the chain.

> [two payments appear; the retainer is paid]

The retainer goes through. Nothing remarkable — and that's the point. **This is the system
working.**

---

## Two — the refusal

> [the second payment is red]

And this one doesn't.

Fifty cents of inference credit. The agent read the instruction correctly and picked the
right vendor — and it was refused, because that payee has never been approved.

Notice what did **not** happen. Nobody caught it. No filter, no review queue, no human in the
loop. The wallet asked the rule, the rule said no, and no money moved.

> [the agent's second message appears]

And now the agent finds out — the same way you did, by asking the chain.

**The agent isn't the adversary here.** It's an employee who doesn't have the key to the
safe. You don't get security by hoping it behaves. You get it because the safe is a safe.

> [press the face scan button; scan]

But we do want to pay them. And loosening what an agent may do costs a live human. Not a
key — a face.

One World ID is registered against this wallet, and **no key can change which one.** Steal
every key we own and you can spend inside the limits you find, and tighten them. You cannot
loosen them.

> [the widening lands; the next tick runs]

Nobody told the agent. It asked again, and the answer had changed.

---

## Three — the shape of loosening

> [the payment goes through; scroll to 05]

But look what my face bought: **one payee, permanently.**

Right price for a contractor's first invoice. Absurd for fifty cents from a provider we'll
use once. And **you cannot pre-approve the world** — an agent that only meets counterparties
you listed in advance is a scheduled script.

So don't widen the list. **Change the rule.**

> [read the second rule's description]

A second rule, already approved by a human: *small payments to anyone, or the full original
rules.* A corporate card has said this for fifty years.

> [press "point the name here"]

ADMIN can point the name at it. ADMIN **cannot approve a rule** — so the worst a stolen admin
key does is choose between rules a human already agreed to.

> [the next tick; the payment goes through]

Same agent, same payee — still not on the list, look — and now it goes through.

**Two payments to strangers. One refused, one allowed. The only difference is the size.**

---

## Close

The agent proposed all of this. The chain decided all of it.

And every refusal is on Sepolia, permanently, because a blocked payment emits an event
instead of reverting. **A system that hides its refusals is only telling you about the days
it worked.**

---

## Not in the video

The per-sponsor summary that used to live here has moved to the README. It is the right
thing to read and the wrong thing to say out loud: a video that stops to explain its own
architecture has stopped being a demo.
