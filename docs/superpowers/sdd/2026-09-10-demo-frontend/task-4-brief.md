### Task 4: `world/demo-render.mjs` — turning state into display strings

**Files:**
- Create: `world/demo-render.mjs`, `world/demo-render.test.mjs`

**Interfaces:**
- Consumes: the `publicState(state)` shape from Task 1
- Produces:
  - `shortHex(h) -> string`
  - `formatUsdc(raw) -> string`
  - `renderStatus(s) -> { tick, at, lag, blind, error }`
  - `renderIntent(intent, payees) -> { id, note, payee, payeeShort, payeeAllowed, amount, verdict, tone, reasonLabel, explain, tx }`
  - `renderRules(s) -> { policy, policyShort, approved, spent, limit, pct, payees: [{ addr, short, allowed }] }`

- [ ] **Step 1: Write the failing tests**

Create `world/demo-render.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { shortHex, formatUsdc, renderStatus, renderIntent, renderRules } from "./demo-render.mjs";

const PAYEE = "0x00000000000000000000000000000000000cafe0";
const TOKEN = "0x768f42455a2d082e23ceef7d51e5787c82d67a39";

const state = () => ({
  tick: 47,
  at: "2026-09-10T12:00:00.000Z",
  source: { subgraphBlock: 11667861, chainBlock: 11667863, lagBlocks: 2 },
  readError: null,
  tickError: null,
  policy: { address: "0x88f2bff031bb4cf2beaa28d47ada52ebeebbc33b", approved: true },
  budget: { token: TOKEN, limit: "1000000000", spent: "310000000", periodEnd: 0 },
  payees: { "0x000000000000000000000000000000000000beef": { allowed: true, lastToken: TOKEN } },
  intents: [],
});

test("shortHex keeps both ends", () => {
  assert.equal(shortHex(PAYEE), "0x0000…cafe0");
  assert.equal(shortHex(null), "—");
});

test("formatUsdc divides by 1e6 and keeps two places", () => {
  assert.equal(formatUsdc("5000000"), "5.00");
  assert.equal(formatUsdc("310000000"), "310.00");
  assert.equal(formatUsdc("1"), "0.00");
  assert.equal(formatUsdc(null), "—");
});

test("renderStatus reports the index lag", () => {
  const r = renderStatus(state());
  assert.equal(r.tick, 47);
  assert.equal(r.lag, "2 blocks behind");
  assert.equal(r.blind, false);
});

test("renderStatus says the agent is blind on a read error", () => {
  const r = renderStatus({ ...state(), readError: "subgraph unreachable: <redacted>" });
  assert.equal(r.blind, true);
  assert.match(r.error, /unreachable/);
});

test("a will-pass intent is toned positive", () => {
  const i = renderIntent(
    { id: "retainer", note: "n", payee: PAYEE, token: TOKEN, amount: "5000000",
      verdict: "will-pass", reason: null, reasonName: null, explain: "e", lastAction: null },
    {},
  );
  assert.equal(i.verdict, "will-pass");
  assert.equal(i.tone, "ok");
  assert.equal(i.amount, "5.00");
  assert.equal(i.reasonLabel, null);
});

test("a blocked intent carries its numbered reason", () => {
  const i = renderIntent(
    { id: "newvendor", note: "n", payee: PAYEE, token: TOKEN, amount: "5000000",
      verdict: "will-be-blocked", reason: 6, reasonName: "PAYEE_NOT_ALLOWED",
      explain: "e", lastAction: null },
    {},
  );
  assert.equal(i.tone, "blocked");
  assert.equal(i.reasonLabel, "6 · PAYEE_NOT_ALLOWED");
});

test("an intent's payee is allowed only when the map says so", () => {
  const base = { id: "x", note: "", payee: PAYEE, token: TOKEN, amount: "1",
                 verdict: "will-pass", reason: null, reasonName: null, explain: "", lastAction: null };
  assert.equal(renderIntent(base, {}).payeeAllowed, false);
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: true } }).payeeAllowed, true);
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: false } }).payeeAllowed, false);
});

test("the map is matched case-insensitively", () => {
  const base = { id: "x", note: "", payee: PAYEE.toUpperCase().replace("0X", "0x"),
                 token: TOKEN, amount: "1", verdict: "will-pass", reason: null,
                 reasonName: null, explain: "", lastAction: null };
  assert.equal(renderIntent(base, { [PAYEE]: { allowed: true } }).payeeAllowed, true);
});

test("a done intent shows its transaction", () => {
  const i = renderIntent(
    { id: "x", note: "", payee: PAYEE, token: TOKEN, amount: "5000000", verdict: "done",
      reason: null, reasonName: null, explain: "",
      lastAction: { kind: "sent", tx: "0x" + "12".repeat(32), outcome: "executed" } },
    {},
  );
  assert.equal(i.tone, "done");
  assert.equal(i.tx, "0x1212…21212");
});

test("renderRules computes the spent percentage", () => {
  const r = renderRules(state());
  assert.equal(r.spent, "310.00");
  assert.equal(r.limit, "1000.00");
  assert.equal(r.pct, 31);
  assert.equal(r.approved, true);
  assert.equal(r.payees.length, 1);
  assert.equal(r.payees[0].allowed, true);
});

test("renderRules survives a null budget and a null policy", () => {
  const r = renderRules({ ...state(), budget: null, policy: null, payees: {} });
  assert.equal(r.limit, "—");
  assert.equal(r.pct, 0);
  assert.equal(r.policyShort, "—");
  assert.equal(r.approved, false);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd world && node --test demo-render.test.mjs`
Expected: FAIL — `Cannot find module './demo-render.mjs'`.

- [ ] **Step 3: Write the module**

Create `world/demo-render.mjs`:

```js
// Pure functions from `publicState()` to the strings the page prints.
//
// They live in their own module for one reason: **there is no browser on the build
// machine**, so the layout's logic has to be testable without one. Nothing here decides
// anything — every verdict, reason and explanation is copied out of what the agent already
// published. If a judgement ever appears in this file, the demo has started faking the one
// thing it exists to show.

export const shortHex = (h) =>
  typeof h === "string" && h.length > 12 ? `${h.slice(0, 6)}…${h.slice(-5)}` : (h ?? "—");

// USDC is 6 decimals. Integer arithmetic on BigInt, because the amounts are strings from
// the chain and Number() would start rounding at ~9 billion units.
export function formatUsdc(raw) {
  if (raw == null) return "—";
  try {
    const units = BigInt(raw);
    const whole = units / 1000000n;
    const cents = (units % 1000000n) / 10000n;
    return `${whole}.${String(cents).padStart(2, "0")}`;
  } catch {
    return "—";
  }
}

export function renderStatus(s) {
  const lag = s.source?.lagBlocks;
  return {
    tick: s.tick,
    at: s.at,
    lag: lag == null ? "—" : lag === 0 ? "up to date" : `${lag} block${lag === 1 ? "" : "s"} behind`,
    blind: Boolean(s.readError),
    error: s.readError ?? s.tickError ?? null,
  };
}

const TONE = {
  "will-pass": "ok",
  "will-be-blocked": "blocked",
  done: "done",
  "in-flight": "pending",
  unconfirmed: "pending",
  unknown: "unknown",
  invalid: "blocked",
};

export function renderIntent(intent, payees) {
  const key = String(intent.payee ?? "").toLowerCase();
  return {
    id: intent.id,
    note: intent.note ?? "",
    payee: intent.payee ?? null,
    payeeShort: shortHex(intent.payee),
    // Absent from the map means never allow-listed — the subgraph writes no Payee entity
    // until one exists — which is also how decide() reads it.
    payeeAllowed: payees?.[key]?.allowed === true,
    amount: formatUsdc(intent.amount),
    verdict: intent.verdict ?? "unknown",
    tone: TONE[intent.verdict] ?? "unknown",
    reasonLabel: intent.reason == null ? null : `${intent.reason} · ${intent.reasonName ?? "?"}`,
    explain: intent.explain ?? "",
    tx: intent.lastAction?.tx ? shortHex(intent.lastAction.tx) : null,
  };
}

export function renderRules(s) {
  const limit = s.budget?.limit ?? null;
  const spent = s.budget?.spent ?? null;
  let pct = 0;
  try {
    if (limit != null && BigInt(limit) > 0n) {
      pct = Number((BigInt(spent ?? 0) * 100n) / BigInt(limit));
    }
  } catch {
    pct = 0;
  }
  return {
    policy: s.policy?.address ?? null,
    policyShort: shortHex(s.policy?.address ?? null),
    approved: s.policy?.approved === true,
    spent: formatUsdc(spent),
    limit: formatUsdc(limit),
    pct,
    payees: Object.entries(s.payees ?? {}).map(([addr, v]) => ({
      addr,
      short: shortHex(addr),
      allowed: v?.allowed === true,
    })),
  };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd world && node --test demo-render.test.mjs`
Expected: PASS — 11 tests, 0 fail.

Then run everything in `world/`: `cd world && node --test`
Expected: PASS — 24 tests (13 from Task 2 + 11 here), 0 fail.

- [ ] **Step 5: Commit**

```bash
git add world/demo-render.mjs world/demo-render.test.mjs
git commit -m "feat: pure render functions, so the layout is testable without a browser"
```

---

