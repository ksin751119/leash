# Prize requirements and how we meet them

> Requirements taken from each sponsor's prize page for ETHGlobal ETHOnline 2026
> (2026-09-01, rechecked 2026-09-07) . A submission may target at most **3** partner prizes.
>
> ⚠️ **Rule found on 2026-09-07: multiple tracks from one sponsor count as a single partner
> prize slot.**
> Their words: "If a partner offers multiple tracks, applicants can qualify for all while
> only counting as a single partner prize selection."
> → Having chosen The Graph, we can win whichever of its three tracks we qualify for
>   **at no extra slot cost**.
> → ENS's second track (Best Integration into Existing Project, $500) is **Continuity
>   only** and unavailable to us.
> → World's second track (AgentKit, $3,500) is also **Continuity only** and unavailable.

---

## ✅ ENS — Best Use of ENSv2 · $4,500

**4 places**: 1st $1,500 / 2nd $1,500 / 3rd $1,000 / Runner-Up $500

| Requirement | How we meet it |
|---|---|
| Must be built on **ENSv2 (Sepolia) ** | ✅ we are on Sepolia anyway |
| **ENSv2 features central to the product, not a cosmetic add-on** | ⚠️ see below |
| The demo must actually run; no hard-coded values | ✅ |
| Open source plus a video or a live demo (both is better) | ✅ |
| **Bonus: incorporating AI agents as namespaces** | ✅✅ this is the entire project |

The features it names: hierarchical registry, wildcard resolution, **Enhanced Access
Control**,
**Permissioned Resolvers**, record/namespace aliasing, subname ecosystems.

### What counts as central rather than cosmetic

**The decorative version**: the agent has an ENS name; it looks nice. → Wins nothing.

**The central version**: **ENS *is* the policy's lookup path**. The 7702 delegate must walk
the registry on every execution to resolve the policy address. Remove ENS and the spend
cannot pass.

Add the three revocation layers (change the record / take back the subname /
`setSubregistry` to kill everything) and the native `expiry`, and **all four ways to stop an
agent come from native ENSv2 features**.

### Mapped to the features it names

| What ENS names | Where we use it |
|---|---|
| Hierarchical registry | the company is the parent name and each agent a subname; `acme.eth` hangs our own registry |
| Enhanced Access Control | a security team gets a "can revoke" role and no "can spend" role |
| Permissioned Resolvers | the policy pointer lives in the resolver, and who may change it is governed by EAC |
| Subname ecosystems | one company, many agents, each with its own limits |
| AI agents as namespaces | ✅ bonus |

---

## ✅ The Graph — Best AI Tooling or AI Use Case (From Scratch)

**1st $2,500 / 2nd $1,500 / 3rd $1,000** (ranked)

| Requirement | How we meet it |
|---|---|
| **Use The Graph as a load-bearing part** | ⚠️ see below |
| Must consume **live data** (Subgraph Studio or The Graph Market) ; **no mocks or local data** | ✅ we index real events from our own contracts |
| **Do meaningful work with the data**: reasoning, decisions, automation or a natural-language interface | ✅ three of the four |
| **Must be net-new work begun during hackathon** | ✅ Start from Scratch |
| Open source, a clear README, a public repo, and a **2-4 minute video** | ✅ |

### What counts as load-bearing

**The weak version**: build a dashboard showing history. → They say explicitly that "just
querying a subgraph" is not enough.

**The strong version**: **the agent queries the subgraph itself to make decisions.** Before
acting it asks:

1. How much of my budget is left this month?
2. Has the company ever paid this address before? A first appearance deserves more care
3. How much have all three of the company's agents spent together? (A single policy contract
   cannot see the others)
4. Why was I blocked last time?

**A policy contract governs one transaction; only the subgraph has the view across time and
across agents.** Remove the subgraph and the agent is blind, able only to fire off
transactions and be blocked on chain.

→ reasoning ✅ decisions ✅ automation ✅

### The other track (not chosen)

**Track 1: Best Use of Composable or Standardized Graph Products** ($5,000,1st/2nd/3rd)
— it requires "composing two or more Graph products" or "building on a standardized
schema".

**Reassessed 2026-09-07:** since multiple tracks from one sponsor count as a single slot,
**entering it costs no slot at all**. We still will not build anything specifically for it —
if the main line finishes with time to spare, consider wiring in one more Graph product
 (the Token API, say) to qualify as composable. **Listed as a post-9/12 stretch goal and not
scheduled.**

---

## ✅ World — Selfie Check · $3,500

**3 places at $1,166 each** (confirmed 2026-09-07; originally unpublished)

| Requirement | How we meet it |
|---|---|
| Uses Selfie Check (or a compatible World ID credential flow) **in a meaningful way** | ✅ it is the only entrance to widening |
| Used as a **risk / eligibility / fairness / continuity / abuse-prevention signal** | ✅ **abuse-prevention**, word for word |
| Remote testing and demoing with the **World ID Sandbox App** | ⚠️ has to be learned; **not yet researched** |
| Submit a **feedback document** (integration experience, the Developer Portal, the state of Sandbox, friction encountered) | ⚠️ extra work |
| Demonstrate a working application | ✅ |

### The angle: only loosening permissions needs a face scan

| Action | Selfie Check |
|---|---|
| Issue a new agent subname | ✅ yes |
| Raise a limit | ✅ yes |
| Allow-list a new payee | ✅ yes |
| **Revoke an agent / lower a limit** | ❌ **no** |

**The argument is solid**: the first thing a compromised agent wants is to register more
permissive rules for itself. Locking "change the rules" behind a real human is the textbook
use of abuse-prevention. And reductions must never be blocked — when something has gone
wrong, hunting for your phone is the last thing you want to do.

### Two gates; do not conflate them (verified 2026-09-01)

Getting Selfie Check running means **passing two gates, applied for through different
channels**:

| Gate | Channel | What it is | Source |
|---|---|---|---|
| **1. Permission to install the Sandbox App** | a **Google Form**, https://forms.gle/mqbaiwMvX5MzmKdY8 | titled "World ID Sandbox Beta Access Request"; it asks only for an email and grants **Firebase App Distribution** access | ETHGlobal's World prize page → Resources → Sandbox Access |
| **2. The Selfie Check (Beta) feature flag** | **email** developers@toolsforhumanity.com | include your app_id; World enables the flag on your app | stated on three separate docs.world.org pages |

**The form does not enable the feature flag** — it asks only for an email, never for an
app_id, and says outright that it grants Firebase App Distribution. Both have to be
submitted.

The feature-flag gate appears three times in the documentation:

* `world-id/idkit/credentials#selfie-check-beta` — "[Request access] (mailto:developers@toolsforhumanity.com) to enable Selfie Check (Beta) for your app." (**ETHGlobal's prize page links straight to this one**)
* `world-id/credentials/11` — "Selfie Check (Beta) is access-gated. To use it, request access so the feature flag can be enabled for your app."
* `world-id/sandbox/testing-selfie-check` — "Selfie Check (Beta) must be enabled for your app before you can test it."

All three are Mintlify `<Warning>` components, which render as coloured callout boxes and
are easy to skim past. Appending `.md` to any docs.world.org URL returns the raw markdown.

### Scoring weights (transcribed 2026-09-07 from the official workshop recording)

Read out item by item by Mateo Sauton (Tools for Humanity) at the ETHGlobal × World
workshop:

| Weight | Item |
|---|---|
| **30%** | strategic fit — does this integration mean anything for World's products |
| **25%** | **the quality of the feedback document** ← "don't be nice"; he said explicitly that he wants to hear the bad news |
| 20% | product quality |
| 15% | technical integration (whether IDKit / AgentKit are wired correctly) |
| 10% | whether it continues after the event |

**The feedback document is a quarter of the score, not a side assignment.**
`world-feedback.md`'s priority moves up — it matters as much as the frontend, and we have
real material (five days with no reply, three pages telling three different stories,
misleading naming) .

The 10% is answered by `PLAN.md`'s v2 sections: control/execution plane separation, and
one-shot batch authorisation.

### What he said explicitly will not win (none of it is us, but note it)

- A static demo with no end-to-end integration
- Plain agent reputation (they have seen far too many)
- An e-commerce demo that just "gives agents a discount" (they built one themselves)

What he wants is **new verticals**. Our angle — gating privilege expansion on an agent
wallet — is not on that exclusion list.

### A naming trap that costs half a day

Two of IDKit's credential labels are counter-intuitive:

| SDK label | What it actually is |
|---|---|
| **`selfieCheckLegacy`** | **Selfie Check ← this is the one we want** |
| `proofOfHuman` | Orb verification (high assurance) |
| `passport` | an NFC passport |
| `identityCheck` | document attributes (age, nationality, …) |
| `orbLegacy` / `secureDocumentLegacy` / `documentLegacy` | the old World ID 3.0 presets |
| `deviceLegacy` | deprecated; the docs tell you to switch to Selfie Check |

"legacy" looks like the discarded option, and it is the correct one. **Do not pick
`proofOfHuman`.** (Cross-checked against the official credentials page on 2026-09-07: the
recording says them colloquially, while the SDK uses camelCase. `deviceLegacy` is deprecated
and the docs point at Selfie Check — which explains why "legacy" ends up on the right
answer.)

> ⚠️ **Selfie Check currently runs World ID 3.0, not 4.0.** Their words: "Currently uses
> World ID 3.0 technology, with World ID 4.0 support not yet available."
> The inference drawn at the time: v4's `rp_context` (the backend signing an RP signature
> first) is **unused**, and backend verification goes to the **v2 endpoint taking an
> `app_id`** rather than `/api/v4/verify/{rp_id}`.
>
> ⚠️ **That inference was wrong, and measurement on 2026-09-07 disproved it.** v2 answers
> this app with `invalid_action` for every action, real or fake, because the app was created
> as a 4.0 RP. Verification must go to **v4** with `protocol_version: "3.0"`. See
> `world/README.md`.

V3 and V4 proofs are both usable.

### Note

World's other track, **AgentKit** ($3,500) , says **Continuity only** and is out of reach.
The workshop confirmed something further: **AgentKit only accepts Orb-verified World ID, and
Selfie Check cannot be used to register on AgentBook** — so it would not connect even under
From Scratch, and ruling it out was the right call. Selfie Check has no such restriction.
World's total pool is $7,000, split evenly between the two tracks.

**The cost**: one extra feedback document. Seen the other way, tracks with homework
attached usually attract fewer entries.

---

## ❌ Ruled out: Hedera x402 · $6,000

The most attractive prize on paper ($6,000, three fixed places at $2,000 each) , but
**architecturally it does not connect**.

Hedera's exact scheme is **not** the EVM's EIP-3009 but a native `TransferTransaction`.
From the specification:

> The decompiled transaction MUST be a `TransferTransaction` **directly**.
> It MUST NOT be wrapped in a `ScheduleCreateTransaction`.

The flow: the client signs a partially-signed `TransferTransaction` with **its own key** →
the facilitator co-signs as fee payer → it is submitted.

**The problem: the payer must be a Hedera account that can sign with a key, and a Hedera
contract account has no such key.**

→ **Our policy wallet cannot be the payer.** The agent would have to pay from an
unconstrained account with the policy layer entirely out of the loop — the project would
vanish from its own demo.

 (In theory Hedera's "contract ID as account key" mechanism might offer a path, but that is
completely untrodden ground and not what a solo entrant should bet nine days on.)

### Two further points of friction

- **Hedera has no EIP-7702** — HIP-1341 is approved but not live;
  hiero-consensus-node#20043 is still OPEN, blocked on Besu 25.4.1, with no timeline
- **The Graph has no hosted service on Hedera** — the documentation requires running your own
  graph node, or switching to Goldsky

### But x402 itself is usable for us

The EVM version of x402 **supports contract wallets** — the reference implementation has
complete **ERC-1271** (deployed) and **EIP-6492** (counterfactual) signature verification.
That submission just would not go to Hedera. Out of scope for now.

---

## ❌ Ruled out: Arc · $2,500 / $2,500 / $5,000 (all split evenly)

Conceptually it fits well (Track 2, Best Agentic Economy, is exactly about autonomous agents
transacting from USDC wallets) , and Arc has EIP-7702 and USDC as gas. **But the cost
structure is wrong.**

| Requirement | The problem |
|---|---|
| **Functional MVP with working frontend, backend, and architecture diagram** | ❌ **all three** tracks mandate a frontend |
| Track 2 requires the **Circle Agent Stack** | ❌ a whole new family of Circle products to learn |
| Track 3 requires being **deployed or deployment-ready on Arc mainnet** by 9/30 | ⚠️ a second chain |
| A video, a slide deck and detailed documentation | ⚠️ more than the others ask |
| split evenly | ⚠️ no cap on places, so the more entrants the smaller each share |

**Arc is the only one of the four candidates that would require building something extra.**
The other three are the work we are doing anyway, told from a different angle.

---

## Summary

| | Fit | Extra cost | Places | Chain |
|---|---|---|---|---|
| **ENS** | native to the idea | put ENS in the resolution path | 4 | Sepolia |
| **The Graph** | high | make the agent really query it | 3 (ranked) | Sepolia |
| **World** | needs integrating, but the argument is solid | a new SDK plus a feedback document | 3 (at $1,166 each) | chain-agnostic |
| ~~Hedera~~ | **architectural conflict** | — | 3 | — |
| ~~Arc~~ | conceptually fits | a frontend, the whole Circle suite, and a second chain | split | Arc |

**Conclusion: ENS + The Graph + World Selfie Check, all on Sepolia — one chain, one set of
contracts, three submissions.**
