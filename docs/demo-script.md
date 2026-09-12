# The demo — story, run of show, and what can go wrong

> Written 2026-09-12 for the ETHOnline submission video (2–4 minutes, no AI voiceover, no
> speed-ups, no phone recordings). Everything below has been run end to end on Sepolia.

---

## The one sentence

**A person asks an AI to send money, the AI agrees, and the chain says no.**

Everything else in this project exists to make that sentence true rather than asserted.

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
| Agent | started **once**, with an empty intent list |
| Owner's face | registered — `ownerNullifier()` is non-zero |

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

### The World action

`WORLD_ACTION` must be an action **this person has not verified before**. `precheck` mints
actions on demand, so any unused string works — the Portal is not involved. Use
`expand-policy-demo2` for the take and keep `demo3` spare.

`ownerNullifier` on the wallet is bound to the action `leash-owner`. **That is the action the
widening scan must use**, and it is what `WORLD_ACTION` is set to at scan time — a different
action produces a different nullifier and the account will refuse it, by design.

### What is on screen

One browser at 1440px or wider, and your phone mirrored beside it. The QR lives inside the
page, so both surfaces show something the whole time. No terminal is needed at any point.

---

## Run of show

Roughly 20 seconds of setup, then three beats. Aim for 3 minutes; the cap is 4.

### Opening — 0:00

The page, idle. Read the masthead aloud: `leash.eth › vendors.leash.eth · 0x46C0…8eba6`.

> "This is a company, an AI agent that works for it, and the wallet that agent can spend
> from. The agent's permissions are not in a config file. They are on chain, under that
> name."

Point at **03 THE RULE**: the name resolves, every tick, to a policy contract, and the
sentence under it is what a human wrote when they approved that address.

### Beat 1 — the agent is real — 0:20

Type, or click the first example:

> **Pay this month's studio retainer, and top up our inference API credits by 50 cents.**

The model takes four or five seconds. Say what is happening while it does:

> "A language model is deciding what to pay. It never writes an address — it picks a vendor
> from a directory of ENS names, and the address comes off the chain."

Two payments appear. The retainer is paid.

> "One went through."

### Beat 2 — the chain refuses, and a face is the only way past it — 0:50

The API top-up is refused, in red, with `6 · PAYEE_NOT_ALLOWED`, and the dashed line points
at the allow-list that explains it. Then the agent comes back and says so in its own words.

> "The agent wanted to pay that one too. The wallet's policy refused it, and the agent found
> out the same way you did — by asking the chain."

This is the moment. Say the thing the project is for:

> "Nothing the agent could have said would have changed that. The rule is not in the agent."

Press **Approve this payee with a face scan**. Scan with World App — the front camera opens.

> "Widening what an agent may do costs a live human. Not a key — a face. The wallet has one
> World ID registered, and no key, not even its own, can change which one."

The widening lands on chain by itself. Then, on the next tick:

> "Nobody told the agent. It asked again, and the answer had changed."

The payment goes through.

### Beat 3 — the rule itself is swappable — 2:00

Scroll to **05 THE ADMIN KEY**. Two approved rules; one is live.

> "A face scan doesn't approve a payment — it adds a payee, permanently. One scan, one
> counterparty, forever. That is exactly right for a new contractor's first invoice. It is
> absurd for a fifty-cent API top-up from a provider we may use once. **And you cannot
> pre-approve the world.** So don't change the allow-list — change the rule."

Read the second rule's description aloud; a human wrote it at approval time:

> **"Under 1.00 USDC to any payee, or the full StandardPolicy rules."**

Press **point the name here**.

> "ADMIN can move this pointer. ADMIN cannot approve a rule — that needs an attestation, and
> the attester is immutable. So the worst a stolen admin key does is pick between rules a
> human already approved."

Next tick, the refused payment goes through — and the payee panel now reads
**`paid, never listed`**.

> "That address was never approved. It was paid because the rule now says a small enough
> payment doesn't need approval. Two payments to strangers: one refused, one allowed, and the
> only difference is the size."

### Close — 2:40

> "The agent proposed all of this. The chain decided all of it. Everything you saw is on
> Sepolia — the refusals too, because a blocked payment emits an event rather than reverting,
> which is the only reason you can see it at all."

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

**Do not restart the agent mid-take.** Intent state is in memory, so a restart re-proposes
everything and pays the retainer a second time.

---

## After the take

Reset for the next one:

1. `setPolicy(node, StandardPolicy)` — put the pointer back
2. Point `bluefin.leash.eth` and `api.leash.eth` at fresh addresses
3. Set `WORLD_ACTION` to the next unused action
4. Restart the agent with an empty intent list

`removePayee` also exists and needs no attestation — but it leaves `everAllowed` set, so the
payee reads `revoked` afterwards. Moving the ENS record is the cleaner reset, and it is the
better demonstration of what a name indirection is for.
