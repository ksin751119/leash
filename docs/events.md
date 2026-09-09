# Event schema (final)

**Status:** 🔒 **frozen** (frozen 2026-09-05; **thawed once on 2026-09-07 and once on
09-08, amended, and refrozen each time** — see the change log)
**Date:** 2026-09-08
**Why this was written first:** a subgraph eats events. Discovering after the contracts are
written that the events are insufficient costs a redeploy → a reindex → mapping changes →
agent query changes: four layers in one chain. See judgement ① in `sprint.md`.

> **The rule once frozen:** fields and events may be *added*; the type, order or meaning of
> an existing field may not change. If something really must change, come back and change
> this document, and leave a line in the change log below.

---

## One decision first: should a blocked transaction revert, or no-op?

**This question decides whether the subgraph has anything at all to index.**

| | revert | **no-op + event (adopted)** |
|---|---|---|
| Did money move | no | no |
| A record on chain | ❌ **logs from a reverted call are discarded** | ✅ `SpendBlocked` reaches the subgraph |
| Agent asks "why was I blocked last time?" | cannot answer | query the subgraph |
| Act two of the demo | a red revert | a **recorded refusal**, with a reason code |

**No-op is adopted.** A policy violation means: no transfer, emit `SpendBlocked`, return
normally. Only an **authorisation failure** (the caller is not a bound agent at all)
reverts — that is not a policy decision, it is an intrusion.

> The evidence of a block is that **money did not move**, not that the transaction went red.
> And what The Graph's track asks for is precisely "an agent really querying indexed data to
> make decisions" — if blocked attempts cannot be queried, question 4 does not exist.

---

## Who decides which reason codes

**Codes 1-4 and 10 are decided by `LeashAccount` before it calls the policy; 5-9 and 11 are
decided by the policy.**

The line is drawn deliberately: bindings, the policy pointer, the policy approval list, and
pausing are security-critical and stay in the account's own hands forever. A policy only
answers "does this spend satisfy the rules?" — **swapping the policy cannot reach the
control plane.**

## Reason codes (`uint8 reason`)

An `enum Reason` in the contracts, sent as a `uint8` in the events. **Once the numbers are
fixed, never renumber them.**

| Code | Name | Meaning | Who can clear it |
|---|---|---|---|
| 0 | `OK` | allowed | — |
| 1 | `AGENT_NOT_BOUND` | this agent does not belong to this name | ADMIN |
| 2 | `AGENT_REVOKED` | already revoked | ADMIN (reducing needs no face scan; restoring does) |
| 3 | `NO_POLICY` | no policy pointer resolvable through ENS | ADMIN |
| 4 | `POLICY_NOT_APPROVED` | the policy address is not on the approval list | **face scan only** |
| 5 | `TOKEN_NOT_ALLOWED` | this token is not on the allow-list | **face scan** |
| 6 | `PAYEE_NOT_ALLOWED` | the payee is not allow-listed | **face scan** |
| 7 | `OVER_TX_LIMIT` | over the per-transaction cap | **face scan** |
| 8 | `OVER_PERIOD_LIMIT` | over the cap for this period | **face scan** |
| 9 | `OUTSIDE_TIME_WINDOW` | outside the permitted window | **face scan** |
| 10 | `PAUSED` | the whole account is paused | ADMIN |
| 11 | `OVER_SHARED_LIMIT` | the budget pooled across agents is exhausted | **face scan** |
| 12 | `POLICY_FAILED` | the policy call failed, blew the gas cap, or returned the wrong shape | swap in another policy (ADMIN) |

> 4-9 and 11 are widenings and all require Selfie Check. 1-3, 10 and 12 are an ADMIN's
> routine operations.
>
> **Why 12 needs its own code:** the account caps the gas when calling a policy and checks
> the return length, failing closed when either is wrong. Reusing 4
> (`POLICY_NOT_APPROVED`) would mislead — that code means "no human approved this policy",
> while 12 means "this policy is broken". The two call for entirely different responses.
> This table is the machine-readable form of the widening/reduction asymmetry in
> `PLAN.md`.

---

## Events

### 1. The ENS layer — `LeashRegistry` / `LeashResolver`

```solidity
/// A subname was created. The label is sent in the clear so the subgraph can recover it.
event SubnameRegistered(
    bytes32 indexed node,      // namehash("alpha.leash.eth")
    string          label,     // "alpha"
    address indexed owner,
    uint64          expiry
);

/// A subname was revoked — act four's "pull the plug".
event SubnameRevoked(
    bytes32 indexed node,
    address indexed by
);

/// The policy pointer was rewritten. This is the system's control-plane event.
event PolicyPointerSet(
    bytes32 indexed node,
    address indexed policy,    // 0x0 = cleared, equivalent to halting everything
    address indexed setBy,
    bool            approved        // whether that address was on the approval list at the time
);
```

**Why `approved` is recorded here:** the ENS pointer is controlled by ADMIN and the
approval list by a face scan. Separating them is the whole point — **a stolen ADMIN key can
move the pointer, but cannot make an unapproved policy become approved on the existing
list** (`PolicyApprovals.attester` and `LeashResolver.approvals` are both `immutable`, with
no setter).

> ⚠️ **Wording corrected on 2026-09-08.** It used to read "cannot point at a policy that was
> never approved" — **and that sentence was false at the time.** Code review pointed out
> that `setAttester` was `onlyOwner` and needed no attestation, while the deployment gave
> all three contracts the same ADMIN key as owner, so
> `setAttester(something that always returns true)` → `approve(anything)` ran straight
> through. The fix was to remove those two setters (making them `immutable`), and **the
> claim had to be narrowed to something exact**: ADMIN can still deploy an entire new
> control plane and repoint the names at it — but that is **a visible sequence of onchain
> transactions**, and the new list starts empty, so every single name has to be repointed.
> What ADMIN cannot do is widen **quietly**.

Recording the outcome at the time means the subgraph can show "was the thing this pointer
aims at ever approved?" without recomputing it.

---

### 2. The execution layer — `LeashAccount`

```solidity
/// The policy resolved out of ENS before each execution.
/// Evidence that the policy address really came through ENS rather than being hardcoded
/// (one of the definition-of-done conditions).
event PolicyResolved(
    bytes32 indexed node,
    address indexed policy,
    bool            approved
);

event SpendExecuted(
    bytes32         node,         // which ENS name this spend happened under
    address indexed agent,
    address indexed payee,
    address indexed token,
    uint256         amount,
    address         policy,
    uint256         spentAfter,   // running total for this period (this spend included)
    uint256         limit,        // the cap for this period
    uint64          periodEnd     // when this period resets
);

event SpendBlocked(
    bytes32         node,
    address indexed agent,
    address indexed payee,
    address indexed token,
    uint256         amount,
    uint8           reason,       // see the table above
    address         policy,
    uint256         spentSoFar,
    uint256         limit
);

/// Account initialisation. Evidence that this EOA now delegates to LeashAccount.
/// Note: removing a delegation emits no event — EIP-7702 has no log, so the only way to
/// observe it is polling isLeashed().
event Leashed(bytes32 indexed node, address indexed wallet, address impl);

event AgentBound(address indexed agent, bytes32 indexed node);
event AgentRevoked(address indexed agent, address indexed by);
event Paused(address indexed by);
event Unpaused(address indexed by, bytes32 attestationHash);
```

**Why both spend events carry `node`:** one account can have several agents pointing at
different policies. Without `node`, the subgraph would have to reconstruct the timeline of
bindings itself to work out which agent a spend counts against.
`node` is not indexed — the three indexed slots go to agent/payee/token, which are the
dimensions actually queried.

**Why `SpendExecuted` and `SpendBlocked` are not merged into one event with a
`bool allowed`:** separate handlers are cleaner in the subgraph, and "how much do I have
left?" and "why was I blocked?" are two different agent queries, so separate entities save
a filter.

---

### 3. Allow-list changes — `LeashAccount`

**Every widening must carry an `attestationHash`. A reduction carries `by` (who did it) and
no hash.** That asymmetry in the types is deliberate — the event signature alone tells you
which operations need a human.

```solidity
// --- widenings: always carry an attestationHash ---
event LimitRaised(
    bytes32 indexed node,
    address indexed token,
    uint256         oldLimit,
    uint256         newLimit,
    uint64          period,
    bytes32         attestationHash
);
event PayeeAllowed(bytes32 indexed node, address indexed payee, bytes32 attestationHash);
event TokenAllowed(bytes32 indexed node, address indexed token, bytes32 attestationHash);
event PolicyApproved(address indexed policy, string description, bytes32 attestationHash);

// --- reductions: no hash, and always available ---
event LimitLowered(
    bytes32 indexed node,
    address indexed token,
    uint256         oldLimit,
    uint256         newLimit,
    address indexed by
);
event PayeeRemoved(bytes32 indexed node, address indexed payee, address indexed by);
event TokenRemoved(bytes32 indexed node, address indexed token, address indexed by);
event PolicyRevoked(address indexed policy, address indexed by);
```

---

### 4. The identity layer — ~~`AttesterGate`~~, emitted by the attestation's **consumers**

> ⚠️ **2026-09-08: the `AttesterGate` contract will not exist.**
>
> There are only three consumers of an attestation (`PolicyApprovals`, `LeashRegistry`, and
> later `LeashAccount`), and embedding the verification in each is simpler than another
> layer of forwarding — an extra contract buys nothing within a five-day budget.
>
> **Ownership settled:** `AttestationAccepted` is emitted by **`LeashAccount`** (the only
> place holding a per-wallet nonce, and the value of that event is the anti-replay audit
> trail). `PolicyApprovals` and `LeashRegistry` each carry the same information via their
> own `attestationUsed` mapping plus the `attestationHash` field on their existing events.
>
> **`AttesterChanged` has been deleted.** `attester` is now `immutable` in all three
> contracts with no setter, so there is no such event to emit — see C1 in the change log
> below.
>
> The range of the `action` field widens from "reason codes 4-9" to **4-9 and 11**.

```solidity
/// An attestation was accepted and spent. The nonce prevents replay.
event AttestationAccepted(
    bytes32 indexed attestationHash,
    address indexed subject,     // who this attestation authorises
    uint8           action,      // maps to reason codes 4-9; says which one it clears
    uint256         nonce,
    address indexed attester     // WorldAttester or MockAttester
);

/// Swapping the attester implementation — emitted when World's approval lands.
event AttesterChanged(address indexed oldAttester, address indexed newAttester);
```

**Why `AttesterChanged` existed:** judgement ② in `sprint.md` said the attester would be
behind an interface from day one. This event let the demo show honestly whether a mock or
the real World is running, rather than asserting it verbally. (Deleted 2026-09-08; see
above.)

---

## The four questions an agent asks → which event answers each

| # | Question | Read | Cut priority |
|---|---|---|---|
| 1 | How much is left this period? | the latest `SpendExecuted.spentAfter` / `limit` | must have |
| 2 | Have I paid this payee before? | `PayeeAllowed` − `PayeeRemoved` | must have |
| 3 | Which policy am I on, and was it approved? | `PolicyPointerSet` + `PolicyApproved` | must have |
| 4 | Why was I blocked last time? | `SpendBlocked.reason` | **second thing to cut** |

---

## The one thing a subgraph cannot see: is the leash still on?

`isLeashed(node)` asks whether the wallet still delegates to `LeashAccount`.

**An EIP-7702 delegation change emits no log at all**, so a subgraph cannot index it — the
only way to observe it is **polling with `eth_call`** (the frontend checks once on load, a
monitoring script polls). Written down here so nobody later assumes we forgot an event.

The account emits `Leashed(node, wallet, impl)` on first initialisation, which records the
leash going *on*. There is no corresponding event for it coming *off*: that is a limitation
of the protocol, not an oversight of ours.

---

## Change log

| Date | What changed | Why |
|---|---|---|
| 2026-09-05 | first draft | — |
| 2026-09-05 | 🔒 frozen; added "who decides which reason codes" | finalised before work started |
| 2026-09-07 | **thawed once**: the approval list is keyed by **address** instead of codehash | once a policy may keep its own storage, a codehash no longer determines behaviour (measured: two contracts with the same codehash reaching opposite verdicts). See "key the allow-list by address" in `PLAN.md` |
| 2026-09-07 | `PolicyCodehashApproved` → `PolicyApproved(address, string, bytes32)`; `PolicyCodehashRevoked` → `PolicyRevoked(address, address)` | as above |
| 2026-09-07 | `PolicyPointerSet.policyCodehash` (bytes32) → `approved` (bool); `PolicyResolved`'s two codehash fields collapsed into `approved` (bool) | the address is already an indexed parameter, so recording a fingerprint again carries no information |
| 2026-09-07 | reason code 4 renamed `POLICY_NOT_APPROVED` (**the number is unchanged**); added 11 `OVER_SHARED_LIMIT` | a shared budget is kept by a policy's own ledger rather than by a special case in the account |
| 2026-09-07 | added a `node` field to `SpendExecuted` and `SpendBlocked`; added `Leashed` | three items agreed earlier that had never been written down |
| 2026-09-07 | 🔒 **refrozen** — the contracts were not deployed and the subgraph was not written, so this was the last painless chance to change it | — |
| 2026-09-08 | **thawed a second time**: added reason code **12 `POLICY_FAILED`** | the account caps the policy's gas and checks the return length, and had no code to report when failing closed. Reusing 4 would mislead the subgraph |
| 2026-09-08 | added a `tokenId` field to `SubnameRegistered` and `SubnameRevoked`; added `SubnameRenewed`; `ResolverChanged` / `SubregistryChanged` now take `node` as their first indexed field and carry `tokenId` | the registry internally uses a tokenId derived from the labelhash, while the subgraph's join key is `node` (a namehash). **Both are needed**, or the indexer has to rebuild the tokenId→label→namehash mapping itself |
| 2026-09-08 | **deleted `AttesterChanged`**; the `AttesterGate` contract will not exist, and `AttestationAccepted` is emitted by `LeashAccount` instead | code review C1: a mutable attester pointer let one stolen ADMIN key open both locks. With `attester` made `immutable` there is no setter, and therefore no such event |
| 2026-09-08 | added a `nonce` field to `PolicyApproved` | code review C2: the original digest had no nonce and kept no record of spent attestations, which combined with a public `revoke` allows a replay — revoke, then re-approve with the same attestation, with no new face scan from anyone |
| 2026-09-08 | the `action` field's range widened from reason codes 4-9 to 4-9 and 11 | a shared budget (11) is a widening too and needs an attestation |
| 2026-09-08 | 🔒 **refrozen**. The contracts were deployed but the subgraph was not yet written — this batch requires redeploying `LeashRegistry` and `PolicyApprovals`, which costs something, but less than carrying a false security argument in front of judges | — |

> **Where this batch came from:** a code review of `a9f5051..c3c704e` on 2026-09-08, run
> through `superpowers:requesting-code-review`, verdict `With fixes`.
> Its two Critical findings — one key opening both locks, and a replayable attestation —
> refuted exactly the claim this document made at what was then line 94. The full account is
> in that review's fix commit.
