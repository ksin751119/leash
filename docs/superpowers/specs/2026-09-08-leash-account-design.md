# LeashAccount design — the EIP-7702 account that enforces

**Date:** 2026-09-08
**Sprint item:** 7a (replacing the original "contract wallet" version; a 7702 delegate directly)
**Status:** approved, awaiting implementation

---

## What this exists to solve

The five contracts before this each do their own job, but **nothing forces any of them to be
used**:

- `StandardPolicy` can judge, but nobody has to ask it
- `LeashResolver` can resolve a policy address, but nobody has to resolve one
- `PolicyApprovals` records which policies were approved, but nobody has to check
- `LeashRegistry` can revoke a subname, but revoking affects no actual spending

`LeashAccount` is **the agent's only spending path**. It turns those four things into
preconditions for payment, inside the agent's own execution flow — **the agent has no option
to bypass them, because the check is not outside it but within it.**

Remove ENS, step 4 resolves no policy, and no agent-initiated spend can pass (reason code 3).

> ⚠️ **Do not phrase this as "the only spending path". That sentence is false, and it
> collapses under the first question a judge asks.**
> EIP-7702 constrains only **calls to that EOA**. The WALLET private key can still sign
> `to = USDC, data = transfer(anyone, balance)` directly, and the policy path never executes.
>
> This is both the boundary and the **escape hatch**: the wallet's owner can always retrieve
> their own funds and can never be locked out by a policy they installed. Saying so is better
> than being caught out, and the story is stronger this way.
>
> **A test must pin this boundary:** a WALLET-signed transfer succeeds and emits **no**
> `SpendExecuted`.

---

## Decision record

Eight settled forks in the road, written down before implementation so they are not later
taken for arbitrary choices. (1-4 came from brainstorming, 5-8 from the first round of
review.)

| # | Decision | Rejected alternatives | Why |
|---|---|---|---|
| 1 | **A 7702 delegate directly**, not a separate contract wallet | a contract wallet (the sprint's original plan), one bytecode serving both | 7702's story is "an existing EOA governed by the policy, with no funds to move". The toolchain risk was cleared by measurement on 09-03 |
| 2 | **No `initialize()`**; the global configuration is `immutable` | `initialize()` restricted to `msg.sender == address(this)` | No initialisation step means nothing to front-run. And the impl address itself denotes the whole control plane, so `delegateOf` answers it in one call |
| 3 | **WALLET binds which ENS name governs it** | ADMIN binds it | The threat model is "the agent is compromised", not "the wallet's owner harms themselves". WALLET can only choose among **rulesets a human already approved** |
| 4 | **Resolution starts at `ETH_REGISTRY`** (three hops) | four hops from RootRegistry; hardcoding the resolver address | Three hops is the shortest path that preserves all three revocation layers. The fourth hop buys no revocation capability, and hardcoding the resolver would make ENS decorative |
| 5 | **Widening is two-of-two: `msg.sender == address(this)` **and** an attestation** | attestation only (the first version) | See C1 below — with attestation alone, a compromised agent plus `MockAttester` can widen its own authority in one step |
| 6 | **`unpause` needs only `address(this)`, no attestation** | requiring an attestation (the first version) | The frozen document lists reason code 10 as "an ADMIN's routine operation". And any agent can `pause` for free, so if `unpause` cost a face scan, a compromised agent could force repeated scans (a DoS) |
| 7 | **No standalone `AttesterGate` contract** | building one per section 4 of the frozen document | There are only two consumers of an attestation (`LeashAccount`, `PolicyApprovals`), and embedding the verification in each is simpler than another layer of forwarding. **This is a deviation from the frozen document and must be recorded in its change log** |
| 8 | **`setRule` (needs an attestation) + `tightenRule` (needs only `address(this)`)** | six separate raise/lower functions | `TokenRule` has five tunable fields, and paired functions would leave the window and period uncovered. `tightenRule` requires **every field to be weakly monotonically tightened**, turning "stricter" into a checkable assertion |
### Two old notes overturned by measurement on a local anvil, 09-08

`docs/ensv2-sepolia.md` recorded two 7702 "traps", **both of them misreadings** (the delegate
at the time was `MockUSDC`, an ERC-20 with no matching functions):

| The old note | What measurement showed |
|---|---|
| The transaction's `to` must not be the delegated EOA itself | ❌ wrong. `to = EOA` **is** the normal way to call a delegate's functions |
| A delegate must be stateless | ❌ wrong. A delegate **may have storage**, held in the **EOA's own** storage. Two EOAs sharing one impl have entirely independent storage |

**This is good news for the design:** each wallet has its own allow-list and budget, with no
mapping needed in the impl.

> ⚠️ **The first row is over-corrected, and this spec says so later** (see the `receive()`
> section): the old note is *correct* for empty calldata and wrong only for calldata with a
> matching selector. The two cases have to be stated separately.

And the spike found a **real** hole:

> 🔴 After delegation the EOA's storage is empty, so **anyone can call `initialize` first and
> set themselves as admin.**

Decision 2 exists to eliminate that attack surface.

---
## Architecture

### One impl, zero per-instance state

```solidity
contract LeashAccount {
    // Burned into the bytecode. No initialize, so nothing to front-run.
    address          immutable ETH_REGISTRY;  // ENSv2's .eth registry; where resolution starts
    IPolicyApprovals immutable APPROVALS;
    IAttester        immutable ATTESTER;

    string constant PARENT_LABEL = "leash";   // our name under ETH_REGISTRY
}
```

Changing the control plane means **deploying a new impl and redelegating** — and redelegating
is itself the escape hatch in the wallet holder's hands, so no separate mechanism is needed.

### Storage: an ERC-7201 namespaced slot (necessary, not fastidious)

Delegated code executes against the **EOA's own storage**. If that EOA later redelegates to
**a different impl with a different layout**, the old data gets reinterpreted under the new
meaning — the kind of disaster where a budget reads back as an admin address.

```solidity
/// @custom:storage-location erc7201:leash.account.v1
struct AccountStorage {
    mapping(address agent => AgentBinding) bindings;
    mapping(bytes32 node => mapping(address token => TokenRule)) rules;
    mapping(bytes32 node => mapping(address token => mapping(address payee => bool))) payees;
    mapping(bytes32 node => mapping(address token => mapping(uint256 bucket => uint256))) spent;
    mapping(bytes32 digest => bool) usedAttestations;
    bool paused;
    bool entered;              // the reentrancy lock
}

// ERC-7201: keccak256(abi.encode(uint256(keccak256("leash.account.v1")) - 1)) & ~bytes32(uint256(0xff))
// Computed 09-08; pin it with a test during implementation (get it wrong and every piece of
// state lands in a different slot)
bytes32 private constant SLOT =
    0x9e007e5c5750cc23875b31a9093bc96547487e271abecbfffde0d1fe2245b800;
```

The version lives inside the string (`v1`); change the layout, change the string, and the old
slot can never be misread.

```solidity
struct AgentBinding {
    bytes32 node;      // namehash("<label>.leash.eth"), for reading resolver records
    string  label;     // "vendors", for LeashRegistry.getResolver(label)
    bool    revoked;
}

struct TokenRule {
    bool    allowed;
    uint256 txLimit;      // 0 = unlimited
    uint256 periodLimit;  // 0 = unlimited
    uint64  period;       // period length in seconds. 0 means no period
    uint16  windowStart;  // minute of the day, UTC
    uint16  windowEnd;    // start == end means all day
    uint32  epoch;        // never decreases. **Any change to period must bump it** - see below
}
```

---

## The spending flow

```
agent -> EOA.spend(address token, address payee, uint256 amount)
```

**`node` and `label` are not supplied by the caller; they are read from
`bindings[msg.sender]`.** Reviewing my own draft, the original signature had the caller pass
`node`, which creates an entire class of "node and label disagree" validation. Writing them
at bind time makes the problem cease to exist at compile time — one agent, one name, which
also matches the "several agents, each pointing at a different policy" model.

| Step | Action | Behaviour on failure |
|---|---|---|
| 1 | The reentrancy lock, `entered` | **revert** |
| 2a | **Is it bound?** `bindings[msg.sender].node != 0` | **revert** `NotBoundAgent` |
| 2b | **Has it been revoked?** `!revoked` | `SpendBlocked(AGENT_REVOKED)`, return |
| 3 | `paused`? | `SpendBlocked(PAUSED)`, return |
| 4 | **the three ENS hops** → the policy address | any hop failing or returning `0x0` → `SpendBlocked(NO_POLICY)` |
| 5 | `approved = APPROVALS.isApproved(policy)`, then **emit `PolicyResolved(node, policy, approved)`** | |
| 6 | `!approved` | `SpendBlocked(POLICY_NOT_APPROVED)`, return |
| 7 | Build the `SpendContext` from the account's own `rules` / `payees` / `spent` | |
| 8 | `policy.check{gas: POLICY_GAS}(ctx)` | the call failing or a return length ≠ 32 → `SpendBlocked(POLICY_FAILED)`. **Note this is 32, unlike ENS hop three's 96** |
| 9 | `reason != OK` | `SpendBlocked(reason)`, return |
| 10 | **`spent[node][token][period] += amount`** | |
| 11 | `token.transfer(payee, amount)`, checking the return value | **revert** |
| 12 | Emit `SpendExecuted` | |
| 13 | Unlock | |

### Why 2a reverts and 2b does not

**This line is drawn deliberately, and the first version drew it wrong.** That version
collapsed both "not bound" and "revoked" into `revert NotBoundAgent`, with the result that
**reason codes 1 and 2 could never be emitted** — directly contradicting `events.md`'s
"codes 1-4 and 10 are decided by `LeashAccount`".

The frozen document confines the revert exception to "the caller is **not** a bound agent at
all". And **a revoked agent *is* bound** — revocation is an administrative act, and that
agent should be able to look up why it is stuck (question 4 of The Graph's track). Logs from
a reverted call are discarded, so it could not.

- **2a, not bound → revert.** That is not a policy decision, it is an intrusion, and there is
  no reason to leave an indexable record
- **2b, revoked → `SpendBlocked(2)`.** That is a policy decision and needs a record

> The evidence of a block is that **money did not move**, not that the transaction went red.

### `PolicyResolved.approved` must carry the real value

The first version emitted this event **after** the approval check, where `approved` could
only ever be `true` — leaving that field in the frozen schema permanently dead. Emitting it
**at** the check is what lets the subgraph see "the pointer aims at an unapproved policy",
which is exactly the one onchain signal that the ADMIN key has been stolen.

### Why step 10 comes before step 11

`token.transfer` is an external call. A malicious payee (or a malicious token) can call
`spend` again from inside the transfer's callback. The reentrancy lock is the first line of
defence and **writing the ledger first is the second** — it takes both failing to cause harm.
### The period index: `period == 0` is an edge case that must be handled

The `spent` key has two problems to solve; the second was caught in round two of review.

**Problem one: `period == 0` divides by zero.** `TokenRule.period` is allowed to be `0` (no
period).

**Problem two (not properly fixed in the first version): changing `period` resurrects the
budget.** If the key is nothing but `block.timestamp / rule.period`, then changing `period`
changes the bucket number and `spent` reads back as `0` from the new bucket — **"adjust the
period" becomes a free wipe-the-ledger button.**

The first version only froze `period` in `tightenRule`, while `setRule` — which does have an
attestation — could still change it, so the problem remained. Worse, **a test I wrote myself
required that "the running total must not zero after `setRule` changes the period" — and
nothing in the design provided that property.** That test could never have passed.

**The fix: add a monotonically increasing `epoch` and key `spent` on it.**

```solidity
uint256 bucket = rule.period == 0
    ? (uint256(rule.epoch) << 224)                      // no period: one bucket per epoch
    : (uint256(rule.epoch) << 224) | (block.timestamp / rule.period);

uint64 periodEnd = rule.period == 0
    ? 0                                                  // 0 means "never resets", not "already ended"
    : uint64(((block.timestamp / rule.period) + 1) * rule.period);
```

`epoch` occupies the high bits and the period index the low bits, so neither contaminates the
other (`period` is at least 1 second, and `timestamp / 1` is far below `2^224`).

**The rule: `setRule` increments `epoch` only when `period` actually changes.** That is
deliberate — a new period means a new ledger and the old one should not be inherited; and
because `epoch` never decreases, **wiping the ledger always costs an attestation**, which the
free `tightenRule` cannot obtain.

When `period == 0`, every spend accumulates into `periodIdx = 0` — a **total that never
resets**, which combined with `periodLimit` is a lifetime allowance. That is a sensible
meaning, not a fallback. `SpendExecuted.periodEnd` sends `0` for "never resets", and the
subgraph must read it that way.

**This edge case needs its own test**; do not rely on fuzzing happening to hit it.

### The three ENS hops

```solidity
function _resolvePolicy(bytes32 node, string memory agentLabel)
    private view returns (address policy)
{
    // 1. ETH_REGISTRY.getSubregistry("leash") -> LeashRegistry
    //    this hop is what makes ETHRegistry.setSubregistry(leash.eth, 0x0) the kill-everything lever
    // 2. LeashRegistry.getResolver(agentLabel) -> LeashResolver
    //    this hop is what makes revoke(label) and expiry the kill-one-agent levers
    // 3. LeashResolver.resolve(dnsName, abi.encodeCall(addr, node)) -> policy
    // Any hop whose staticcall fails, returns a length other than **that hop expects**, or
    // returns 0x0 -> return address(0)
}
```

#### 🔴 Each hop returns a different length, and getting it wrong means nothing can ever be paid

The first version said only "the wrong return length" without saying what the right one is.
**If the implementation checks hop three for `== 32`, the happy path never succeeds**, while
the reported reason code is `NO_POLICY` ("ENS has no policy pointer") — which sends you to
debug entirely the wrong thing and can burn half a day.

Measured against the deployed contracts on 09-08 (`cast rpc eth_call`, raw returndata,
undecoded):

| Hop | Call | Raw returndata | Why |
|---|---|---|---|
| 1 | `ETH_REGISTRY.getSubregistry("leash")` | **32 bytes** | returns an `address` |
| 2 | `LeashRegistry.getResolver("vendors")` | **32 bytes** | returns an `address` |
| 3 | `LeashResolver.resolve(dns, inner)` | **96 bytes** | returns `bytes`: offset (32) + length (32) + inner (32) |

Hop three's actual bytes:

```
0x 0000…0020   <- offset = 32
   0000…0020   <- length = 32
   0000…b70f52e0ffc361e6e3c7765a58068308d4fa75cc   <- the inner abi.encode(address)
```

So hop three must: check `returndatasize() == 96` → decode the outer `bytes` → confirm its
length is 32 → then decode the `address`.

**Implementation requirements:**
- Use a low-level `staticcall` per hop and check each one's own expected length; do not share
  a single constant
- Use a **bounded** `returndatacopy`; never copy someone else's return data unbounded (they
  are an external contract)
- Cap the gas on every hop — ENS's contracts are in their audit window and must not be able
  to drag us down
- **Write a test per hop for its length**, and the happy path must run against the real chain
  in a fork test

**All three hops use `staticcall` wrapped in `try` or a low-level call** — ENS's contracts
are still in their Immunefi audit window (through 09-14), so addresses may move and behaviour
may change. Another contract reverting must not wedge the account; failing to resolve is
`NO_POLICY`, no money moves, and that is the safe default.

Both `label` and `node` come from the binding, written together by the wallet's holder in
`bindAgent` — **the caller never gets the chance to submit an inconsistent pair.** That is an
invariant established at bind time, not something to verify on every spend.

### 🔴 `bindAgent` **must** check `node == namehash(label + ".leash.eth")`

The first version said not to check, on the grounds that "computing a namehash on chain needs
a keccak loop, and getting it wrong only means the policy does not resolve". **Both premises
are false.**

**Wrong on cost.** The parent is always `leash.eth`, so it takes **two keccaks**, not a loop:

```solidity
bytes32 expected = keccak256(abi.encodePacked(PARENT_NODE, keccak256(bytes(label))));
```

`PARENT_NODE = namehash("leash.eth")` is a compile-time constant
(`0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf`). About 200 gas, once.

**Wrong on consequence.** `node` is **not only** the resolver's key — it is also the key for
`rules`, `payees` and `spent`. So:

```
bindAgent(agentB, node = namehash("vendors.leash.eth"), label = "payroll")
```

would let agentB spend **vendors' human-approved limits and budget** while being judged by
**payroll's policy**. Two rulesets wired to each other by mistake — and since the
`AgentBound(agent, node)` event **carries no label** (`events.md`), **it would be completely
invisible offchain.**

200 gas, once, to trade an invisible misconfiguration for a revert. **Check it.**

---

## The non-`spend` call surface: `receive()` is required, not a courtesy

**After delegation, a plain ETH transfer into that EOA is a call to the delegate with empty
calldata.** With neither function present → Solidity's dispatcher reverts → **that wallet
cannot receive ETH and cannot be topped up with gas.** Faucets, exchanges and
`cast send --value` all stop working, and `PLAN.md` explicitly plans to top up in stages.

Confirmed on a local anvil on 09-08:

| delegate | `payable(eoa).call{value: 1 ether}("")` |
|---|---|
| without `receive()` | **`false`** |
| with `receive()` | `true`, and the balance increases correctly |

```solidity
receive() external payable { }              // required, or the wallet becomes one-way
fallback() external payable { revert UnknownSelector(); }   // refuse explicitly; do not swallow
```

> **This is also where I over-corrected while fixing my notes on 09-08.**
> `ensv2-sepolia.md` recorded that "the transaction's `to` must not be the delegated EOA
> itself", and I marked the whole note wrong — but it is correct for **empty calldata** and
> wrong only for calldata that is non-empty with a matching selector. The two cases have to be
> stated separately.

`fallback` reverts rather than accepting silently, because accepting silently would make a
mistyped selector look like success. This account does not do general-purpose call
forwarding (see the YAGNI table).
## Allow-list changes: widening needs an attestation, reducing does not

The asymmetry in the types is deliberate — the function signature alone tells you which
operations need a human.

> 🔴 **The first version of this table had a critical.** Its widening rows said only "needs
> an attestation", with no sender check — because I had copied across the comment from
> `PolicyApprovals.sol`, "the gate is the attestation, not an identity". **That comment is
> correct in its own context and wrong when carried here:** `PolicyApprovals` is a global
> singleton where who submits the transaction genuinely does not matter, while a per-wallet
> account **has a natural canonical sender** (the wallet itself).
>
> Combined with `MockAttester` (which returns `true` for any input, and **is exactly the one
> we deployed on Sepolia on 09-08 and are using**), a compromised agent could empty the
> wallet in three steps: `allowPayee(itself)` → `allowToken(no limit)` →
> `spend(entire balance)`. It never bypassed a check — **it rewrote the check's inputs.**
>
> And it resurrects the attack decision 2 was meant to kill: during the window after
> delegation when storage is still blank, anyone can plant themselves on the allow-list, and
> it takes effect once the real holder binds an agent — with no reason for the holder to
> look. **Decision 2 was right, but not sufficient.**

| Action | Who may | Attestation | Event |
|---|---|---|---|
| `bindAgent(agent, node, label)` | `address(this)` | ❌ | `AgentBound` |
| `unbindAgent(agent)` | `address(this)` **or that agent itself** | ❌ | `AgentRevoked` |
| `restoreAgent(agent, node, label, attestation)` | `address(this)` | ✅ | `AgentBound` |
| `revokeAgent(agent)` | `address(this)` **or that agent itself** | ❌ | `AgentRevoked` |
| `pause()` | `address(this)` or any bound agent **that has not been revoked** | ❌ | `Paused` |
| `unpause()` | `address(this)` | ❌ | `Unpaused` |
| `setRule(node, token, rule, attestation)` | `address(this)` | ✅ | `TokenAllowed` / `LimitRaised` |
| `allowPayee(node, token, payee, attestation)` | `address(this)` | ✅ | `PayeeAllowed` |
| `tightenRule(node, token, rule)` | `address(this)` | ❌ | `LimitLowered` / `TokenRemoved` |
| `removePayee(node, token, payee)` | `address(this)` | ❌ | `PayeeRemoved` |

**Widening is two-of-two: `msg.sender == address(this)` **and** a valid attestation.**

**`bindAgent` must revert on an existing binding.** Otherwise "revoke an agent, then rebind
it for free" would sidestep what the frozen document says about reason code 2 (clearing
`AGENT_REVOKED` requires "ADMIN — reducing needs no face scan, **restoring does**").

**But that would make a wrong bind permanent** — caught in round two of review: with
`bindAgent` reverting on an existing binding and `restoreAgent` only restoring the old
node/label, binding agent A to the wrong name once would leave it unfixable.

**Two functions solve it together:**
- **`unbindAgent(agent)` is entirely free** (`address(this)` or that agent itself).
  Unbinding is a **reduction** — that agent can do nothing afterwards, returned to the
  unbound state. It can then be bound to the correct name with `bindAgent`
- **`restoreAgent(agent, node, label, attestation)` takes the full parameters**, all three of
  which go into the digest. This is the path for restoring a revoked agent, and it needs an
  attestation

`unbindAgent` then `bindAgent` takes two transactions but **needs no face scan** — because
both steps are reductions (return to zero, then start from zero), and at no point in between
does the agent hold more authority than before. That is the correct asymmetry. It costs one
line per function, and it cuts the C1 attack chain at its first step.

**Even an agent itself can press `pause()`.** Same reasoning as `PolicyApprovals.revoke`:
hitting the brake can only make the system stricter, and requiring a permission for it does
the attacker a favour at exactly the moment things go wrong.
**Which is precisely why `unpause` cannot require an attestation** — otherwise a compromised
agent could `pause` for free and force the holder to scan their face over and over. A free
brake demands a free release, both controlled by the wallet itself.

### `tightenRule`: turning "stricter" into a checkable assertion

`TokenRule` has five tunable fields (`allowed` / `txLimit` / `periodLimit` / `period` / the
window). A pair of raise/lower functions would leave the window and the period uncovered, and
**precisely those omissions could then be used to widen**:

> Change `period` and `periodIdx` changes with it, zeroing the `spent` counter — so
> **"lower the cap" would actually increase what can be spent.**

So reduction has a single entry point, and it requires **every field to be weakly
monotonically tightened**:

```solidity
function _isTighter(TokenRule memory old_, TokenRule memory new_) private pure returns (bool) {
    if (old_.allowed && !new_.allowed) return true;      // switching it off is always stricter
    if (!old_.allowed) return false;                     // already off; nothing stricter to be
    return _lteOrUnlimited(new_.txLimit, old_.txLimit)
        && _lteOrUnlimited(new_.periodLimit, old_.periodLimit)
        && new_.period == old_.period                    // <- must not move; see above
        && new_.epoch  == old_.epoch                     // <- must not move either, or the ledger wipes for free
        && _windowIsSubset(new_, old_);
}
```

Note that the `0 = unlimited` semantics make "compare magnitudes" more than a plain `<=`:
`0` → `100` **tightens**, while `100` → `0` **widens**. `_lteOrUnlimited` has to handle that
inversion, **and it needs a dedicated test** — it is the easiest line in the design to get
backwards. (Round two of review confirmed the semantics are right.)

#### `_windowIsSubset` — define it explicitly, because windows cross midnight

The semantics of `StandardPolicy._inWindow` (`src/StandardPolicy.sol:41-48`):

- `start == end` → **open all day**
- `start < end` → the same-day interval `[start, end)`
- `start > end` → **crossing midnight**, e.g. 22:00-06:00 = `[start, 1440) ∪ [0, end)`

So "stricter" cannot be decided by comparing magnitudes. Three rules, each needing a test:

| Case | Verdict | Example |
|---|---|---|
| The old window is all day (`start == end`) | **any** new window tightens | `(0,0)` → `(9,17)` ✅ |
| The new window is all day and the old is not | **a widening; refuse** | `(9,17)` → `(0,0)` ❌ |
| Both are bounded intervals | the new minute set must be a **subset** of the old | `(21,7)` → `(22,6)` ✅; `(22,6)` → `(21,7)` ❌ |

Do not try to decide the overnight subset case with inequalities — **normalise each interval
to `[start, start + length)` and compare the offset and the length**, or simply accept an
O(1440) loop.

> ⚠️ **The parenthetical that used to be here — "this is a `view`, so gas does not matter" —
> was wrong.** `_windowIsSubset` is called from `tightenRule`, which is external and
> state-changing, so the gas is really paid in a transaction. Measured at about 480k gas in
> the worst case. The loop is still the right choice; the reason is clarity, not that it is
> free.

**Clear beats clever: getting this section wrong silently widens the rule.**

### Two details that line up with the frozen events

**`Unpaused(by, attestationHash)` has a hash field, while `unpause()` no longer takes an
attestation.** → Emit `bytes32(0)`. The subgraph must read `0` as "an unpause that needs no
attestation", not as missing data.

**`setRule` maps onto two frozen events** (`TokenAllowed` / `LimitRaised`), and which fires
when must be stated, or the subgraph's two handlers will each guess:

| Condition | Emit |
|---|---|
| `allowed` goes `false` → `true` | `TokenAllowed` |
| `txLimit`, `periodLimit` or `period` loosens (including an `epoch` increment) | `LimitRaised` |
| Both at once | **both**, in the order `TokenAllowed` then `LimitRaised` |

`tightenRule` is the mirror: disabling a token emits `TokenRemoved`, tightening a limit emits
`LimitLowered`, and both may fire.

### What an attestation's digest binds

```solidity
digest = keccak256(abi.encode(
    TYPEHASH,          // one per action
    address(this),     // <- this wallet. A's attestation cannot be moved to B
    SELF,              // <- **this impl version**. See below
    block.chainid,     // <- this chain
    node, token, ...,  // the action's parameters
    nonce              // <- replay protection
));
require(!usedAttestations[digest]);
```

Inside a 7702 delegate, `address(this)` is **that EOA**, so under one impl every wallet's
digest naturally differs — no extra salt is needed.

**But `address(this)` is not enough to bind which impl version** — caught in round two of
review. After wallet W redelegates to impl v2, `address(this)` is still W, so **an attestation
signed for v1 could be replayed on v2** — and while `usedAttestations` lives in the EOA's
storage and v2 reads the same mapping… **if v2 changed its ERC-7201 namespace (see the
"Storage" section: change the layout, change the string), that "already used" record becomes
unreadable and the replay succeeds.**

The fix: add an `address immutable SELF`, set in the constructor to `address(this)` — the
address the **implementation contract itself** was deployed at, not the EOA at execution time.
When the delegate runs, `address(this)` is the EOA while `SELF` is still the impl's address,
and putting both into the digest binds which wallet *and* which impl version.

> A small trap specific to 7702: inside one piece of code, `address(this)` and "where this
> code lives" are **two different values**. An `immutable` is burned into the bytecode at
> deploy time, so it remembers the latter.

---
## Four amendments to a frozen document — **one of which is not an addition**

`docs/events.md`'s freeze rule is "fields and events may be added; **the type, order or
meaning of an existing field may not change**". The first version of this spec claimed there
were only two amendments and that both were additions. **That was wrong** — review found
four, of which one is a deviation, one widens a field's range, and one was simply my
mistake. Making exactly this kind of thing surface is what the freeze rule is for, so all
four are listed below, and each needs a corresponding line in `events.md`'s change log.

### 1. Adding reason code 12 `POLICY_FAILED`

There was no existing code for step 8 failing closed. Reusing `POLICY_NOT_APPROVED` (4)
would mislead the subgraph — that code means "no human approved this policy", while the
situation here is "this policy is broken or eats too much gas". The two call for entirely
different responses.

### 2. One new constraint on the `IPolicy` interface

> **A policy may only write to its ledger when it returns `Reason.OK`.**

Because the account **does not revert** when it blocks: if a policy debits the shared budget
and *then* returns "over limit", that debit is never rolled back and the shared budget leaks.
The way `SharedBudgetPolicy` is written happens to be correct (check first, then accumulate),
but that is an accident rather than a requirement — write it into `IPolicy`'s doc comments.

### 3. `AttesterGate` will not exist, and its events move to the consumers ⚠️ **a deviation**

Section 4 of `events.md` has a standalone component, `AttesterGate`, carrying
`AttestationAccepted(...)`. We decided not to build it (decision 7) — the only consumers of
an attestation are `LeashAccount` and `PolicyApprovals`, embedding the verification in each
is simpler than another layer of forwarding, and an extra contract buys nothing within a
five-day budget.

**What this changes is who emits the event**, not its fields. The subgraph's data source has
to follow. Mark in `events.md` that this component does not exist, so nobody later assumes it
was forgotten.

**Ownership settled (round two of review required this be decided on the spot, not left
open):** `AttestationAccepted` is **emitted by `LeashAccount`**, because it is the only place
holding the nonce and `usedAttestations` — the value of that event is the anti-replay audit
trail. `PolicyApprovals` **does not** emit it; it already carries the same information in
`PolicyApproved.attestationHash`, and changing an already-deployed contract for this is not
worth it. Both sentences go into `events.md`, pinning down where the event comes from.

Separately, `AttestationAccepted.action` is documented as "maps to reason codes 4-9", and we
also need to cover **11** (the shared budget). That **widens an existing field's range**, and
the change log needs a line for it.

### 4. Reason code 10 `PAUSED` ⚠️ **here the spec was wrong, not the document**

The frozen table says `| 10 | PAUSED | the whole account is paused | **ADMIN** |`, with the
note below that "1-3 and 10 are an ADMIN's routine operations" — **needing no face scan**.

The first version of this spec wrote `unpause(attestation)`, **in direct conflict with the
frozen document.**

**The frozen document is right.** And for a reason more substantial than "it was written
first": any bound agent can `pause` for free, so if `unpause` cost a face scan, a compromised
agent could force the holder to scan over and over — a DoS. A free brake demands a free
release. Changed to `address(this)` per decision 6.

**This item is listed here because the first version of the spec claimed there were "only two
amendments, both additions", and that was false.** Of the four, one is a deviation (item 3),
one widens a range (the second half of item 3), and one was simply my mistake (item 4). The
freeze rule exists to force exactly this into the open; it must not be quietly patched.

### Something that is not a documentation problem but would leave the subgraph blind

`SpendExecuted` and `SpendBlocked` **are emitted from each EOA itself**, not from one shared
contract. And 7702 delegation **emits no log at all**, so there is no factory event to
trigger a subgraph template from — **the subgraph does not know which addresses to watch.**

Two fixes; sprint item 9 has to pick:
- **Hardcode** the demo wallet addresses in `subgraph.yaml` (simplest, and enough for a
  hackathon)
- Emit `Leashed(node, wallet, impl)` on the **first `bindAgent`** as the template's trigger
  (cleaner, and `Leashed` is already in the frozen schema, so this gives it a definite moment
  of emission)

**Recommend doing both:** emitting `Leashed` is the correct design, and hardcoding the
addresses is the demo's insurance.


---

## `LeashLens` — is the leash still on?

`PLAN.md` originally specified `isLeashed(bytes32 node) → (bool, address)`, walking
ENS → wallet → delegate. **That direction does not exist** — ENS records node → policy, there
is no node → wallet reverse index, and building one costs another contract and another thing
to maintain.

Changed to:

```solidity
contract LeashLens {
    function delegateOf(address wallet) external view returns (bool leashed, address impl);
}
```

Read `wallet.code`, check that its length is 23 and its prefix is `0xef0100`, and return the
20 bytes that follow. The frontend checks once on load; a monitoring script polls.

**An EIP-7702 delegation change emits no log at all**, so a subgraph cannot index the leash
coming off — only `eth_call` polling can observe it. This is already written in `events.md`;
`LeashLens` is its implementation.

---
## Error handling, complete

| Situation | Behaviour |
|---|---|
| The caller is not a bound agent | **revert** `NotBoundAgent` |
| Reentrancy | **revert** `Reentrant` |
| The caller is bound but **has been revoked** | `SpendBlocked(AGENT_REVOKED)`, no revert |
| Any ENS hop reverts / returns `0x0` / **returns a length other than that hop expects (1: 32, 2: 32, 3: 96)** | `SpendBlocked(NO_POLICY)` |
| The policy is not on the approval list | `SpendBlocked(POLICY_NOT_APPROVED)` |
| `policy.check` reverts / blows the gas cap / returns a length ≠ 32 | `SpendBlocked(POLICY_FAILED)` |
| The policy returns `reason != OK` | `SpendBlocked(reason)` |
| `token.transfer` reverts or returns anything but a 32-byte `true` | **revert** (the whole thing rolls back atomically) |
| `amount == 0` | **revert** `ZeroAmount` — meaningless, and it would pollute the subgraph |
| `token` or `payee` is `address(this)` / `address(0)` | **revert** `BadTarget` (see below) |
| `token.code.length == 0` | **revert** `BadTarget` |
| The attestation has already been used | **revert** `AttestationReused` |

### 🔴 `token` and `payee` are chosen by the agent, so pointing back at this account must be blocked

When step 11's `token.transfer(payee, amount)` goes out, `msg.sender == address(this)` —
**exactly the authority `bindAgent` / `tightenRule` / `removePayee` accept.**

Today there is no selector collision (`transfer` is `0xa9059cbb`), so this is not an
immediate takeover. The danger is in the return check: with SafeERC20's permissive
convention (`success && (ret.length == 0 || abi.decode(ret) == true)`), then:

- `token == address(this)` → hits our own `fallback`, and if that does not revert, it
  **reports success while transferring nothing**
- `token == address(0)` → a call to an empty address **always succeeds and returns empty
  returndata** → the permissive check reads it as success

Both cases mean: **`spent` increases and `SpendExecuted` is emitted while not a cent
moved.** The subgraph would record a payment that never happened.

```solidity
if (token == address(this) || payee == address(this)) revert BadTarget();
if (token == address(0)   || payee == address(0))     revert BadTarget();
if (token.code.length == 0)                           revert BadTarget();
// the policy must not be this account either - the same authority-confusion problem
if (policy == address(this)) return NO_POLICY;
```

**And the return check must be strict:** exactly 32 bytes that decode to `true`.
Not SafeERC20's permissive variant — we only need to support the tokens our own demo uses,
not to be compatible with old ERC-20s that return nothing. **The compatibility permissiveness
buys is paid for here with a fake success.**

**`POLICY_GAS = 200_000`.** A policy that genuinely needs more fails closed.
The cap is deliberate: a policy that can burn all the gas is a DoS switch.
Write the number as a `constant` and state it in the documentation.

---

## Test plan

| Layer | Tool | What it covers |
|---|---|---|
| **7702 semantics** | `vm.signAndAttachDelegation` | callable after delegating, storage belongs to the EOA, two EOAs do not interfere, **an attacker cannot seize control** |
| **fork** | `vm.createSelectFork(sepolia)` | the three ENS hops against the real registry, using the addresses deployed 09-08. **The happy path must be verified at this layer** |
| **unit** | mock registry / mock policy | one test per reason code, including all three ways to trigger `POLICY_FAILED` (revert / burn gas / wrong return length) |
| **reentrancy** | a malicious token and a malicious payee | the lock works, and writing the ledger first still holds when the lock is defeated |
| **asymmetry** | — | every widening function fails without an attestation; every reduction function needs none |
| **fuzz** | — | budget accounting neither overflows nor under-debits; the running total for any sequence of `amount`s equals the sum |
| **three revocation layers** | fork | swapping the policy / `revoke(label)` / `expiry` lapsing / `setSubregistry(0x0)` each stop spending |
| **per-hop lengths** | fork + mock | 32 bytes for hops 1 and 2, 96 for hop 3. **A fake registry that deliberately returns the wrong length must be judged `NO_POLICY`** |
| **receiving ETH** | 7702 | after delegating, `payable(wallet).call{value: 1 ether}("")` **must succeed** |
| **C1 regression** | 7702 + `MockAttester` | **with the mock attester accepting everything**, every widening function must still fail for a caller that is not `address(this)` |
| **C4 boundary** | 7702 | a WALLET-signed `USDC.transfer` **succeeds** and emits **no** `SpendExecuted` — pinning the escape hatch as a specification |
| **fake success** | mock | `token`/`payee` = `address(this)` / `address(0)` / no code → revert, and `spent` unchanged |
| **the inversion of `0 = unlimited`** | — | `txLimit` `0`→`100` tightens (allowed); `100`→`0` widens (`tightenRule` must refuse) |
| **calling the impl directly is inert** | — | calling `spend` or any widening function on the impl address itself must have no effect |
| **full reason-code coverage** | mock | for each code: `SpendBlocked` was emitted **and** `balanceOf` did not change |
| **namehash mismatch** | — | `bindAgent(agent, node, label)` where node and label disagree → **revert** (M2 regression) |
| **rebinding** | — | `bindAgent` on an already-bound agent → **revert**; after `unbindAgent` it can be bound to the correct name (M4 regression) |
| **attestation replay across impl versions** | 7702 | an attestation signed for impl v1 **must be invalid** once the wallet redelegates to v2 (`SELF` goes into the digest) |
| **`_windowIsSubset`** | — | one test per rule: all-day→bounded ✅, bounded→all-day ❌, overnight subset `(21,7)→(22,6)` ✅ and `(22,6)→(21,7)` ❌ |
| **only `epoch` increments can wipe the ledger** | — | `tightenRule` touching `epoch` or `period` → revert; `setRule` changing `period` → `epoch` +1 with the old bucket's total **left in the old bucket** |

**Definition of done:** in the fork tests, a delegated EOA can pay successfully, can be
stopped by each of the four revocation levers, and each of them leaves the correct reason
code.

---

## Explicitly not doing (YAGNI)

| Not doing | Why |
|---|---|
| A general-purpose `execute(target, data)` | `SpendContext` is frozen into the payee/token/amount shape. General calls would need the policy to parse calldata, which is a different project |
| Spending native ETH | The demo uses MockUSDC. The `token` field stays, and ETH can be added later under the `address(0)` convention |
| Batched spends | One at a time, so the events line up |
| EIP-4337 compatibility | None of the three prizes requires it |
| An upgrade mechanism | Redelegating **is** 7702's upgrade mechanism |
