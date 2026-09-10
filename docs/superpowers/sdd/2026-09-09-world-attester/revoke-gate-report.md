# Revoke-bypass gate — report

**Status:** Done.

**Commit:** `5f498b4` — "fix: close revoke-bypass hole in LeashAccount.unbindAgent"
(4 files changed: `src/LeashAccount.sol`, `test/LeashAccountBinding.t.sol`, `README.md`,
`docs/superpowers/plans/2026-09-09-world-attester.md`).

## Fix

`unbindAgent` now refuses to unbind a binding while `revoked == true`, reverting with a
new `RevokedNeedsRestore()` error. No storage layout change — reuses the existing
`revoked` flag `revokeAgent` already sets. `bindAgent`'s comment was updated to explain
that its `AlreadyBound` guard alone was insufficient and now depends on this second
guard in `unbindAgent`.

## New test count

Baseline: 197 passed / 1 skipped / 0 failed (198 total).
After: **200 passed / 1 skipped / 0 failed (201 total)** — 3 new tests, all passing:

- `test_unbind_reverts_on_a_revoked_binding`
- `test_revoke_unbind_bind_no_longer_restores_authority_for_free`
- `test_restore_with_valid_attestation_still_works_after_the_fix`

`forge fmt --check` is clean.

## Mutation test

Removed the `if ($.bindings[agent].revoked) revert RevokedNeedsRestore();` line from
`unbindAgent`, reran the two bypass-specific tests:

```
Ran 2 tests for test/LeashAccountBinding.t.sol:LeashAccountBindingTest
[FAIL: next call did not revert as expected] test_revoke_unbind_bind_no_longer_restores_authority_for_free() (gas: 111329)
[FAIL: next call did not revert as expected] test_unbind_reverts_on_a_revoked_binding() (gas: 111354)
Suite result: FAILED. 0 passed; 2 failed; 0 skipped; finished in 2.86ms
```

Both went RED as expected. Restored the guard; full suite back to 200 passed / 0 failed /
1 skipped, `forge fmt --check` clean.

## Existing test that already covered the untouched remedy

`test_a_mis_binding_is_correctable_for_free` (`test/LeashAccountBinding.t.sol:325`, no
line-number shift before it) already binds → unbinds → rebinds with no revocation in
between. No duplicate test was added for that case; a one-line note was added next to
the new tests pointing at it instead.

## Documentation

- `README.md:86` — the "Restore a revoked agent | ✅ | ✅" row was already literally true
  (it's about `restoreAgent`, which was always correctly gated); the bypass ran through
  `unbindAgent`, not that row. What needed fixing was the surrounding claim
  ("Expansion is two-of-two...") and the "Revoke or unbind an agent" row, which read as
  if unbind were unconditionally free. Added a paragraph after the widening/reduction
  table's "Expansion is two-of-two" prose explaining the one exception: `unbindAgent`
  refuses a revoked binding, why, and that it costs nothing in capability.
- `docs/architecture.md` and `docs/deployments.md` — checked; neither mentions
  `LeashAccount.unbindAgent` at all. Their revoke/restore language (lines ~128-129 in
  architecture.md) is about `revokeAgent`/`restoreAgent`, which were already correct and
  are unaffected by this fix. No changes made to either file.
- `docs/superpowers/plans/2026-09-09-world-attester.md` — added a
  "Post-Execution: revoke-bypass fix" section at the end recording the hole, the fix,
  and the new tests, since this plan is the record of the branch.

## Concerns

None outstanding. Scope was kept to `src/LeashAccount.sol` and
`test/LeashAccountBinding.t.sol` plus the two documentation files named in the task;
`world/` and `script/` were not touched (confirmed via `git status` — the other agent's
`world/` commits landed separately on this branch and were left alone). No secrets were
read or echoed.

---

## Addendum: two follow-ups from the team lead (commit `4283570`)

**1. `restoreDigest` missing `restoreAgent`'s node/label check.** `restoreDigest` did not
verify `node == nodeFor(label)`, unlike `restoreAgent` (which reverts `NodeLabelMismatch`
before ever reaching `_consumeAttestation`). Fixed by mirroring the check in
`restoreDigest`. Checked `ruleDigest`/`payeeDigest` against their consumers (`setRule`,
`allowPayee`) for the analogous gap: **neither consumer performs any pre-attestation
validation beyond what its digest already encodes**, so there is no equivalent fix needed
there — ruling this closed rather than passing it back.

New test: `test_restoreDigest_rejects_a_node_label_mismatch` in
`test/LeashAccountDigests.t.sol` (the existing home for `restoreDigest`/`ruleDigest`
tests). Full suite: **201 passed / 1 skipped / 0 failed (202 total)**, up from 200/1/0.
`forge fmt --check` clean.

**2. README wording nuance.** Reworded the paragraph added for the revoke-bypass fix so
it doesn't overclaim: the guard makes re-activating *that same revoked agent address*
require an attestation, not "no agent on this node without a face scan." Added a
follow-up paragraph stating plainly that the wallet key alone can still bind a **fresh**
agent address to the same node for free — by design, since `bindAgent` grants authority
from zero and its content comes from the ENS side and approval list, not from the new
address itself.

Commit: `4283570` — "fix: restoreDigest must mirror restoreAgent's node/label check;
sharpen README claim" (`src/LeashAccount.sol`, `test/LeashAccountDigests.t.sol`,
`README.md`, `docs/superpowers/plans/2026-09-09-world-attester.md`). Same scope
constraints held: `world/` and `script/` untouched, no secrets read or echoed, not
pushed.
