# Step 7 — post-deployment docs report

**Status:** done.
**Commit:** `380a79aed82f11f1c0d9bc1a54f3aec199adcaef` (branch `world-attester`)
**Tests:** `forge test` → 201 passed / 1 skipped / 0 failed, unchanged (docs-only change; only `README.md` and `docs/deployments.md` touched).

## Claims changed false → true

- **README.md, "Attestation column" callout (was ~118-125):** was "the deployed system is
  wired to MockAttester ... nothing about World ID is enforced onchain yet." Now states
  `WorldAttester` is deployed and `LeashAccount`'s current impl requires a valid EIP-712
  signature from the World RP signer for `setRule`/`allowToken`/`allowPayee`/`restoreAgent`,
  with the `NotAttested()` static-call proof.
- **README.md, World section:** was "The onchain `IAttester` is still the mock." Now says
  the onchain `IAttester` behind `LeashAccount`'s widening paths is `WorldAttester`, while
  noting the digest path from a live proof to an onchain `verify()` call has not itself been
  run end to end.
- **README.md, "Live on Sepolia" table:** `LeashAccount` row pointed at the superseded impl
  address `0x136b33c6…B83C`; now points at the current impl `0x55528C70…7f23`, with a line
  noting the redeployment and pointing to `docs/deployments.md` for history. Added a
  `WorldAttester` row.
- **docs/deployments.md, line-64 warning:** was "switching to a real WorldAttester requires
  a redeployment" (future tense, implying nothing had happened). Now states that
  redeployment happened for `LeashAccount` only, and that `PolicyApprovals`/`LeashRegistry`
  are unaffected by design.
- **docs/deployments.md, "Currently wired to MockAttester" section (~line 329, now ~347):**
  retitled and reframed as history ("that run's steps 3–4 used MockAttester — since fixed
  for LeashAccount"), with a forward pointer to the new section below.
- **docs/deployments.md:** added a new "LeashAccount v2: `WorldAttester` is live" section at
  the end with the `WorldAttester` and new impl addresses/txs, the re-delegation tx (type 4,
  block 11667630, gas 36,844), the unchanged-storage and unchanged-`APPROVALS`/`ETH_REGISTRY`
  readback, and the three static-call results proving `NotAttested()` now fires.
- **docs/deployments.md, EIP-7702 execution layer table:** the original `LeashAccount` impl
  row is now marked "(superseded — see LeashAccount v2 below)" rather than presented as
  current; kept, not deleted, per instructions — its deploy tx and everything measured
  against it remain in the document as history.

## Claims kept true → true (deliberately not weakened)

- `MockAttester` row and warning in both files: kept, with the scope narrowed to name
  exactly which two contracts (`PolicyApprovals.approve`, `LeashRegistry.register`) still use
  it and why (deliberate scoping, not an oversight).
- The digest-path-never-exercised-live caveat: stated in both files, tied to
  `expand-policy-demo1` / `action_1f91e0b88227d9c86c276c28d30c3324` having one reserved,
  unspent verification.
- The credential_type/verification_level `"device"` caveat and the "proves the RP signer
  signed this digest, not that a human was present" framing: both restated at the strength
  `docs/world-feedback.md` and `WorldAttester.describe()` already use, not strengthened.
- README.md lines 95-111 (the `unbindAgent`/revoke-bypass paragraph): left untouched, as
  instructed — it already states the "one address, not the whole node" scope correctly.
- The "Expansion needs a human; reduction never does" table: checked every row against
  current contract behavior; none is wrong (attestation is still required at the code level
  for the same set of actions — which contract actually enforces it is a separate fact,
  covered by the callout beneath the table). Left unchanged.

## Found already false, not named in the brief, not touched

- **README.md "Tests" section** still says "170 unit and fuzz tests ... `170 passed, 0
  failed, 1 skipped (171 total)`." The actual current suite is 201 passed / 1 skipped / 0
  failed (verified by running `forge test`, output above). This drift predates today's
  WorldAttester work — it's from tests added since that line was last updated — and is
  unrelated to the MockAttester/WorldAttester claims this task was scoped to, so I left it
  alone rather than widening scope. Flagging it since it's a real inaccuracy a reader would
  hit right after the (now-corrected) attestation claims.

No other stale claims found in either file relevant to today's deployment.
