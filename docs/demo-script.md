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

### Run the check, don't read a list

```bash
./preflight.sh
```

It is read-only — no transaction, no process started — and it verifies every one of the
things below against the live chain. Each check exists because something went wrong once.
Fix the FAILs, run it again, and record when it says READY.

```
1. the face          WORLD_ACTION is leash-owner; ownerNullifier matches it
2. the rule          the pointer is StandardPolicy; both policies are approved
3. the payees        acme allowed, bluefin and api not
4. the budget        how much room is left, and which beats still fit in it
5. money and gas     the wallet's USDC, and ETH on AGENT / AGENT2 / ADMIN
6. the binding       both agents on vendors.leash.eth — beat 3 is nothing without it
7. the index         the subgraph answers 200 and is within a few blocks
8. the processes     page on 8787, both agents on 8788 / 8789
```

The budget check reports **which beats still fit** rather than a bare pass/fail, because a
partly-spent day is the normal case and the beat carrying the only unmeasured wait — the
face scan — needs 5.50 of room while a full run needs 10.50. Knowing you can still rehearse
the scan is worth more at 2am than being told to wait.

**A check that can report green on its own failure is worse than no check.** The first
version read `spentInCurrentPeriod` without its token argument, `cast` errored, the empty
string became `0` through a shell default, and it printed *"0.00 of 50.00 — the script's
numbers will match"* over a budget that was 42.00. Every read now returns `ERR` on failure
and every caller treats `ERR` as a mismatch.

### The order on the day

1. `./preflight.sh` — expect warnings about the processes, nothing else
2. `./reset-demo.sh` — only if step 1 flagged the pointer or a payee. It generates the fresh addresses itself
3. `./run-demo.sh --dry` — starts the page and both agents, pays nothing
4. `./preflight.sh` again — now everything should be green
5. Open both windows: `?agent=payments` and `?agent=subscriptions`
6. Record
7. **`./run-demo.sh --stop`** — or the subgraph quota is gone by morning

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

**The quota is not spent by recording. It is spent by leaving the agents running.** Two
agents ticking every 8 seconds is 900 queries an hour; idle overnight is about ten thousand,
and that is how v0.0.7, v0.0.9 and v0.0.10 each died — none of them to anybody using the
demo. On the page it reads as `no name resolves here`, which looks like the project is
broken when only the allowance is.

**So: `./run-demo.sh --stop` whenever you walk away.** A deployment that is not being
queried keeps its allowance, and the same version label lasts across days.

If one does get throttled, `graph deploy --version-label v0.0.N` with identical code gets a
fresh allowance — measured, not assumed (v0.0.5 and v0.0.6 answered 200 while v0.0.7 was
throttled). Treat that as the repair, not the routine: redeploying every morning is treating
the symptom, and it costs a sync wait you do not want before a take.

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

## The no-edit take: fire everything, acknowledge it later

**Do not stand and watch a payment land.** Type the next instruction and keep talking; the
completion arrives on its own, and you point at it when it does.

This is the difference between a take that runs six minutes and one that runs four, and it
needs no editing at all. The three chain waits — about 25 s after beat 1, about 15 s after
the scan, about 15 s after the policy switch — all disappear underneath narration that
belongs to a *later* beat.

| # | do this | and immediately say | what lands underneath |
|---|---|---|---|
| 1 | — | the cold open | — |
| 2 | type **beat 1** | beat 1's narration (Claude never touches an address…) | — |
| 3 | type **beat 2** — do NOT wait for beat 1 | beat 2's refusal block | **beat 1 turns DONE.** Glance at it: *"and the retainer went through while we were talking"* |
| 4 | press the scan button, scan | the World block | — |
| 5 | switch window, type **beat 3** | beat 3's narration | **beat 2's payment lands** |
| 6 | back to payments, type **beat 4** | beat 4's first half | — |
| 7 | press **point the name here** | the admin block, then the close | **beat 4's card turns DONE.** Point at it: *"and there it is"* |

Three lines in the script are therefore said **when you see them happen**, not where they
sit on the page:

- *"The retainer is paid. No approval. No human click."*
- *"Nobody told the agent. It tried again, and the answer had changed."*
- *"The rule changed, and the same fifty cents went through."*

Everything on screen is in one merged list, so nothing scrolls away while you wait — a card
that turned green three beats ago is still there to point at.

### What this cannot compress

One Sepolia block is twelve seconds and there are three payments, so about 36 s of the take
is chain no matter what. Pipelining hides it under narration; nothing removes it.

---

## Run of show — what you do, and what you say while it happens

Every wait below is measured (see *How long it actually takes*). The narration in the
**say** column is sized to cover it; where it runs short, that is where you cut.

Two browser windows, side by side: `localhost:8787/?agent=payments` on the left,
`?agent=subscriptions` on the right. Phone unlocked with World App open. Start recording.

**Every instruction is typed.** There are no preset buttons — a page with a
"click here to demo" button undercuts the one thing this beat is showing, which is a person
telling an AI what to do in English. Keep `docs/instructions.txt` open and paste one at a
time; the first three beats are all in the payments window and only beat 3 switches.

---

### Cold open · no clicking · ~35 s

| | |
|---|---|
| **do** | nothing. The page is idle |
| **point at** | the ENS panel (middle of the band), then the budget panel beside it |
| **say** | *"AI agents can already move money…"* → *"Fifty dollars per day."* |
| **on screen** | `vendors.leash.eth` · `StandardPolicy/1: …` · `0.00 of 50.00` |

If the budget does not read `0.00`, the numbers you are about to say are wrong. Stop and
read the budget note below.

---

### Beat 1 · the retainer · ~35 s

| | |
|---|---|
| **do** | type it into the **payments** window |
| **type** | `Pay this month's studio retainer.` |
| **⏱** | **21.8 s** before the card appears — keep talking |
| **say** | *"It's the first of the month…"* → *"One dollar out of fifty."* |
| **watch for** | a card with **DONE**, then the budget bar moving to `1.00` about **6 s** later |

The card appears already DONE — the model, the send and the receipt all happen inside that
one wait. There is no "pending" state to narrate.

---

### Beat 2 · the refusal, and the face · ~75 s

| | |
|---|---|
| **do** | **still the payments window** — beat 2 does not switch agents |
| **type** | `Bluefin Design finished the rebrand. Pay their first invoice.` |
| **⏱** | **~10 s** — nothing is sent, so there is no receipt to wait for |
| **watch for** | red card · `6 · PAYEE_NOT_ALLOWED` · the amber button lights up · right panel gains `0x0000…0c0de  not on the list` |
| **say** | *"Now, a new contractor…"* → *"We can audit what they tried to do."* |

Then:

| | |
|---|---|
| **do** | press **Approve this payee with a face scan** |
| **watch for** | a QR inside the page |
| **do** | scan with World App — **the front camera must open.** If it only asks for device verification, stop: the wrong credential was requested |
| **say** | *"But this contractor is real…"* → *"No key can do this — not the agent's, not ours."* |
| **⏱** | **unmeasured.** This is the number the rehearsal is for |
| **watch for** | `YOUR FACE APPROVED IT — THE AGENT WILL NOTICE ON ITS NEXT TICK` |
| **⏱** | **~8–16 s** for the next tick |
| **say** | *"We don't message the agent…"* → *"Three dollars out of fifty."* |
| **watch for** | the card turns **DONE**, budget `3.00`, the payee row flips to **allowed** |

If the scan runs long, cut while the phone is up. The World App interaction is worth
showing; every second of it is not.

---

### Beat 3 · two agents, one budget · ~45 s

| | |
|---|---|
| **do** | move to the **subscriptions** window (or click its tab) |
| **type** | `Renew our annual design-tools licence with Acme Studio — 48.00 USDC for the year.` |
| **⏱** | **~10 s** |
| **watch for** | `8 · OVER_PERIOD_LIMIT` and the line *"this would exceed the period budget — 47.00 left of 50.00 USDC, and this payment is 48.00"* |
| **say** | *"Now let's switch agents…"* → *"Another forty-eight would break the daily budget."* |
| **point at** | the agent's **third** message — its own words, unprompted |
| **say** | *"And the agent understands that from the chain."* |
| **point at** | the split under the budget bar: two names, one track |
| **say** | *"This is why the budget doesn't belong to an agent…"* → *"I didn't add a single dollar to the budget."* |

This beat sends no transaction and costs nothing. It is repeatable if a take goes wrong.

---

### Beat 4 · switching the rule · ~50 s

| | |
|---|---|
| **do** | scroll the right column to **The admin key** |
| **say** | *"Here we have another policy that a human already approved…"* → *"We can combine policies with an OR."* |
| **do** | press **point the name here** on the second rule |
| **⏱** | **~12–15 s**, one Sepolia block |
| **say** | *"The admin key points the name at a different policy…"* → *"the account checks it on every payment."* |
| **watch for** | the green edge moves to `0xec45…92490`; the band's rule description changes |
| **do** | back to the **payments** window |
| **type** | `Top up our inference API credits by 50 cents.` |
| **⏱** | **21.8 s** |
| **say** | *"Now let's try fifty cents…"* → *"That's just another policy."* |
| **watch for** | **DONE**, and the payee panel showing `0x0000…0face  paid, never listed` |

**Do not say the two refused payees are the same one.** Beat 2 refused `0x…c0de`; this is
`0x…face`. Both addresses are on screen and a viewer reading them would catch it. The
script says *"another payee nobody has approved"*, which is the true version and the
stronger one.

---

### 🔴 If a judge asks: "so what stops ADMIN approving its own policy?"

**Nothing, in this deployment. Say so.**

`PolicyApprovals.approve` is `external` with no owner; its only gate is
`attester.verify`, and the attester wired in is `MockAttester`, which returns `true` for any
input. A stolen admin key could approve a policy of its own and then point the name at it.

The design is right and the mechanism is real — `attester` is `immutable` with no setter,
so the gate cannot be moved once it is right. It simply is not right yet: fixing it means
redeploying `PolicyApprovals`, then `LeashAccount` (whose `APPROVALS` is also `immutable`),
re-delegating the wallet, and re-approving both policies through a face-scan flow that does
not exist on our server. It is in `README.md` and `docs/deployments.md`, in both places
marked with a warning rather than buried.

**What is enforced today, and is worth saying instead:** the account refuses any policy that
is not on the approval list, with reason code 4. That is a real check on a real list, made
on every payment, and the narration claims exactly that and nothing more. An earlier draft
claimed the stronger thing; it was cut for this reason, and this is the third time in this
project that this particular claim has had to be walked back.

### Close · no clicking · ~30 s

| | |
|---|---|
| **do** | nothing |
| **say** | *"Today, no human reviewed these payments…"* → *"even if the agent is compromised, the rules stay the same."* |

Stop recording. Then **`./run-demo.sh --stop`**.

---

## Why the numbers are these numbers

| | amount | why that one |
|---|---|---|
| retainer | **1.00** | the payment nobody wants to make by hand, and small enough to repeat |
| Bluefin's first invoice | **2.00** | a new counterparty — the one case where interrupting a human is right. Above `MicroPaymentPolicy`'s 1.00 cap, so it stays refused whichever policy is installed |
| annual licence | **48.00** | refused by the day's spending, not by its own size. 3.00 + 48.00 = 51.00 against a 50.00 limit |
| API top-up | **0.50** | under the 1.00 cap, which is the only reason beat 4 lands |

### A full run costs 3.50, and that is the point

| | |
|---|---|
| a complete four-beat run | **3.50** |
| against a daily budget of | 50.00 |
| **takes available per day** | **14** |

They were 5.00 and 5.00, which is 10.50 a run and **four takes a day** — and a bad morning
runs out of budget long before it runs out of time. Nothing in the script depends on the
figures being large; three of them are spoken aloud and the narration was changed to match
in the same commit.

### Most of a take costs nothing to redo

The video is cut between shots anyway, so a fumbled beat is reshot on its own rather than
by starting again:

| | cost to retry |
|---|---|
| **beat 3** — the shared-budget refusal | **free.** It is refused, so no transaction exists |
| **the face scan itself** | **free.** `leash-owner` is reused; World answers "nullifier reuse" |
| **the policy switch** | **free** but for gas |
| beat 1 | 1.00 |
| beat 2's payment after the scan | 2.00, and it needs `./reset-demo.sh` first so the payee is unapproved again |
| beat 4's top-up | 0.50 |

Only three actions in the whole demo spend anything.

### The budget cannot be reset, and that is the product

`spent[node][token][bucket]` moves only when `epoch` or `period` does, and both are written
only by `setRule`, which takes an attestation from the real `WorldAttester`. Raising a limit
costs a live human — which is the thing the video is about, so hitting it from the inside is
the design working rather than a gap to route around.

It zeroes itself at **00:00 UTC / 08:00 Taipei** and not otherwise. `preflight.sh` prints the
countdown and says which beats still fit in whatever is left.

## How long it actually takes

The word count measures talking. It does not measure **waiting**, and the waiting is what
decides whether this fits in four minutes.

Measured on 2026-09-12 against the live deployment, not estimated:

| what you do | what you wait for | measured |
|---|---|---|
| press **Ask** (a payment that will go through) | model plans, agent reads the index, sends, and the receipt comes back — the card appears already **DONE** | **21.8 s** |
| ↳ of which, the model alone | | 3.7 – 7.1 s (n=4) |
| then | the budget bar moves (the index catches up) | **+6.1 s** |
| press **Ask** (a payment that will be refused) | model only — nothing is sent, so there is no receipt to wait for | **8.5 – 11.2 s** |
| press **point the name here** | one Sepolia block | ~12 – 15 s |
| **the face scan** | open World App, scan, camera, liveness, relay | **not measured — you have to run it** |

**Add it up and the raw take is six to six and a half minutes** against a four-minute cap.
That is not a problem, because cuts between shots are allowed and speed-ups are not: the
dead time comes out in the edit. But it has to come out deliberately, which means knowing
where it is before you record.

### Talk over the waits, don't wait in silence

The script is written so each wait has narration sized to cover it. Where it does not, the
gap is where you cut.

| wait | what you say over it | fits? |
|---|---|---|
| beat 1, 21.8 s | "Claude is deciding what to pay… it can't make up an address and send money there." (~50 words, ~18 s) | close — a couple of seconds to trim |
| beat 2, ~10 s | "Now we have a new contractor… It picks the right vendor." (~22 words, ~8 s) | yes |
| the face scan, ? | "But this contractor is real… An API key or an agent key cannot do this." (~60 words, ~22 s) | **unknown until you time the scan** |
| widening → next tick | "And we don't need to tell the agent anything… Now the payment goes through." (~20 words, ~7 s) | short — expect to cut |
| beat 4 swap, ~15 s | "The admin key can point the ENS name… rules a human already agreed to." (~45 words, ~16 s) | yes |
| beat 4 payment, ~22 s | "And this time, it works… The difference is the amount." (~35 words, ~13 s) | short by ~9 s — cut |

### The one number only you can measure

**Time the face scan on a full rehearsal**, phone in hand, from pressing the button to the
payment landing. It is the longest single wait and the only one that cannot be talked over
comfortably, because you are holding a phone and looking at it rather than at the screen.

If it runs past ~25 seconds, the honest fix is an edit cut while the phone is up — the World
App interaction is worth showing, but not every second of it.

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
