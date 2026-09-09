# Agent Decision Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A process that acts as the AI agent — it reads policy state from the subgraph, decides whether each payment it wants to make will be allowed, sends only the ones it believes will pass, and publishes its reasoning at `GET /api/agent/state` for the frontend to render.

**Architecture:** Four small modules, each testable alone: a reason table pinned to Solidity, a pure `decide()`, a subgraph reader that normalises what it fetches, and a sender that turns a receipt into an outcome. `loop.mjs` composes them and serves the state. Its own process, port 8788, holding only `AGENT_PK`.

**Tech Stack:** Node 24 ESM (`.mjs`), `node --test` for tests (no test framework dependency), `viem@2.56.3` for signing and sending, plain `fetch` for GraphQL.

**Spec:** `docs/superpowers/specs/2026-09-09-agent-loop-design.md`

## Global Constraints

- **Reason codes are frozen.** `src/Reason.sol` is the authority. `src/Reason.sol:8`: *"The numbers must never be renumbered: the subgraph, the frontend and the agent all depend on them."* `subgraph/src/reason.ts` is the second table; this plan adds the third.
- **The agent process reads exactly four environment variables:** `AGENT_PK`, `SEPOLIA_RPC`, `SUBGRAPH_URL`, `AGENT_TICK_MS`. It must **never** read `WORLD_RP_SIGNER_PK`, `WALLET_PK`, or `ADMIN_PK`, and must never be started by sourcing `.env` wholesale.
- **Never echo `SEPOLIA_RPC`** — it carries an API key. Never log `AGENT_PK`.
- **Never shell out to `cast send`.** `--private-key` has no env variant, so the key would appear in `argv` and be readable via `ps`. Signing stays in-process.
- **Subgraph entity ids are lowercase.** `.env` holds checksummed addresses. Every id built from an address must be lowercased or the query returns an empty array — which fail-closed then renders as "the agent does nothing", a symptom that looks nothing like its cause.
- **Amounts are base-unit decimal strings, never JS numbers.** MockUSDC has 6 decimals (verified onchain 2026-09-09), so `"100000000"` is 100 USDC.
- **Pre-flight never re-derives policy logic.** It reads conclusions the index already states. See the spec's section on why.
- **Intents are one-shot.** An executed intent is terminal. The tick is 5s; a re-sendable intent would drain the budget in under a minute.
- Deliverables (comments, docs, commit messages) in English.
- `forge test` must stay at **201 passed / 1 skipped / 0 failed** — this plan touches no Solidity.

## Live values, verified 2026-09-09

| What | Value |
|---|---|
| Subgraph | `https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4` |
| `AGENT_ADDR` | `0xf9248C78183E44b27AfAF6e0CdF5e3e2a3771De0` |
| `WALLET_ADDR` (the delegated EOA, the `to` of `spend`) | `0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6` |
| `MOCK_USDC` | `0x768f42455a2d082e23ceef7d51e5787c82d67a39` |
| node (`vendors.leash.eth`) | `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121` |
| Existing **allowed** payee | `0x000000000000000000000000000000000000beef` |
| Live budget | `limit` 1000000000, `spent` 300000000, `remaining` 700000000, `periodEnd` **1788998400 = 2026-09-10T00:00:00Z** |
| `spend(address,address,uint256)` selector | `0x791c27ef` |
| `SpendExecuted` topic0 | `0xf0b4af7bfd5a13b5eff4d2de508be60041b405cee18bf6f135c692be137d1381` |
| `SpendBlocked` topic0 | `0x8ab53b1df82e8bdff7dad3143040ff0efb1d94506ab3e47853c38b5925c50828` |

Entity id shapes, exactly as the live index stores them (all lowercase):

```
Agent          <wallet>-<agent>
AgentBudget    <wallet>-<node>-<token>
Payee          <wallet>-<node>-<payee>
PolicyPointer  <node>
Subname        <node>
```

---

## File structure

| File | Responsibility |
|---|---|
| `agent/reason.mjs` | The 13 reason codes and their names. Nothing else. |
| `agent/check-reason-table.mjs` | Reads `src/Reason.sol` and asserts `reason.mjs` matches it. Runnable, no network. |
| `agent/decide.mjs` | `decide(snapshot, intent, nowSec)` → `{ verdict, reason, reasonName, explain }`. Pure. |
| `agent/subgraph.mjs` | `fetchSnapshot(cfg)` → normalised snapshot, or `{ ok: false, error }`. Builds lowercase ids. |
| `agent/send.mjs` | `sendSpend(cfg, intent)` → `{ kind, tx, outcome, reason? }`. Owns viem. |
| `agent/loop.mjs` | The tick loop, the in-flight lock, one-shot bookkeeping, and the HTTP server. |
| `agent/intents.json` | The payment list. |
| `agent/package.json` | `viem@2.56.3`, `type: module`. |
| `agent/README.md` | How to run it, and the two things that surprise people. |
| `agent/*.test.mjs` | `node --test` suites beside each module. |

---

## Task 1: The reason table, pinned to Solidity

**Files:**
- Create: `agent/package.json`, `agent/reason.mjs`, `agent/check-reason-table.mjs`, `agent/reason.test.mjs`

**Interfaces:**
- Produces: `REASON` (object, name → number), `reasonName(code) -> string`, `REASON_NAMES` (array indexed by code).

- [ ] **Step 1: Create `agent/package.json`**

```json
{
  "name": "leash-agent",
  "private": true,
  "type": "module",
  "description": "The agent decision loop - reads the subgraph, decides, sends",
  "dependencies": {
    "viem": "2.56.3"
  }
}
```

Then `cd agent && npm install`.

- [ ] **Step 2: Write the failing test**

```js
// agent/reason.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { REASON, reasonName } from "./reason.mjs";

test("the codes match src/Reason.sol exactly", () => {
  assert.equal(REASON.OK, 0);
  assert.equal(REASON.AGENT_NOT_BOUND, 1);
  assert.equal(REASON.AGENT_REVOKED, 2);
  assert.equal(REASON.NO_POLICY, 3);
  assert.equal(REASON.POLICY_NOT_APPROVED, 4);
  assert.equal(REASON.TOKEN_NOT_ALLOWED, 5);
  assert.equal(REASON.PAYEE_NOT_ALLOWED, 6);
  assert.equal(REASON.OVER_TX_LIMIT, 7);
  assert.equal(REASON.OVER_PERIOD_LIMIT, 8);
  assert.equal(REASON.OUTSIDE_TIME_WINDOW, 9);
  assert.equal(REASON.PAUSED, 10);
  assert.equal(REASON.OVER_SHARED_LIMIT, 11);
  assert.equal(REASON.POLICY_FAILED, 12);
});

test("reasonName round-trips every code", () => {
  for (const [name, code] of Object.entries(REASON)) {
    assert.equal(reasonName(code), name, `code ${code}`);
  }
});

test("an unknown code does not throw", () => {
  assert.equal(reasonName(99), "UNKNOWN");
  assert.equal(reasonName(-1), "UNKNOWN");
});
```

- [ ] **Step 3: Run it and watch it fail**

Run: `cd agent && node --test reason.test.mjs`
Expected: FAIL — `Cannot find module './reason.mjs'`.

- [ ] **Step 4: Write `agent/reason.mjs`**

```js
// The block reason codes, frozen in docs/events.md and defined in src/Reason.sol.
//
// This is the THIRD copy of this table - src/Reason.sol is the authority and
// subgraph/src/reason.ts is the second. src/Reason.sol says so out loud: "The numbers must
// never be renumbered: the subgraph, the frontend and the agent all depend on them."
// `check-reason-table.mjs` reads the Solidity and asserts this file matches, so a
// renumbering fails loudly instead of silently mislabelling what the agent reports.
export const REASON = Object.freeze({
  OK: 0,
  AGENT_NOT_BOUND: 1,
  AGENT_REVOKED: 2,
  NO_POLICY: 3,
  POLICY_NOT_APPROVED: 4,
  TOKEN_NOT_ALLOWED: 5,
  PAYEE_NOT_ALLOWED: 6,
  OVER_TX_LIMIT: 7,
  OVER_PERIOD_LIMIT: 8,
  OUTSIDE_TIME_WINDOW: 9,
  PAUSED: 10,
  OVER_SHARED_LIMIT: 11,
  POLICY_FAILED: 12,
});

export const REASON_NAMES = Object.freeze(
  Object.entries(REASON)
    .sort((a, b) => a[1] - b[1])
    .map(([name]) => name),
);

export function reasonName(code) {
  return REASON_NAMES[code] ?? "UNKNOWN";
}
```

- [ ] **Step 5: Run the test and watch it pass**

Run: `cd agent && node --test reason.test.mjs`
Expected: PASS, 3 tests.

- [ ] **Step 6: Write the pinning check**

This is the point of the task. It must read the Solidity, not a copy of it.

```js
// agent/check-reason-table.mjs
// Reads src/Reason.sol and asserts agent/reason.mjs agrees with it, code for code.
//
// Why this exists: this repo now holds the same 13 numbers in three languages. A
// renumbering in Solidity would leave the agent confidently reporting the wrong reason to
// whoever is watching the demo - "over the limit" when the chain said "no human approved
// this". Nothing else would catch it, because each table is self-consistent.
//
// Run: node check-reason-table.mjs   (exit 0 = agree, 1 = drifted)
import { readFileSync } from "node:fs";
import { REASON } from "./reason.mjs";

const sol = readFileSync(new URL("../src/Reason.sol", import.meta.url), "utf8");

// uint8 internal constant NAME = 7;
const re = /uint8\s+internal\s+constant\s+([A-Z_]+)\s*=\s*(\d+)\s*;/g;
const fromSol = {};
for (const m of sol.matchAll(re)) fromSol[m[1]] = Number(m[2]);

const solNames = Object.keys(fromSol).sort();
const jsNames = Object.keys(REASON).sort();
let bad = 0;

if (solNames.length === 0) {
  console.log("FAIL  parsed 0 constants out of src/Reason.sol - the regex no longer matches");
  process.exit(1);
}

for (const name of new Set([...solNames, ...jsNames])) {
  const s = fromSol[name];
  const j = REASON[name];
  const ok = s !== undefined && j !== undefined && s === j;
  if (!ok) bad++;
  console.log(
    `${ok ? "ok  " : "FAIL"}  ${name.padEnd(20)} solidity=${s ?? "(absent)"} js=${j ?? "(absent)"}`,
  );
}

console.log(bad === 0 ? `\nall ${solNames.length} codes agree` : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
```

- [ ] **Step 7: Run the check**

Run: `cd agent && node check-reason-table.mjs`
Expected: 13 `ok` lines and `all 13 codes agree`, exit 0.

- [ ] **Step 8: Prove the check can fail**

Temporarily change `PAUSED: 10` to `PAUSED: 99` in `agent/reason.mjs`, run the check again, and confirm it prints `FAIL  PAUSED  solidity=10 js=99` and exits 1. **Then revert it** and re-run to confirm you are back to `all 13 codes agree`. Report both outputs.

- [ ] **Step 9: Commit**

```bash
git add agent/package.json agent/package-lock.json agent/reason.mjs agent/check-reason-table.mjs agent/reason.test.mjs
git commit -F - <<'MSG'
feat: the agent's reason table, pinned to src/Reason.sol

This is the third copy of the same 13 numbers - Solidity is the
authority, the subgraph mapping is the second. A renumbering would
leave the agent confidently reporting the wrong reason to whoever is
watching, and nothing would catch it, because each table is
self-consistent on its own. check-reason-table.mjs reads the Solidity
and asserts this one matches.
MSG
```

---

## Task 2: `decide()` — the pure pre-flight

**Files:**
- Create: `agent/decide.mjs`, `agent/decide.test.mjs`

**Interfaces:**
- Consumes: `REASON`, `reasonName` from `agent/reason.mjs` (Task 1).
- Produces: `decide(snapshot, intent, nowSec) -> { verdict, reason, reasonName, explain }`.
  - `verdict` is one of `"will-pass"`, `"will-be-blocked"`, `"unknown"`.
  - `reason` is a number or `null`. `explain` is a human sentence or `null`.
  - `snapshot` shape (Task 3 produces it):
    ```js
    { ok: true, block: { subgraph: 11667861, chain: 11667862, lag: 1 },
      agent: { address, revoked },
      subname: { label, live },
      policy: { address, approved },
      budget: { token, limit: "1000000000", spent: "300000000", periodEnd: 1788998400 } | null,
      payees: { "0x…beef": { allowed: true, lastToken: "0x…" } } }
    ```
  - `intent` shape: `{ id, token, payee, amount, note }` with `amount` a base-unit decimal string.

- [ ] **Step 1: Write the failing tests**

```js
// agent/decide.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./decide.mjs";
import { REASON } from "./reason.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200; // 2026-09-09T12:00:00Z

const base = () => ({
  ok: true,
  block: { subgraph: 11667861, chain: 11667861, lag: 0 },
  agent: { address: "0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0", revoked: false },
  subname: { label: "vendors", live: true },
  policy: { address: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "300000000", periodEnd: 1788998400 },
  payees: { [PAYEE]: { allowed: true, lastToken: TOKEN } },
});

const intent = (over = {}) => ({
  id: "t", token: TOKEN, payee: PAYEE, amount: "100000000", note: "", ...over,
});

test("a payment inside every limit will pass", () => {
  const d = decide(base(), intent(), NOW);
  assert.equal(d.verdict, "will-pass");
  assert.equal(d.reason, null);
});

test("a revoked agent is blocked with AGENT_REVOKED", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.AGENT_REVOKED);
});

test("no policy pointer is blocked with NO_POLICY", () => {
  const s = base();
  s.policy = null;
  assert.equal(decide(s, intent(), NOW).reason, REASON.NO_POLICY);
});

test("an unapproved policy is blocked with POLICY_NOT_APPROVED", () => {
  const s = base();
  s.policy.approved = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.POLICY_NOT_APPROVED);
});

test("a payee absent from the index is blocked with PAYEE_NOT_ALLOWED", () => {
  const d = decide(base(), intent({ payee: "0x00000000000000000000000000000000000000ca" }), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.PAYEE_NOT_ALLOWED);
});

test("a payee explicitly not allowed is blocked with PAYEE_NOT_ALLOWED", () => {
  const s = base();
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.PAYEE_NOT_ALLOWED);
});

test("exceeding the remaining period budget is blocked with OVER_PERIOD_LIMIT", () => {
  // limit 1000, spent 300 => 700 remaining; 800 must not fit
  const d = decide(base(), intent({ amount: "800000000" }), NOW);
  assert.equal(d.verdict, "will-be-blocked");
  assert.equal(d.reason, REASON.OVER_PERIOD_LIMIT);
});

test("exactly the remaining budget still passes", () => {
  assert.equal(decide(base(), intent({ amount: "700000000" }), NOW).verdict, "will-pass");
});

test("a rolled-over period frees the whole limit again", () => {
  // periodEnd 1788998400 is 2026-09-10T00:00:00Z; decide one second after it
  const d = decide(base(), intent({ amount: "900000000" }), 1788998401);
  assert.equal(d.verdict, "will-pass", "spent must be treated as 0 once the period has reset");
});

test("periodEnd 0 means a lifetime budget and never rolls over", () => {
  const s = base();
  s.budget.periodEnd = 0;
  assert.equal(decide(s, intent({ amount: "800000000" }), NOW).reason, REASON.OVER_PERIOD_LIMIT);
});

test("limit 0 means unlimited", () => {
  const s = base();
  s.budget.limit = "0";
  assert.equal(decide(s, intent({ amount: "999999999999" }), NOW).verdict, "will-pass");
});

test("a missing budget row is unknown, not a block", () => {
  const s = base();
  s.budget = null;
  const d = decide(s, intent(), NOW);
  assert.equal(d.verdict, "unknown");
  assert.equal(d.reason, null);
});

test("a token other than the budget's token is unknown, because the index cannot say", () => {
  const d = decide(base(), intent({ token: "0x1111111111111111111111111111111111111111" }), NOW);
  assert.equal(d.verdict, "unknown");
});

test("a failed read blocks nothing and sends nothing", () => {
  const d = decide({ ok: false, error: "boom" }, intent(), NOW);
  assert.equal(d.verdict, "unknown-read-failed");
  assert.equal(d.reason, null);
});

test("the account layer is checked before the policy layer, as the contract does", () => {
  // revoked (2, account) AND payee not allowed (6, policy) - the contract reports 2
  const s = base();
  s.agent.revoked = true;
  s.payees[PAYEE].allowed = false;
  assert.equal(decide(s, intent(), NOW).reason, REASON.AGENT_REVOKED);
});

test("every verdict carries a reasonName and an explain when it blocks", () => {
  const s = base();
  s.agent.revoked = true;
  const d = decide(s, intent(), NOW);
  assert.equal(d.reasonName, "AGENT_REVOKED");
  assert.ok(d.explain && d.explain.length > 10);
});
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd agent && node --test decide.test.mjs`
Expected: FAIL — `Cannot find module './decide.mjs'`.

- [ ] **Step 3: Write `agent/decide.mjs`**

```js
// The pre-flight. Given a snapshot of what the index says and one intent, predict whether
// the chain will allow the spend.
//
// **This function is trustworthy when it refuses and not when it permits**, and that is by
// design, not a limitation to fix later:
//
//   - Payee.allowed is keyed by (node, payee) and NOT by token, because the frozen
//     PayeeAllowed event carries no token (see subgraph/schema.graphql). So `allowed: true`
//     may be optimistic for a second token.
//   - Five reason codes are not indexed at all: 5 TOKEN_NOT_ALLOWED, 7 OVER_TX_LIMIT,
//     9 OUTSIDE_TIME_WINDOW, 10 PAUSED, 11 OVER_SHARED_LIMIT. Plus 12 POLICY_FAILED, which
//     is unpredictable by nature.
//
// So "will-pass" means "I found nothing that forbids it", never "it will succeed". The
// caller must handle a send that gets blocked anyway - the loop records that as
// `blocked-despite-green`, which is the project's thesis in miniature: the agent's optimism
// is bounded by the contract.
//
// **What this function must never do is re-derive policy logic.** Completing the prediction
// would mean reimplementing StandardPolicy in JavaScript - per-transaction limits, time
// windows, period alignment. On 2026-09-09 this repo caught a Critical of exactly that
// shape: a JS reimplementation of a hashing rule diverged from the real one and no test
// could see it, because both sides were self-consistent. Read conclusions the index states;
// never recompute them.
import { REASON, reasonName } from "./reason.mjs";

const blocked = (reason, explain) => ({
  verdict: "will-be-blocked",
  reason,
  reasonName: reasonName(reason),
  explain,
});
const unknown = (verdict, explain) => ({ verdict, reason: null, reasonName: null, explain });
const pass = () => ({ verdict: "will-pass", reason: null, reasonName: null, explain: null });

const lower = (a) => String(a ?? "").toLowerCase();

export function decide(snapshot, intent, nowSec) {
  if (!snapshot || snapshot.ok !== true) {
    return unknown(
      "unknown-read-failed",
      `could not read the index (${snapshot?.error ?? "no snapshot"}); sending nothing`,
    );
  }

  // Account layer first, in the contract's own order (src/Reason.sol: 1-4 and 10 are decided
  // by LeashAccount before it calls the policy). Reason 1 AGENT_NOT_BOUND reverts rather than
  // emitting, and reason 10 PAUSED is not indexed, so neither appears here.
  if (snapshot.agent?.revoked === true) {
    return blocked(REASON.AGENT_REVOKED, "this agent has been revoked; restoring it needs a face scan");
  }
  if (!snapshot.policy || !snapshot.policy.address) {
    return blocked(REASON.NO_POLICY, "this name points at no policy");
  }
  if (snapshot.policy.approved !== true) {
    return blocked(REASON.POLICY_NOT_APPROVED, "no human has approved the policy this name points at");
  }

  // Policy layer, for the two the index can answer.
  const payee = snapshot.payees?.[lower(intent.payee)];
  if (!payee || payee.allowed !== true) {
    return blocked(
      REASON.PAYEE_NOT_ALLOWED,
      "this payee is not on the allow-list; adding it is a widening and needs a face scan",
    );
  }

  const budget = snapshot.budget;
  if (!budget) {
    return unknown("unknown", "the index has no budget row for this token yet; the chain will decide");
  }
  if (lower(budget.token) !== lower(intent.token)) {
    return unknown(
      "unknown",
      "the indexed budget is for a different token, and the index cannot answer per-token; the chain will decide",
    );
  }

  const limit = BigInt(budget.limit);
  if (limit !== 0n) {
    // periodEnd is when the period resets. The index only moves `spent` when a spend is
    // indexed, so once periodEnd has passed the chain has already reset the budget while the
    // index still reports the old figure. Reading the field with the meaning the schema gives
    // it is not re-deriving policy logic.
    const periodEnd = Number(budget.periodEnd ?? 0);
    const rolledOver = periodEnd > 0 && periodEnd <= nowSec;
    const spent = rolledOver ? 0n : BigInt(budget.spent);
    if (spent + BigInt(intent.amount) > limit) {
      return blocked(
        REASON.OVER_PERIOD_LIMIT,
        `this would exceed the period budget (${limit - spent} left of ${limit})`,
      );
    }
  }

  return pass();
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd agent && node --test decide.test.mjs`
Expected: PASS, 16 tests.

- [ ] **Step 5: Mutation-test the two subtle branches**

These two are the ones a plausible "simplification" would break, and no other test covers them. For each: apply it, run `node --test decide.test.mjs`, confirm the named test goes RED, then revert.

| Mutation | Must fail |
|---|---|
| Drop the `rolledOver` handling — always `BigInt(budget.spent)` | `a rolled-over period frees the whole limit again` |
| Change `periodEnd > 0 && periodEnd <= nowSec` to just `periodEnd <= nowSec` | `periodEnd 0 means a lifetime budget and never rolls over` |
| Move the payee check above the `agent.revoked` check | `the account layer is checked before the policy layer, as the contract does` |

Report which test failed for each, and confirm the file is byte-identical to before afterwards.

- [ ] **Step 6: Commit**

```bash
git add agent/decide.mjs agent/decide.test.mjs
git commit -F - <<'MSG'
feat: the agent's pre-flight decision, as a pure function

decide(snapshot, intent, now) predicts whether the chain will allow a
spend, from what the index states as fact. It is trustworthy when it
refuses and not when it permits: Payee.allowed is not per-token, and
five reason codes are not indexed at all, so "will-pass" means "I found
nothing forbidding it" and the caller must handle a send that is blocked
anyway.

It deliberately re-derives nothing. Completing the prediction would mean
reimplementing StandardPolicy in JavaScript, which is the shape of the
Critical this repo caught earlier today - a JS reimplementation that
diverged with no test able to see it.

`now` is a parameter rather than a clock read, so the rolled-over budget
period is testable without mocking time.
MSG
```

---

## Task 3: The subgraph reader

**Files:**
- Create: `agent/subgraph.mjs`, `agent/subgraph.test.mjs`

**Interfaces:**
- Produces: `buildIds({ wallet, node, agent, token })` → `{ agent, budget, payeePrefix }` (all lowercase), and `async fetchSnapshot(cfg, fetchImpl = fetch)` → the snapshot shape Task 2 consumes.
  - `cfg`: `{ url, wallet, node, agent, token }`.
  - On any failure returns `{ ok: false, error: "<sentence>" }` — it never throws.
  - `fetchImpl` is injectable so the tests need no network.

- [ ] **Step 1: Write the failing tests**

```js
// agent/subgraph.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildIds, fetchSnapshot } from "./subgraph.mjs";

const CFG = {
  url: "http://example.invalid/graphql",
  wallet: "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6", // checksummed on purpose
  node: "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
  agent: "0xf9248C78183E44b27AfAF6e0CdF5e3e2a3771De0", // checksummed on purpose
  token: "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
};

const okBody = {
  data: {
    _meta: { block: { number: 11667861 } },
    agent: { id: "x", revoked: false },
    subname: { label: "vendors", live: true },
    policyPointer: { policy: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
    agentBudget: {
      token: "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
      limit: "1000000000",
      spent: "300000000",
      periodEnd: "1788998400",
    },
    payees: [
      { payee: "0x000000000000000000000000000000000000beef", allowed: true, lastToken: null },
    ],
  },
};

const stub = (body, status = 200) => async () => ({
  ok: status === 200,
  status,
  json: async () => body,
});

test("ids are lowercased, because the index stores them that way", () => {
  const ids = buildIds(CFG);
  assert.equal(ids.agent, "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6-0xf9248c78183e44b27afaf6e0cdf5e3e2a3771de0");
  assert.equal(
    ids.budget,
    "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6-0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121-0x768f42455a2d082e23ceef7d51e5787c82d67a39",
  );
  assert.equal(ids.wallet, "0x46c09255377525b34b27ada1a8f0f5bbd0d8eba6");
  assert.equal(ids.node, "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121");
  assert.ok(!/[A-F]/.test(ids.agent + ids.budget + ids.wallet), "no uppercase hex may survive");
});

test("a good response becomes a snapshot", async () => {
  const s = await fetchSnapshot({ ...CFG, chainBlock: 11667862 }, stub(okBody));
  assert.equal(s.ok, true);
  assert.equal(s.block.subgraph, 11667861);
  assert.equal(s.block.lag, 1);
  assert.equal(s.agent.revoked, false);
  assert.equal(s.policy.approved, true);
  assert.equal(s.budget.limit, "1000000000");
  assert.equal(s.budget.periodEnd, 1788998400, "periodEnd must be a number, not a string");
  assert.equal(s.payees["0x000000000000000000000000000000000000beef"].allowed, true);
});

test("payee keys are lowercased so decide() can look them up", async () => {
  const body = structuredClone(okBody);
  body.data.payees[0].payee = "0x000000000000000000000000000000000000BEEF";
  const s = await fetchSnapshot(CFG, stub(body));
  assert.ok(s.payees["0x000000000000000000000000000000000000beef"]);
});

test("GraphQL errors fail closed", async () => {
  const s = await fetchSnapshot(CFG, stub({ errors: [{ message: "bad query" }] }));
  assert.equal(s.ok, false);
  assert.match(s.error, /bad query/);
});

test("a non-200 fails closed", async () => {
  const s = await fetchSnapshot(CFG, stub({}, 502));
  assert.equal(s.ok, false);
  assert.match(s.error, /502/);
});

test("a thrown fetch fails closed instead of propagating", async () => {
  const s = await fetchSnapshot(CFG, async () => {
    throw new Error("ECONNREFUSED");
  });
  assert.equal(s.ok, false);
  assert.match(s.error, /ECONNREFUSED/);
});

test("a missing _meta fails closed - we must never decide on an unknown block", async () => {
  const body = structuredClone(okBody);
  delete body.data._meta;
  const s = await fetchSnapshot(CFG, stub(body));
  assert.equal(s.ok, false);
});

test("absent optional rows are null, not an error", async () => {
  const body = structuredClone(okBody);
  body.data.agentBudget = null;
  body.data.policyPointer = null;
  const s = await fetchSnapshot(CFG, stub(body));
  assert.equal(s.ok, true);
  assert.equal(s.budget, null);
  assert.equal(s.policy, null);
});

test("the error sentence never contains the url on the non-200 path", async () => {
  const s = await fetchSnapshot({ ...CFG, url: "https://x/secret-key-abc" }, stub({}, 500));
  assert.ok(!s.error.includes("secret-key-abc"));
});

test("the error sentence never contains the url on the throw path (malformed URL)", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-abc123";
  const fetchWithUrlInError = async () => {
    throw new Error(`Failed to fetch from ${secretUrl}`);
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithUrlInError);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-abc123"), "the secret key must not appear");
  assert.ok(!s.error.includes(secretUrl), "the url must be redacted");
  assert.ok(s.error.includes("Failed to fetch"), "other error details must survive redaction");
});

test("real connection failures put the detail in err.cause, not err.message", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-xyz";
  const fetchWithCauseError = async () => {
    const err = new Error("fetch failed");
    err.cause = new Error("ECONNREFUSED");
    throw err;
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithCauseError);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-xyz"), "the secret key must not appear");
  assert.ok(s.error.includes("ECONNREFUSED"), "the real diagnostic from err.cause must be present");
  assert.ok(s.error.includes("fetch failed"), "the top-level message must also be present");
});

test("hostname in err.cause does not leak through redaction", async () => {
  const secretUrl = "https://api.example.com/query?api-key=SECRET-KEY-abc";
  const fetchWithHostnameInCause = async () => {
    const err = new Error("fetch failed");
    err.cause = new Error("getaddrinfo ENOTFOUND api.example.com");
    throw err;
  };
  const s = await fetchSnapshot({ ...CFG, url: secretUrl }, fetchWithHostnameInCause);
  assert.equal(s.ok, false);
  assert.ok(!s.error.includes("SECRET-KEY-abc"), "the secret key must not appear");
  assert.ok(!s.error.includes("api.example.com"), "the hostname must not leak");
  assert.ok(s.error.includes("ENOTFOUND"), "the error reason must be present");
});
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd agent && node --test subgraph.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `agent/subgraph.mjs`**

```js
// The one read the agent makes per tick.
//
// Entity ids in the deployed index are LOWERCASE, while .env holds checksummed addresses.
// Interpolating a checksummed address returns an empty result, and because this module fails
// closed, that surfaces as "the agent does nothing" - a symptom that looks nothing like its
// cause. buildIds is separate and directly tested for exactly that reason.
const lower = (a) => String(a ?? "").toLowerCase();

export function buildIds({ wallet, node, agent, token }) {
  const w = lower(wallet);
  const n = lower(node);
  return {
    agent: `${w}-${lower(agent)}`,
    budget: `${w}-${n}-${lower(token)}`,
    node: n,
    wallet: w,
  };
}

// Payees are filtered on the `wallet` and `node` FIELDS, not by an id prefix.
// `id_starts_with` is not available on an `ID!` field in graph-node - verified against the
// live index on 2026-09-09, which answers "Invalid value provided for argument `where`".
// Both fields are `Bytes!` in the schema, so they take lowercase hex.
const QUERY = `
query AgentState($agentId: ID!, $budgetId: ID!, $node: ID!, $wallet: Bytes!, $nodeBytes: Bytes!) {
  _meta { block { number } }
  agent(id: $agentId) { id revoked }
  subname(id: $node) { label live }
  policyPointer(id: $node) { policy approved }
  agentBudget(id: $budgetId) { token limit spent periodEnd }
  payees(where: { wallet: $wallet, node: $nodeBytes }) { payee allowed lastToken }
}`;

export async function fetchSnapshot(cfg, fetchImpl = fetch) {
  const ids = buildIds(cfg);
  let body;
  try {
    const res = await fetchImpl(cfg.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: QUERY,
        variables: {
          agentId: ids.agent,
          budgetId: ids.budget,
          node: ids.node,
          wallet: ids.wallet,
          nodeBytes: ids.node,
        },
      }),
    });
    // Never put cfg.url in an error: a subgraph url can carry an API key.
    if (!res.ok) return { ok: false, error: `subgraph returned HTTP ${res.status}` };
    body = await res.json();
  } catch (err) {
    // Never put cfg.url in an error: a subgraph url can carry an API key.
    // The exception path can leak the URL in err.message (Node's fetch does this for
    // malformed URLs). Real connection failures (DNS, host unreachable, ECONNREFUSED)
    // put the detail in err.cause.message instead, which carries only the hostname,
    // never a path or API key. Include both for proper diagnostics without leaking.
    const raw = String(err?.message ?? err);
    const cause = err?.cause?.message ? ` (${err.cause.message})` : "";
    const full = raw + cause;
    let safe = full;
    if (cfg.url) {
      safe = full.split(cfg.url).join("<redacted>");
      // Also redact the hostname part, since connection errors report only the hostname
      try {
        const u = new URL(cfg.url);
        safe = safe.split(u.hostname).join("<redacted>");
      } catch {
        // If URL parsing fails, the split-redaction above is still active
      }
    }
    return { ok: false, error: `subgraph unreachable: ${safe}` };
  }

  if (body?.errors?.length) {
    return { ok: false, error: `subgraph errors: ${body.errors.map((e) => e.message).join("; ")}` };
  }
  const d = body?.data;
  const blockNumber = d?._meta?.block?.number;
  if (typeof blockNumber !== "number") {
    // Deciding without knowing how far behind the index is would make every verdict
    // unfalsifiable. Fail closed instead.
    return { ok: false, error: "subgraph did not report _meta.block.number" };
  }

  const payees = {};
  for (const p of d.payees ?? []) {
    payees[lower(p.payee)] = { allowed: p.allowed === true, lastToken: p.lastToken ? lower(p.lastToken) : null };
  }

  const chain = typeof cfg.chainBlock === "number" ? cfg.chainBlock : blockNumber;
  return {
    ok: true,
    block: { subgraph: blockNumber, chain, lag: Math.max(0, chain - blockNumber) },
    agent: { address: lower(cfg.agent), revoked: d.agent?.revoked === true },
    subname: d.subname ? { label: d.subname.label, live: d.subname.live === true } : null,
    policy: d.policyPointer
      ? { address: lower(d.policyPointer.policy), approved: d.policyPointer.approved === true }
      : null,
    budget: d.agentBudget
      ? {
          token: lower(d.agentBudget.token),
          limit: String(d.agentBudget.limit),
          spent: String(d.agentBudget.spent),
          periodEnd: Number(d.agentBudget.periodEnd ?? 0),
        }
      : null,
    payees,
  };
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd agent && node --test subgraph.test.mjs`
Expected: PASS, 12 tests.

- [ ] **Step 5: Run it against the live index, once**

This proves the query and the id shapes are right against the real deployment, which no stub can.

```bash
cd agent
ENV=/home/ubuntu/DEV/ETHOnline2026/.env
get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
node -e '
const { fetchSnapshot } = await import("./subgraph.mjs");
const s = await fetchSnapshot({
  url: "https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4",
  wallet: "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6",
  node: "0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121",
  agent: "0xf9248C78183E44b27AfAF6e0CdF5e3e2a3771De0",
  token: "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
});
console.log(JSON.stringify(s, null, 2));
'
```

Expected: `ok: true`, a `subgraph` block number in the 11.6M range, `agent.revoked: false`, `policy.approved: true`, `budget.limit "1000000000"`, and `payees` containing `0x000000000000000000000000000000000000beef` with `allowed: true`. **If `agent`, `policy` or `budget` come back null, the ids are wrong** — check the lowercasing first. Paste the output in your report.

- [ ] **Step 6: Commit**

```bash
git add agent/subgraph.mjs agent/subgraph.test.mjs
git commit -F - <<'MSG'
feat: the agent's subgraph read, failing closed

One query per tick for everything the decision needs. Every failure -
non-200, GraphQL errors, an unreachable host, a missing _meta - returns
{ok: false} rather than throwing, so the loop's default under
uncertainty is to send nothing.

Entity ids are built lowercase in a separately tested function, because
.env holds checksummed addresses and the index stores lowercase ones:
interpolating the checksummed form returns empty rows, which fail-closed
then renders as "the agent does nothing", a symptom nothing like its
cause.

Error sentences never include the subgraph url, which can carry an API
key.
MSG
```

---

## Task 4: The sender

**Files:**
- Create: `agent/send.mjs`, `agent/send.test.mjs`

**Interfaces:**
- Consumes: `reasonName` from `agent/reason.mjs`.
- Produces:
  - `classifyReceipt(receipt, walletAddress)` → `{ outcome, reason, reasonName }` where `outcome` is `"executed"`, `"blocked"`, or `"no-event"`.
  - `async sendSpend({ rpcUrl, privKey, wallet, token, payee, amount })` → `{ tx, outcome, reason, reasonName }` or `{ error }`.
  - `redactUrls(text)` → the same text with any `http(s)://…` run replaced by `<rpc>`.
- `classifyReceipt` and `redactUrls` are pure and are where the tests live. `sendSpend` owns
  viem and is not unit-tested here — it is exercised for real in Task 5 Step 9. That is why
  its error path's redaction is extracted into `redactUrls`: an untested redaction on a
  secret-bearing string is exactly the defect found in Task 3, where the pinned test drove
  the one path that was already safe.

**Event topics** (computed with `cast keccak`, 2026-09-09):
- `SpendExecuted(bytes32,address,address,address,uint256,address,uint256,uint256,uint64)` → `0xf0b4af7bfd5a13b5eff4d2de508be60041b405cee18bf6f135c692be137d1381`
- `SpendBlocked(bytes32,address,address,address,uint256,uint8,address,uint256,uint256)` → `0x8ab53b1df82e8bdff7dad3143040ff0efb1d94506ab3e47853c38b5925c50828`

- [ ] **Step 1: Write the failing tests**

```js
// agent/send.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyReceipt, redactUrls, TOPIC_EXECUTED, TOPIC_BLOCKED } from "./send.mjs";

const WALLET = "0x46C09255377525b34B27ada1A8F0F5BBd0d8eba6";
const OTHER = "0x1111111111111111111111111111111111111111";

// SpendBlocked's non-indexed args in order: node, amount, reason, policy, spentSoFar, limit.
// node is word 0, amount word 1, reason word 2. reason 6 in word 2:
const blockedData =
  "0x" +
  "00".repeat(32) + // node
  "00".repeat(32) + // amount
  "00".repeat(31) + "06" + // reason = 6
  "00".repeat(32) + // policy
  "00".repeat(32) + // spentSoFar
  "00".repeat(32); // limit

test("a SpendExecuted log is executed", () => {
  const r = classifyReceipt({ logs: [{ address: WALLET, topics: [TOPIC_EXECUTED], data: "0x" }] }, WALLET);
  assert.equal(r.outcome, "executed");
  assert.equal(r.reason, null);
});

test("a SpendBlocked log yields its reason code", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET, topics: [TOPIC_BLOCKED], data: blockedData }] },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
  assert.equal(r.reason, 6);
  assert.equal(r.reasonName, "PAYEE_NOT_ALLOWED");
});

test("logs from another address are ignored", () => {
  const r = classifyReceipt({ logs: [{ address: OTHER, topics: [TOPIC_EXECUTED], data: "0x" }] }, WALLET);
  assert.equal(r.outcome, "no-event");
});

test("address comparison is case-insensitive", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET.toLowerCase(), topics: [TOPIC_EXECUTED], data: "0x" }] },
    WALLET.toUpperCase().replace("0X", "0x"),
  );
  assert.equal(r.outcome, "executed");
});

test("no logs at all is no-event, not a crash", () => {
  assert.equal(classifyReceipt({ logs: [] }, WALLET).outcome, "no-event");
  assert.equal(classifyReceipt({}, WALLET).outcome, "no-event");
});

test("SpendBlocked wins if both appear, because a block is the safer reading", () => {
  const r = classifyReceipt(
    {
      logs: [
        { address: WALLET, topics: [TOPIC_EXECUTED], data: "0x" },
        { address: WALLET, topics: [TOPIC_BLOCKED], data: blockedData },
      ],
    },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
});

test("redactUrls removes an rpc url carrying an api key", () => {
  const msg = 'HTTP request failed. URL: https://eth-sepolia.g.alchemy.com/v2/SECRET-KEY-abc123';
  const out = redactUrls(msg);
  assert.ok(!out.includes("SECRET-KEY-abc123"), "the key must not survive");
  assert.ok(!out.includes("alchemy.com"), "the host must not survive either");
  assert.match(out, /<rpc>/);
});

test("redactUrls keeps the non-url detail, so it cannot regress to a generic message", () => {
  const out = redactUrls("connect ECONNREFUSED https://eth-sepolia.example/KEY-xyz 443");
  assert.match(out, /ECONNREFUSED/, "the diagnostic must survive");
  assert.ok(!out.includes("KEY-xyz"));
  assert.match(out, /443/, "detail after the url must survive too");
});

test("a truncated SpendBlocked data field does not throw", () => {
  const r = classifyReceipt(
    { logs: [{ address: WALLET, topics: [TOPIC_BLOCKED], data: "0x1234" }] },
    WALLET,
  );
  assert.equal(r.outcome, "blocked");
  assert.equal(r.reason, null);
});
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd agent && node --test send.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `agent/send.mjs`**

```js
// Sending one spend, and reading what the chain said about it.
//
// A policy block does NOT revert - src/LeashAccount.sol:802 emits SpendBlocked and returns
// normally, so the subgraph can index it. So a successful receipt is not a successful
// payment: the outcome is in the logs, and it has to be read there.
//
// Signing happens in-process. Never shell out to `cast send`: its --private-key flag has no
// environment variant, so the key would sit in argv where `ps` can read it.
import { createWalletClient, createPublicClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { reasonName } from "./reason.mjs";

// cast keccak, 2026-09-09.
export const TOPIC_EXECUTED =
  "0xf0b4af7bfd5a13b5eff4d2de508be60041b405cee18bf6f135c692be137d1381";
export const TOPIC_BLOCKED =
  "0x8ab53b1df82e8bdff7dad3143040ff0efb1d94506ab3e47853c38b5925c50828";

const ABI = parseAbi(["function spend(address token, address payee, uint256 amount)"]);
const lower = (a) => String(a ?? "").toLowerCase();

// SEPOLIA_RPC carries an API key, so no error string may contain it. Extracted and exported
// rather than inlined in the catch because sendSpend itself is not unit-tested - it needs a
// chain - and an untested redaction on a secret-bearing string is the defect Task 3 shipped:
// there the pinned test exercised the one path that was already safe, so the hole survived
// review. Keep the non-url detail: an error that says only "something went wrong" costs real
// debugging time on a path that fires when configuration is already broken.
export function redactUrls(text) {
  return String(text ?? "").replace(/https?:\/\/\S+/g, "<rpc>");
}

export function classifyReceipt(receipt, walletAddress) {
  const w = lower(walletAddress);
  const logs = (receipt?.logs ?? []).filter((l) => lower(l.address) === w);

  // Check for a block first: if both somehow appear, "blocked" is the safer reading.
  const b = logs.find((l) => lower(l.topics?.[0]) === TOPIC_BLOCKED);
  if (b) {
    // Non-indexed args, in order: node, amount, reason, policy, spentSoFar, limit.
    // reason is the third word. A short data field means we cannot say - do not guess.
    const hex = String(b.data ?? "0x").slice(2);
    if (hex.length < 64 * 3) return { outcome: "blocked", reason: null, reasonName: null };
    const word = hex.slice(64 * 2, 64 * 3);
    const reason = Number(BigInt("0x" + word));
    return { outcome: "blocked", reason, reasonName: reasonName(reason) };
  }

  if (logs.some((l) => lower(l.topics?.[0]) === TOPIC_EXECUTED)) {
    return { outcome: "executed", reason: null, reasonName: null };
  }
  return { outcome: "no-event", reason: null, reasonName: null };
}

export async function sendSpend({ rpcUrl, privKey, wallet, token, payee, amount }) {
  // Declared outside the try so the catch can still see it: a hash obtained before a later
  // failure (waitForTransactionReceipt timing out is the case that matters - 120s is ten
  // Sepolia blocks, and congestion makes it ordinary) must reach the caller. "Sent, outcome
  // unknown" and "never sent" are different states; conflating them by dropping the hash on
  // any error is what let a timeout re-arm an intent whose transaction might still land, and
  // pay it twice.
  let tx;
  try {
    const account = privateKeyToAccount(privKey);
    const transport = http(rpcUrl);
    const walletClient = createWalletClient({ account, chain: sepolia, transport });
    const publicClient = createPublicClient({ chain: sepolia, transport });

    tx = await walletClient.writeContract({
      address: wallet,
      abi: ABI,
      functionName: "spend",
      args: [token, payee, BigInt(amount)],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx, timeout: 120_000 });
    return { tx, ...classifyReceipt(receipt, wallet) };
  } catch (err) {
    // Never let an RPC url reach a log or a response: it can carry an API key.
    const msg = String(err?.shortMessage ?? err?.message ?? err).split("\n")[0];
    return tx ? { tx, error: redactUrls(msg) } : { error: redactUrls(msg) };
  }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd agent && node --test send.test.mjs`
Expected: PASS, 9 tests.

- [ ] **Step 5: Prove the reason decode is not accidentally right**

Change the word offset from `hex.slice(64 * 2, 64 * 3)` to `hex.slice(64 * 1, 64 * 2)` (reading `amount` instead of `reason`), run the tests, and confirm `a SpendBlocked log yields its reason code` goes RED with `reason` 0 rather than 6. Revert and re-run. Report the failure output.

- [ ] **Step 6: Commit**

```bash
git add agent/send.mjs agent/send.test.mjs
git commit -F - <<'MSG'
feat: send a spend, and read what the chain said about it

A policy block does not revert - LeashAccount emits SpendBlocked and
returns normally so the subgraph can index it. So a successful receipt
is not a successful payment, and classifyReceipt is where that
distinction lives: it reads the outcome out of the logs and pulls the
reason code from the third non-indexed word.

Signing is in-process. Shelling out to `cast send` was rejected because
--private-key has no environment variant, so the key would sit in argv
where ps can read it. RPC urls are stripped from every error string.
MSG
```

---

## Task 5: The loop, the endpoint, and the live run

**Files:**
- Create: `agent/loop.mjs`, `agent/intents.json`, `agent/README.md`, `agent/loop.test.mjs`

**Interfaces:**
- Consumes: `fetchSnapshot` (Task 3), `decide` (Task 2), `sendSpend`/`classifyReceipt` (Task 4).
- Produces: `advance(state, snapshot, intents, nowSec)` → `{ state, toSend }` — the pure bookkeeping half, separately testable; and the process serving `GET /api/agent/state` and `POST /api/agent/tick` on port 8788.

- [ ] **Step 1: Write `agent/intents.json`**

`0x…beef` is already allow-listed, so the first intent demonstrates "inside the policy, no human needed". The second targets a fresh address that is **not** allow-listed, so it stays blocked until a face scan widens the policy — then the agent completes it on its own. Amounts are base units; MockUSDC has 6 decimals.

```json
[
  {
    "id": "retainer",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x000000000000000000000000000000000000beef",
    "amount": "5000000",
    "note": "monthly retainer - inside the policy, no human in the loop"
  },
  {
    "id": "newvendor",
    "token": "0x768f42455a2d082e23ceef7d51e5787c82d67a39",
    "payee": "0x00000000000000000000000000000000000cafe0",
    "amount": "5000000",
    "note": "a vendor the policy has never seen - needs a face scan"
  }
]
```

- [ ] **Step 2: Write the failing tests for the bookkeeping**

```js
// agent/loop.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { advance, initialState, sendAndRecord } from "./loop.mjs";

const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";
const PAYEE = "0x000000000000000000000000000000000000beef";
const NOW = 1788955200;

const intents = [{ id: "a", token: TOKEN, payee: PAYEE, amount: "5000000", note: "" }];

const okSnap = () => ({
  ok: true,
  block: { subgraph: 11667861, chain: 11667863, lag: 2 },
  agent: { address: "0xaa", revoked: false },
  subname: { label: "vendors", live: true },
  policy: { address: "0xbb", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "0", periodEnd: 0 },
  payees: { [PAYEE]: { allowed: true, lastToken: TOKEN } },
});

test("an eligible intent is queued to send", () => {
  const { toSend } = advance(initialState(), okSnap(), intents, NOW);
  assert.deepEqual(toSend.map((i) => i.id), ["a"]);
});

test("an in-flight intent is not queued again - this is what stops duplicate payments", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.inFlight = true;
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "in-flight");
});

test("an executed intent is terminal and never sent again", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", outcome: "executed", tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "done");
});

test("a blocked intent stays eligible, so the agent retries after a widening", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", outcome: "blocked", reason: 6, tx: "0x1" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

test("a failed read sends nothing and says so", () => {
  const { state, toSend } = advance(initialState(), { ok: false, error: "boom" }, intents, NOW);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.verdict, "unknown-read-failed");
});

test("a predicted block is not sent", () => {
  const s = okSnap();
  s.payees[PAYEE].allowed = false;
  const { toSend, state } = advance(initialState(), s, intents, NOW);
  assert.deepEqual(toSend, []);
  assert.equal(state.intents.a.reason, 6);
});

test("the tick counter and the source block land in the state", () => {
  // subgraph, chain and lag are all distinct here so a swap between subgraphBlock and
  // chainBlock in advance() cannot hide behind equal fixture values.
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  assert.equal(state.tick, 1);
  assert.equal(state.source.subgraphBlock, 11667861);
  assert.equal(state.source.chainBlock, 11667863);
  assert.equal(state.source.lagBlocks, 2);
});

// A timed-out send obtains a transaction hash but never gets a classified outcome (send.mjs's
// 120s wait on waitForTransactionReceipt threw). That hash reaching state, and the intent NOT
// being queued again, is the second duplicate-payment path: without it, the next tick would
// send the same payment a second time on top of one that might still land.
test("a send that got a hash but no confirmed outcome is not re-sent, and the hash stays visible", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "sent", tx: "0xdeadbeef", outcome: null, error: "timeout" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend, []);
  assert.equal(next.state.intents.a.verdict, "unconfirmed");
  assert.match(next.state.intents.a.explain, /0xdeadbeef/);
  assert.equal(next.state.intents.a.lastAction.tx, "0xdeadbeef");
});

// The counterpart: a failure with no hash at all means nothing was ever submitted, so the
// intent must stay eligible - otherwise the fix for the timeout case would over-correct into
// never retrying a genuine pre-send failure (bad nonce, insufficient gas, RPC down).
test("a pre-send failure with no hash stays eligible, since nothing was sent", () => {
  let { state } = advance(initialState(), okSnap(), intents, NOW);
  state.intents.a.lastAction = { kind: "error", tx: null, outcome: null, error: "insufficient funds for gas" };
  const next = advance(state, okSnap(), intents, NOW);
  assert.deepEqual(next.toSend.map((i) => i.id), ["a"]);
});

// sendAndRecord clears `inFlight` in a `finally`, so the guard holds even if `sendImpl`
// throws instead of returning - which the real sendSpend never does today, but nothing in
// loop.mjs enforced that until now. Without the finally, a throwing send would leave the
// intent stuck reporting "in-flight" forever, indistinguishable on stage from index lag.
test("inFlight is cleared even when the send throws, via a finally", async () => {
  const rec = { id: "a", inFlight: false, lastAction: null };
  const throwingSend = async () => {
    throw new Error("network exploded");
  };
  await assert.rejects(() => sendAndRecord(rec, intents[0], { rpcUrl: "", privKey: "", wallet: "" }, throwingSend));
  assert.equal(rec.inFlight, false);
});
```

- [ ] **Step 3: Run them and watch them fail**

Run: `cd agent && node --test loop.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 4: Write `agent/loop.mjs`**

```js
// The agent decision loop.
//
// Runs as its own process holding ONLY AGENT_PK. docs/architecture.md:68 says AGENT "holds
// nothing" and can only call spend; world/server.mjs holds WORLD_RP_SIGNER_PK, which can
// authorise any widening. Sharing one process would put those two keys together and invert
// the security model this project exists to demonstrate.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createPublicClient, http as viemHttp } from "viem";
import { sepolia } from "viem/chains";
import { fetchSnapshot } from "./subgraph.mjs";
import { decide } from "./decide.mjs";
import { sendSpend } from "./send.mjs";

const PORT = Number(process.env.PORT || 8788);
const TICK_MS = Number(process.env.AGENT_TICK_MS || 5000);
const SUBGRAPH_URL =
  process.env.SUBGRAPH_URL ||
  "https://api.studio.thegraph.com/query/1758546/leash-sepolia/v0.0.4";

export const initialState = () => ({ tick: 0, at: null, source: null, snapshot: null, intents: {} });

// The pure half: given the state, a snapshot and the intents, work out each verdict and
// which intents to send. Kept separate from the IO so duplicate-payment prevention is
// testable without a chain.
export function advance(state, snapshot, intents, nowSec) {
  const next = { ...state, tick: state.tick + 1, at: new Date(nowSec * 1000).toISOString() };
  next.source = snapshot?.ok
    ? { subgraphBlock: snapshot.block.subgraph, chainBlock: snapshot.block.chain, lagBlocks: snapshot.block.lag }
    : { subgraphBlock: null, chainBlock: null, lagBlocks: null };
  next.snapshot = snapshot?.ok ? snapshot : null;
  next.readError = snapshot?.ok ? null : (snapshot?.error ?? "no snapshot");
  next.intents = { ...state.intents };

  const toSend = [];
  for (const intent of intents) {
    const prev = next.intents[intent.id] ?? { inFlight: false, lastAction: null };
    const rec = { ...prev, id: intent.id, note: intent.note ?? "" };

    if (prev.lastAction?.outcome === "executed") {
      // One-shot. The tick is seconds and the budget is finite: an intent that stayed
      // eligible after succeeding would be paid twelve times a minute.
      rec.verdict = "done";
      rec.reason = null;
      rec.reasonName = null; // cleared with `reason`, or a previous block's name survives
      rec.explain = "already paid; intents are one-shot";
    } else if (prev.lastAction?.kind === "sent" && prev.lastAction?.tx && prev.lastAction?.outcome == null) {
      // A transaction hash was obtained but no receipt was ever classified into an outcome -
      // most likely send.mjs's 120s wait timed out. The payment may still land on chain, so
      // re-sending risks a second one on top of it. This is the duplicate-payment path a
      // lost hash used to open: the hash must stay visible (it does, via lastAction, spread
      // from `prev` below) so an operator can look it up instead of the agent guessing.
      rec.verdict = "unconfirmed";
      rec.reason = null;
      rec.reasonName = null;
      rec.explain = `sent but never confirmed (tx ${prev.lastAction.tx}); will not retry on its own`;
    } else if (prev.inFlight) {
      rec.verdict = "in-flight";
      rec.reason = null;
      rec.reasonName = null; // same reason as above
      rec.explain = "waiting for the receipt of the transaction just sent";
    } else {
      const d = decide(snapshot, intent, nowSec);
      rec.verdict = d.verdict;
      rec.reason = d.reason;
      rec.reasonName = d.reasonName;
      rec.explain = d.explain;
      if (d.verdict === "will-pass") toSend.push(intent);
    }
    next.intents[intent.id] = rec;
  }
  return { state: next, toSend };
}

// Send one intent's spend and record what happened, clearing `inFlight` in a `finally` so
// that guard holds by construction rather than by every branch of `sendImpl` remembering to
// return normally. `sendSpend` today always returns an object literal and never throws past
// itself, so nothing currently exploits this - but that invariant living only in an audit of
// a different module is exactly the shape of gap this project keeps finding. `sendImpl` is
// injectable so this is testable without a chain: the real caller (`tick`, below) leaves it
// at the default.
export async function sendAndRecord(rec, intent, cfg, sendImpl = sendSpend) {
  rec.inFlight = true;
  rec.verdict = "in-flight";
  try {
    const res = await sendImpl({
      rpcUrl: cfg.rpcUrl,
      privKey: cfg.privKey,
      wallet: cfg.wallet,
      token: intent.token,
      payee: intent.payee,
      amount: intent.amount,
    });
    rec.lastAction = res.error
      ? {
          // A hash means the transaction was actually submitted - "sent, outcome unknown"
          // - and must be told apart from "never sent". Conflating them is what let a
          // timeout re-arm an intent whose transaction might still land, and pay it twice.
          kind: res.tx ? "sent" : "error",
          tx: res.tx ?? null,
          outcome: null,
          error: res.error,
        }
      : {
          kind: "sent",
          tx: res.tx,
          outcome: res.outcome,
          reason: res.reason ?? null,
          reasonName: res.reasonName ?? null,
          // The agent predicted this would pass. If the chain blocked it anyway, that is
          // the thesis in miniature: the agent's optimism is bounded by the contract.
          note: res.outcome === "blocked" ? "blocked-despite-green" : null,
        };
  } finally {
    rec.inFlight = false;
  }
  return rec;
}

// --- IO half ---

let state = initialState();
let intents = [];
let ticking = false;

function publicState() {
  const s = state;
  return {
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
    agent: s.snapshot?.agent ?? null,
    subname: s.snapshot?.subname ?? null,
    policy: s.snapshot?.policy ?? null,
    budget: s.snapshot?.budget ?? null,
    intents: Object.values(s.intents).map((i) => ({
      id: i.id,
      note: i.note,
      verdict: i.verdict ?? null,
      reason: i.reason ?? null,
      reasonName: i.reasonName ?? null,
      explain: i.explain ?? null,
      lastAction: i.lastAction ?? null,
    })),
  };
}

async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    const cfg = {
      url: SUBGRAPH_URL,
      wallet: process.env.WALLET_ADDR,
      node: process.env.LEASH_NODE,
      agent: process.env.AGENT_ADDR,
      token: intents[0]?.token,
    };
    let chainBlock;
    try {
      const pc = createPublicClient({ chain: sepolia, transport: viemHttp(process.env.SEPOLIA_RPC) });
      chainBlock = Number(await pc.getBlockNumber());
    } catch {
      chainBlock = undefined; // lag becomes 0; the read itself still decides
    }
    const snapshot = await fetchSnapshot({ ...cfg, chainBlock });
    const nowSec = Math.floor(Date.now() / 1000);
    const advanced = advance(state, snapshot, intents, nowSec);
    state = advanced.state;

    for (const intent of advanced.toSend) {
      const rec = await sendAndRecord(state.intents[intent.id], intent, {
        rpcUrl: process.env.SEPOLIA_RPC,
        privKey: process.env.AGENT_PK,
        wallet: process.env.WALLET_ADDR,
      });
      const a = rec.lastAction;
      console.log(
        `tick ${state.tick}  ${intent.id}  ${
          a.error
            ? a.tx
              ? `unconfirmed (tx ${a.tx}): ${a.error}`
              : `error: ${a.error}`
            : `${a.outcome}${a.reason != null ? ` (${a.reasonName})` : ""} ${a.tx}`
        }`,
      );
    }

    for (const i of Object.values(state.intents)) {
      if (!advanced.toSend.some((t) => t.id === i.id)) {
        console.log(`tick ${state.tick}  ${i.id}  ${i.verdict}${i.reason != null ? ` (${i.reasonName})` : ""}`);
      }
    }
  } finally {
    ticking = false;
  }
}

// Everything below only runs when this file is executed directly (`node loop.mjs`), never
// on import. Without this guard, importing advance/initialState from loop.test.mjs would
// also run the env-var check (killing the test process via process.exit) and start the
// HTTP server - the pure half would no longer be testable without a chain, which is the
// whole reason it was split out.
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  for (const v of ["AGENT_PK", "SEPOLIA_RPC", "WALLET_ADDR", "AGENT_ADDR", "LEASH_NODE"]) {
    if (!process.env[v]) {
      console.error(`${v} is not set. Extract single variables; never source .env wholesale.`);
      process.exit(1);
    }
  }
  intents = JSON.parse(await readFile(new URL("./intents.json", import.meta.url), "utf8"));

  createServer(async (req, res) => {
    const json = (code, body) => {
      res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify(body, null, 2));
    };
    if (req.method === "GET" && req.url === "/api/agent/state") return json(200, publicState());
    if (req.method === "POST" && req.url === "/api/agent/tick") {
      await tick();
      return json(200, publicState());
    }
    json(404, { error: "not found" });
  }).listen(PORT, () => {
    console.log(`agent loop on http://localhost:${PORT}  (tick ${TICK_MS}ms)`);
    console.log(`  state: curl -s localhost:${PORT}/api/agent/state | jq`);
    tick();
    setInterval(tick, TICK_MS);
  });
}
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `cd agent && node --test loop.test.mjs`
Expected: PASS, 10 tests.

- [ ] **Step 6: Run every check together**

```bash
cd agent && node --test && node check-reason-table.mjs
```
Expected: all suites pass and `all 13 codes agree`. The count is **51 tests across five
files** — reason 4, decide 16, subgraph 12, send 9, loop 10 (reason and subgraph grew in
their fix rounds; loop grew from 7 to 10 fixing the timeout duplicate-payment path). If your
total differs, say so
rather than assuming the plan is right: this number is the plan author's arithmetic, not a
measurement.

- [ ] **Step 7: Prove the duplicate-payment guard is load-bearing**

Remove the `else if (prev.inFlight)` branch from `advance`, run `node --test loop.test.mjs`, and confirm `an in-flight intent is not queued again - this is what stops duplicate payments` goes RED. Then remove the `prev.lastAction?.outcome === "executed"` branch and confirm `an executed intent is terminal and never sent again` goes RED. Revert both and re-run. Report both failures — these two guards are the difference between one payment and a drained budget.

- [ ] **Step 8: Write `agent/README.md`**

```markdown
# The agent decision loop

Sprint item 10. Reads the subgraph, decides whether each payment in `intents.json` will be
allowed, sends only the ones it believes will pass, and publishes its reasoning.

```bash
ENV=/home/ubuntu/DEV/ETHOnline2026/.env
get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2-; }
AGENT_PK="$(get AGENT_PK)" SEPOLIA_RPC="$(get SEPOLIA_RPC)" \
WALLET_ADDR="$(get WALLET_ADDR)" AGENT_ADDR="$(get AGENT_ADDR)" \
LEASH_NODE=0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121 \
  node loop.mjs

curl -s localhost:8788/api/agent/state | jq     # what it currently believes
curl -s -X POST localhost:8788/api/agent/tick   # run one cycle now, do not wait
```

Extract single variables as above. **Never source `.env` wholesale** — it also holds
`WALLET_PK` and `WORLD_RP_SIGNER_PK`, and this process must hold neither.

## Three things that surprise people

**A block is not a revert.** `LeashAccount` emits `SpendBlocked` and returns normally so the
subgraph can index it. A transaction that "succeeded" may have moved no money — the outcome
is in the logs.

**Restarting re-arms every payment.** Intents are one-shot and that state is in memory, so a
restart makes every executed intent eligible again. That is the intended reset before a
rehearsal, and it is also how you accidentally pay twice.

**A timed-out send leaves an intent `unconfirmed`, not retried.** `send.mjs` waits up to 120s
(ten Sepolia blocks) for a receipt; if that times out, the transaction hash is real but no
outcome was ever classified. The verdict becomes `unconfirmed`, the hash is in
`lastAction.tx`, and the agent will not send that intent again on its own — the payment may
still land, so guessing wrong risks paying it twice. Look the hash up and resolve it by
hand.

## What it cannot predict

Five reason codes are not in the index — 5 `TOKEN_NOT_ALLOWED`, 7 `OVER_TX_LIMIT`,
9 `OUTSIDE_TIME_WINDOW`, 10 `PAUSED`, 11 `OVER_SHARED_LIMIT` — plus 12 `POLICY_FAILED`. For
those the verdict is `unknown` and the agent sends, letting the chain answer. `will-pass`
means "I found nothing forbidding it", never "this will succeed": `Payee.allowed` is not
per-token, so the agent can be optimistic and the contract is what stops it. When that
happens the outcome reads `blocked-despite-green`.
```

- [ ] **Step 9: Live run — requires explicit human authorisation**

This sends real Sepolia transactions and moves real MockUSDC out of the wallet's budget. **Ask before running it.** The budget is finite and is needed for the demo: `retainer` is 5 USDC per run against a 1000 USDC period limit.

Run the loop with the command from the README and watch two ticks. Expected:

- `retainer` → `will-pass`, then a tx, then `executed`, then `done` on every later tick.
- `newvendor` → `will-be-blocked (PAYEE_NOT_ALLOWED)` on every tick, and **never sent**.
- `curl -s localhost:8788/api/agent/state | jq` shows `source.lagBlocks` as 0 or 1.

Paste the first three ticks of output and the state JSON. Then stop the loop.

- [ ] **Step 10: Commit**

```bash
git add agent/loop.mjs agent/intents.json agent/README.md agent/loop.test.mjs
git commit -F - <<'MSG'
feat: the agent loop, its state endpoint, and the guards that matter

advance() is the pure bookkeeping half, so the two guards that keep this
from draining the budget are testable without a chain: an in-flight
intent is never queued twice, and an executed intent is terminal. The
tick is 5s and Sepolia blocks are ~12s, so without the first guard the
same payment goes out two or three times before the first confirms.

The loop holds only AGENT_PK and refuses to start without its four
variables named individually, because sourcing .env wholesale would hand
this process WALLET_PK and WORLD_RP_SIGNER_PK too.

GET /api/agent/state is the single source of truth for the frontend, so
two readers cannot contradict each other on stage; it carries both block
numbers so the index lag is a number on screen rather than silence.
MSG
```

---

## Self-review

**Spec coverage.** Decision 1 (receipt + subgraph split) → Tasks 3 and 4. Decision 2
(pre-flight) → Task 2. Decision 3 (autonomous, visible, manual trigger) → Task 5, including
`POST /api/agent/tick`. Decision 4 (one endpoint) → Task 5 Step 4. Decision 5 (separate
process, one key) → Task 5's env guard and the `agent/` directory itself. One-shot intents →
Task 5 Steps 2, 4, 7. Rolled-over period → Task 2's test and mutation. Fail-closed → Task 3.
Duplicate payments → Task 5 Step 7. Reason-table pinning → Task 1. The `unknown` verdicts →
Task 2. `blocked-despite-green` → Task 5 Step 4.

**Type consistency.** `decide(snapshot, intent, nowSec)` is called with that arity in Task 5.
`fetchSnapshot(cfg, fetchImpl)` returns the shape Task 2's tests construct, including
`periodEnd` as a number. `classifyReceipt(receipt, walletAddress)` and `sendSpend({...})`
match Task 5's call sites. `advance(state, snapshot, intents, nowSec)` returns
`{ state, toSend }` as its tests expect.

**Known gap, deliberate.** `cfg.token` in Task 5's `tick()` uses `intents[0].token`, so the
budget row fetched is the first intent's token. Every intent in `intents.json` uses MockUSDC,
and `decide` returns `unknown` for any intent whose token differs from the budget's — so a
mixed-token list degrades to "ask the chain" rather than deciding wrongly. Fixing it properly
means one budget query per distinct token; not worth it for a two-intent demo, and the
failure mode is safe.
