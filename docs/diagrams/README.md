# Diagrams

Three self-contained HTML pages. Open any of them directly in a browser — no
server, no build step. Each has a light/dark toggle, pan and zoom, search,
relationship tracing, guided views, and PNG/SVG export.

| File | What it answers |
|---|---|
| [`leash-architecture.html`](leash-architecture.html) | What the components are and how they fit together |
| [`leash-spend-sequence.html`](leash-spend-sequence.html) | What happens inside one `spend()` call, first step to last |
| [`leash-demo-workflow.html`](leash-demo-workflow.html) | The demo end to end: refused → face scan → rule widened → paid |

The `.json` beside each page is its source. Regenerate with:

```bash
node bin/archify.mjs deliver <type> docs/diagrams/<name>.json docs/diagrams/<name>.html \
  --quality showcase --repo-root .
```

`leash.architecture.json` carries source evidence (`meta.repository` +
per-component `sources`), so its nodes link to the exact files at revision
`2edcde2`. That is why it needs `--repo-root`; the other two do not.
