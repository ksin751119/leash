# Task 1 report: widen the agent's state payload

## What changed and where

`agent/loop.mjs`:

1. **`advance()`'s record widening** (was `agent/loop.mjs:143`, inside the `for (const intent of intents)` loop). Replaced
   `const rec = { ...prev, id: intent.id, note: intent.note ?? "" };` with a version that also copies
   `payee: intent.payee ?? null`, `token: intent.token ?? null`, `amount: intent.amount ?? null` onto the record, with a
   comment noting these are inputs, not decisions, and that no branch below reads them. Nothing else in the loop body
   was touched — no branch, condition, or the executed/unconfirmed/inFlight/decide ordering changed. Verified via
   `git diff agent/loop.mjs` (included below) that this is a pure addition to the object literal.

2. **`publicState`** (was `agent/loop.mjs:253`). Changed from a module-private `function publicState()` that closed over
   the module-level `state` variable via `const s = state;`, to `export function publicState(s)`, a pure function of its
   argument. Added `payees: s.snapshot?.payees ?? {}` (falls back to `{}`, never to a previous tick's map, per the
   constraint — commented why: a stale allow-list on a failed read would show a permission that may no longer exist)
   and, in the per-intent map, `payee`, `token`, `amount` (each `?? null`) alongside the existing fields.

3. **Call sites.** The brief said there was "exactly one call site" at `agent/loop.mjs:405`, but the actual file has
   **two**: the `GET /api/agent/state` handler and the `POST /api/agent/tick` handler (after `await tick()` succeeds),
   both originally calling `publicState()` with no argument. Since `publicState` is now a pure function reading its
   argument instead of closing over module state, leaving the second call site unfixed would have made the tick
   endpoint throw (`s.tick` on `undefined`). I updated both to `publicState(state)`, reading the module-level `state`
   variable that `tick()` reassigns. This is a mechanical consequence of the signature change, not a design decision —
   flagging it since it's a place where the brief's description of the code didn't match the code.

`agent/loop.test.mjs`:

- Extended the existing `import { ... } from "./loop.mjs"` on line 3 to add `publicState` (rather than a second import
  line — brief said either is fine).
- Appended the six tests from the brief's Step 1 verbatim, after the existing `routePath` tests at the end of the file.
  No existing test was edited.

## Test command and output

Baseline (before any change): `cd agent && node --test` → `tests 72`, `pass 72`, `fail 0`.

After changes: `cd agent && node --test`

```
ℹ tests 78
ℹ suites 0
ℹ pass 78
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
```

All 6 new tests pass by name:
- `a record carries the intent's payee, token and amount`
- `those three survive a second tick without being recomputed away`
- `publicState forwards the payee allow-list`
- `publicState publishes the three new intent fields`
- `payees is an empty object when the read failed, never stale`
- `an intent with no payee publishes null rather than undefined`

All 72 pre-existing tests still pass (no regressions), confirming Step 3 was a pure addition.

## Diff (agent/loop.mjs)

```diff
@@ -140,7 +140,17 @@ export function advance(state, snapshot, intents, nowSec) {
   const queued = new Set();
   for (const intent of intents) {
     const prev = next.intents[intent.id] ?? { inFlight: false, lastAction: null };
-    const rec = { ...prev, id: intent.id, note: intent.note ?? "" };
+    // payee/token/amount are copied onto the record so the state endpoint can say who an
+    // intent pays and how much. They are inputs, not decisions: nothing below reads them,
+    // and no branch in this function changes because they exist.
+    const rec = {
+      ...prev,
+      id: intent.id,
+      note: intent.note ?? "",
+      payee: intent.payee ?? null,
+      token: intent.token ?? null,
+      amount: intent.amount ?? null,
+    };
 
     if (prev.lastAction?.outcome === "executed") {
       ...
@@ -250,8 +260,7 @@
 let AGENT_PK, SEPOLIA_RPC, WALLET_ADDR, AGENT_ADDR, LEASH_NODE;
 
-function publicState() {
-  const s = state;
+export function publicState(s) {
   return {
     tick: s.tick,
     at: s.at,
@@ -262,9 +271,16 @@
     subname: s.snapshot?.subname ?? null,
     policy: s.snapshot?.policy ?? null,
     budget: s.snapshot?.budget ?? null,
+    // Forwarded from the snapshot, so it is absent exactly when the read failed. Falling
+    // back to `{}` rather than the previous tick's map matters: a stale allow-list on a
+    // failed read would show the page a permission that may no longer exist.
+    payees: s.snapshot?.payees ?? {},
     intents: Object.values(s.intents).map((i) => ({
       id: i.id,
       note: i.note,
+      payee: i.payee ?? null,
+      token: i.token ?? null,
+      amount: i.amount ?? null,
       verdict: i.verdict ?? null,
       reason: i.reason ?? null,
       reasonName: i.reasonName ?? null,
@@ -402,7 +418,7 @@ if (isMain) {
     try {
       const pathname = routePath(req.url);
-      if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState());
+      if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState(state));
       if (req.method === "POST" && pathname === "/api/agent/tick") {
         try {
           await tick();
@@ -411,7 +427,7 @@ if (isMain) {
           return json(500, { error: String(err?.message ?? err) });
         }
-        return json(200, publicState());
+        return json(200, publicState(state));
       }
```

## What I was unsure about

- **Two call sites vs. the brief's "one".** Covered above under item 3. I resolved this by fixing both, since the
  alternative (fixing only the `GET` handler as literally shown) would leave the `POST /api/agent/tick` response
  throwing on the very next request. There's no existing test exercising the live HTTP server for this path (the
  suite tests `advance`/`publicState`/`routePath` etc. as pure functions, not the `http.createServer` handler), so
  this wouldn't have shown up as a red test — it would only have surfaced at runtime, which is exactly the kind of
  gap Tasks 4/5 (the actual demo page hitting these endpoints) would have hit. Flagging this explicitly since it's a
  case where I extended past the brief's literal text based on what the surrounding code actually does.

- Everything else in the brief (record shape, `publicState` return shape, payees fallback, the six tests) I followed
  verbatim — no other judgment calls were needed.

## What I noticed but did not change

- `tick()`'s catch block (`agent/loop.mjs:~322`, "Backstop... a throw here degrades to a visible tickError") sets
  `state.tickError = String(...)` by mutating the module-level `state` object directly rather than going through
  `advance()`. This is pre-existing behavior, out of scope for this task, and untouched by my diff — noting it only
  because it's adjacent to the code I read closely.
- No other duplicate-payment-relevant branch, and no other call site of `publicState`, exists in `agent/loop.mjs`
  (confirmed via `grep -n "publicState" agent/loop.mjs` both before and after the edit — two call sites total, both
  now fixed).
- Did not touch `agent/package.json` — no new dependency was needed.
