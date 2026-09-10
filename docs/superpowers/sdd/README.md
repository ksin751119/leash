# Subagent-driven development ledgers

Working records from two features that were built with a spec-driven, subagent-driven
workflow. They are published because ETHOnline's AI rules ask for them: *"Spec-driven
workflows require submission of all spec files and prompts."*

These are not documentation. They are the raw ledger written while the work happened —
including the mistakes, the rulings that turned out wrong, and the reviews that caught
them. Nothing has been cleaned up after the fact.

| Directory | Feature | Spec | Plan |
|---|---|---|---|
| [`2026-09-09-world-attester/`](2026-09-09-world-attester) | `WorldAttester` + EIP-712 attestation issuance | [spec](../specs/2026-09-09-world-attester-design.md) | [plan](../plans/2026-09-09-world-attester.md) |
| [`2026-09-09-agent-loop/`](2026-09-09-agent-loop) | The agent decision loop | [spec](../specs/2026-09-09-agent-loop-design.md) | [plan](../plans/2026-09-09-agent-loop.md) |

## What each file is

| File | Contents |
|---|---|
| `progress.md` | The controller's ledger: the pre-flight conflict scan, every task's completion record, and every `Ruling:` made while the plan was running |
| `task-N-report.md` | What the implementer subagent did, what it tested, and what it was unsure about |
| `final-review-report.md` | A whole-branch review by a fresh reviewer that saw only the diff |
| `final-rereview-report.md` | A scoped re-review after the fixes |

`LeashAccount` (the largest piece) has a
[spec](../specs/2026-09-08-leash-account-design.md) and a
[plan](../plans/2026-09-08-leash-account.md) but no ledger — it was built before this
workflow was adopted.

## What is worth reading

The reviews are the interesting part, because they are adversarial and several of them
landed:

- **`2026-09-09-world-attester/final-review-report.md`** — found that `hashSignal()` hashed
  a hex digest as UTF-8, so `POST /api/attest` could never have succeeded on the digest
  path. Every existing check missed it because the test pinned the server against itself.
- **`2026-09-09-agent-loop/final-review-report.md`** — found four separate paths that could
  pay the same intent twice.
- **`2026-09-09-agent-loop/progress.md`** — records a recurring defect class found five
  times: *a test that passes without exercising the property it names*.

## One known error, left in place

`2026-09-09-agent-loop/progress.md` repeatedly asserts that `SEPOLIA_RPC` carries an API key
and must never be echoed. **That is false for this project** — the endpoint is
`https://ethereum-sepolia-rpc.publicnode.com`, a public keyless URL. The redaction guards
built on that premise are harmless and would be correct against a paid RPC, so nothing was
undone; but the reasoning recorded in the ledger is wrong, and it is left visible rather
than quietly edited.

## Secret audit

Before publishing, every file here was checked against the six real private keys in the
project's `.env` (both `0x`-prefixed and bare): **zero matches**. The `64`-hex strings that
appear are EIP-712 digests, event topic hashes, `namehash` values, Sepolia transaction
hashes, and Anvil's published test key `0xac0974be…`. The strings `SECRET-KEY-abc123` and
`SUPERSECRETKEY123` are test fixtures for the redaction tests, not credentials.
