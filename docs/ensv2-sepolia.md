# ENSv2 on Sepolia — measured results

> Measured: 2026-09-01
> RPC:`https://ethereum-sepolia-rpc.publicnode.com`
> Tool: `cast` (foundry 1.7.1)
> **Every item below came from actually hitting the chain, not from reading documentation.**

ENSv2 is currently **on Sepolia only** (the beta started 2026-08-12); mainnet is not live.
That also explains why the ENS prize requires Sepolia.

---

## Contract addresses (all confirmed to have bytecode)

| Contract | Address |
|---|---|
| RootRegistry | `0x8115186e8f2e0b0281e86ab91f0f48ba90364354` |
| ETHRegistry | `0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2` |
| ETHRegistrar | `0xa88553f454b77203b0d036a05c894d555eaaa2cc` |
| UniversalResolverV2 | `0x4a1817d13e9cf196f471725176355c1234b63c70` |
| PublicResolverV2 | `0xe7b9a25607e02da8145e4eb1836ca539e53f11f7` |
| PermissionedResolverImpl | `0x9eae5c2730a7dd16bdd1dee6421a1b91e3b0365e` |
| ManagedUniversalResolverProxy | `0x6d80F2172CFdEc5730fE683860C33d26fC42e6F1` |
| **MockUSDC** (the token registration is paid in) | `0x768f42455a2d082e23ceef7d51e5787c82d67a39` |
| PriceOracle | `0x8914b66260eb8c4fff795650c3ae8cd335958987` |

RootRegistry and ETHRegistry have identical bytecode lengths (29463 chars), consistent with
both being instances of PermissionedRegistry.

MockUSDC: symbol `USDC`, 6 decimals, and `mint(address,uint256)` (`0x40c10f19`) with **no
access control** — simulating a mint from a random address via `eth_call` succeeds. It also
has `permit`.

---

## ⚠️ The most important finding: resolvers support ENSIP-10 only

```
supportsInterface(addr    0x3b3b57de) = false
supportsInterface(text    0x59d1d43c) = false
supportsInterface(resolve 0x9061b923) = TRUE
```

**Calling `addr(bytes32)` or `text(bytes32,string)` directly reverts. All three attempts
failed.**

The ENSIP-10 wildcard interface must be used instead:

```solidity
resolver.resolve(
    dnsEncodedName,                                  // e.g. 0x046e69636b0365746800
    abi.encodeCall(ITextResolver.text, (node, "policy"))
);
```

### And this is exactly the good news

Measured: `resolve()` **returns data directly** — no `OffchainLookup` revert, no gateway, no
CCIP-read.

> **The risk that would have overturned the whole architecture — "a contract cannot read the
> policy at execution time" — is now ruled out by measurement.**

Implementation note: do not write `addr()` out of ENSv1 habit; it only wastes time.

---

## Verifying the onchain walk (`nick.eth`)

```
RootRegistry.getSubregistry("eth")
  → 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2      ✅ exactly the ETHRegistry in the docs

ETHRegistry.getResolver("nick")
  → 0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba

resolver.resolve(0x046e69636b0365746800, addr(node))
  → 0xb8c2c29ee19d8307cb7255e1cd9cbde883a267d5
```

**Running the same query through UniversalResolverV2 returns exactly the same address.**
The path we walk by hand is equivalent to the official entry point — meaning a 7702 delegate
can walk it itself, without depending on UniversalResolver.

---

## Verified selectors

### IRegistry / PermissionedRegistry

| Function | Selector | Purpose |
|---|---|---|
| `getSubregistry(string)` | `0x35af6216` | walk one level down |
| `getResolver(string)` | `0xe4ae7d77` | fetch the resolver |
| **`setSubregistry(uint256,address)`** | **`0x341ec559`** | **the kill-everything revocation** |
| `setResolver(uint256,address)` | `0xbc7b6d62` | swap the policy |
| `ownerOf(uint256)` | `0x6352211e` | ERC1155Singleton |
| `getResource(uint256)` | `0x1e8fca2d` | EAC resource |

### ETHRegistrar

| Function | Selector |
|---|---|
| `isAvailable(string)` | `0x965306aa` |
| `getRegisterPrice(string,uint64,address)` → `(base, premium)` | `0x61907b12` |
| `getRenewPrice(string,uint64,address)` | `0xddf0effc` |
| `commit(bytes32)` | `0xf14fcbc8` |
| `makeCommitment(string,address,uint256,address,address,uint64,uint256)` | `0x1e966f07` |
| `register(string,address,uint256,address,address,uint64,address,uint256)` | `0xcff3e7c2` |

Constants (measured):

| Constant | Value |
|---|---|
| MIN_COMMITMENT_AGE | 60 s |
| MAX_COMMITMENT_AGE | 86400 s (24 hours) |
| MIN_REGISTRATION_DURATION | 2419200 s (28 days) |

---

## The registration flow

A classic commit-reveal:

```
makeCommitment(label, owner, secret, subregistry, resolver, duration, referrer)
  → commit(commitment)
    → wait ≥60 s
      → register(label, owner, secret, subregistry, resolver, duration, paymentToken, referrer)
```

### The single most important point for us

**`register()` already takes a `subregistry` parameter.**
Our own registry can be hung at the moment `acme.eth` is registered; no separate step
afterwards is needed.

The role bitmap the registrant receives includes:
`ROLE_SET_SUBREGISTRY`、`ROLE_SET_SUBREGISTRY_ADMIN`、
`ROLE_SET_RESOLVER`、`ROLE_SET_RESOLVER_ADMIN`、`ROLE_CAN_TRANSFER_ADMIN`

→ **"One transaction halts every agent in the company" is confirmed viable.**

---

## Prices (in MockUSDC, freely mintable = effectively free)

| Name | 1 year | Note |
|---|---|---|
| `agentwallet` | **8.000021 USDC** | 5 characters or more |
| `policy-agent-demo` | **8.000021 USDC** | |
| `acme` | 160.000009 USDC | 4 characters costs more; 28 days is only 12.27 |

**Measured as available**: `acme` `agentwallet` `policyagent` `hackathon` `ethglobal`
`company` `parent` `sub`
**Already taken**: `nick` `test` `ens` `dao` `agent` `demo` `org` `integration-tests`

---

## Incidental observations

**Each name really does get its own resolver clone.**
In a real registration transaction a 78-byte contract is created (an EIP-1167 minimal
proxy), and `supportsInterface(0x9061b923)` = true.
This confirms the "per-account Permissioned Resolver" the documentation describes.

**ENSv2 Sepolia is very active.**
**1813** registrar events in the last 5000 blocks.
Upside: the network is alive and the documentation is maintained.
Downside: **it confirms that "a redeploy during the audit window (8/18-9/14)" is a real
risk** — addresses must be managed in one place.

---

## Known traps

The official app-developer tutorial says explicitly:

> subname owners typically hold no roles on the parent resolver,
> so a `setText` from their wallet reverts with `EACUnauthorizedAccountRoles`

A subname's holder **cannot change records on the parent's resolver by default**.

The fix: give the subname its own resolver, or delegate the role with `authorize*Roles`.

**For us this is a feature, not a bug** — an agent should never be able to change its own
policy.

---

## How to reproduce

```bash
export R=https://ethereum-sepolia-rpc.publicnode.com
ROOT=0x8115186e8f2e0b0281e86ab91f0f48ba90364354

# 1. walk to .eth
cast call $ROOT "getSubregistry(string)(address)" "eth" --rpc-url $R

# 2. fetch nick.eth's resolver
ETHREG=0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
cast call $ETHREG "getResolver(string)(address)" "nick" --rpc-url $R

# 3. read the record via ENSIP-10 (note: calling addr() directly reverts)
RES=0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba
NODE=$(cast namehash nick.eth)
cast call $RES "resolve(bytes,bytes)(bytes)" \
  0x046e69636b0365746800 $(cast calldata "addr(bytes32)" $NODE) --rpc-url $R
```

---

## How tokenId is derived (measured 2026-09-02)

`setSubregistry(uint256,address)` and `setResolver(uint256,address)` both take a
**tokenId**, not a string. Comparing after actually registering `leash.eth`:

```
keccak256("leash") = 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011342ffc412
actual tokenId     = 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000
                                                                              ^^^^^^^^
```

**tokenId = the labelhash with its low 32 bits zeroed.**

```solidity
uint256 tokenId = uint256(keccak256(bytes(label))) & ~uint256(type(uint32).max);
```

Those 32 bits are `Entry.tokenVersionId`. They increment when a name is burned or
re-registered after expiry, and **the tokenId changes with them** — so anywhere a tokenId is
stored long-term has to account for it.

A freshly registered name has `tokenVersionId` 0, which is why it currently equals the
aligned labelhash exactly — but **do not rely on that coincidence**. The safest source is
the ERC-1155 `TransferSingle` log:

```bash
cast receipt <TX> --rpc-url $R --json \
  | python3 -c "..."   # topics[0] == keccak('TransferSingle(address,address,address,uint256,uint256)')
                       # data[0:32] = id
```

## The actual registration record (a reproducible baseline)

| Item | Value |
|---|---|
| Name | `leash.eth` |
| owner | `0x36B3F5364A0dE03dc8eBaf0162C516E22D6bF959` |
| tokenId | `0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000` |
| Duration | 31536000 s (1 year) |
| Paid | MockUSDC **8.000021** (exactly getRegisterPrice's quote, to the digit) |
| register gas | 217,387 |
| commit tx | `0x0339df95b0b66399e3d5ff46253747551fb4ae74c2b6fff9ef0a81ecf9bc440e` |
| register tx | `0xcf6792b412f8d61cd1b00115b7c838a79a7cc76ae206f2f83f316bb5ab5a9d08` |
| subregistry / resolver at registration | both `address(0)`; wired up on 9/4 |

**Function signatures (verified by reversing the selectors; `secret` and `referrer` are
`bytes32`, not `uint256`):**

```
isAvailable(string)                                                       0x965306aa
getRegisterPrice(string,uint64,address)                                   0x61907b12
makeCommitment(string,address,bytes32,address,address,uint64,bytes32)     0x1e966f07
commit(bytes32)                                                           0xf14fcbc8
register(string,address,bytes32,address,address,uint64,address,bytes32)   0xcff3e7c2
renew(string,uint64,address,bytes32)                                      0x89d779c3
```

MIN_COMMITMENT_AGE = 60 s · MAX_COMMITMENT_AGE = 2,419,200 s (28 days) · MIN_DURATION = 86,400 s

---
---

# Pre-event research, 2026-09-03 (all read-only; the only two writes are a 7702
# authorisation and its revocation)

## 1. EIP-7702 is fully usable on Sepolia ✅

foundry 1.7.1 supports `cast send --auth <address>` and `cast wallet sign-auth`.

**Measured (an agent EOA delegating to MockUSDC, then revoking):**

```bash
# delegate
cast send $ADMIN_ADDR --auth $MOCK_USDC --private-key $AGENT_PK --value 0
#   tx 0xfc91071b…08fa · status 1 · type 0x4 · gas 36,800
cast code $AGENT_ADDR
#   0xef0100768f42455a2d082e23ceef7d51e5787c82d67a39
#   = 0xef0100 + the delegate address, exactly EIP-7702's delegation designator

# revoke
cast send $ADMIN_ADDR --auth 0x0000000000000000000000000000000000000000 --private-key $AGENT_PK --value 0
#   tx 0x8c083e58…1b296 · gas 36,800
cast code $AGENT_ADDR   # → 0x
```

**⚠️ Trap one: the transaction's `to` must not be the delegated EOA itself.**
Once delegation is in effect, empty calldata hits the delegate's fallback. That is exactly
how the first attempt reverted
(`Failed to estimate gas: execution reverted, data: "0x"`)。
Point `to` at any ordinary address instead — the authorisation rides on the transaction and
has nothing to do with `to`.

**⚠️ Trap two (important for the architecture): delegated code executes against the EOA's
own storage.**

After delegating to MockUSDC, calling the EOA's address:

```
decimals()  → 0     (not 6)
symbol()    → ""    (not "USDC")
```

The functions **do execute** (nothing reverts), but what they read is the EOA's empty
storage, not MockUSDC's.

→ **Our delegate cannot rely on storage of its own.**
The policy address comes out of ENS and the policy contract is stateless — the current
design fits exactly. If state is ever wanted inside the delegate, the EOA's storage layout
has to be planned deliberately.

> **Refined during implementation.** The precise statement is that delegated code executes
> in the *EOA's* storage, which is empty at first — not that it cannot use storage. Deliberate
> planning is exactly what `LeashStorage`'s ERC-7201 namespace does, and `LeashAccount` keeps
> per-wallet state there.

**Cost: roughly 36,800 gas each for delegating and revoking.**

---

## 2. The complete `PermissionedRegistry` ABI (the reference implementation for
##    `LeashRegistry`)

**RootRegistry and ETHRegistry have identical selector sets** — the same implementation.
What follows was recovered by extracting selectors from the bytecode and resolving them
against the openchain signature database, **not copied from documentation**.

### Name operations

| Function | Selector |
|---|---|
| `register(string,address,address,address,uint256,uint64)` | `0x85f3e643` |
| `unregister(uint256)` | `0xa02b161e` |
| `renew(uint256,uint64)` | `0x5569f33d` |
| `setSubregistry(uint256,address)` | `0x341ec559` |
| `setResolver(uint256,address)` | `0xbc7b6d62` |
| `setParent(address,string)` | `0x5357263f` |
| `setURI(string,address)` | `0x48688f95` |

`register`'s fifth parameter, a `uint256`, is the **roleBitmap**; the sixth is the expiry.
This is the entry point through which `LeashRegistry` issues subnames like
`alpha.leash.eth`.

### Queries

| Function | Selector | Detail |
|---|---|---|
| `getSubregistry(string)` | `0x35af6216` | |
| `getResolver(string)` | `0xe4ae7d77` | |
| `getParent()` | `0x80f76021` | returns (registry, label) |
| **`findTokenId(string)`** | **`0x91b3c037`** | **see below** |
| `findOwner(string)` | `0x63560a8e` | |
| `findExpiry(string)` | `0x6f537c72` | |
| `getTokenId(uint256)` | `0x14ff5ea3` | |
| `getOwner(uint256)` | `0xc41a360a` | |
| `latestOwnerOf(uint256)` | `0xbd242bcb` | |
| `getExpiry(uint256)` | `0x13c72608` | |
| `getState(uint256)` | `0x44c9af28` | |
| `getStatus(uint256)` | `0x5c622a0e` | |
| `getResource(uint256)` | `0x1e8fca2d` | |
| `ROOT_RESOURCE()` | `0x1c3fc3eb` | = 0 |
| `LABEL_STORE()` | `0x9dbba19d` | |
| `isContractNamer(address)` | `0x6f3ff726` | |
| `uri(uint256)` | `0x0e89341c` | |

### Enhanced Access Control(EAC)

| Function | Selector |
|---|---|
| `roles(uint256,address)` | `0x5adf4724` |
| `roleCount(uint256)` | `0x2f27fa24` |
| `hasRoles(uint256,uint256,address)` | `0xd3bf89b1` |
| `grantRoles(uint256,uint256,address)` | `0x7c300586` |
| `revokeRoles(uint256,uint256,address)` | `0xdfa70d8b` |
| `hasRootRoles(uint256,address)` | `0x781ef8db` |
| `grantRootRoles(uint256,address)` | `0x072d5d77` |
| `revokeRootRoles(uint256,address)` | `0xce156e82` |
| `hasAssignees(uint256,uint256)` | `0x11b8e00a` |
| `getAssigneeCount(uint256,uint256)` | `0x3634f911` |

Plus the standard ERC-1155 surface (`balanceOf`, `balanceOfBatch`, `setApprovalForAll`,
`isApprovedForAll`、`safeTransferFrom`、`safeBatchTransferFrom`、`ownerOf`)。

---

## 3. `findTokenId(string)` makes "parse the logs for a tokenId" obsolete

```bash
cast call $ETH_REGISTRY 'findTokenId(string)(uint256)' "leash"
#  → 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000
#  exactly matches what the TransferSingle log decodes to
```

**One view call gets it; no receipt parsing needed.** The log-parsing approach earlier in
this document stays as a fallback (when the value is needed within the same transaction, for
instance), but routine queries use `findTokenId`.

`findOwner(string)` and `findExpiry(string)` work the same way, saving the two-step "compute
the tokenId, then query".

---

## 4. `leash.eth`'s role configuration (decoded from measurement)

```
resource   = getResource(tokenId) = the tokenId itself
roles      = 0x1110000000000000000000000000000001100000
bits       = [20, 24, 148, 152, 156]
```

EAC's rule is that **bit N is the role itself and bit N+128 is that role's admin**:

| bit | Meaning |
|---|---|
| 20 | a base role (can `setSubregistry`) |
| 24 | a base role (can `setResolver`) |
| 148 | admin of bit 20 |
| 152 | admin of bit 24 |
| 156 | **admin of bit 28 — while not holding bit 28 itself** |

In other words: **the owner does not have role 28, but can grant role 28 to anyone,
themselves included.**

### Permission simulation (`cast call --from human`, changing no state)

| Action | Result |
|---|---|
| `setResolver(tid, …)` | ✅ |
| `setSubregistry(tid, …)` | ✅ |
| `safeTransferFrom(human→agent)` | ✅ transferable |
| `grantRoles(res, 1<<28, human)` | ✅ can self-grant |
| `renew(tid, …)` | ❌ **REVERT** |
| `unregister(tid)` | ❌ **REVERT** |

**Renewal goes through `ETHRegistrar.renew(string,uint64,address,bytes32)` (`0x89d779c3`)
and requires payment**; it cannot be called on the registry directly. It will not come up
during the demo (the expiry is 1819875720 = 2027-09-02), but do not point the code at the
wrong contract.

---

## 5. There are two kinds of resolver; do not conflate them

The earlier note that "ENSv2 resolvers accept ENSIP-10 only" needs refining — both kinds
exist:

### (a) The minimal kind — ENSIP-10 only

`nick.eth`'s resolver, `0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba`:

```
resolve(bytes,bytes)                  0x9061b923   ✅ present
addr(bytes32)                         0x3b3b57de   ❌ absent; calling it reverts
text(bytes32,string)                  0x59d1d43c   ❌ absent

supportsInterface(0x9061b923) → true
supportsInterface(0x3b3b57de) → false
supportsInterface(0x59d1d43c) → false
```

### (b) `PermissionedResolverImpl` `0x9eae5c27…365e` — it has both

```
resolve(bytes,bytes)                  0x9061b923   ✅
addr(bytes32)                         0x3b3b57de   ✅
addr(bytes32,uint256)                 0xf1cb7e06   ✅
text(bytes32,string)                  0x59d1d43c   ✅
contenthash(bytes32)                  0xbc1c58d1   ✅
setAddr / setText / setContenthash                 ✅
multicall(bytes[])                    0xac9650d8   ✅
```

It is also **UUPS-upgradeable** (`upgradeToAndCall` `0x4f1ef286`, `proxiableUUID`
`0x52d1902d`, `UPGRADE_INTERFACE_VERSION` `0xad3cb1cc`) and carries the same set of EAC role
functions.

### Our conclusion (unchanged)

**`LeashResolver` implementing `resolve(bytes,bytes)` alone is sufficient.**

Why: UniversalResolverV2 goes through ENSIP-10, and a resolver like `nick.eth`'s that
implements ENSIP-10 only resolves correctly on chain — confirmed by measurement on 9/1. The
legacy interfaces are optional, not required.

---

## Measuring the separation of authority (2026-09-03)

Three keys, simulated with `cast call --from` (changing no state):

| Action | ADMIN | WALLET | AGENT |
|---|---|---|---|
| `setResolver(leashTokenId, …)` | ✅ | ❌ REVERT | ❌ REVERT |
| `setSubregistry(leashTokenId, …)` | ✅ | ❌ REVERT | — |
| `grantRoles(res, …)` | ✅ | ❌ REVERT | — |

```
roles(resource, ADMIN)  = 0x1110000000000000000000000000000001100000
roles(resource, WALLET) = 0
roles(resource, AGENT)  = 0
```

**This demonstrates the architecture's core security property:** WALLET — 7702-delegated and
holding the funds — **has no ENS authority whatsoever**. Even with a broken policy that
permits an arbitrary target, an agent calling `ETHRegistry.setResolver` through the account
reverts — not because we check, but because that key never had the role.

**A broken policy's blast radius is bounded by the money and never spreads to control.**
