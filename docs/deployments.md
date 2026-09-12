# Deployments — Sepolia

**Chain:** Sepolia (chain id `11155111`)
**Current deployment:** 2026-09-08 16:34 UTC (**the second one** — see "Why we
redeployed" below)
**Deployer:** `0x36B3F5364A0dE03dc8eBaf0162C516E22D6bF959` (ADMIN)

> Every block timestamp below is **stamped by Ethereum and cannot be forged**. That is
> part of our evidence for ETHGlobal's "Start from Scratch" rule.

---

## Current addresses

| Contract | Address | Deployment tx |
|---|---|---|
| `LeashRegistry` | `0x6fB6CB4a789067b2283C4d4C657d3422ce742A51` | [`0xb23a39a8…`](https://sepolia.etherscan.io/tx/0xb23a39a85cccb679f4104567f610874ca1fecdba6470d87459678b47a5828172) |
| `LeashResolver` | `0x607a4d7363d9E7511a932F82eAE1e12FB609915b` | [`0x5ef9cbbb…`](https://sepolia.etherscan.io/tx/0x5ef9cbbb1f382aa84daaad625d2545c4ac38c6ab227a49ae031d7df0c968077b) |
| `PolicyApprovals` | `0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4` | [`0x0a8a3162…`](https://sepolia.etherscan.io/tx/0x0a8a31625189c3d432413abdc3c57e00d51eccc03d3d1ab37f2fe911b501d930) |
| `StandardPolicy` | `0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b` | [`0xff667665…`](https://sepolia.etherscan.io/tx/0xff6676659802654ca4ca35d0fa17b78a310df23fb95d1543cb2d729e14640ac7) |
| `MockAttester` ⚠️ | `0x268990a91B0727E80d38d5ED4Ab10d8889754124` | [`0x3142d584…`](https://sepolia.etherscan.io/tx/0x3142d584af188eb0f40e6cb2b474ccf99e2e2ffff3f9db0942548ef75b61540c) |
| `WorldAttester` | `0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26` | [`0xec9a06d3…`](https://sepolia.etherscan.io/tx/0xec9a06d398d51868fa5b576bdc54f424d9826acfd461be3226dc2d3720368cfa) |

### The ENS dependency, demonstrated by accident (2026-09-12)

The README's central claim about ENS is **"remove ENS and the spend cannot pass."** On
2026-09-12 that was not a thought experiment for about five minutes, because a script I did
not intend to run zeroed the live pointer.

| block | what |
|---|---|
| 11686336 | `acme.leash.eth` paid 5.00 USDC — the pointer still resolved |
| 11686340 | [`0x79fe18a0…`](https://sepolia.etherscan.io/tx/0x79fe18a045e9f1220e53d3517b6cd5805a1175303a2450aacccca738c494a4e7) set `vendors.leash.eth`'s policy record to `0x0` |
| — | `resolvePolicy(node, "vendors")` on the live account returned `0x0000…0000`. Every agent payment would now block with `3 NO_POLICY` |
| 11686xxx | [`0x1399d6f7…`](https://sepolia.etherscan.io/tx/0x1399d6f7bf2cb5c472feaa0febd9d849c665ff00e596e3e779221cfe2d369ff2) restored it to `StandardPolicy` |

Read back from the account after the restore, which is the check that matters because the
account does the walk rather than trusting a stored value:

```
$ cast call $WALLET "resolvePolicy(bytes32,string)(address)" $NODE "vendors"
0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b
```

**What the five minutes actually showed**, and it is worth more than the tidy version:

1. The three-hop walk is real. `getSubregistry("leash")` → `getResolver("vendors")` →
   `resolve(dnsName, addr(node))`. Break the third and the first two still answer perfectly
   while the wallet is disarmed.
2. **The account never trusts a cached policy address.** It walks every single spend, so the
   pointer going to zero disarms it on the next transaction rather than at some later
   refresh.
3. The subgraph reported the *old* pointer for a while afterwards, because `PolicyPointer`
   is written from the `PolicyPointerSet` event and the index was behind. So for a few
   blocks the page said one thing and the chain said another — which is the exact gap the
   `index N blocks behind` line on the demo page exists to make visible.

**How it happened, recorded because the process failure is the more useful lesson.** The
script was written and executed in a single shell invocation. My human partner rejected that
invocation, and the rejection landed after the transaction had already gone out — so a
refusal that was given was not a refusal that took effect. Anything that writes to the chain
is now written to a file in one step and run in a separate one, so there is a moment where
"no" can still mean no.

---

### `LeashAccount` v3 — the face outranks the key (2026-09-11)

| What | Value |
|---|---|
| Impl | `0xbB488f01b10cAc1572F16E82682Ba512375f3B85` ([`0x47de7cf8…`](https://sepolia.etherscan.io/tx/0x47de7cf8304d927915751a3deb2b6e4848756625a0aff768a11d33c42d638497)) |
| Wallet re-delegation | [`0xb5cc1e0b…`](https://sepolia.etherscan.io/tx/0xb5cc1e0bf21716cead45003a1c2e314834f327ee8e4a774ad45ece7d74f9a36b) — type 4, block 11682652, **36,844 gas**, identical to the 09-09 re-delegation |
| Owner's face registered | [`0x3a2f7ebe…`](https://sepolia.etherscan.io/tx/0x3a2f7ebe47cb242245be9d23f560ae7a80b2937da651598bb314d1517437222b) |
| `ownerNullifier()` | `0x180f9ee15bedaa3c1912ea178de159e0997ecaea8751f1b3f9f880601b49e881` |

Adds `allowPayeeByFace` — **no `onlySelf`** — and `setOwnerNullifier`. `allowPayee` is
untouched and still works; it is the fallback if anything about the new path misbehaves,
and keeping it cost nothing.

**Storage survived the re-delegation**, which is the thing to check and not assume. The
layout is ERC-7201 and `ownerNullifier` was appended at `SLOT + 6`, which was unused. Read
back immediately after:

```
ruleOf        → 1, 500000000, 50000000, 86400, 0, 0, 0   ← unchanged
isPayeeAllowed(…bEEF)  → true                            ← unchanged
balanceOf(wallet)      → 653000000                       ← unchanged
bindingOf(agent)       → (node, true)                    ← unchanged
ownerNullifier()       → 0                               ← the new field, at its new slot
```

**The property, verified against the live contract rather than a test.** The wallet, using
its own private key, asked the account to point at a different face:

```
$ cast call $WALLET "setOwnerNullifier(uint256,uint256,bytes)" \
    0x219b2715…b540c9 1 0xc0ffee --from $WALLET
Error: execution reverted, data: "0x99efb890"

$ cast sig "NotAttested()"
0x99efb890
```

Sepolia refused the key that owns it. Changing the registered face needs an attestation
from the face currently registered — the first registration is the only one the key can
make alone.

The price is stated in the contract's own notes: **losing that World ID permanently ends
widening on this wallet.** There is no key that overrides it, because a key that overrode
it would be the thing the function exists to rule out. Tightening paths — paying inside
existing limits, removing a payee, lowering a limit, revoking an agent, pausing — all keep
working with no face at all.

---

### Policy composition (deployed 2026-09-11 05:44 UTC)

| Contract | Address | Deployment tx |
|---|---|---|
| `MicroPaymentPolicy` (CAP = 1.00 USDC) | `0x0142BE4199942ff40F67c94aF181Cc9A0C9C19Df` | [`0xc7445756…`](https://sepolia.etherscan.io/tx/0xc7445756873c2ef137c050f5865868a61328702da6bf20966630d8fef0a1031c) |
| `PolicySet` | `0xec45e967F4e907B92bb1A9a8b4fcF9F041792490` | [`0xcdab0935…`](https://sepolia.etherscan.io/tx/0xcdab0935cdd124a605b49454c4153e47a8bb0123c9266e36238aa3b45032bcb7) |

Both in block `0xb238d6`. The set composes

```
clause 1 = [ MicroPaymentPolicy ]      a small payment, to anyone, still inside the budget
        OR
clause 2 = [ StandardPolicy ]          the full rules, including the payee allow-list
```

**`MicroPaymentPolicy` is not safe on its own and says so in its own `describe()`** — alone
it would allow any small payment to anyone. It is the exception half of a rule that only
makes sense as a whole.

Readback, 2026-09-11:

```
$ cast call $MICRO "CAP()(uint256)"          → 1000000            (1.00 USDC, 6 decimals)
$ cast call $SET   "clauseCount()(uint256)"  → 2
$ cast call $SET   "memberAt(uint256)" 0     → 0x0142BE41…  MicroPaymentPolicy
$ cast call $SET   "memberAt(uint256)" 1     → 0x88F2bfF0…  StandardPolicy
$ cast call $APPROVALS "isApproved(address)(bool)" $SET → true
$ cast call $APPROVALS "descriptionOf(address)(string)" $SET
    → "Under 1.00 USDC to any payee, or the full StandardPolicy rules"
```

Approved in tx
[`0x37865cec…`](https://sepolia.etherscan.io/tx/0x37865cec176071f8120593b9b8c1d8872f80796d665f9fb41bfbdc49f2bea2a1)
(block `0xb23928`) by `script/ApprovePolicySet.s.sol`, with an **empty attestation** —
see the caveat below for why that verifies. The description string is what the frontend and
the demo page show as "what this rule is", which is why it is written for a person.

**The ENS pointer is moved as the demo's finale, and the ordering is load-bearing.**
Installing the set is a separate `setPolicy`, deliberately run *after* the face-scan beat:
`world/demo.html` lights its face-scan button on the **agent's** predicted refusal, and
under the composition the agent no longer predicts that refusal — the chain does. Swap the
pointer before the face-scan beat and the button never appears.

It was moved for the first time on 2026-09-11 in
[`0x53b16bbb…`](https://sepolia.etherscan.io/tx/0x53b16bbb90b3c32cd54b04096a65bf08cbaacd3785300f82842bd226327d6c0c),
and one tick later the agent paid an intent it had been refusing for the previous 460 ticks
([`0x0335f905…`](https://sepolia.etherscan.io/tx/0x0335f9058ea926397707ed30e6f8a652bd55ea2d1e6505bfce1cf2137def476e)).
Nothing about the agent changed. Only the rule did.

**Between rehearsals the pointer is reset to `StandardPolicy`**, so whichever policy
`vendors.leash.eth` resolves to when you read this is whatever the last run left. Ask the
chain rather than this document: `LeashResolver.resolve` on the node, or read the demo
page's POLICY panel.

That last line is not an oversight — but read the next paragraph before reading it as a
security property.

**Approving a policy is not human-gated in this deployment.** `PolicyApprovals.attester` is
`immutable` and points at `MockAttester` (`0x2689…4124`), whose `verify` returns `true` for
any input. ADMIN can therefore approve a policy here with no attestation at all. The
asymmetry is per-contract and worth stating precisely:

| Gate | Attester | Real today? |
|---|---|---|
| `LeashAccount.allowPayee` — widening a payee, the face-scan beat | `WorldAttester` | **yes** |
| `PolicyApprovals.approve` — making a new policy installable | `MockAttester` | no |

So the lock a judge watches on camera is genuine and the one behind it is not. Changing it
means deploying a fresh `PolicyApprovals` and re-approving every policy through it — the
setter was deliberately removed (see the contract's own notes on why relocating the key was
not a fix), and that is the price of having removed it.

The composition was dry-run against the live contract with the wallet's real rule
(txLimit 500.000000, periodLimit 50.000000, window open all day) — these are `eth_call`s on
the deployed `PolicySet`, not tests.

**`SpendContext` is passed in whole, so these rows reproduce regardless of what the
allow-list says today.** `payeeAllowed` is a field of the struct the account assembles and
hands to the policy, so an `eth_call` supplies it directly; the third column below is the
value passed, not a lookup. `0x…CafE0` has since been allow-listed by a real face scan, and
the middle row still returns `6` when you pass `payeeAllowed: false` — which is the point of
a policy being a total function of its inputs.

| intent | amount | payee | returned |
|---|---|---|---|
| `retainer` | 5.00 | `0x…bEEF`, allow-listed | **0** `OK` — clause 1 fails on the cap, clause 2 passes |
| `newvendor` | 5.00 | `0x…CafE0`, `payeeAllowed: false` | **6** `PAYEE_NOT_ALLOWED` — both clauses fail, the **last** clause's reason is reported |
| `apitopup` | 0.50 | `0x…f00D`, a stranger | **0** `OK` — clause 1 passes, clause 2 never runs |

The third row is the whole argument for `OR` without anyone having to explain disjunctive
normal form: **two payments to strangers, one refused and one allowed, and the only
difference is the size.** The `6` in the middle row matters twice — it is what the demo
page's widen button keys on, and it is the one code a face scan actually fixes.

---

`MockAttester` and `WorldAttester` are **both** live, and that is not a typo: `attester` is
`immutable` per contract, and `PolicyApprovals` / `LeashRegistry` still point at the mock (see
the callout below), while `LeashAccount`'s current impl points at `WorldAttester` (see
"LeashAccount v2" at the end of this document). Which contract uses which is a per-contract
fact, not a project-wide one.

### EIP-7702 execution layer (deployed 2026-09-09 01:18 UTC)

| Contract | Address | Deployment tx |
|---|---|---|
| `LeashAccount` (impl, **superseded** — see "LeashAccount v2" below) | `0x136b33c68439C1ee8649048bb86E3a98ACd9B83C` | [`0x1aab21e0…`](https://sepolia.etherscan.io/tx/0x1aab21e0658c060431b94a198cba6cde9c5f27bf98bab668b1b4b4c365d51538) |
| `LeashLens` | `0xB6eB4C26AF866057920f7AB6fAFf69A914067B83` | [`0x4e615801…`](https://sepolia.etherscan.io/tx/0x4e615801b448399e13611a6490ddd59ed01771189e22325a13c76cd60a0c5004) |

The wallet no longer delegates to the impl above — it was re-delegated the same day to a
second impl wired to `WorldAttester` instead of `MockAttester`. The row is kept, not deleted:
its deploy tx, its onchain readback below, and the end-to-end run further down this document
all happened against it and remain true as history.

`LeashAccount` is an **implementation, not an instance**. Wallets delegate to it via
EIP-7702, and its code then executes in the wallet's own storage — so "deployed" and
"a wallet is using it" are two different facts.

Four things checked onchain immediately after deployment:

```
impl code size                              12,858 bytes
ETH_REGISTRY()                              0xBDC85dD5…F0E2   ← matches the table above
APPROVALS()                                 0x7CB9d4Ac…25B4
ATTESTER()                                  0x268990a9…4124
SELF()                                      0x136b33c6…B83C   ← equals its own deploy address
resolvePolicy(vendors node, "vendors")      0x88F2bfF0…75cc   ← StandardPolicy
```

**That last line is the first onchain evidence for this project's central claim:** a
properly deployed contract — not a test, not a fork — walked three hops through the real
ENSv2 and resolved a real policy address.

`SELF()` equalling the deployment address is worth recording too. It proves the
`immutable` captured **the impl itself**, not the runtime `address(this)` (which, inside
a delegate, is the delegating EOA). Attestation digests rely on that distinction to bind
both *which wallet* and *which impl version*.

> ⚠️ **Delegation is a separate step.** The wallet signs its own authorization:
> ```bash
> cast send $WALLET_ADDR --auth 0x136b33c68439C1ee8649048bb86E3a98ACd9B83C \
>   --private-key $WALLET_PK --rpc-url $R
> ```
> The deploy script deliberately contains no `WALLET_PK` — that key has no business in a
> deployment flow. Confirm with `LeashLens.delegateOf(wallet)`. Revoking is another
> `--auth` transaction pointing at `address(0)`, about 36,800 gas. **That is the wallet
> owner's escape hatch.**

> ⚠️ **`MockAttester` performs no verification and returns `true` for any input, and it is
> still what `PolicyApprovals` and `LeashRegistry` are wired to.** Its `describe()` says so
> out loud — `"MockAttester (NO verification - testing only)"` — and the frontend displays
> it. `attester` is **`immutable`** in both, so switching either of them to a real
> `WorldAttester` would need its own redeployment, a visible onchain transaction, exactly
> like the one this paragraph originally predicted for `LeashAccount`. That redeployment has
> now happened, but **only for `LeashAccount`**: its current impl is wired to
> `WorldAttester`, not the mock — see "LeashAccount v2" at the end of this document. This was
> a deliberate scoping decision, not a partial fix that ran out of time; see C1 below and
> decision 1 of the design spec for why `PolicyApprovals` and `LeashRegistry` were left as
> they were.

## Wiring transactions

| Action | Transaction |
|---|---|
| `PolicyApprovals.approve(StandardPolicy, nonce=1, attestation)` | [`0xdd14b8b5…`](https://sepolia.etherscan.io/tx/0xdd14b8b53cc5bb03118d0b181d236fa6d10afcc41d8a71af7f25839bd65d2f31) |
| `LeashRegistry.register("vendors", …, 30 days, nonce=1, attestation)` | [`0xcc379643…`](https://sepolia.etherscan.io/tx/0xcc3796431fa04bda68237147063ab2d1ce42e3af078ecca8cf40b7b85dee634f) |
| `LeashResolver.setPolicy(vendors node, StandardPolicy)` | [`0x74bec557…`](https://sepolia.etherscan.io/tx/0x74bec5575c4bd355ddaa397657590c05dff3cafb1780274c14d680effdbb331c) |
| **`ETHRegistry.setSubregistry(leash.eth, LeashRegistry)`** | [`0x19b8f085…`](https://sepolia.etherscan.io/tx/0x19b8f0856434422313365e1b32ab69db8c3c4bc3ec76514b1782bb5b2b35265b) |
| **`ETHRegistry.setResolver(leash.eth, 0x0)`** ← see I4 | [`0xd8b434f7…`](https://sepolia.etherscan.io/tx/0xd8b434f752d30dc40f61f0531a7f102f26c7cadba8c3b25fbf3a0a9890ca2501) |
| `LeashRegistry.setParent(ETHRegistry, "leash")` | [`0xa8c274de…`](https://sepolia.etherscan.io/tx/0xa8c274deba5d56e29640ffd07e4390e414c650663caf38baf843b8d439083f59) |

---

## Why we redeployed (2026-09-08)

The first deployment went out at 13:31 UTC the same day. A code review found **two
Critical issues**. Both falsified a load-bearing sentence in our security argument, and
both needed a contract change to fix.

**C1 — one key opened both locks.** `setAttester` was `onlyOwner` and needed no
attestation, and the first deployment gave all three contracts the same ADMIN owner. So
`setAttester(always-true)` → `approve(anything)` → `setPolicy` ran straight through.

Locking down `setAttester` alone would not have been enough: `LeashResolver.setApprovalsSource`
was `onlyOwner` too, so a stolen key needed only one extra step — deploy your own list
with your own attester and point at it.

**The fix was to remove the mutability, not to change who holds the key:** `attester` and
`approvals` are both `immutable` now. `PolicyApprovals` consequently needs no `owner` at
all, which makes this attack structurally impossible for it rather than merely guarded
against.

**C2 — attestations were replayable.** The digest carried no nonce and nothing recorded
a spent attestation, while `revoke` is public by design. So once a real `WorldAttester`
went live: copy the attestation out of public calldata → `revoke(policy)` → re-`approve`
with the **same** blob, and no human ever scans their face again. Now a standard EIP-712
digest with a nonce, plus an `attestationUsed` record.

**I4 — a wildcard resolver bypassed the middle revocation layer.** The first deployment
set `LeashResolver` as `leash.eth`'s own resolver, so the demo could look the name up
directly. That made it a wildcard for the entire subtree: when a subname has no resolver,
ENS's `UniversalResolver` walks up and finds it — and `LeashResolver` deliberately
ignores `name`, reading only the node. So `revoke` and `expiry` **did not stop resolution
through the official tooling.**

Measured onchain with `ghost.leash.eth`, a subname that was never issued:

| | First deployment | Now |
|---|---|---|
| `LeashRegistry.getResolver("ghost")` | `0x0` | `0x0` |
| `UniversalResolverV2` | **fell back to our resolver** ❌ | **reverts `ResolverNotFound`** ✅ |

Our own three-hop walk was correct throughout — it stops at hop two, returns
`NO_POLICY`, and no money moves. What was broken was the path the demo pointed at: after
a revocation, that same command still printed a policy address.

**The fix: leave `leash.eth` without a resolver.** Resolution is then *forced* through our
registry, with no side road.

The measurement above is of a name that was never issued. A *revoked* name should behave
identically, because `revoke` clears `resolver` and `expiry` so `getResolver` returns the
same `0x0` — and the fallback now fails on the parent, whatever the child. That is a
derivation from the two facts, not a third measurement.

The first deployment's addresses and transactions remain on chain (blocks
11661370–11661383) and are no longer used.

---

## Pre-existing ENSv2 addresses (not deployed by us)

| Contract | Address |
|---|---|
| RootRegistry | `0x8115186e8f2e0b0281e86ab91f0f48ba90364354` |
| ETHRegistry | `0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2` |
| UniversalResolverV2 | `0x4a1817d13e9cf196f471725176355c1234b63c70` |
| MockUSDC (minted by us) | `0x768f42455a2d082e23ceef7d51e5787c82d67a39` |

## Names and nodes

| Name | Value |
|---|---|
| `leash.eth` tokenId | `0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000` |
| `leash.eth` expiry | `1819875720` = 2027-09-02 |
| namehash(`leash.eth`) | `0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf` |
| namehash(`vendors.leash.eth`) | `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121` |
| DNS encoding of `vendors.leash.eth` | `0x0776656e646f7273056c656173680365746800` |

> The deploy script **no longer hardcodes the tokenId** — it queries
> `ETHRegistry.findTokenId("leash")` — and carries a `require(block.chainid == 11155111)`
> guard. The wrong RPC would put the entire control plane on another chain, and it would
> look like it succeeded.

---

## Verify it yourself, onchain

Paste this and reproduce it. `$R` is any Sepolia RPC.

```bash
ROOT=0x8115186e8f2e0b0281e86ab91f0f48ba90364354
NODE=0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121
DNS=0x0776656e646f7273056c656173680365746800

E=$(cast call $ROOT 'getSubregistry(string)(address)' eth --rpc-url $R)          # → ETHRegistry
LR=$(cast call $E 'getSubregistry(string)(address)' leash --rpc-url $R)          # → our registry
RES=$(cast call $LR 'getResolver(string)(address)' vendors --rpc-url $R)         # → our resolver
cast call $RES 'resolve(bytes,bytes)(bytes)' $DNS "$(cast calldata 'addr(bytes32)' $NODE)" --rpc-url $R
```

Actual output at 2026-09-08 16:36 UTC:

```
hop1  ETHRegistry.getSubregistry("leash")   = 0x6fB6CB4a789067b2283C4d4C657d3422ce742A51  ← ours
hop2  LeashRegistry.getResolver("vendors")  = 0x607a4d7363d9E7511a932F82eAE1e12FB609915b  ← ours
hop3  resolve(dns, addr(node))              = 0x…88f2bff031bb4cf2beaa28d47ada52ebeebbc33b  ← StandardPolicy
```

**Remove ENS and hop three has no answer, so no agent-initiated spend can pass (reason
code 3).**

To see that yourself, run the fork test — it does exactly this against a live fork of
Sepolia, with no transaction and nothing to undo:

```bash
SEPOLIA_RPC=$R forge test --match-test test_removing_the_ens_subtree_stops_resolution -vv
```

It mocks hop one to `0x0` and asserts `resolvePolicy` returns `address(0)`.

> The onchain equivalent is `ETHRegistry.setSubregistry(leash.eth, 0x0)` — the heavy
> revocation lever. **It needs the ADMIN key and it halts every agent at once**, so it is
> not part of the paste-and-run recipe above. Use the fork test.

> ⚠️ **Do not call this "the only spending path".** EIP-7702 constrains only calls *to*
> the delegated EOA; the wallet's private key can still sign `USDC.transfer` directly.
> The accurate claim is "**the agent's** only spending path". That the wallet is
> unconstrained is **both the boundary and the escape hatch** — the owner can always
> retrieve their own funds. A test asserts it: a wallet-signed direct transfer succeeds
> and emits no `SpendExecuted`.

### Each hop returns a different number of bytes (an implementation trap)

| Hop | Raw returndata | Why |
|---|---|---|
| 1 | **32 bytes** | returns an `address` |
| 2 | **32 bytes** | returns an `address` |
| 3 | **96 bytes** | returns `bytes`: offset (32) + length (32) + inner (32) |

Check hop three for `== 32` and **the happy path never succeeds** — while the reported
reason code says "ENS has no policy pointer", sending you to debug the ENS wiring where
nothing is wrong.

---

## Three revocation layers, one transaction each

| Layer | Transaction | Effect |
|---|---|---|
| light | `LeashResolver.setPolicy(node, stricter)` | Swap the rules |
| medium | `LeashRegistry.revoke("vendors")` | **That one agent dies**; others untouched |
| **heavy** | `ETHRegistry.setSubregistry(leash.eth, 0x0)` | **Every agent halts at once** |

And a fourth that needs **no transaction at all**: when an agent subname's `expiry`
lapses, `getResolver` returns `0x0` on its own. Renewal takes a human **and an
attestation** — a dead man's switch that costs nothing to arm. `MAX_DURATION` caps it at
365 days, so "issue a name that never expires" is not expressible.

**None of the four touches the agent's account.**

---

## End-to-end run on Sepolia (2026-09-09 01:20-01:35 UTC)

**A production-deployed impl, a real wallet, real money moving.** Not a test, not a fork.

| # | Action | Sent by | Transaction | Result |
|---|---|---|---|---|
| 1 | **Delegate** WALLET → impl | WALLET itself | [`0xd5a7f1c3…`](https://sepolia.etherscan.io/tx/0xd5a7f1c3bce760b9f04b83d8078131426f4bf0a87eacf636efa7d0bf19caff1f) | 36,844 gas. Code becomes the 23-byte `0xef0100 \|\| impl` |
| 2 | `bindAgent(AGENT, vendors, "vendors")` | WALLET | [`0xa65d10de…`](https://sepolia.etherscan.io/tx/0xa65d10de0916127571857e3af472a621c7a3827008526e70bdf090572cc6036a) | 94,036 gas. Emits `AgentBound` **and `Leashed`** |
| 3 | `setRule` (500 per tx / 1000 USDC per day) | WALLET + attestation | [`0x53f2bd28…`](https://sepolia.etherscan.io/tx/0x53f2bd28c633385e12057a9b4233926d5609c6bad058f6784e7ce155225060ce) | 148,349 gas. Emits `TokenAllowed` + `LimitRaised` |
| 4 | `allowPayee` | WALLET + attestation | [`0xbbfad4aa…`](https://sepolia.etherscan.io/tx/0xbbfad4aa9dbcfafabb65739f24f734ce4bd02cc5a04e206d518c8c62a94c1595) | 74,632 gas |
| 5 | **🎬 Act one** `spend(USDC, payee, 200)` | **AGENT** | [`0x64e40eeb…`](https://sepolia.etherscan.io/tx/0x64e40eebad9bc31dd9e9c929aad85acf72ec04180c1330e42dd8464b8b60711a) | 144,129 gas. `PolicyResolved` → `Transfer` → `SpendExecuted`. **Money moved** |
| 6 | **🎬 Act two** `spend` 600 to a brand-new address | **AGENT** | [`0x66333f4a…`](https://sepolia.etherscan.io/tx/0x66333f4af0943cd5558c73328ea468bf5de87c17b8ab9c367a05d2691347aaf0) | 91,921 gas. **status = 1 (no revert)**, `SpendBlocked(reason=6)`, **no `Transfer`** |
| 7 | **🎬 Act four** `LeashRegistry.revoke("vendors")` | ADMIN | [`0x60188de3…`](https://sepolia.etherscan.io/tx/0x60188de308c44320146d7ade93f62b300c75f9cb43b4a1c4635ba2856164ef17) | 39,083 gas. **One transaction halts the agent** |
| 8 | AGENT retries the legitimate payment | AGENT | [`0x82c015a7…`](https://sepolia.etherscan.io/tx/0x82c015a7d0af225bb9c739b6b54fa38642cb2acd1b730822ab324234793abcca) | status = 1, but `resolvePolicy` returns `0x0` → `SpendBlocked(reason=3)`, **no money moved** |
| 9 | Re-issue the subname → agent restored | ADMIN → AGENT | [`0xaed86814…`](https://sepolia.etherscan.io/tx/0xaed868149f378d1aa5afb8c6c93aed664c811c9e8505df29988076e571283e85) | Payment succeeds; 300 USDC cumulative |

> The transaction hashes for steps 8 and 9 were blank in this table until the subgraph was
> deployed and indexed them (blocks 11664759 and 11664762). They had been recorded by hand
> from a terminal session that only noted the outcomes.

### Three things that got onchain evidence for the first time here

**The evidence of a policy violation is that money did not move, not that the
transaction went red.** Step 6 **succeeded** (`status = 1`), yet USDC emitted no `Transfer`, the `WALLET`
balance did not change, and `spentInCurrentPeriod` was never incremented. Decoding the
`SpendBlocked` data:

```
amount     0x23c34600 = 600 USDC
reason     0x06       = PAYEE_NOT_ALLOWED
spentSoFar 0x0bebc200 = 200 USDC
limit      0x3b9aca00 = 1000 USDC
```

The reason is **6 (payee not allowed)** rather than 7 (over the per-tx limit) because
`StandardPolicy` reports the outermost violation first, working from outside in — exactly
the behaviour `test_reports_outermost_violation_first` pins down.

**`Leashed` really is emitted on the first `bindAgent`.** EIP-7702 delegation emits no
log at all, so a subgraph has no factory event to trigger an address template from. The
second event in step 2 (whose `data` is the impl address) is that trigger. The reasoning
from design time holds onchain.

**The middle revocation layer: one transaction, 39,083 gas, and the agent's account was
never touched.** After the revocation both `getResolver` and `resolvePolicy` return
`0x0`, and the agent's legitimate payment — transaction successful — cannot move a cent.
Re-issuing the subname restores it immediately, so the loop is repeatable and the demo
does not burn itself out on one run.

## The subgraph is live

```
https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.10
```

Deployed to Subgraph Studio, indexing from block 11662233 (the control plane) and 11664742
(the wallet), with `hasIndexingErrors: false`. The four questions an agent asks each map to
one entity — paste this into the endpoint above:

> **v0.0.5 (2026-09-11) indexes `LimitLowered`; v0.0.4 did not.** Every other reduction was
> already indexed — a payee removed, an agent revoked, a policy revoked, a subname revoked —
> so the index agreed with the chain about every way of taking authority away except the one
> that moves a number. Found by tightening the period limit from 1000 to 50 USDC
> ([`0x4f7e9936…`](https://sepolia.etherscan.io/tx/0x4f7e99369024c3c13243aa8220b167c504cfadadedb18db396829093f81720e3))
> and watching the index go on answering 1000. Studio keeps both versions live, so the same
> query shows the difference directly:
>
> ```
> v0.0.4   limit 1000.0   remaining 995.0     ← disagrees with the chain
> v0.0.5   limit   50.0   remaining  45.0     ← agrees
> ruleOf   (true, 500000000, 50000000, 86400, 0, 0, 0)
> ```

> **v0.0.6 (2026-09-11) stops inventing allow-list entries.** When a `SpendExecuted`
> arrives for a payee with no `Payee` row yet, the handler creates one — and it used to
> create it with `allowed = true`, reasoning that "a spend that executed proves the payee
> was allowed at that moment".
>
> That was true while `StandardPolicy` was the only policy, because it ANDs `payeeAllowed`
> into every verdict. **`PolicySet` makes it false**: `MicroPaymentPolicy` never reads
> `payeeAllowed`, so a sub-cap payment executes for a payee nobody allow-listed.
>
> Caught in a live rehearsal, not by a test. The demo page reported `0x…f00d` as
> **allowed** while the chain said otherwise — and that payee's entire purpose is to be
> paid *without* being on the list. The panel was erasing the thing it existed to show:
>
> ```
> v0.0.5   payee 0x…f00d   allowed true      ← invented; the chain has no such entry
> v0.0.6   payee 0x…f00d   allowed false     ← agrees
> isPayeeAllowed(node, USDC, 0x…f00d)  false
> ```
>
> This is the same defect class as the `agent/decide.mjs` Critical found the same day:
> an **offchain component that had absorbed `StandardPolicy`'s rules as an invariant**.
> The PolicySet spec said "the subgraph needs no change either"; that was the second
> sentence in its "What does not change" section to turn out false.

```graphql
{
  agentBudgets  { remaining spent limit periodEnd }        # 1. how much is left
  payees        { payee allowed paidCount paidTotal }      # 2. may I pay this payee
  policyPointers{ policy approved }                        # 3a. which policy
  approvedPolicies{ policy approved description }          # 3b. did a human approve it
  spends(where: { executed: false }, orderBy: blockNumber, orderDirection: desc) {
    reasonName amount payee                                # 4. why was I blocked
  }
}
```

Against the run above that returns: 700 USDC remaining of 1000; the payee allowed with 2
payments totalling 300 USDC; `StandardPolicy` approved with its `describe()` string; and the
two blocked attempts, `PAYEE_NOT_ALLOWED` and `NO_POLICY`.

Question 3 is deliberately two entities and not one. `PolicyPointer` is where ADMIN points
the name; `ApprovedPolicy` is what a human approved, and it comes from a different contract.
An earlier version copied the description onto `PolicyPointer` to save a query — code review
caught that this makes it a copy with no invalidation, since approving *after* the pointer is
set leaves it null forever. The field is gone; the join happens at query time, where it is
correct.

**`LeashedWallet` proves the design reasoning held.** EIP-7702 delegation emits no log, so a
subgraph has no factory event to trigger a template from. `LeashAccount` emits `Leashed` on
the first `bindAgent` instead, and the subgraph indexed it — wallet
`0x46c09255…8eba6` → impl `0x136b33c6…d9b83c`.

### That run's steps 3–4 used `MockAttester` — since fixed for `LeashAccount`

Steps 3 and 4 pass `0x00` as the attestation, and `MockAttester` returns `true` for any
input. So at the time of that run, of the two conditions behind "widening requires a real
human face", only one was actually guarding: `msg.sender == address(this)` was real (steps 3
and 4 had to be sent by WALLET itself), while the attestation half was a mock. Nothing above
is retroactively different — that run happened against the impl this document now marks
superseded, and its logs say exactly what they always said.

Swapping in `WorldAttester` was the back half of sprint item 8, and it is now done. See
"LeashAccount v2: `WorldAttester` is live" below for the new impl, the re-delegation, and the
static calls that prove the attestation half now actually guards something — plus what that
does and does not yet establish.

## LeashAccount v2: `WorldAttester` is live

Later the same day, `LeashAccount` was redeployed a second time with one change: its
`ATTESTER` is [`WorldAttester`](../src/WorldAttester.sol), not `MockAttester`. The wallet then
re-delegated to it. Nothing else moved.

| Contract | Address | Deployment tx |
|---|---|---|
| `WorldAttester` | `0xa4E208dA16f49CC6CecD70913Cf168CeAd865F26` | [`0xec9a06d3…`](https://sepolia.etherscan.io/tx/0xec9a06d398d51868fa5b576bdc54f424d9826acfd461be3226dc2d3720368cfa) |
| `LeashAccount` (impl, **current**) | `0x55528C707Bff43175CC7d7fCe6D9767060C67f23` | [`0xdf3ed24c…`](https://sepolia.etherscan.io/tx/0xdf3ed24ccf91f304d1e78432f46865bee4fded45b91405c806bea749067abc51) |

Read back from chain rather than trusted from the deploy log:

```
WorldAttester.SIGNER()        0x85b89D21DB13f220601430d48244B2AE06120969   ← World RP signer, rp_ef35d4e2d4f1a031
new impl.ATTESTER()            = WorldAttester above
new impl.APPROVALS()           0x7CB9d4Ac…25B4   ← unchanged from the superseded impl
new impl.ETH_REGISTRY()        0xBDC85dD5…F0E2   ← unchanged from the superseded impl
```

`APPROVALS()` and `ETH_REGISTRY()` matching means this deployment moved exactly one thing.

| Action | Transaction |
|---|---|
| `WALLET` re-authorises (EIP-7702) to the new impl | [`0xfe8cb0fd…`](https://sepolia.etherscan.io/tx/0xfe8cb0fd6096fca1e5da9563fbec91b1dadcd066ed6f87f67520708fac458008) — type 4, block 11667630, gas 36,844 |

Wallet storage was snapshotted before and after re-delegation and came back byte-identical —
the ERC-7201 storage-layout property working as designed, not merely asserted:

```
bindingOf(agent)        (0x9b4cc576…e121, "vendors", false)
ruleOf(node, MockUSDC)  (true, 500000000, 1000000000, 86400, 0, 0, 0)
```

Enforcement was then proved live with free static calls against the re-delegated wallet:

```
allowPayee(73 junk bytes)   → reverts 0x99efb890 = NotAttested()   (confirmed with `cast sig`)
allowPayee(empty bytes)     → reverts 0x99efb890 = NotAttested()
removePayee(no attestation) → succeeds, no error
```

Under the superseded impl's `MockAttester` wiring, the first two calls above would have been
**accepted**. This is the first onchain evidence that the attestation half of "widening needs
a live human" is actually guarding something, not decorative.

**What this does not yet establish.** The digest path above has never been exercised against
World's live API. The World action behind it, `expand-policy-demo1`
(`action_1f91e0b88227d9c86c276c28d30c3324`), allows exactly one verification and it was still
unspent as of this deployment — it is reserved for the demo itself, because
`max_verifications` cannot be raised once set. So the static calls above prove the *contract*
correctly rejects a malformed or missing attestation and would accept a well-formed signature
from `SIGNER`.

**The full chain ran for the first time on 2026-09-11, with a real face.** World App opened
the camera, the proof returned `identifier: "selfie"`, the backend verified it at the v4
endpoint and signed, and `allowPayee` landed in tx
[`0x53d31784…`](https://sepolia.etherscan.io/tx/0x53d317849a08c1cdb0614028ef1a99d0b6f59ebf542b1b142afbac1dc5d7ca63).
The agent noticed the widening on its next tick and paid the vendor it had been refusing, in
[`0x00a9080f…`](https://sepolia.etherscan.io/tx/0x00a9080f4b649eb2d90d66edd6fc40a66c1012c50dacf5cb2168ca710a67a392),
without anyone touching the agent.

**The three actions, and which scan each is for.**

> **Corrected 2026-09-11 — actions are not scarce, and `max_verifications` does not do what
> we assumed.** This section used to say "a scan is a consumable and there are three of
> them". Two measurements refute it. First, `precheck` **creates** an action rather than
> looking one up: posting a randomly generated string returns a real, active action with its
> own id and `external_nullifier`, so you can mint as many as you like without the Portal.
> Second, re-verifying an already-used action still returned `success: true`, with the
> message `"Proof verified successfully (nullifier reuse)"`. Whatever `max_verifications: 1`
> limits, it is not "can this person produce another valid proof for this action" — and we
> did not measure what it does limit, so we are not guessing. See `docs/world-feedback.md`
> §6.3 and §7.6.
>
> The practical consequence is the opposite of what this table implied: **rehearse freely.**
> The reserved actions below are a naming convention now, not a budget.

Created and verified via `precheck` on 2026-09-09; all three came back `status: active`,
`max_verifications: 1`, `enable_face_check: true`, `can_user_verify: yes`.

| Action | Action id | Reserved for | Spent |
|---|---|---|---|
| `expand-policy-demo1` | `action_1f91e0b88227d9c86c276c28d30c3324` | first live run / rehearsal | no |
| `expand-policy-demo2` | `action_e7e06eb49915d9225abcb5d01a7ec166` | recording the video | no |
| `expand-policy-demo3` | `action_ffa11f8425f2d2e4bd7fa9c114df710e` | live judging, spare | no |
| **`leash-owner`** | minted by `precheck` on demand | **every widening, always** | reusable |

### 🔴 Superseded on 2026-09-12: the three reserved actions are not for the widening scan

The table above predates `ownerNullifier`. Once a face is registered, **the action is no
longer a free choice** — a nullifier is `hash(person, action)`, `allowPayeeByFace` refuses
anything that is not the registered value, and a fresh action therefore produces a different
number and a refused widening.

```
ownerNullifier()                      0x180f9ee1…b49e881   read from the wallet, 2026-09-12
a leash-owner scan on 2026-09-11      0x180f9ee1…b49e881   getDebugReport, evidence E9
```

`WORLD_ACTION` is `leash-owner` and stays there. Re-verification of a used action succeeds
(*"Proof verified successfully (nullifier reuse)"*), so it costs nothing to reuse it every
take. The `expand-policy-demo*` actions remain valid for anything that does **not** check
against a registered face — nothing in the current demo does.

`expand-policy` itself was consumed on 2026-09-07 and is dead. Update the Spent column as
each is used — a scan that is already gone is the one fact that is expensive to rediscover,
because rediscovering it means a failed verification in front of an audience.

Two more limits worth restating rather than letting the good news above imply past them:

- **`MockAttester` is still deployed and still used**, by `PolicyApprovals.approve` and
  `LeashRegistry.register`. Only `LeashAccount`'s widening paths (`setRule`, `allowToken`,
  `allowPayee`, `restoreAgent`) became real; approving a new policy and issuing a new agent
  subname still accept any input. Deliberate scope, not an oversight — see the callout above
  and decision 1 of the design spec.
- **A `WorldAttester` proof cannot prove it came from Selfie Check.** `verify()` proves only
  that the RP signer signed this exact digest before its deadline — `describe()` on the
  contract says as much. The link to a live human is offchain: World App runs Selfie Check →
  World's v4 endpoint verifies the proof → the backend signs only after that call returns
  HTTP 200. **That last hop is where the guarantee lives, and as of 2026-09-11 it is
  checked rather than assumed:** `world/attest.mjs` refuses to sign unless the result says
  `identifier: "selfie"`, and refuses again unless the proof's `signal_hash` equals the
  digest being widened.

  > **Corrected 2026-09-11.** This bullet used to end: "Even a successful proof reports
  > `credential_type` and `verification_level` as `"device"`, identical to a passcode-only
  > session; the liveness guarantee lives in the app's `enable_face_check` setting, not in
  > the credential."
  >
  > That was measured false. A proof reports `device` when a **device credential** is what
  > was requested — which is all `@worldcoin/idkit-standalone` can request, since its
  > `verification_level` vocabulary contains no face check. Requested properly, as a World
  > ID 4.0 `SelfieCheckLegacy` credential through `@worldcoin/idkit-core`, the camera opens
  > and the proof comes back `identifier: "selfie"`. The credential does say which one was
  > exercised; we had never asked for the one we wanted. See `docs/world-feedback.md` §7.5
  > and §7.9.

## Two agents, one budget (2026-09-12)

A second agent was bound to the **same** name, `vendors.leash.eth`. No contract changed,
and none needed to: the property was already in the data model, it had simply never been
exercised.

| # | Action | Sent by | Transaction | Result |
|---|---|---|---|---|
| 1 | gas for `AGENT2` | ADMIN | [`0x1441fb4a…`](https://sepolia.etherscan.io/tx/0x1441fb4ade8086005c3cc96c29ca93cea6798daa881129d6e7aff584ae43a64c) | 0.012 ETH |
| 2 | `bindAgent(AGENT2, vendors, "vendors")` | WALLET | [`0xa7d6fbbd…`](https://sepolia.etherscan.io/tx/0xa7d6fbbddd1542b038905f3d730c994c7122c9d8ec11efcae7f78347d74f026a) | 72,051 gas. `AgentBound` only |
| 3 | `spend(USDC, acme, 1.00)` | **AGENT2** | [`0xbe743cd4…`](https://sepolia.etherscan.io/tx/0xbe743cd45fe05d9d97a1970eb07e7c1fe8b8f3f86c4311c29fe3fc70e3a1bfd1) | 109,929 gas. `SpendExecuted` |

`AGENT2` is `0x2160562A1C07f854cA37F502fa34BE0887259F8a`.

**Step 2 cost 72,051 gas against the first bind's 94,036.** The difference is `Leashed`,
which fires once per wallet and had already fired — `leashedEmitted` behaving as designed.

**Step 3 is the measurement.** Read either side of it:

```
spentInCurrentPeriod(vendors, USDC)   before   20.50 USDC   ← put there by AGENT
spentInCurrentPeriod(vendors, USDC)   after    21.50 USDC   ← moved by AGENT2
```

AGENT2 had never sent a transaction before. It began its first payment 20.50 USDC into a
50 USDC budget, because **the budget is not its own**. Nothing links the two agents but the
node they are both bound to: no shared database, no coordinator, no message between them.

### Why this needed no new code

```solidity
mapping(bytes32 node => mapping(address token => mapping(uint256 bucket => uint256))) spent;
```

Three keys — name, token, period. **No agent.** And the getter's ABI says the same thing
out loud:

```solidity
function spentInCurrentPeriod(bytes32 node, address token) external view returns (uint256);
```

There is no per-agent overload because there is no per-agent number.

The guard in `bindAgent` is often misread as preventing this:

```solidity
if (b.node != bytes32(0)) revert AlreadyBound();
```

It refuses **an agent that is already bound**. It says nothing about the node. So the
constraint runs one way only, and that is the useful direction:

- many agents → one node — **allowed**, and now measured
- one agent → two nodes — **refused**

The second is refused deliberately. An agent that could sit under two budgets would move
to the other one when the first ran out, which turns a limit into a suggestion.

### Attribution survives the sharing

`SpendExecuted` and `SpendBlocked` both carry `address indexed agent`. The limit belongs to
the department; every transaction is still filed under the agent that sent it. That is the
corporate-card arrangement exactly — one credit line, and the statement still names the
cardholder on every line item.

### Rehearsal, 2026-09-12 09:40–09:55 UTC — every beat but the face scan

Run end to end against the deployed contracts, with two agent processes and the page.

| Beat | What was asked, and of whom | Result |
|---|---|---|
| 1 | **payments**: "Pay this month's studio retainer." | 5.00 USDC → `acme.leash.eth`, [`0x946af0d4…`](https://sepolia.etherscan.io/tx/0x946af0d4b0cb99d483ca3751a2bf50b23e59f6985af77e816a06542f8dc7c75c). Budget 26.50 → 31.50 |
| 3 | **subscriptions**: "Renew our annual licence with Acme Studio — 48.00 USDC." | refused, `8 OVER_PERIOD_LIMIT`. *"18.50 left of 50.00 USDC, and this payment is 48.00"* |
| 4a | ADMIN points the name at `PolicySet` | [`0xfb8c44d4…`](https://sepolia.etherscan.io/tx/0xfb8c44d4afe5ffbc5e212c1c0fd60a00d139f004e7f1b8ae6ee44e7cce7fca51) |
| 4b | **payments**: "Top up our inference API credits by 50 cents." | 0.50 USDC → `api.leash.eth` — a payee **never on the allow-list** — [`0xf4f17919…`](https://sepolia.etherscan.io/tx/0xf4f17919e7b1d01af94e427ddc02b8cd5796a2759e102da5050a27410c297f62). The payee panel reads **`paid, never listed`** |
| — | pointer restored to `StandardPolicy` | [`0xafd1196f…`](https://sepolia.etherscan.io/tx/0xafd1196f0d813f6c5b923970b28b3432eee5a0816d7ba911099495519288b7a2) |

**Beat 2 (the face scan) was not rehearsed** — it needs a phone in front of a camera, and
there is no way to fake it that would be worth anything. Its two halves were exercised
separately on 2026-09-11 (a real scan reaching `allowPayeeByFace`) and are unchanged since.

#### What the second agent said, unprompted

> "The Acme Studio renewal of 48.00 USDC was refused because it exceeds our period budget —
> we have only 18.50 USDC remaining of our 50.00 USDC limit. To make this payment, we'd need
> the period budget increased **or expenses in other categories reduced** to free up the
> necessary funds."

Nobody told it about the other agent. It read the budget off the chain, found the money
gone, and inferred a colleague. That last clause is the demo's whole argument arriving from
the model rather than from the narration.

#### One thing this rehearsal changed

The refusal first read `this would exceed the period budget (23500000 left of 50000000)`.
Base units are what the chain speaks and what every comparison in `decide.mjs` uses, but
nobody watching could size them at a glance — and that sentence is the one place a shared
budget becomes legible. Only the explanation is formatted; every decision above it stays in
base units. `decide.test.mjs` now pins the string.

### The second agent's refusal is on chain, not only predicted (2026-09-12 09:48 UTC)

The rehearsal above recorded beat 3 as a **prediction** — `decide()` read the budget off the
index, found no room, and never sent. That is what happens under `StandardPolicy`.

Minutes later, while the pointer was swapped to `PolicySet` for beat 4, the same intent was
still live in the subscriptions agent. `decide()` declines to guess when the installed policy
is not the one whose rules it encodes, so it returned `will-pass` — *let the chain answer* —
and the agent sent it. Twice.

| Transaction | Sent by | Result |
|---|---|---|
| [`0x695e618c…`](https://sepolia.etherscan.io/tx/0x695e618c1b3da3b2d78b71d2e8479a99c66766c030f4ef52daa539db21a27eb1) | `AGENT2` | status = 1, `SpendBlocked(reason = 8)`, 48.00 USDC, **no `Transfer`** |
| [`0x096467a3…`](https://sepolia.etherscan.io/tx/0x096467a3f40c559dd8b10465e3797f5eb9360e427c86b24c92c7418b7bdef022) | `AGENT2` | the same, one tick later |

Three things are settled by those two transactions, and none of them were staged:

1. **The shared budget is enforced by the contract, not by the agent's pre-flight.** The
   refusal in the rehearsal was the agent declining to try; these are the chain declining to
   pay. Same reason code, and this time nothing offchain was involved in the decision.
2. **`PolicySet` honours the period budget.** 48.00 is over `MicroPaymentPolicy`'s 1.00 cap,
   so that clause fails and the general clause decides — and the reported code is the *last*
   clause's, which is the rule `PolicySet` was written to follow. An OR composition that
   reported the first clause's code would have said "over the micro cap" when the fact worth
   knowing is "the company's budget is spent".
3. **`blocked-despite-green` is a real state, not a defensive comment.** `agent/loop.mjs`
   names it because a pre-flight that reads an index can be wrong in the permissive
   direction; here it was, twice, and the money still did not move.

The second transaction is the latch working: the agent sent once, got a refusal, and stopped
asking — the re-send happened because the *policy pointer changed between ticks*, which is
exactly one of the three conditions `advance()` treats as "something that could change the
answer".

### The face scan, run by a human, end to end (2026-09-12 12:1x UTC)

The last untested step. A person scanned with World App, the front camera opened, the
widening relayed itself, and the agent paid on its next tick without being told.

| | |
|---|---|
| payee before | `0x…b1ef` — `allowed: false`, `everAllowed: false` |
| payee after | `allowed: true`, `everAllowed: true` |
| the payment | [`0x05286487…`](https://sepolia.etherscan.io/tx/0x052864877ce387d2a985999121f44f8e2e0bdace44c05e0fd9e64da9147078e2) — 5.00 USDC to `bluefin.leash.eth`, `SpendExecuted` |
| action used | `leash-owner`, reused — World answered on a nullifier it had already seen |

`WORLD_ACTION` had been wrong in `.env` an hour earlier (`expand-policy-demo2`, which
would have produced a different nullifier and a refused widening); this run is the
correction working.

#### A distinction the page was blurring, found by watching it rather than reading it

The refused `bluefin` card **never appeared in the refusal log**, and that is correct:

```
decide()  → PAYEE_NOT_ALLOWED, predicted from the index
loop.mjs  → sends only `will-pass`, so no transaction exists
chain     → no SpendBlocked event, so the index has nothing to show
```

**The agent declining to try and the chain refusing are different events**, and only the
second is indexable. Everything in that list was a real `SpendBlocked`.

This is the honest behaviour — an agent that spends gas on a payment it can already see
will fail is a worse agent — but the page said `Turned away earlier` over a list that
silently meant something narrower. It now says **`Refused by the chain`**, with one line
underneath drawing the line explicitly. The case that *does* reach the list is the one
worth being able to see: `blocked-despite-green`, where the pre-flight was wrong and the
contract caught it. Two of those are recorded above.
