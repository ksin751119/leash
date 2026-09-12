# The story

> The narration, to be read aloud over the demo. Stage directions in brackets; everything
> else is the script.
>
> One rule behind every line: **nothing is claimed that the screen does not show.** Where the
> narration says the chain refused something, the chain refused it, and the transaction is on
> Sepolia.

---

## Cold open — the job nobody wants

> [the page, idle]

It's the first of the month, and somebody at this four-person studio has to do the payables.

There's the design studio we keep on retainer. There's a contractor we signed last week.
There's the inference API, which needs topping up roughly every other day and costs about
fifty cents a time.

It's two hours of work and nobody's favourite two hours. **Every one of us would hand it to
an agent tomorrow.**

We don't. Not because an agent would be bad at it — it would be good at it. We don't because
**the way it goes wrong has no ceiling.**

An agent that reads invoices can be told, by an invoice, to pay somebody else. A key can
leak. A model can be confidently wrong about an address. And none of those have an undo. So
we keep doing it by hand, and the safe version of this just doesn't exist.

> [point at 03 THE RULE]

That's what this is. The agent's spending limit isn't a setting it reads — it's a contract,
found by walking an ENS name, checked on every single payment it tries to make.

---

## One — the first of the month

> [type the instruction]

So: a month's payables.

> [the model runs, four or five seconds]

A language model is reading that and deciding what to pay. Notice it never writes an
address — it picks a vendor by name, and the address comes off the chain.

> [two payments; the retainer is paid]

Retainer's done. Five dollars, same as every month since March. **That's the part we wanted
automated, and it just happened.**

---

## Two — the payment you'd want to be asked about

> [the second line is red]

And this one doesn't.

Fifty cents of API credit, to a provider we've never paid before. The agent read the
instruction correctly and chose the right vendor — and the wallet refused it, because that
payee has never been approved.

Now, notice what didn't happen. **Nobody caught it.** There's no filter here, no review
queue, nobody watching a dashboard. The wallet asked the rule, the rule said no, and the
money didn't move.

That's the whole difference. Every other way of doing this puts the limit somewhere the agent
can reach — a config file, an API key, a session key it enforces itself. **Compromise the
agent and you get the limit too.** Here, whatever the agent believes about what it may do is
irrelevant.

> [the agent's second message appears]

And now it finds out — the same way you just did, by asking the chain.

**The agent isn't the adversary.** It's an employee who doesn't have the key to the safe. You
don't get safety by hoping it behaves; you get it because the safe is a safe.

> [press the button; scan]

But we *do* want to pay them. And loosening what an agent may do costs a live human. Not a
key — a face.

One World ID is registered against this wallet, and **no key can change which one.** Steal
every private key we own: you can spend inside the limits you find, and you can make them
tighter. You cannot make them looser.

> [the widening lands; next tick]

Nobody told the agent. It asked again, and the answer had changed.

---

## Three — the payment you'd hate to be asked about

> [payment goes through; scroll to 05]

Except — look at what my face just bought. **One payee. Permanently.**

For a new contractor's first invoice, that's exactly right. I *want* to be interrupted for
that one.

For fifty cents of API credit, twice a week, from providers we try once and drop? **That's a
phone call at 2am about a coffee.** And it doesn't scale: an agent that can only pay
counterparties I listed in advance is a scheduled script. Meeting people I didn't plan for is
most of the reason to have an agent.

So don't widen the list. **Change the rule.**

> [read the second rule's description]

Here's a second rule, already approved by a human: *small payments to anyone, or the full
original rules.* Every corporate card in the world has worked this way for fifty years — a
limit you don't need a signature under.

> [press "point the name here"]

Admin can point the name at it. Admin **cannot approve a rule** — so the worst a stolen admin
key does is pick between rules a human already agreed to.

> [next tick; payment goes through]

Same agent. Same payee — still not on the allow-list, look — and now it goes through.

**Two payments to strangers. One refused, one allowed, and the only difference is the size.**

---

## Close

Nobody reviewed anything today. The agent proposed all of it, and the chain decided all of
it — and it would have decided exactly the same way if the agent had been compromised,
confused, or lying.

> [gesture at the refusals]

And every refusal is still there, on Sepolia, because a blocked payment here emits an event
rather than reverting. **A system that hides its refusals is only telling you about the days
it worked.**

That's the two hours back.

---

## Not in the video

The per-sponsor summary lives in the README. It is the right thing to read and the wrong
thing to say aloud: a video that stops to explain its own architecture has stopped being a
demo.

## Why these three vendors

They are not arbitrary — each one is a different answer to "should a human look at this?"

| | the payment | should a human see it? |
|---|---|---|
| **Acme Studio** | the retainer, monthly, unchanged since March | no — this is the work you wanted automated |
| **Bluefin Design** | a new contractor's first invoice | **yes** — a new counterparty is exactly when to interrupt someone |
| **the inference API** | fifty cents, twice a week, a provider you may drop | no — and asking is worse than not asking |

The demo works because those three sit at different points on one axis, and a single
allow-list cannot tell them apart. That is the argument for composing rules, and it is why
the third beat is a rule change rather than another face scan.
