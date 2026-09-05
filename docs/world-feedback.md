# World Selfie Check — Integration Feedback

Submitted for the **ETHOnline 2026 · World Selfie Check** prize track.

Project: **Leash** — an onchain policy engine for AI agent wallets.
Selfie Check gates *privilege expansion*; privilege *reduction* is deliberately ungated.

> **This is a running log, written as things happen — not reconstructed afterwards.**
> Each entry is dated. Nothing below is hypothetical.

---

## Scope of this document

The prize asks for feedback on four areas. This document is organised the same way:

1. Selfie Check docs and integration flow
2. Developer Portal navigation, search, product discovery, debugging guidance
3. Sandbox App states, proof flows, test users, errors, edge cases
4. What was confusing, missing, broken, or hard to test

---

## 1. Selfie Check docs and integration flow

### 1.1 The access gate is documented three times, in three different wordings — and never next to the thing it blocks

*Logged 2026-09-01 / 09-02.*

Selfie Check (Beta) requires a feature flag to be enabled on your app before you can
use it at all. That fact appears in three places, each phrased differently:

| Page | Wording | Actionable? |
|---|---|---|
| `world-id/idkit/credentials#selfie-check-beta` | "**Request access** to enable Selfie Check (Beta) for your app." | ✅ links `mailto:developers@toolsforhumanity.com` |
| `world-id/credentials/11` | "Selfie Check (Beta) is **access-gated**. To use it, request access so the feature flag can be enabled for your app." | ✅ same mailto |
| `world-id/sandbox/testing-selfie-check` | "must be enabled for your app before you can test it. To enable the feature flag, request access **through your World point of contact**." | ❌ no address given |

**The problem:** the third page is the one a developer reaches when they are actually
trying to test, and it is the *only* one of the three that does **not** give the email
address. It tells you to contact a person you do not have. A developer who lands there
first — which is the natural path, since it is the page about testing — has no way
forward without backtracking to a different page.

The same page closes with "Reach out to your World point of contact" again.

**Suggested fix:** use the `mailto:` link in all three places. "Your World point of
contact" is meaningful for an enterprise partner and meaningless for a hackathon
participant, which is the audience this Beta is being pushed to.

### 1.2 All three warnings are `<Warning>` callouts, which are easy to scan past

*Logged 2026-09-02.*

Every mention of the gate is inside a Mintlify `<Warning>` component. On the rendered
HTML site these are coloured boxes that read as decoration, and a developer skimming
headings will miss all three. In our case a human reader searched for this requirement
and could not find it; it was only located by fetching the raw Markdown
(appending `.md` to the docs URL) and grepping.

**Suggested fix:** a hard blocker — you cannot use the product at all without it —
should be a step in the integration flow, not a side note. Put "Step 0: request
access" at the top of the Selfie Check page's numbered instructions.

*(Aside: the `.md` suffix on `docs.world.org` URLs is genuinely useful and we used it
throughout. It is not mentioned anywhere in the docs themselves as far as we could
find. Worth advertising — it makes the docs greppable.)*

### 1.3 Two separate access gates, never explained together

*Logged 2026-09-02.*

Getting to a working Selfie Check demo requires clearing **two independent gates with
two different application channels**:

| Gate | Channel | What it grants |
|---|---|---|
| Sandbox App install | Google Form (linked from the ETHGlobal prize page) | Firebase App Distribution access to the sandbox World ID app |
| Selfie Check (Beta) feature flag | Email to `developers@toolsforhumanity.com` | The flag on *your* app |

**No single page states that both are required.** The Google Form asks only for an
email address and mentions only Firebase App Distribution — it does not ask for an
`app_id`, so it cannot possibly be enabling a per-app feature flag. We only worked out
that these were two separate gates by noticing that mismatch.

A developer who fills in the form and assumes they are unblocked will discover
otherwise only after building the integration and watching it fail.

**Suggested fix:** one "Before you start" checklist on the Selfie Check page listing
both gates, what each grants, and the expected turnaround for each. The turnaround is
the important part — see 4.1.

### 1.4 Version story is clear, and we want to record that it was clear

*Logged 2026-09-01.*

The docs are explicit that the `selfieCheckLegacy()` preset uses World ID 3.0 and that
4.0 support is not yet available. This saved us real time: we had independently
verified on Sepolia that the World ID 4.0 `WorldIDVerifier` is deployed only on World
Chain, and the docs' statement let us stop investigating a cross-chain problem that we
did not actually have. Positive feedback — this kind of explicit "not yet" is much more
useful than silence.

### 1.5 Selfie Check's stated limits are the reason we chose it

*Logged 2026-09-01.*

The docs are clear that Selfie Check gives **liveness and facial similarity**, and
explicitly **not** a uniqueness or Sybil guarantee. We want to note that we read this
and chose the credential *because* of it, not despite it.

Our use case needs to know that a live human is present at the moment a spending limit
is raised. It does not need to know that this human is globally unique. Requiring an
Orb would be wrong for us, not merely expensive.

The docs' three named use cases — **liveness detection**, **abuse resistance**, and
**continuity** — describe our integration exactly. We would suggest surfacing those
three words higher on the page; they did more to tell us "yes, this is the right
credential" than the technical description above them did.

### 1.6 The 90-day inactivity window is documented — and we would like it more prominent

*Logged 2026-09-01.*

"Selfie Check has a 90-day inactivity window. After 90 days without use, the user
completes the camera flow again before returning another proof."

This has real product-design consequences for anything used infrequently — and a
policy-change gate is *exactly* an infrequent action. A user who raises their agent's
limit twice a year will hit the re-enrollment flow every single time. That is fine, but
it changes what the UI has to say. This deserves to be in the integration flow section,
not only in the credential description.

---

## 2. Developer Portal navigation, search, product discovery, debugging

### 2.1 The Portal contains the only working sandbox install path, and the docs never mention it

*Logged 2026-09-02.*

See 4.3 for the full write-up. In short: the **Install World ID Sandbox** panel in the
Portal is the real entry point for both iOS and Android, and it does not appear in the
documentation at all. We found it by chance after concluding from the docs that iOS was
hard-blocked.

The panel itself is good — platform tabs, numbered steps, a visible pending state, and
it tells you what happens after approval. It deserves to be linked from
`world-id/sandbox/sandbox-access` as *the* way in.

### 2.2 The iOS enrolment field prefills the wrong email, and cannot be corrected

*Logged 2026-09-02. Cost us a real mistake.*

The iOS tab asks for your **Apple Account email**. In our case the field arrived
already populated with the email we use to log in to the Developer Portal — which, for
most developers, is not the Apple Account signed in on their iPhone. We submitted
without noticing the distinction and enrolled the wrong address.

There is then no way back. The panel shows only:

> Your enrollment request for `<email>` is pending.

No edit, no withdraw, no resubmit. The field that is easiest to get wrong is the one
field you cannot change.

**Suggested fix, cheapest first:**

1. **Do not prefill it.** The Portal login email is a bad default for this field
   specifically, because it looks correct and usually isn't.
2. Add one line of helper text: *"This must be the Apple Account signed in on the
   iPhone you'll test on — usually different from your Portal login."*
3. Allow the pending request to be edited or withdrawn.

**Mitigation, for anyone who hits this:** if you can still read mail at the address you
submitted, the TestFlight invite carries a redemption code that can be entered in the
TestFlight app on a device signed in to a different Apple Account. That is what we
intend to do. It works, but it is a workaround for a form that should have let us fix
a typo.

### 2.3 Still to evaluate

Pending items we will fill in once the sandbox app is installed and the Selfie Check
flag is enabled:

- [ ] Is Selfie Check discoverable in the Portal *before* the flag is enabled, or is
      there no sign the product exists?
- [ ] Where is `rp_id` surfaced, and is it labelled? The verify endpoint is
      `/api/v4/verify/${rp_id}`, so it is load-bearing.
- [ ] Is the Sandbox vs Production environment distinction visible at a glance?
- [ ] `what-is-sandbox` advertises **controllable gating** — "You decide whether the
      system enforces fraud, risk, and attestation checks" — but never says where that
      control lives. We have not found it. If it is in the Portal it is not labelled in
      terms that match the docs.
- [ ] Is there any debugging surface at all — proof inspection, request logs, decoded
      error reasons?
- [ ] Does Portal search find "Selfie Check"?

## 3. Sandbox App: states, proof flows, test users, errors, edge cases

*To be filled in — app not yet installed as of 2026-09-02.*

The docs define coverage across Hot / Cold / Semi-cold states and native / web entry
surfaces. We plan to exercise the web app path (cross-device via QR) as our primary
flow, since Leash's control surface is a web page.

Things to record:

- [ ] Cold flow end to end: install → account → date of birth → invite code →
      enrollment → Selfie Check. Where does it stall?
- [ ] Invite code handling on our platform — the docs flag this as differing by platform
- [ ] Cross-device QR: does the proof reliably return to the originating web session?
- [ ] What does a *failed* Selfie Check look like from the relying party's side?
      (The docs describe the happy path in far more detail than the failure paths.)
- [ ] Account reset behaviour — docs say accounts are freely deletable and recreatable
- [ ] `user_presence_failed` and other error surfaces: are they distinguishable?

**Known limitations the docs already disclose** (so we can confirm or contradict rather
than re-report):

- iOS Semi-cold is limited — tapping "Sign in" instead of "Sign up" mid-flow leaves no
  path to enter the invite code, requiring a restart from a fresh QR/deep link
- Sandbox builds are not publicly listed, so store acquisition differs from production
- Invite-code presentation differs by platform

---

## 4. What was confusing, missing, broken, or hard to test

### 4.1 No stated turnaround time on the access request — this is the single biggest issue

*Logged 2026-09-02.*

Neither the docs nor the form state how long access takes to be granted. For a
hackathon with a fixed 10-day window, an unbounded wait on a hard blocker is the
highest-risk item in the whole project — and it is the one thing a participant cannot
mitigate by working harder.

We sent our request on **day −2** (2026-09-02, two days before the hackathon opens)
specifically to absorb this unknown, and we structured our build order so that the
contracts, the ENS integration, and the subgraph can all be completed without World
access. That is a reasonable engineering response, but it should not have been
necessary.

**Suggested fix:** state an SLA, even a loose one ("usually within two business days").
Better still, for a time-boxed event, pre-enable the flag for anyone who submits the
ETHGlobal-linked form — the form already collects the email, and the event already
knows who its participants are.

### 4.2 The ETHGlobal prize page and the World docs disagree about how the sandbox app is distributed

*Logged 2026-09-02.*

- World docs (`world-id/sandbox/sandbox-access`) describe **TestFlight** (iOS) and a
  **private Google Play testing track** (Android).
- The ETHGlobal-linked form says it grants **Firebase App Distribution** access.

These are three different distribution mechanisms. We do not know which one we will
actually receive, or whether the hackathon path differs from the documented path. This
is resolvable — we will find out — but it made it impossible to prepare in advance,
and it meant we could not tell whether the form and the docs described the same thing.

### 4.3 The docs' iOS instructions are stale, and contradict the product

*Logged 2026-09-02, corrected the same day after finding the working path.*

`world-id/sandbox/sandbox-access` gives exactly one iOS install path — a public
TestFlight link — and states explicitly:

> Open the public TestFlight link to join the external tester group:
> [testflight.apple.com/join/VZEurhHe](https://testflight.apple.com/join/VZEurhHe)
>
> **No App Store Connect account or per-email invite is required** — the public link
> admits you to the external tester group directly.

Two problems with that paragraph:

**1. The link is closed.** As of 2026-09-02 it returns "This beta isn't accepting any
new testers right now." (Verified with an iOS user agent; HTTP 200, Apple's standard
not-accepting-testers page.) Since the sandbox app is not listed in the App Store,
a developer following the docs has no fallback and no reason to think one exists.

**2. The claim that no per-email invite is required is the opposite of how the product
actually works.** The Developer Portal has an **Install World ID Sandbox** panel with
iOS and Android tabs. The iOS tab asks for your **Apple Account email** and enrols you
individually:

> 1. Install TestFlight on your iPhone.
> 2. Submit your Apple Account email for enrollment.
> 3. When you are approved, you will receive an email. World ID Sandbox will then
>    appear in TestFlight.

That is a per-email invite — precisely what the docs say is not required. It works, and
it is the path we ended up using. Our request is currently pending.

**Why this cost us time:** the docs present iOS as the *easy* platform (public link, no
enrolment) and Android as the gated one (Portal enrolment, tester approval, wait). The
reality is that both platforms are gated through the Portal in the same way. We
concluded we were hard-blocked on iOS and started planning a degraded demo, before
finding the Portal panel by chance. Nothing in the docs points to it.

**Suggested fix:**

1. Rewrite the iOS section of `sandbox-access` to describe the Portal enrolment flow,
   the same way the Android section already does. Delete the "no per-email invite is
   required" sentence — it is actively misleading.
2. Remove or annotate the public TestFlight link while it is closed. A dead link
   presented as *the* path is worse than no link.
3. State the expected approval turnaround for the enrolment, on both platforms.
4. Consider linking the Portal's **Install World ID Sandbox** panel directly from the
   docs. It is the real entry point for both platforms and it is not mentioned once.

**Meta-observation:** the Portal panel is well built — clear three-step instructions,
visible pending state, tells you what happens next. The problem is purely that the docs
describe a different, non-working world. Of everything in this document, this is the
gap where the docs and the product have drifted furthest apart.

### 4.4 Onchain verification of Selfie Check is undocumented

*Logged 2026-09-01.*

The docs cover verifying a proof by POSTing it to
`https://developer.world.org/api/v4/verify/${rp_id}`. They do not describe verifying a
Selfie Check proof **onchain**.

For Proof of Human this path is well documented, and we independently confirmed that
the World ID 3.0 `WorldIDRouter` is live on Sepolia at
`0x469449f251692e0779667583026b5a1e99512157` with four populated groups (0–3, all with
non-zero `latestRoot()`). Submitting a deliberately invalid proof reverted with
`0xddae3b71` = `NonExistentRoot()`, which confirms routing and merkle-root checking are
functional there.

What we could not determine, without a real proof, is **which group ID (if any) a
Selfie Check proof verifies against**. That is not answerable from the docs.

**Impact on our design:** we are using the documented off-chain path as our primary
flow — backend verifies with World, then signs an EIP-712 attestation the contract
accepts. This introduces a trusted attester, which we would prefer to avoid. We think
the seam is in a defensible place (privilege expansion is inherently a human, off-chain
action) but we would have chosen the trustless path if it had been documented.

**Suggested fix:** either document the onchain verification path for Selfie Check with
the group ID, or state explicitly that Selfie Check is off-chain-verification-only.
Right now the absence reads as an omission rather than a decision, and we spent time
probing contracts to find out which it was.

---

## Summary

**What worked well:** the version story (3.0 vs 4.0) is stated plainly instead of left
implicit; the credential's limits are described honestly, including what it explicitly
does not guarantee; the Sandbox coverage matrix and the disclosed known limitations are
genuinely useful and saved us from re-reporting them; and `.md` URL suffixes make the
docs greppable.

**What cost us the most time,** in order:

1. **The iOS install instructions are stale and contradict the product** — the
   documented public link is closed, and the docs explicitly deny needing the
   per-email enrolment that actually works and is only discoverable in the Portal
2. An unbounded, un-SLA'd wait on a hard access gate, in a 10-day event
3. Two separate access gates with two separate channels, never described together
4. The access requirement being invisible on the page where you most need it, and
   phrased there without an actual contact address
5. Onchain verification being neither documented nor explicitly ruled out

All five are documentation, distribution, and process issues — not product issues. The credential
itself does exactly what we need it to do, and we picked it on the merits.
