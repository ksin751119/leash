### Task 5: `world/demo.html` — the page

**Files:**
- Create: `world/demo.html`

**Interfaces:**
- Consumes: `demo-render.mjs` (Task 4), `GET /api/widen-plan` (Task 3), `GET /api/config` and `POST /api/attest` (existing), `GET http://localhost:8788/api/agent/state` (Task 1)
- Produces: nothing other tasks consume

**Read `world/index.html` first.** Its IDKit boot sequence (`/api/config` → `IDKit.init` → `IDKit.open`) is the working reference and must be copied in shape, not reinvented. In particular `handleVerify(proof, signal)` takes the signal as a parameter rather than re-reading it, so the proof cannot be bound to a different value than the one shown.

- [ ] **Step 1: Write the page**

Create `world/demo.html`. Requirements it must satisfy, all of them checked in Step 2:

1. Two fixed columns: AGENT on the left, RULES on the right. Neither scrolls at 1280×720.
2. Body text ≥ 16px at 1280×720; verdicts carried by a **word and** a colour, never colour alone.
3. Polls `http://localhost:8788/api/agent/state` every 1000 ms and renders via `demo-render.mjs`.
4. Shows tick, timestamp, and the index lag from `renderStatus`.
5. A `readError` paints a banner reading **"the agent is blind — it will propose nothing"**; the intent list dims.
6. Each intent shows: id, note, `payeeShort`, amount in USDC, the verdict word, and — when blocked — `reasonLabel`.
7. The RULES column shows `policyShort` with an approved/unapproved badge, the budget bar (`pct`), and the payee list.
8. The blocked intent is joined to the payee list by a visible connector.
9. A button, enabled only when some intent is `will-be-blocked` with `reason === 6`, that runs the widening flow.

The widening flow, in order:

```js
// 1. Ask the server what this widening's digest is.
const plan = await (await fetch(
  `/api/widen-plan?payee=${encodeURIComponent(intent.payee)}&token=${encodeURIComponent(intent.token)}`
)).json();

// 2. Bind the scan to that digest. `signal` is passed to handleVerify rather than re-read,
//    exactly as world/index.html does, so the proof cannot end up bound to another value.
const cfg = await (await fetch("/api/config")).json();
IDKit.init({
  app_id: cfg.app_id,
  action: cfg.action,
  signal: plan.digest,
  verification_level: "selfieCheckLegacy",
  handleVerify: (proof) => handleVerify(proof, plan.digest),
  onSuccess: () => {},
});
IDKit.open();

// 3. Exchange the proof for an attestation. The server signs only after World returns 200.
async function handleVerify(proof, digest) {
  const r = await fetch("/api/attest", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ digest, proof }),
  });
  const body = await r.json();
  if (!r.ok) throw new Error(body.error ?? `attest failed: HTTP ${r.status}`);
  // 4. Substitute the blob into the command. A string replace, not a decision.
  showCommand(plan.command.replace("$ATTESTATION", body.attestation), body.deadline);
}
```

10. After a successful scan the page shows the finished command with a copy button, and the countdown `signed · valid for 15 min · run the command`.
11. While the payee is still absent from `payees`, show `subgraph is N blocks behind` from `renderStatus().lag`, then `next tick in 3… 2… 1` derived from `tick` and `at`.
12. **The page never fetches an RPC and never asks for a transaction hash.**

- [ ] **Step 2: Verify what can be verified without a browser**

```bash
cd world && node server.mjs &
sleep 1
curl -s localhost:8787/ | grep -c "demo-render.mjs"          # 1 — the module is imported
curl -s -o /dev/null -w "%{http_code}\n" localhost:8787/demo-render.mjs   # 200
curl -s localhost:8787/demo-render.mjs | head -3              # real JS, not HTML
node --input-type=module -e 'await import("./demo-render.mjs")' # parses
kill %1
```

Expected: `1`, `200`, JavaScript source, no import error.

Then grep the page for the constraints that a human reviewer would otherwise have to eyeball:

```bash
grep -c "8788/api/agent/state" world/demo.html   # 1
grep -c "eth_call\|jsonrpc" world/demo.html      # 0 — the page never talks to an RPC
grep -c "WALLET_PK" world/demo.html              # 0 — no key, not even the name
grep -ci "selfieCheckLegacy" world/demo.html     # 1 — not proofOfHuman
```

- [ ] **Step 3: Commit**

```bash
git add world/demo.html
git commit -m "feat: the demo page — the agent's reasoning and the face scan on one screen"
```

- [ ] **Step 4: Hand back for visual review**

There is no Chrome here, so the layout has **not** been seen. Report that plainly and list what a human must check:

- readable at 1280×720 full screen
- nothing scrolls, nothing reflows when a verdict flips
- the connector actually lands on the payee row
- light and dark both legible

---

## Self-Review

**1. Spec coverage.**

| Spec requirement | Task |
|---|---|
| Page served at `:8787`, harness to `/harness` | 3 |
| Polls `:8788`, no CORS change | 1, 5 |
| `publicState()` gains `payees` + three intent fields | 1 |
| No branch in `advance()` changes | 1 (Step 5 asserts 72 pre-existing tests still pass) |
| `GET /api/widen-plan` contract | 2, 3 |
| Command carries `$WALLET_PK` as a name | 2 (Step 5 proves the test is non-vacuous) |
| RPC errors redact url and hostname | 2 |
| Env guard mirroring `checkAttestEnv` | 2, 3 |
| Two fixed columns, 720p legibility | 5 |
| The wait made legible | 5 (items 11) |
| Errors shown, never swallowed | 4 (`renderStatus.blind`), 5 (item 5) |
| Render functions testable without a browser | 4 |
| No new dependency | 2 (`@noble/hashes` only) |

**2. Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". Task 5's HTML is specified as numbered requirements plus the exact widening-flow code, because the markup and CSS are the part a fresh implementer should be free to write well; every behaviour that could be got wrong is either code here or a grep in Step 2.

**3. Type consistency.** `publicState(s)` (Task 1) → `renderStatus/renderIntent/renderRules(s, payees)` (Task 4) → consumed in Task 5. `widenPlan({payee, token, env, nonce, fetchImpl})` returns `{status, body}` in Task 2 and is destructured as `{status, body}` in Task 3. `buildCommand` emits `$ATTESTATION`; Task 5 replaces exactly that token. `payees` is keyed lowercase in `agent/subgraph.mjs` and `renderIntent` lowercases before lookup.
