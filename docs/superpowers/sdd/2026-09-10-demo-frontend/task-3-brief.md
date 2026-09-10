### Task 3: Wire the routes into `world/server.mjs`

**Files:**
- Modify: `world/server.mjs`

**Interfaces:**
- Consumes: `checkWidenEnv`, `widenPlan` from Task 2
- Produces: `GET /` (demo), `GET /harness` (old page), `GET /demo-render.mjs`, `GET /api/widen-plan`

- [ ] **Step 1: Add the import**

At the top of `world/server.mjs`, beside the existing `attest.mjs` import:

```js
import { widenPlan, checkWidenEnv } from "./widen-plan.mjs";
```

- [ ] **Step 2: Move the harness and serve the demo**

Replace the existing `GET /` handler:

```js
    // The demo page is the front door: during judging this is what is on screen. The
    // harness stays reachable at /harness because it is the tool you reach for when the
    // demo misbehaves, and losing it would cost the fallback.
    if (req.method === "GET" && (req.url === "/" || req.url.startsWith("/?"))) {
      const html = await readFile(new URL("./demo.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (req.method === "GET" && (req.url === "/harness" || req.url.startsWith("/harness?"))) {
      const html = await readFile(new URL("./index.html", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    // demo.html imports this as an ES module, so it needs a JavaScript content type.
    if (req.method === "GET" && req.url === "/demo-render.mjs") {
      const js = await readFile(new URL("./demo-render.mjs", import.meta.url));
      res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" });
      return res.end(js);
    }
```

- [ ] **Step 3: Add the widen-plan route**

Place it beside `/api/attest`:

```js
    if (req.method === "GET" && req.url.startsWith("/api/widen-plan")) {
      const q = new URL(req.url, "http://localhost").searchParams;
      const { status, body } = await widenPlan({
        payee: q.get("payee"),
        token: q.get("token"),
        env: process.env,
        nonce: Math.floor(Date.now() / 1000),
      });
      return json(res, status, body);
    }
```

- [ ] **Step 4: Warn at boot**

Inside the existing `server.listen(PORT, "127.0.0.1", () => { … })` callback, after the URLs it already prints:

```js
  // Not fatal: /api/config, /api/precheck and /harness still work without these, and
  // finding out mid-demo is worse than a line at boot. The route itself still refuses with
  // a 500, so it can never half-work.
  const widenErr = checkWidenEnv(process.env);
  if (widenErr) console.warn(`⚠ /api/widen-plan is unavailable: ${widenErr}`);
```

- [ ] **Step 5: Verify by hand**

```bash
cd world && node server.mjs &
sleep 1
curl -s -o /dev/null -w "%{http_code} harness\n" localhost:8787/harness
curl -s "localhost:8787/api/widen-plan?payee=0xnope&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39"
curl -s "localhost:8787/api/widen-plan?payee=0x00000000000000000000000000000000000cafe0&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39" | head -20
kill %1
```

Expected: `200 harness`; the malformed payee returns `{"error":"payee must be 0x + 40 hex chars"}`; the good call returns a `digest`, a `nonce` and a `command` (or a `500` naming the missing env var if `.env` is not loaded — that is the guard working).

`GET /` throws ENOENT on the missing `demo.html` until Task 5, which the outer try/catch turns into a 500. That is expected at this point.

- [ ] **Step 6: Commit**

```bash
git add world/server.mjs
git commit -m "feat: serve the demo at /, move the harness to /harness, add the widen-plan route"
```

---

