# Task 5 report — `world/demo.html`

Commit `c9026ef` on `item-12-demo-frontend`. One new file, 758 lines, no dependency added.

---

## 1. Layout, and why it is shaped this way

### The frame

A single `grid` on `.stage` with three rows, sized to a 720px budget rather than left to
content:

| row | height | holds |
|---|---|---|
| 1 | auto (~30px) | wordmark, and the heartbeat: tick, clock, index lag |
| 2 | `minmax(0, 1fr)` (~380px) | the two columns |
| 3 | `232px` fixed | the action strip: the button and the wait on the left, the command on the right |

Row 3 is a fixed height rather than `auto` on purpose. It is empty at the start of the
video and holds a wrapped four-line `cast send` at the end; if it grew, the two columns
above would shrink at exactly the dramatic moment and every verdict on screen would jump.
Reserving the space costs an empty rectangle for the first minute and buys a page that
never moves.

`.cols` and `.act` declare the **same** grid tracks (`1.12fr 1fr`, 56px gap), so the
command block's left edge lands exactly under the RULES column and the button's under
AGENT. The 56px gutter is not decoration — it is where the connector is drawn.

### Why 232px

Worked from the widest thing that has to fit. The right track at 1280 is ~557px, minus
`#cmd` padding ~533px of text at 12px monospace ≈ 74 characters per line. The finished
command is four source lines, of which the argument line (node 66 + token 42 + payee 42 +
nonce + a 148-char attestation) wraps to five — eight visual lines at `line-height: 1.5`
≈ 139px, plus 20px padding, plus the label row, the validity line and two 8px gaps ≈ 218px.
232px leaves headroom. `#cmd` also carries `overflow-y: auto` as a safety valve: if the
arithmetic is off on a real font stack, the command scrolls inside its own box instead of
being silently clipped mid-hex, and the commented note in the CSS says which number to
change. Same valve on `#intents` and `#payees` — the columns cannot push the page past
720px no matter how many intents or payees the agent publishes.

### Nothing reflows when a verdict flips

Three deliberate fixed sizes:

- `.intent` is `height: 118px` with a four-row inner grid. The reason line is a row that
  exists whether or not there is a reason; blocked → unblocked empties its text and moves
  nothing.
- `.verdict` is `width: 192px`, centred. `WILL BE BLOCKED` (15 chars) and `WILL PASS`
  (9) occupy identical space, so the note beside it never re-flows on a flip.
- `.payee-row` is `height: 38px` for both a real row and a pending one.

Intent cards and payee rows are **reused across polls**, keyed by `id` and by lowercase
address in two `Map`s. A poll updates `textContent` on existing nodes; it never rebuilds
the list. That is what makes a flip a colour-and-word change on a node that stays put,
rather than a teardown at 1 Hz.

### The connector, and where the flip happens

Requirement 8 asked for a visible join between the blocked intent and the payee list. It
is an absolutely-positioned SVG over `.cols`: a dashed red bezier from the right edge of
the blocked intent card to the left edge of one specific payee row, with a dot at the
source and the label `not on this list` on an opaque plate (the 56px gutter is narrower
than the words, so without the plate the label would sit on top of whatever it crossed).

The row it lands on is the interesting decision. The payee that is missing gets a **ghost
row of its own**, dashed, badged `not on the list`, appended to the allow-list — keyed by
the same address the real row will have. When `cast send` lands and the subgraph indexes
it, the address appears in `payees`, the same DOM node changes its badge to `allowed` and
its border from dashed to solid, and the connector's target does not move. The list does
not grow a line and push anything down. The judge is already looking at that row, because
a red line has been pointing at it for the whole video.

`drawWire()` is pure geometry over two elements that are already on screen; which two was
decided by the agent (see §2). It is re-run after every render via `requestAnimationFrame`
and on `resize`, and hides itself when the agent is blind.

### Legibility

Body 17px, intent id 18px, amounts 17px, notes and payee addresses 15-16px, the smallest
text on the page 12px (the command) and 13px (badges, the wire label). Verdicts are a
**word first** — `WILL BE BLOCKED`, `WILL PASS`, `IN FLIGHT`, `DONE` — with colour and a
coloured left border on the card as the second and third signals. Nothing on the page is
distinguished by colour alone: every pill and every verdict carries its own text.

### One theme, deliberately

The page commits to dark and paints every colour explicitly (`color-scheme: dark`, no
`prefers-color-scheme` block). Stated in a comment at the top of the file. The reasoning:
nobody can look at this page before it is recorded, so one appearance is one appearance to
be wrong about instead of two, and the recording is made in one theme regardless. The
consequence for review is in §5 — "light and dark both legible" becomes "the single
painted theme is legible", because the host's preference has no effect.

---

## 2. The page computes nothing

Worth stating explicitly, since it is the constraint the whole demo rests on.

- Every verdict word is `renderIntent(...).verdict` uppercased with hyphens spaced. Every
  tone class is `renderIntent(...).tone`. Every reason string is `reasonLabel`. Every
  amount is `amount`, already through `formatUsdc` upstream. Every address is
  `payeeShort` / `short` / `policyShort`. The budget bar's width is `renderRules(...).pct`.
  The lag string is `renderStatus(...).lag`.
- `formatUsdc` is imported by nobody — I removed it from the import list, with a comment
  saying why: `renderIntent` and `renderRules` have already run every amount through it,
  and a second import would invite a second, divergent way to print money on one screen.
- The "pending payee" set is `views.filter(v => v.tone === "blocked" && !v.payeeAllowed)`.
  Both halves are the agent's: the tone comes from the verdict it published, and
  `payeeAllowed` is `demo-render`'s read of the allow-list it published alongside. The page
  does not ask whether the payee *ought* to be allowed.
- The widen button's target is `intents.find(i => i.verdict === "will-be-blocked" &&
  i.reason === 6 && i.payee && i.token)`. That is not re-deciding: the agent decided and
  published `reason`; this asks only "is what it objected to the thing a face scan fixes?"
- The one transformation the page performs on data it was given is
  `plan.command.replace("$ATTESTATION", body.attestation)`.
- The page's own state — "cannot reach the agent", "IDKit did not load", "waiting for the
  agent…" — is said in the page's own words and never dressed as a verdict. The agent being
  unreachable is a red dot in the heartbeat plus a message under the button; it is not
  `readError`, which is the agent's word for its own blindness.

`readError` paints the banner with the exact sentence from the brief, held as a literal in
the markup, and dims `#intents` to 32% with a grayscale filter. `tickError` alone reuses
the same banner in amber with different words, so a failed tick is visible rather than
swallowed — the verdicts on screen are from before it, and the banner says so.

---

## 3. How the wait is made legible

Item 11, and the reason it exists: the video may not be sped up, so ~15-20s of wall clock
(a ~12s Sepolia block, then the agent's 5s tick, then indexing) sits in the recording
uncut.

The strip under the button is visible **whenever a pending payee exists** — not only after
the scan. Before the scan it reads `subgraph is up to date · next tick in 3…`, which
already tells a judge the agent is alive and the index is current; after `cast send` the
same strip is the thing that fills the dead air. It has three parts:

1. `subgraph is <renderStatus().lag>` — "up to date", "2 blocks behind", verbatim from the
   agent.
2. `next tick in 5… 4… 3… 2… 1…`, then `reading the index…` while the tick is in flight.
3. A 4px bar that drains continuously over the interval, so something is moving in every
   frame rather than a number changing once a second.

The countdown is derived from `at` and the measured interval: the loop publishes `at` once
per tick, so two consecutive distinct values are one interval apart. It is measured rather
than assumed because `AGENT_TICK_MS` is the loop's env var and is not part of the published
state; 5000ms is only the fallback for the first tick. Deltas outside 0.5-60s are ignored,
so one skipped poll cannot poison the interval. A 250ms UI timer repaints the countdown and
the bar independently of the 1000ms poll, so the seconds tick down smoothly instead of in
1s jerks.

The attestation's validity is on the same principle: `#valid` holds the literal
`signed · valid for 15 min · run the command` in the markup, and `#expires` counts down
`· 14:37 left` beside it from the deadline the server returned, ending in
`· expired — scan again`.

---

## 4. Verification

Everything below was run against the committed file. There is no browser on this machine,
so these are checks of the things that would otherwise render a blank page in silence.

### The three required checks

```
$ python3 (extract inline module) && node --check /tmp/demo-inline.mjs
1 module script(s), 16502 chars
SYNTAX OK

=== check 2 ===
imported: ['renderIntent', 'renderRules', 'renderStatus', 'shortHex']
missing : none

=== check 3 ===
defined: 32 referenced: 31
referenced but never defined: none
```

(Check 3's one defined-but-unreferenced id is `tickBar`, a CSS hook for the draining bar;
its inner `#tickBarFill` is the element the script writes to.)

### The brief's Step 2

```
$ cd world && node server.mjs &
grep -c demo-render.mjs on /:  1
HTTP /demo-render.mjs:         200
// Pure functions from `publicState()` to the strings the page prints.
//
// They live in their own module for one reason: **there is no browser on the build
module imports clean
```

Note on the first line: my header comment originally named the module a second time, which
made the brief's `grep -c` print `2`. Reworded to "the render module imported below" so the
count is the `1` the brief expects and a reviewer running the command verbatim sees no
false alarm.

### The brief's constraint greps

```
8788/api/agent/state : 1
eth_call|jsonrpc     : 0
WALLET_PK            : 0
selfieCheckLegacy    : 1
proofOfHuman         : 0
```

### Test suite still green

```
$ node --test world/*.test.mjs agent/*.test.mjs
ℹ tests 105
ℹ pass 105
ℹ fail 0
```

### A render probe, since the DOM cannot be exercised

Fed `demo-render` the exact state shape the controller verified live (`0x…beef` allowed,
`0x…cafe0` absent from `payees` rather than present-and-false) and printed every field the
page reads:

- `renderStatus` → `lag: "2 blocks behind"`, `blind: false`; with `readError` set,
  `blind: true` and `error` carrying the message the banner prints.
- `retainer` → `tone: "pending"`, word `IN FLIGHT`, `0x0000…0beef`, `5.00`,
  `payeeAllowed: true`, `reasonLabel: null`, `tx: "0xabcd…bcdef"`.
- `newvendor` → `tone: "blocked"`, word `WILL BE BLOCKED`, `0x0000…cafe0`, `5.00`,
  `payeeAllowed: false`, `reasonLabel: "6 · PAYEE_NOT_ALLOWED"`.
- The pending filter yields exactly `newvendor`'s payee, and that address is confirmed
  absent from `renderRules().payees` — which is what makes the ghost row appear and the
  connector have somewhere to land.
- `renderRules` → `pct: 10`, `5.00` of `50.00`, one payee row, policy `0x1234…45678`
  approved.

So the data path from the endpoint to the strings is confirmed end to end without a
browser. What is *not* confirmed is that those strings land in the right pixels.

---

## 5. What a human must check, because I could not

There is no Chrome on this machine. **The layout has never been rendered.** Every number in
§1 is arithmetic from font metrics, not measurement. In rough order of how likely I think
each is to be wrong:

1. **The 232px action strip really holds the finished command.** Highest-risk item. If the
   system monospace is wider than I assumed, `#cmd` will scroll internally instead of
   showing all four lines. Check after a real scan, with the attestation in place — not
   with the digest placeholder, which is one short line. Fix: raise the `232px` row.
2. **The RULES column fits in the space row 2 gives it.** I budgeted ~380px against ~370px
   of content for three payee rows. A fourth allow-listed payee, or larger default fonts,
   makes `#payees` scroll. Confirm at exactly 1280×720, full screen, no browser chrome.
3. **The connector lands on the payee row**, not above or below it, and its label plate
   does not obscure the amount on the intent card or the address on the payee row. Also
   check it after the widening lands: it should disappear the moment the payee is allowed.
4. **Nothing reflows when the verdict flips.** The real test is the recording: watch
   `newvendor` go `WILL BE BLOCKED` → `WILL PASS` and confirm nothing else on screen moves
   by a pixel. If the verdict pill's 192px is too narrow for a wrapped `WILL BE BLOCKED`,
   the card will grow a line — that is the one that would ruin a take.
5. **Nothing scrolls.** No scrollbar on the body, none inside `#intents`, `#payees` or
   `#cmd`. Any scrollbar that appears is a sizing bug, not a feature — the `overflow-y`
   rules are valves, not the plan.
6. **The single dark theme is legible** on the recording's display and after 720p
   compression. Specifically: `--mut` (#8e99a8) on `--panel` (#14181d) for the note and
   explain lines, and the 12px command text. The page ignores the host's light/dark
   preference by design, so there is one rendering to check, not two — but that one has to
   hold up, and thin light-on-dark text is the first casualty of a video codec.
7. **The wait strip actually counts down.** Needs a live agent loop, which I was told not
   to start. Confirm `5… 4… 3… 2… 1…` matches the tick actually landing, and that the
   drain bar resets rather than jumping backwards.
8. **The IDKit modal opens over the page** and the World App scan completes with
   `selfieCheckLegacy`. Not runnable here at all.
9. **The copy button.** `navigator.clipboard` needs a secure context; `http://localhost`
   qualifies in Chrome, but if the page is opened through a tunnel on a non-localhost
   origin it will fall back to selecting the text and saying "selected — copy it". Worth
   one click before recording.

### One thing I deliberately did not do

The page shows `lastAction.tx` when the agent publishes one, shortened. That is a hash the
agent already published, not one the page asked anybody for — requirement 12 is about the
page never reaching for the chain, and it does not: no provider, no node url, no request
outside `localhost:8787` and the agent's state endpoint. If a reviewer reads requirement 12
more strictly than that, deleting the `tx` span is a one-line change with no layout effect
(the row it sits in is fixed-height and shared with the reason label).

---

# Fix round 1

All six Important findings fixed, all four folded Minors fixed, and the two Minors ruled
"leave" were left untouched. Nothing in the widening flow's logic changed: the digest is
still fetched before the scan, still passed to `handleVerify` as an argument, and the
substitution is still the same single `String.replace`.

## 1. Body text below 16px (`:161,172,176,180,241`)

Raised to 16px: the verdict word, `payeeShort`, `reasonLabel`, `explain`, and the wait
strip's row.

Four more readouts were at 15px and are not chrome by the same reading, so they went up
with them: the heartbeat (`.beat` — tick, clock, index lag, which is requirement 4's
data), `#widenMsg` (a full sentence of instruction), `.budget-line` (spent / limit / pct),
`#valid`, and the tagline. Flagging this as scope I added: the review named five, I changed
nine.

Left below 16px, deliberately: `.col > h2` 14, `.kv .k` 14, `.pill` 13, `#cmd` 12 (all per
the ruling), plus `#cmdLabel` 14, `#copy` 14, the wire label 13, the banner's raw error
detail 13, the `USDC` unit suffix beside a 17px number 14, and `.intent .tx` 13.

## 2. The verdict pill and the card's row budget (`:159-166`)

`white-space: nowrap` added, and the card re-budgeted against the real pill height instead
of a guess. The review's arithmetic was right and the fix makes the numbers explicit in a
comment beside them:

| row | height | tallest content |
|---|---|---|
| 1 | 30px | verdict pill: 16px x 1.2 line-height + 8 padding + 2 border = 29.2 |
| 2 | 24px | amount: 17px x 1.3 = 22.1 |
| 3 | 22px | explain: 16px x 1.3 = 20.8 |
| 4 | 22px | reason: 16px x 1.3 = 20.8 |

98px of rows in a content box of `122 - 21 padding - 2 border = 99`. `line-height` is now
pinned on `.intent .line` (1.3) and `.verdict` (1.2) rather than inherited from the body's
1.45, so those numbers are what the browser will actually use. Card height 118 -> 122; two
cards plus the banner is ~340px in a ~394px column.

`WILL BE BLOCKED` at 16px bold with `.06em` tracking is ~158px in the 192px pill.

## 3. The connector's label plate (`:574-583`)

The plate was ~100px of text centred in a ~61px gutter, painted in `--bg` — so it did not
merely overlap the amount, it erased it. Two changes:

- The label is now the single word `absent` (~42px of text, ~54px of plate), which fits.
- `drawWire` measures the gutter as `x2 - x1` and, if the plate is still wider, hides the
  label and the plate and draws the line alone. The path and the dot are shown before that
  test, so the connector itself is never at the mercy of the label.

The words are not lost: the ghost row it points at is badged `not on the list`.

## 4. Poll pile-up and out-of-order repaints (`:754`)

`inFlight` guard plus `AbortSignal.timeout(POLL_MS)`. One request at a time means responses
can only arrive in the order they were asked for, so a late one can no longer repaint an
older tick — the failure the review described, numbers jumping backwards on camera. A
timeout is reported as `cannot reach the agent — no answer in 1000ms` rather than a bare
`TimeoutError`.

## 5. `busy` latching on a dismissed modal (`:661,688,690`)

The demo-fatal one. `#widen` is now never a dead end:

- While `busy`, the button stays **enabled** and reads
  `Cancel — press if the scan did not finish`. Clicking it runs `cancelWiden()`: clears
  `busy`, calls `IDKit.close()` if that build has one (guarded), resets the command box, and
  says `scan cancelled — press the button to start a new one`.
- The label now always states the state: `Approve this payee with a face scan` /
  `Cancel — press if the scan did not finish` / `Signed — run the command`.

Cancelling resets this page and nothing else — no proof exists, the server has signed
nothing, the digest was only ever a question. If the operator completes the dismissed scan
anyway, `handleVerify` still runs and the command still appears, because the proof was bound
to that digest either way.

## 6. `signed` latching past the deadline (`:624,647,724`)

`paintExpiry` now clears `signed` at the moment the deadline passes, so the button
re-enables in the same frame the page starts saying `the attestation expired — scan again`.
It also relabels the command box `EXPIRED — THIS COMMAND WILL BE REJECTED` and hides the
copy button, since a command with a dead deadline is not something anyone should be
encouraged to paste.

The literal `signed · valid for 15 min · run the command` moved into its own `#validText`
span so the expiry message can replace it without destroying the `#expires` node beside it
(which would have thrown on the next scan). `showCommand` restores it from `VALID_TEXT`,
captured from the markup at boot, so the sentence still has exactly one source.

## Minors

- SVG now uses `var(--blocked)` / `var(--bg)` instead of hardcoded hex.
- `/api/config` is checked for `ok` and for a present `app_id`/`action`; a bad config now
  fails visibly on the page instead of inside the IDKit modal.
- The ghost row shortens `String(payee).toLowerCase()`, matching how `renderRules` shortens
  the allow-list's lowercase keys, so the address cannot change case at the flip.
- `renderStatus` runs once per state into `lastStatus`; `paintWait` reads that instead of
  recomputing at 4Hz, so the heartbeat and the countdown cannot disagree about a tick.

Left alone per the ruling: verdict formatting stays in the page, and `drawWire` is still not
bound to `#intents` scroll.

## Checks re-run

```
1 module script(s), 20953 chars      node --check -> SYNTAX OK
imported: ['renderIntent','renderRules','renderStatus','shortHex']   missing: none
defined: 33  referenced: 32          referenced but never defined: none
```

Brief greps unchanged: `8788/api/agent/state` 1, `eth_call|jsonrpc` 0, `WALLET_PK` 0,
`selfieCheckLegacy` 1. Server still serves: `/` 200 with exactly one `demo-render.mjs`
reference, `/demo-render.mjs` 200.

## What is still unseen

Everything in §5 above still stands — there is no browser here, and the fixes are arithmetic
and state machines, not renderings. Two additions to that list:

- **The cancel path.** Open the scan, dismiss World App, confirm the button says `Cancel`,
  press it, confirm a second scan starts cleanly. This is the one worth rehearsing before
  recording, because it is the failure that would end a take.
- **The connector's label.** If `absent` and its plate do not fit the real gutter, the label
  will be absent too and only the dashed line will show. That is the intended degradation,
  but check whether the line alone still reads as pointing at the ghost row.

---

# Fix round 2 — final review wave

One Important and four Minors, all in `world/demo.html`. Nothing the reviews found correct
was touched: the page still computes nothing, the signed digest is still the displayed one,
the substitution is still the one `String.replace`, and the `inFlight` guard, the cancel
escape and the card geometry are unchanged. `parts` in `drawWire` is still used at its
`for (const el of parts)` line and was left alone.

## Important — the connector could assert a cause the agent never gave

The review is right, and this is the one defect class the page exists to rule out. `pending`
selected on `tone === "blocked"`, which is true of `AGENT_REVOKED`, `POLICY_NOT_APPROVED`,
`TOKEN_NOT_ALLOWED` and `verdict: "invalid"` alike. A revoked agent would have drawn a red
line from a card reading `2 · AGENT_REVOKED` to the payee list — the page telling the viewer
the refusal was about a missing payee, which the agent never said.

Fixed the way the review preferred: **one selection, `widenable(state, views)`, and
everything downstream reads it** — the ghost payee row, the connector, the wait strip and
the button's target. `widenTarget()` is now `pending[0] ?? null`, and `drawWire` calls
`widenTarget()` too, so Minor 1 is closed by construction rather than by a second matching
condition: with two blocked intents the line and the scan cannot pick different payees,
because there is only one list and both take its head.

Every clause of `widenable` is a fact the agent published: `verdict === "will-be-blocked"`,
the refusal is the payee one, both `payee` and `token` are present (the plan needs both), and
`renderIntent`'s `payeeAllowed` agrees the payee is absent.

## Minor 2 — the reason code was a bare `6`

Now `reasonName ? reasonName === "PAYEE_NOT_ALLOWED" : reason === 6`. Deliberately not an
OR: if `agent/reason.mjs` renumbers, `6` becomes some *other* refusal, and an OR would offer
a face scan for it. The name decides when the agent published one; the number is the fallback
for a state that did not.

## Minor 3 — `#valid` was only ever unhidden

## Minor 4 — the error path left a digest under "THIS SCAN IS BOUND TO THIS DIGEST"

Both are the same shape, so both got the same fix: `resetCommandBox()` — placeholder label,
empty command, copy hidden, `#valid` hidden and its text restored from the markup — called
from `cancelWiden()`, from `startWiden`'s catch, and at the *start* of `startWiden` so a new
attempt never inherits the last one's digest or expiry notice.

Two things came out of doing it:

- `handleVerify`'s catch got the same reset. The review only named `startWiden`, but the
  attempt is equally over there and the box equally belongs to it.
- Both catches had `setMsg` **before** `paintButton`, and `paintButton` writes the idle
  message over whatever is there — so every error message was being erased in the same frame
  it was set. Reordered. Not in the review; found while editing those lines.

## Checks re-run

```
1 module script(s), 23479 chars      node --check -> SYNTAX OK
imported: ['renderIntent','renderRules','renderStatus','shortHex']   missing: none
defined: 33  referenced: 32          referenced but never defined: none
8788/api/agent/state 1 · eth_call|jsonrpc 0 · WALLET_PK 0 · selfieCheckLegacy 1
```

### The new selection, exercised

`widenable` and `isPayeeNotAllowed` were **sliced out of `demo.html` by text** and run in
node against `demo-render.mjs` — the real source, not a retyped copy, since the inline module
cannot be imported whole without a DOM:

```
payee missing          -> [ 'newvendor->0x0000…cafe0' ]
AGENT_REVOKED          -> []            <- the defect the review found
verdict invalid        -> []
no token               -> []
payee already allowed  -> []
code 6, other name     -> []            <- the renumbering guard
no reasonName, code 6  -> [ 'nameless->0x0000…cafe0' ]   <- the numeric fallback
revoked + missing      -> [ 'newvendor->0x0000…cafe0' ]  <- connector and button both take [0]
```

## Still unseen

Everything in §5 and in fix round 1's list still stands — no browser here. Nothing in this
round changes the layout, so the visual checklist is unchanged; the revoked-agent path above
is now covered by the probe rather than by eye.
