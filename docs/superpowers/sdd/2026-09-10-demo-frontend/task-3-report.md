# Task 3 report: wire the routes into `world/server.mjs`

## Summary

Followed `task-3-brief.md` verbatim. All five diff snippets from the brief were applied
to `world/server.mjs` exactly as given, in the order specified. Commit `80297d5`.

## Routes added/changed

1. **Import** — added `import { widenPlan, checkWidenEnv } from "./widen-plan.mjs";`
   beside the existing `attest.mjs` import.

2. **`GET /`** — REPLACED (not shadowed). Previously served `index.html`; now serves
   `demo.html` via `readFile(new URL("./demo.html", import.meta.url))`. This is the only
   handler for `req.url === "/" || req.url.startsWith("/?")`, and it appears first in the
   handler chain, exactly where the old one was.

3. **`GET /harness`** (new) — serves `index.html` (the old harness content, unchanged),
   matching `/harness` or `/harness?...`.

4. **`GET /demo-render.mjs`** (new) — serves `demo-render.mjs` with
   `Content-Type: text/javascript; charset=utf-8`.

5. **`GET /api/widen-plan`** (new) — placed directly after `/api/attest`, before the
   `404` fallback. Parses `payee` and `token` from the query string via
   `new URL(req.url, "http://localhost").searchParams`, derives `nonce` server-side as
   `Math.floor(Date.now() / 1000)` (never read from the query string, per the constraint),
   passes `env: process.env`, and forwards `widenPlan`'s `{status, body}` straight to the
   existing `json()` helper. No `fetchImpl` passed, so it defaults to global `fetch`.

6. **Boot warning** — inside the `server.listen` callback, after the existing console
   logs: calls `checkWidenEnv(process.env)` and `console.warn`s a one-line message naming
   the missing/malformed var if any, without printing values.

`world/index.html` was not touched. `world/package.json` was not touched — dependency set
is still exactly `@noble/curves` + `@noble/hashes`.

## Commands run and output

Syntax check:
```
$ node --check world/server.mjs
SYNTAX OK
```

`npm install` was needed first — `world/node_modules` did not have the noble packages
resolvable by this Node version (`ERR_MODULE_NOT_FOUND '@noble/curves'` on first server
start). Ran `npm install --no-audit --no-fund` inside `world/`; it added 2 packages and
did not touch `package.json` or create a lockfile diff. `world/node_modules` is
gitignored (confirmed via `git check-ignore -v`), so nothing stray got staged.

Step 5 verification, without any World/chain env loaded:
```
200 harness
500 demo                  (ENOENT on demo.html — expected, Task 5 not done yet)
500 demo-render.mjs       (ENOENT — expected, Task 4 not done yet)

$ curl -s ".../api/widen-plan?payee=0xnope&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39"
{"error":"payee must be 0x + 40 hex chars"}

$ curl -s ".../api/widen-plan?payee=0x00000000000000000000000000000000000cafe0&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39"
{"error":"SEPOLIA_RPC not set"}
```
Boot log (no `.env` loaded) printed:
```
⚠ /api/widen-plan is unavailable: SEPOLIA_RPC not set
```
followed by the two expected ENOENT stack traces from the `/` and `/demo-render.mjs`
requests, caught by the outer try/catch and turned into the 500s above.

End-to-end verification with the real chain, env loaded as instructed (`.env` sourced in
a subshell, `WALLET_ADDR` and `LEASH_NODE` exported, values never echoed or logged):
- Boot log printed no `⚠ /api/widen-plan is unavailable` line (env complete).
- `GET /api/widen-plan?payee=0x00000000000000000000000000000000000cafe0&token=0x768f42455a2d082e23ceef7d51e5787c82d67a39`
  returned 200 with `digest`, `nonce` (a real `Date.now()`-derived value), `node`, `token`,
  `payee`, and `command`. The `command` string contains the literal substrings
  `$WALLET_PK` and `$ATTESTATION` (shell variable names, not resolved) and no RPC URL.
- Separately called `widenPlan` directly (not through the route, so I could pin
  `nonce: 7`) with the same `payee`/`token`/env, to check against the brief's known-good
  value:
  ```
  $ node -e 'import("./widen-plan.mjs").then(({widenPlan}) => widenPlan({..., nonce: 7}).then(r => console.log(r.body.digest)))'
  "0x95746f35c6bf6e05d1b7ca05aa7d6b5c4c7df160b8b8dc73d8d128cbd8e0e6a0"
  ```
  This matches the brief's expected digest for nonce 7 exactly, confirming the route's
  plumbing (env → `widenPlan` → RPC → response) is wired correctly; the live route itself
  necessarily produces a different digest because its nonce is `Date.now()`-derived, not 7.

All server processes were started/killed cleanly in background subshells; no secret
values were printed to this transcript at any point.

## Uncertain about / noted but did not change

- `npm install` was required to get the server running at all (missing `node_modules`
  resolution) — this looks like local environment setup, not something Task 3 should fix
  in the repo, so I only ran it locally and did not touch `package.json` or add a
  lockfile.
- The brief's Step 5 curl commands don't `set -a`/source env first, so run as literally
  written they'd hit the `SEPOLIA_RPC not set` 500 branch rather than a real digest — I
  verified both that guard path (no env) and the real success path (env loaded per the
  task instructions), plus the nonce-7 digest match, since the task instructions said to
  verify with the real chain when possible.
- Did not create `demo.html` or `demo-render.mjs` stubs; left the two routes 500ing as
  instructed — that's Task 4/5's job.
