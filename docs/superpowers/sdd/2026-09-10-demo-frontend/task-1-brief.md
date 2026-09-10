### Task 1: Widen the agent's state payload

**Files:**
- Modify: `agent/loop.mjs:143` (the record), `agent/loop.mjs:253-275` (`publicState`), and its one call site
- Test: `agent/loop.test.mjs` (append only)

**Interfaces:**
- Consumes: nothing
- Produces: `publicState(state)` — now an **exported function taking state as a parameter**, returning the object below. Tasks 4 and 5 render exactly this shape.

```
{ tick, at, source, readError, tickError,
  agent, subname, policy, budget,
  payees: { "<lowercase addr>": { allowed: boolean, lastToken: string|null } },
  intents: [{ id, note, payee, token, amount,
              verdict, reason, reasonName, explain, lastAction }] }
```

- [ ] **Step 1: Write the failing tests**

Append to `agent/loop.test.mjs`:

```js
import { publicState } from "./loop.mjs";

test("a record carries the intent's payee, token and amount", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const rec = state.intents.a;
  assert.equal(rec.payee, PAYEE);
  assert.equal(rec.token, TOKEN);
  assert.equal(rec.amount, "5000000");
});

test("those three survive a second tick without being recomputed away", () => {
  const first = advance(initialState(), okSnap(), intents, NOW).state;
  const second = advance(first, okSnap(), intents, NOW + 5).state;
  assert.equal(second.intents.a.payee, PAYEE);
  assert.equal(second.intents.a.amount, "5000000");
});

test("publicState forwards the payee allow-list", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const pub = publicState(state);
  assert.equal(pub.payees[PAYEE].allowed, true);
});

test("publicState publishes the three new intent fields", () => {
  const { state } = advance(initialState(), okSnap(), intents, NOW);
  const i = publicState(state).intents[0];
  assert.equal(i.payee, PAYEE);
  assert.equal(i.token, TOKEN);
  assert.equal(i.amount, "5000000");
});

test("payees is an empty object when the read failed, never stale", () => {
  const good = advance(initialState(), okSnap(), intents, NOW).state;
  const bad = advance(good, { ok: false, error: "boom" }, intents, NOW + 5).state;
  assert.deepEqual(publicState(bad).payees, {});
  assert.equal(publicState(bad).readError, "boom");
});

test("an intent with no payee publishes null rather than undefined", () => {
  const bare = [{ id: "z", token: TOKEN, payee: PAYEE, amount: "1", note: "" }];
  delete bare[0].payee;
  const { state } = advance(initialState(), okSnap(), bare, NOW);
  assert.equal(publicState(state).intents[0].payee, null);
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd agent && node --test loop.test.mjs`
Expected: FAIL — `publicState` is not exported (`SyntaxError: The requested module './loop.mjs' does not provide an export named 'publicState'`).

- [ ] **Step 3: Widen the record**

`agent/loop.mjs:143`, replace:

```js
    const rec = { ...prev, id: intent.id, note: intent.note ?? "" };
```

with:

```js
    // payee/token/amount are copied onto the record so the state endpoint can say who an
    // intent pays and how much. They are inputs, not decisions: nothing below reads them,
    // and no branch in this function changes because they exist.
    const rec = {
      ...prev,
      id: intent.id,
      note: intent.note ?? "",
      payee: intent.payee ?? null,
      token: intent.token ?? null,
      amount: intent.amount ?? null,
    };
```

- [ ] **Step 4: Make `publicState` a pure function of state, and export it**

`agent/loop.mjs:253`, replace the whole function:

```js
export function publicState(s) {
  return {
    tick: s.tick,
    at: s.at,
    source: s.source,
    readError: s.readError ?? null,
    tickError: s.tickError ?? null,
    agent: s.snapshot?.agent ?? null,
    subname: s.snapshot?.subname ?? null,
    policy: s.snapshot?.policy ?? null,
    budget: s.snapshot?.budget ?? null,
    // Forwarded from the snapshot, so it is absent exactly when the read failed. Falling
    // back to `{}` rather than the previous tick's map matters: a stale allow-list on a
    // failed read would show the page a permission that may no longer exist.
    payees: s.snapshot?.payees ?? {},
    intents: Object.values(s.intents).map((i) => ({
      id: i.id,
      note: i.note,
      payee: i.payee ?? null,
      token: i.token ?? null,
      amount: i.amount ?? null,
      verdict: i.verdict ?? null,
      reason: i.reason ?? null,
      reasonName: i.reasonName ?? null,
      explain: i.explain ?? null,
      lastAction: i.lastAction ?? null,
    })),
  };
}
```

Then fix the single call site (`agent/loop.mjs:405`):

```js
      if (req.method === "GET" && pathname === "/api/agent/state") return json(200, publicState(state));
```

- [ ] **Step 5: Run the whole agent suite**

Run: `cd agent && node --test`
Expected: PASS — **78 tests, 0 fail** (72 before, 6 added). If any pre-existing test fails, a branch was changed; revert and redo Step 3 as a pure addition.

- [ ] **Step 6: Commit**

```bash
git add agent/loop.mjs agent/loop.test.mjs
git commit -m "feat: publish the payee, amount and allow-list the demo page needs"
```

---

