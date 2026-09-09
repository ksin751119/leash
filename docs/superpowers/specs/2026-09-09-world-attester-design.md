# WorldAttester design — turning the human-in-the-loop claim into onchain enforcement

**Date:** 2026-09-09
**Sprint items:** 8 (second half) and 11
**Status:** approved, awaiting implementation

---

## What this solves

`IAttester` has existed since day one and `MockAttester` — which returns `true` for **any**
input — is what is deployed. So of the two conditions behind "widening requires a real
human", only `msg.sender == address(this)` is actually guarding. The README, the
architecture summary and `deployments.md` all say so plainly, because saying otherwise
would be false.

This replaces the mock on the path the demo exercises, so that "a live human authorised
this" becomes something a contract checks rather than something a document promises.

**What becomes real:** `LeashAccount`'s widenings — `allowPayee`, `setRule`,
`restoreAgent`. That is act three of the demo: the agent is blocked, a human scans their
face on camera, the widening lands, the retry succeeds.

**What stays mocked, and why:** `PolicyApprovals.approve` (approve a new policy) and
`LeashRegistry.register` / `renew` (issue or extend an agent subname). Both take their
attester as an `immutable` constructor argument, so switching them means redeploying
`PolicyApprovals`, `LeashResolver` (its `approvals` pointer is immutable too) and
`LeashRegistry`, re-wiring ENS, and creating two more World actions in the Portal —
`max_verifications` is 1 per action and cannot be raised, so every widening that needs a
real scan needs its own action. The mechanism they would use is **byte-for-byte the same
`WorldAttester`** demonstrated on the path above. Coverage, not proof of mechanism.

---

## Decision record

Five decisions, settled in brainstorming before any code, so they are not later taken for
arbitrary choices.

| # | Decision | Rejected | Why |
|---|---|---|---|
| 1 | **Only `LeashAccount` switches to `WorldAttester`** | switching all three consumers | The two control-plane widenings happen at *deployment* time, before the video starts — a judge watching four minutes never sees them. Switching them costs 3 redeployments, an ENS re-wire, 2 more Portal actions, and it desynchronises `deployments.md`'s address table from its own end-to-end run, which would then have to be re-run in full. The mechanism is identical either way |
| 2 | **`attestation` = 73 packed bytes, not `abi.encode`** | `abi.encode(uint64, bytes)` | `abi.encode` of a dynamic member produces a header (offset, length) that has to be validated before it can be trusted — exactly the hop-three trap in `resolvePolicy`, where a right-length blob with a forged header makes `abi.decode` revert. A fixed 73-byte layout needs one length check and no header |
| 3 | **The signature covers an EIP-712 struct, not the raw digest** | `recover(digest, sig)` | The RP signer key **also signs `rp_context` for World**. Raw-signing an arbitrary 32-byte hash with a key that signs other things is the pattern to avoid. The EIP-712 domain also binds `verifyingContract = address(this)`, which closes replay onto a *later* `WorldAttester` — and since rotating the signer means redeploying, that is a path that will actually exist. Same reasoning as `SELF` in `LeashAccount` |
| 4 | **A deadline inside the signed struct** | signature only | Without one, a signature for an unconsumed digest is valid forever — a bearer cheque with no expiry date. It fails silently and permissively, which is the class of defect this project keeps finding. Widening means "a human is standing here now consenting"; there is no reason that consent is still good in six months |
| 5 | **`SIGNER` is `immutable`, with no setter** | an owner-settable signer | Identical to the C1 fix. A mutable signer pointer hands both locks to one key. Rotation means deploying a new `WorldAttester`, which is a visible onchain transaction |

**No signer rotation before the demo** (confirmed). `SIGNER` is
`0x85b89D21DB13f220601430d48244B2AE06120969` — verified to be the address
`WORLD_RP_SIGNER_PK` derives to, and the signer address the Developer Portal displays for
`rp_ef35d4e2d4f1a031`.

---

## The attestation format

**73 bytes, packed, no header:**

```
bytes  0..8    uint64 deadline   (big-endian)
bytes  8..40   bytes32 r
bytes 40..72   bytes32 s
bytes 72..73   uint8   v         (27 or 28)
```

The contract reads it with `calldata` slicing after a single `length != 73` check. No
`abi.decode` touches attacker-supplied bytes anywhere in this contract.

**What the signature covers:**

```
DOMAIN_TYPEHASH = keccak256(
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
ATTESTATION_TYPEHASH = keccak256("LeashAttestation(bytes32 digest,uint64 deadline)")

domainSeparator = keccak256(abi.encode(
    DOMAIN_TYPEHASH, keccak256("Leash"), keccak256("1"),
    block.chainid, address(this)))

structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, digest, deadline))

attestationHash = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash))

// This value has exactly one name throughout: `attestationHash`. It is what the backend
// signs and what `WorldAttester.attestationHash(digest, deadline)` returns, and the
// cross-check compares those two.
```

`name = "Leash"` and `version = "1"` match `PolicyApprovals`, `LeashRegistry` and
`LeashAccount`, so all four contracts share one EIP-712 identity.

> ⚠️ **`deadline` is a `uint64` in the type but a full 32-byte word inside
> `abi.encode`.** The JS side must left-pad it. Getting this wrong produces a signature
> that simply fails to verify, with nothing anywhere saying why — see the cross-check
> below, which exists for precisely this.

`deadline` appears twice on purpose: packed in the blob so the contract can read it, and
inside the signed struct so it cannot be tampered with. A test signs one deadline and
ships a different one in the blob, and expects `false`.

`domainSeparator()` is recomputed on every call rather than cached, matching the other
three contracts — `block.chainid` changes after a chain split and a cached value would
then be wrong.

---

## `src/WorldAttester.sol`

```solidity
contract WorldAttester is IAttester {
    address public immutable SIGNER;

    error ZeroSigner();

    constructor(address signer_) {
        if (signer_ == address(0)) revert ZeroSigner();
        SIGNER = signer_;
    }

    function verify(bytes32 digest, bytes calldata attestation)
        external view returns (bool)
    {
        if (attestation.length != 73) return false;
        uint64 deadline = uint64(bytes8(attestation[0:8]));
        if (block.timestamp > deadline) return false;
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(
            attestationHash(digest, deadline),
            uint8(attestation[72]),                 // v
            bytes32(attestation[8:40]),             // r
            bytes32(attestation[40:72])             // s
        );
        if (err != ECDSA.RecoverError.NoError) return false;
        return rec == SIGNER;
    }

    function attestationHash(bytes32 digest, uint64 deadline)
        public view returns (bytes32) { ... }

    function domainSeparator() public view returns (bytes32) { ... }

    function describe() external pure returns (string memory) { ... }
}
```

**`verify` must never revert, and that is load-bearing.** `IAttester`'s own comment says
an implementation must not revert to signal failure, because the caller has to tell "did
not pass" apart from "this attester is broken". `attestation` is attacker-controlled, and
OpenZeppelin's `ECDSA.recover` reverts on a bad length, a malleable `s`, or a zero
recovery — so `tryRecover`, which returns an error enum instead, is mandatory rather than
stylistic. A fuzz test over arbitrary `bytes` asserts no input reverts.

Malleable signatures are rejected by `tryRecover` for free. It makes no practical
difference here — the consumer marks `attestationUsed[digest]`, so a malleated signature
over an already-spent digest is worthless — but rejecting it is correct and costs nothing.

`describe()` must be honest about where the liveness guarantee lives:

```
"WorldAttester/1: ECDSA over EIP-712 by the World RP signer (rp_ef35d4e2d4f1a031).
 Onchain this proves the RP signer authorised this exact digest before its deadline;
 that a live human was present is enforced offchain by Selfie Check."
```

---

## `src/LeashAccount.sol` — two missing digest getters

There are **six widening TYPEHASHes and only four public digest getters**:

| TYPEHASH | Getter |
|---|---|
| `PolicyApprovals.APPROVAL_TYPEHASH` | `approvalDigest` ✓ |
| `LeashRegistry.REGISTER_TYPEHASH` | `registerDigest` ✓ |
| `LeashRegistry.RENEW_TYPEHASH` | `renewDigest` ✓ |
| `LeashAccount.PAYEE_TYPEHASH` | `payeeDigest` ✓ |
| `LeashAccount.RULE_TYPEHASH` | **missing** |
| `LeashAccount.RESTORE_TYPEHASH` | **missing** |

So nothing outside the contract can compute the digest for `setRule` or `restoreAgent`,
and with a real signer there is therefore nothing to hand the backend to sign. `setRule`
is "raise a limit" — one of the two widenings act three can show.

`MockAttester` hid this completely: it accepts any bytes, so no caller ever needed the
correct digest. **The defect only becomes reachable when the attester becomes real.**

Add `ruleDigest(...)` and `restoreDigest(...)` as public views mirroring `payeeDigest`.
Pure additions, no storage change, so the ERC-7201 layout is untouched.

---

## `world/server.mjs` — `POST /api/attest`

```
request   { digest: "0x…32 bytes", proof: <the IDKit result> }
response  { attestation: "0x…73 bytes", deadline, nullifier }
```

1. **`signal = digest`.** One face scan authorises exactly one digest — an intercepted
   proof cannot be moved to a different widening. This was already the documented
   intention in `IAttester`; it now becomes real.
2. Verify the proof through the existing v4 path (`protocol_version: "3.0"`,
   `nullifier_hash` → `responses[].nullifier`, no `credential_type`).
3. On success: `deadline = now + 900` (15 minutes).
4. Sign `attestationHash` with `WORLD_RP_SIGNER_PK`.
5. Return the 73-byte blob.

> ⚠️ **`@noble/curves` returns `recovery` as 0 or 1; the blob's `v` must be 27 or 28.**
> Forget the `+ 27` and `tryRecover` returns `RecoverError.InvalidSignature`, `verify`
> returns `false`, and the only symptom is "the signature does not verify" — the same
> silent failure the cross-check exists to catch. A unit test covers `v = 0` explicitly
> for this reason.

`deadline` is server wall-clock Unix seconds, compared onchain against `block.timestamp`.
On Sepolia those track each other closely enough for a 15-minute window; a clock skew of
minutes would only shorten or lengthen the window, never let an expired signature pass.

If verification fails, return the upstream error unchanged and sign nothing.

**Dependency: `@noble/curves` for secp256k1**, not viem or ethers. The ABI encoding needed
here is fixed-width types only, which is a few lines by hand and keeps the encoding under
direct control; `@noble/hashes` (already installed, same authors) provides keccak256.

`WORLD_RP_SIGNER_PK` never leaves the backend. The frontend receives only the blob.

---

## The cross-check, which is the most important test here

A mismatch of one byte between the JS-computed `attestationHash` and the contract's produces
exactly one symptom: **the signature does not verify.** Nothing says whether the encoding
was wrong, the key was wrong, the deadline had passed, or `v` was off by 27. That is a
half-day bug.

So `WorldAttester` exposes `attestationHash(digest, deadline)` as a public view, and a
script asserts the JS value equals the chain's for several `(digest, deadline)` pairs,
including `digest = 0x0` and `deadline = 0` and `deadline = type(uint64).max`.

This is the single link between the two halves of the feature, and it is the only place
where an error in either half is visible as an error rather than as silence.

---

## Deployment sequence

Nothing in the control plane moves. ENS is untouched, the subgraph is untouched.

1. Deploy `WorldAttester(0x85b89D21DB13f220601430d48244B2AE06120969)`
2. Deploy `LeashAccount(ETH_REGISTRY, <existing PolicyApprovals>, worldAttester)` —
   the existing `0x7CB9d4Ac…25B4` approvals list is reused deliberately
3. Run the cross-check script against the deployed attester
4. Re-delegate WALLET to the new impl with `cast send $WALLET --auth $impl` — signed by
   WALLET itself, never from a script
5. Update `docs/deployments.md`

**One consequence of the subgraph being untouched: `LeashedWallet.impl` goes stale.**
It records the impl carried by the `Leashed` event, and `Leashed` fires only on the first
`bindAgent` — the account has a `leashedEmitted` flag precisely so it is a wallet-level
fact emitted once. Re-delegating does not re-emit it (and could not: delegation emits no
log at all), so the subgraph will keep reporting the old impl
`0x136b33c6…d9b83c`.

That is not a defect to fix, it is the reason `LeashLens` exists. `delegateOf(wallet)` is
the authoritative source for the *current* delegate, because that question is only
answerable by reading code, never by reading events. The subgraph's field should be
documented as "the impl at the time the leash was first recorded", and the frontend must
call `delegateOf` rather than trust it.

**The wallet's existing state survives, and that is worth stating explicitly.** The
ERC-7201 slot derives from `keccak256("leash.account.v1")`, the layout is unchanged, and
the EOA is the same — so `bindings`, `rules`, `payees` and `spent` are all still there
after re-delegation. No per-wallet setup is repeated. `bindAgent` would revert
`AlreadyBound`, which is correct.

Old attestations cannot be replayed against the new impl, because every
`LeashAccount` digest includes `SELF` — the impl's own deploy address — and that changed.
This is the first time that field has been load-bearing rather than precautionary.

---

## What this does not claim

**Onchain, this proves the RP signer authorised this exact digest before its deadline.**
It does not prove a human was present. That link is: World App performs Selfie Check → the
v4 endpoint verifies the proof → our backend signs only after that verification. Every
step after the first is ours, and the first is World's.

**`verify` is `view`, so nullifiers cannot be recorded onchain.** "One person may only do
this once" is therefore not a chain property. Nor is it a property of our backend: nothing
in `server.mjs` records a nullifier — it forwards one to World and echoes one back, and that
is all. The mechanism is **World's own `max_verifications: 1`**, enforced on their side, 1
per action, and impossible to raise. That is worth stating precisely rather than calling it
a backend property, because it is a *stronger* guarantee than an unwritten one of ours, and
because it is the reason a fresh action is needed before every demo. Replay of an
*attestation* is prevented onchain, by the consumer's `attestationUsed[digest]` plus this
contract's deadline.

**A World ID proof cannot prove it came from Selfie Check.** A successful verification
returns `credential_type: "device"`, identical to the deprecated `deviceLegacy`. "A real
human's face was checked" lives in the app's `enable_face_check` setting, not in the
proof. Leash's human-in-the-loop guarantee is configuration-level, not cryptographic, and
`world/README.md` says so.

**Rotating the signer kills this deployment.** There is no setter; a new `WorldAttester`
and a new `LeashAccount` must be deployed. That is the deliberate consequence of decision 5.

---

## Test plan

Every row is mutation-checkable: delete the guard named in the right column and the test
must fail.

| Test | Guard it pins |
|---|---|
| A valid signature inside its deadline → `true` | the happy path is reachable at all |
| `deadline = block.timestamp - 1` → `false` | the deadline comparison |
| Signed by a different key → `false` | `rec == SIGNER` |
| **Signed over deadline X, blob carries deadline Y → `false`** | that `deadline` is *inside* the signed struct, not merely beside it |
| Signed over a different digest → `false` | `digest` is inside the struct |
| `attestation.length != 73` (72, 74, 0) → `false` | the length check |
| Malleable `s` (upper half) → `false` | `tryRecover`'s S check |
| `v = 0` → `false` | `tryRecover`'s error path |
| The same signature against a second `WorldAttester` → `false` | `verifyingContract` in the domain |
| `testFuzz_verify_never_reverts(bytes)` | `IAttester`'s never-revert contract |
| `attestationHash` equals a hand-computed constant | the encoding, and the JS cross-check's anchor |
| `describe()` contains "offchain" | that the string discloses where liveness is actually enforced, rather than leaving a reader to assume the chain checks it |

Integration, against `LeashAccount` with `ATTESTER = WorldAttester`:

| Test | What it shows |
|---|---|
| `allowPayee` with a real signature succeeds | the whole chain works end to end |
| `allowPayee` with an expired signature reverts `NotAttested` | the deadline reaches the consumer |
| The same attestation twice → `AttestationReused` | the consumer's replay protection still holds |
| `tightenRule` / `removePayee` / `revokeAgent` / `pause` still need no attestation | **the asymmetry survived making the attester real** |

That last row matters most. The whole design rests on reductions being free; a real
attester must not have quietly made any of them cost something.

---

## Explicitly not doing

| Not doing | Why |
|---|---|
| Recording nullifiers onchain | `verify` is `view`. It cannot. |
| An `AttestationAccepted` event from `WorldAttester` | Same reason. The consumers already emit `attestationHash` on their own widening events |
| Switching `PolicyApprovals` / `LeashRegistry` | Decision 1 |
| A settable signer | Decision 5 |
| Verifying the World ID zero-knowledge proof onchain | It would need the World ID router and Semaphore verifier on Sepolia, and Selfie Check is World ID 3.0 while the app is a 4.0 RP. The signed-attestation design is what the interface was built for |
