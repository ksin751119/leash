# Sprint Plan — Leash

**Window:** 2026-09-04 → 2026-09-14 (11 days)
**Team:** 1 person
**Sprint Goal:**

> Let an AI agent spend on chain, with the limit rules living under an ENS name where the
> agent cannot change them; the agent decides whether to send a transaction by querying a
> subgraph; a human face scan is required to loosen the rules, while tightening is always
> available.

---

## Assumptions (say if any are wrong; the whole plan recomputes)

| Assumption | Value | Effect |
|---|---|---|
| Hours available per day | **9** | Directly decides whether this finishes |
| Submission deadline | **9/14** | Everything must be done by 9/13; 9/14 is submission only |
| Video | 2-4 minutes, one shared across all three tracks | Saves 4 hours |

---

## Capacity

```
theoretical   11 days × 9 hours              = 99 hours
effective     × 70% (debugging, being stuck, redoing) = 69 hours
```

**The must-do items total 73 hours.**

> ⚠️ **That is 106% of capacity, so the buffer is negative.**
> Standard practice is a 20% buffer (committing to 55 hours). We cannot afford one.
> Hence the **pre-agreed cut list** below — when behind, cut in order rather than deciding
> in the moment.

---

## Work items

Points = hours. `M` = must (without it a prize is unreachable), `S` = should,
`X` = only with capacity to spare.

| # | Item | h | Level | Depends on | Risk |
|---|---|---|---|---|---|
| 1 | Repo init, foundry, **verify EIP-7702 is viable on Sepolia** | 4 | M | — | 🔴 unverified |
| 2 | **Finalise the event schema** (write it down before any work starts) | 2 | M | — | 🟡 expensive to change |
| 3 | `StandardPolicy` + `Reason` + `IPolicy` (limits, allow-lists, period budgets, time windows) | 6 | M | 2 | ✅ **done 9/6**, 16 tests green |
| 3b | `SharedBudgetPolicy` — a budget pooled across agents (the policy keeps its own ledger) | 1 | S | 3 | 🟢 after the 09-07 redesign it is a single contract |
| 4 | `LeashRegistry` — implementing the ENSv2 `IRegistry` | 5 | M | 2 | ✅ **done 9/8**, 29 tests. The tokenId rule was reverse-engineered from the chain |
| 5 | `LeashResolver` — **ENSIP-10 `resolve(bytes,bytes)` only** | 4 | M | — | ✅ **done 9/7**, 23 tests green. Implementing it did not depend on item 4 |
| 6 | ENS wiring and onchain resolution working end to end (`setResolver`/`setSubregistry`) | 4 | M | 3,4,5 | ✅ **done 9/8**; the official UniversalResolver resolves it too |
| 7a | `LeashAccount` — the wallet that forces every execution through the policy (reentrancy lock, policy gas cap, `isLeashed`) | 5 | M | 3,6 | 🟢 |
| 7b | Upgrade to an **EIP-7702 delegate** (the EOA itself governed by the policy) | 5 | **X** | 1,7a | 🔴 toolchain risk |
| 8 | `AttesterGate` — EIP-712 verification of widening signatures, **behind an interface with two implementations** | 4 | M | 3 | ✅ **done 9/9**: `WorldAttester` deployed and `LeashAccount` re-delegated onto it. `MockAttester` deliberately still serves `PolicyApprovals` and `LeashRegistry` |
| 9 | Subgraph: schema + mappings + deploy to Studio + index | 6 | M | 2,6,7a | 🟡 indexing takes time |
| 10 | The agent decision loop: query the subgraph → decide → sign → send | 6 | M | 9 | 🟢 |
| 11 | World: IDKit + backend verification + EIP-712 issuance | 6 | M | 8 | ✅ **done 9/9**: `POST /api/attest` signs only after World returns 200, and `crosscheck.mjs` proves the JS and Solidity EIP-712 agree. The digest path has never run against World's live API - one action, one scan, saved for the demo |
| 12 | The single-page frontend | 5 | M | 8,9,11 | 🟢 |
| 13 | End-to-end rehearsal and fixes | 5 | M | all | 🟡 |
| 14 | README (public repo, architecture diagram, how to run it) | 3 | M | 13 | 🟢 |
| 15 | A 2-4 minute video | 4 | M | 13 | 🟡 usually squeezed to the end |
| 16 | Finalise the World feedback document | 2 | M | 11 | 🟢 mostly written |
| 17 | Submit to each of the three tracks | 2 | M | 14,15,16 | 🟢 |

~~**† Item 11 is blocked on external approval.**~~ **Cleared 2026-09-07** — the precheck API
confirms `enable_face_check: true`. It was never blocked at all; the Portal simply does not
display the status. See `world-feedback.md` §6.

**Must-do total (excluding 7b): 73h** · **effective capacity 69h**

---

## Day plan

| Day | Date | Theme | Items | h |
|---|---|---|---|---|
| 1 | 9/4 | **Verify before building** | 1, 2 | 6 |
| 2 | 9/5 | The policy core | 3 | 6 |
| 3 | 9/6 | The ENS contracts | 4, 5 | 9 |
| 4 | 9/7 | **ENS resolving end to end** ⛳ | 6, 7a | 9 |
| 5 | 9/8 | Subgraph live ⛳ | 9, 8 | 10 |
| 6 | 9/9 | The agent thinks ⛳ · **World deadline** | 10 | 6 |
| 7 | 9/10 | World integration, or the contingency | 11 | 6 |
| 8 | 9/11 | Frontend | 12 | 5 |
| 9 | 9/12 | **End to end actually runs** ⛳ | 13 | 5 |
| 10 | 9/13 | **Deliver and submit (the last day)** ⛳ | 14, 15, 16, 17 | 11 |

⛳ = a milestone. Miss it on the day and the cut list starts.

> 🔴 **Submission deadline: Sunday 2026-09-13, 12:00 EDT = 9/14 00:00 Taipei** (confirmed
> 2026-09-07). The eleventh day originally planned (9/14) **does not exist** — 9/13 is a
> full working day that ends in submission, with no buffer day. The event running to 9/16 is
> judging and closing, not more coding time.
>
> Judging has two rounds: an asynchronous written screen first, then a live round for
> finalists — **a 4-minute demo plus 3 minutes of Q&A**. Design the video and the demo for
> 4 minutes; do not build a 10-minute thing.

---

## Three decisive judgements

### ① Finalise the event schema before writing contracts (item 2)

A subgraph eats events. Discovering after the contracts are written that the events are
insufficient costs **a redeploy + a reindex + mapping changes + agent query changes** —
four layers in one chain.

**Two hours spent writing the events down first** is the highest-return item in this whole
plan.

The minimum set:
```
PolicyResolved(agent, policyAddr, ensNode)
SpendAttempted(agent, payee, token, amount, allowed, reason)
LimitChanged(agent, oldLimit, newLimit, attestationHash)
PayeeAdded(agent, payee, attestationHash)
AgentRevoked(agent, by)
```

### ② Put the attester behind an interface from day one (item 8)

```solidity
interface IAttester { function verify(bytes calldata) external view returns (bool); }
```

Two implementations: `WorldAttester` and `MockAttester`. The contracts depend only on the
interface.

**That way it does not matter when World lands** — approval arriving means swapping one
address, a 30-minute job rather than a rewrite. If it never arrives, use the mock and say
honestly in the README and the video where it is stuck (the reasoning is written out in full
in `world-feedback.md`).

**Thirty minutes of design buys away the single largest risk in this plan.**

### ③ Demote 7702 to "build the contract wallet first, upgrade only with capacity to spare" (items 7a/7b)

EIP-7702 tells a better story (an existing EOA governed directly by the policy), but the
toolchain risk is high and **none of the three prizes requires it**.

Build `LeashAccount` first (an ordinary contract wallet that forces every execution through
the policy); the demo looks the same. 7b is a stretch goal, abandoned outright if the
must-dos are not finished by 9/12.

---

## Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | ~~World's approval never arrives~~ | — | — | ✅ **eliminated 2026-09-07**: the flag had been on all along. `AttesterGate` still goes behind an interface per judgement ②, but the reason changes from hedging to cleanliness |
| 2 | **ENSv2 resolvers accept ENSIP-10 only** | confirmed | high | Measured: the legacy `addr()`/`text()` are **not supported**. Implement `resolve(bytes,bytes)` only; waste no time on a compatibility layer |
| 3 | The EIP-7702 toolchain on Sepolia | medium | medium | Verify on day 1 and cut 7b if it does not work. Do not discover this on day 8 |
| 4 | Subgraph indexing is slower than expected | medium | medium | Deploy on 9/8, leaving 4 days to find problems. **Do not wait until every feature is written to deploy** |
| 5 | The video gets squeezed into the last day | **high** | high | Block out time on 9/13. End to end must run by 9/12 or there is nothing to film |
| 6 | One person, so any blocker halts everything | high | high | Cut on the day a milestone is missed; do not console yourself with "I will catch up tomorrow" |
| 7 | `leash.eth` expires in a year | low | low | Registered through 2027-09-02. Safe across the judging period |

---

## The pre-agreed cut order

When behind, **cut from the top down**; do not convene a meeting with yourself in the
moment:

1. **7b** the EIP-7702 upgrade — already a stretch goal, so abandon it (−5h)
2. **The agent's fourth question** ("why was I blocked last time?") — three questions
   suffice to show the subgraph is load-bearing (−2h)
3. **The frontend's policy display reads the contract directly** instead of the subgraph —
   the agent still uses it, so The Graph's condition is unaffected (−2h)
4. ~~**World → MockAttester**~~ — **no longer applicable**; the flag is on (−0h)
5. **Keep only happy-path tests** — a hackathon is not a product (−4h)

Cutting through item 3 returns to 62h, below capacity, with 7h of buffer left.

---

## Effort adjustment log

| Date | Adjustment | h |
|---|---|---|
| 2026-09-07 | cut the `Write[]`/`_scratch` write-on-behalf pipeline | −1.0 |
| 2026-09-07 | cut the standalone `SharedLedger` (folded into `SharedBudgetPolicy`) | −1.0 |
| 2026-09-07 | cut the account-level `walletBudget` special case | −0.7 |
| 2026-09-07 | added `SharedBudgetPolicy` | +1.0 |
| 2026-09-07 | added `isLeashed` (folded into 7a, not a separate item) | +1.0 |
| | **net change** | **−0.7** |

The reasoning is in "Policy layer design decisions (settled 2026-09-07)" in `PLAN.md`.
`PolicySet` (DNF) is demoted to a post-9/11 stretch goal and is not in the table above.

---

## Definition of Done

**Per contract:**
- [ ] Deployed to Sepolia, with the address recorded in `docs/deployments.md`
- [ ] At least one happy-path test passing
- [ ] Events match the final `docs/events.md`

**Overall (by end of day 9/12):**
- [ ] The four-act demo runs start to finish with no manual intervention
- [ ] The agent really queries the subgraph rather than reading canned data
- [ ] The policy address really comes through ENS rather than being hardcoded
- [ ] Revoking an agent executes on the spot, with no face scan

**The floor, whatever the progress (9/14):**
- [ ] **Submit, no matter what.** ETHGlobal's rule: "You must submit your hack before the
      submission deadline. **Partial or incomplete hacks are still eligible for stake
      being returned.**" Not submitting = the stake is gone and all three prizes are lost.
      Submit even if it is unfinished.
- [x] Team created ✅ 2026-09-07 (Albert Lin, a team of one)

**Delivery (by end of day 9/13):**
- [ ] The repo is public, and the README has an architecture diagram and how to run it
- [ ] A 2-4 minute video covering all four acts
- [ ] `world-feedback.md` finalised
- [ ] The submission form filled in for each of the three tracks

---

## Daily self-check (30 seconds; do not skip it)

1. Did today's milestone land? If not → **cut now**, not tomorrow
2. ~~Any word from World?~~ Closed (9/7). Ask instead: **has a fresh action been created
   before recording the video / running the demo?** `max_verifications` cannot be changed
   (the Portal has no such setting), but it binds to the action rather than the person —
   **creating a new action resets it**. `expand-policy` has not been used up yet
3. Hit any new friction with World? → record it in `world-feedback.md` on the spot
