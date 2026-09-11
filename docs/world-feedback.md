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

## 5. The access gate, revisited: how access was actually distributed

*Logged 2026-09-07, after watching the recording of the official ETHGlobal × World
workshop "Building Trust Online" (2026-09-05, 03:00 in our timezone).*

This is the most consequential finding in this document, and it is not in the docs.

**The Selfie Check (Beta) flag was granted to workshop attendees, live, as a courtesy.**
From the recording: attendees were told they were "getting it after this presentation."
Sandbox App access (TestFlight / Firebase App Distribution) was collected the same way —
by handing over an email address during the call.

Meanwhile, the documented channel produced nothing:

| Channel | Sent | Response as of 2026-09-07 |
|---|---|---|
| `developers@toolsforhumanity.com` (the address the docs give) | 2026-09-02 | **none, 5 days** |
| Sandbox access Google Form (linked from the ETHGlobal prize page) | 2026-09-02 | **none, 5 days** |

**Why this matters more than it may appear.** The three doc pages we catalogued in §1.1
all point at an asynchronous request channel. In practice, the reliable path was
synchronous and undocumented: be awake for a 30-minute call. For a global online
hackathon that is a timezone lottery. Ours started at 03:00 local; we were asleep.

Two of the four things this document was asked to evaluate — Sandbox App states and
proof flows — are gated behind an access grant we could not obtain through any
documented route. That is a structural gap, not an inconvenience.

**Suggested fixes, in order of how much they would have helped us:**

1. **Make the flag self-serve in the Developer Portal.** The workshop revealed that a
   "request access to sandbox" button already exists in the Portal. Put the Selfie Check
   flag next to it. If a human must approve, approve asynchronously — but let the
   developer *see the request exists and its state*, which today they cannot.
2. **Auto-acknowledge the email.** Five days of total silence is indistinguishable from
   a wrong address, a spam filter, or a dead mailbox. We re-verified our sent mail to
   rule out the first two. An automated "received, typical turnaround N days" would have
   cost nothing and saved a day of doubt.
3. **Name the Discord channel in the docs.** "Your World point of contact" (§1.1) turns
   out to mean, for hackathon participants, the World channel on the event Discord.
   That is a fine answer — it is just never written down anywhere a developer will look.
4. **Say in the docs that the flag is rolling out broadly.** The workshop mentioned
   general availability "probably next week." A developer reading the docs today sees an
   indefinite gate and plans around it. Knowing GA was days away would have changed our
   sequencing.

### 5.1 Credential naming actively misleads

*Logged 2026-09-07, same source.*

In IDKit the two credentials a developer chooses between are labelled:

| Label in the SDK | What it actually is |
|---|---|
| `selfie check legacy` | **Selfie Check** — the credential this prize track is about |
| `proof of human` | **Orb verification** — the high-assurance one |

Both names point the wrong way. "Legacy" reads as deprecated, so the natural instinct is
to avoid it — but it is the current, correct choice for Selfie Check. And "proof of
human" is the phrase the marketing site uses for the *whole product family*, so reading
it as the generic option is the obvious mistake. This was flagged as a known naming
problem during the workshop; recording it here so it does not get lost.

A developer integrating from the docs alone could easily ship against the wrong
credential and only discover it when the flow demands an Orb.

### 5.2 Selfie Check should not need the Sandbox App — but the docs imply it does

*Logged 2026-09-07.*

The Sandbox App exists because online hackers cannot reach a physical Orb. Selfie Check,
by design, does not require an Orb. It therefore looks like Selfie Check can be tested
against the real World App with a real selfie, and the Sandbox is only strictly required
for the Orb-gated credentials (and for AgentKit, which the workshop confirmed accepts
Orb-verified World IDs only).

The docs do not say this. `world-id/sandbox/testing-selfie-check` presents the Sandbox as
the testing path, which reads as a requirement and pulls a developer into a second,
separately-gated access queue they may not need. One sentence — "Selfie Check can also be
tested on the production World App; the Sandbox is for simulating Orb-verified states" —
would remove an entire blocking dependency.

*(Flagged as our reading of the two docs pages, not as confirmed behaviour. If it is
wrong, that is itself worth knowing: it would mean the Sandbox gate silently blocks the
one credential that was designed not to need special hardware.)*

---

## 6. The flag was already enabled. Nothing in the product could tell us.

*Logged 2026-09-07, ~17:30 UTC+8. This is the single most consequential entry in this
document, and it is the one we would most like someone at World to read.*

We spent five days blocked on the Selfie Check (Beta) feature flag: an email on 09-02
that was never answered, a Google Form that was never answered, a plan to escalate on
Discord, and a workshop at 03:00 local time that we slept through and had to recover
from a recording.

**The flag was on.** We only found out by giving up on the UI and calling an
undocumented endpoint.

### 6.1 The Developer Portal has no credential surface at all

`World ID Configuration` — the page whose name promises exactly this answer — contains,
in full:

| Section | Contents |
|---|---|
| (top) | App ID, RP ID, Signer address |
| Key | Rotate signer key |
| Danger zone | Switch to self-managed · Delete this app |

That is the entire page. There is no credential list, no verification-level selector, no
Selfie Check toggle, no "access requested / pending / granted" state — **nothing that
refers to credentials at any point.** The `Verification` page is a log of verifications
performed, not a configuration surface, and it is empty until someone verifies.

So a developer in our position has no way, anywhere in the product, to answer *"has my
access request been granted?"* The honest answer we arrived at was "the Portal cannot
tell you; ask a human on Discord." For a self-serve developer platform that is a
significant gap, and it is the direct cause of the five days.

### 6.2 One undocumented request answered what five days of email could not

> **Corrected 2026-09-11 — this endpoint is not a lookup.** We described it below as the
> place you can *ask* what an app supports. It also **writes**: posting a randomly
> generated action string returns a real, active action with its own id and
> `external_nullifier`, created on the spot. See §7.6. Everything below about what it told
> us stands; "read-only" was our inference, not something the endpoint claims.

```
POST https://developer.worldcoin.org/api/v1/precheck/{app_id}
Content-Type: application/json
{"action": "expand-policy"}
```

```json
{
  "engine": "cloud",
  "is_staging": false,
  "enable_face_check": true,
  "can_user_verify": "yes",
  "action": { "action": "expand-policy", "status": "active",
              "max_verifications": 1, "max_accounts_per_user": 1 }
}
```

`enable_face_check: true`. Unauthenticated, instant, and **not mentioned once in the
docs** — we found it by reasoning about what IDKit itself must call before rendering.

Two observations:

1. **The data exists and is already public.** This is not a case of information the
   platform does not have. It is one boolean, served without authentication, that the
   Portal simply does not render. Putting `enable_face_check` on the World ID
   Configuration page — even as read-only text — would have saved us five days.
2. **`precheck` is genuinely useful and completely undocumented.** It is the fastest way
   to confirm an app's configuration, and every developer debugging an integration
   wants it. It deserves a documented page of its own.

**Suggested fix, in one sentence:** render the app's enabled credentials on the World ID
Configuration page, with an explicit state for *not enabled — request access*, linking to
whatever the current request channel is.

### 6.3 `max_verifications` defaults to 1, and nothing in the product says what that means

*Logged 2026-09-07. **Corrected 2026-09-11** — the claim this section originally made is
quoted below rather than deleted.*

The action we created defaulted to `max_verifications: 1` and
`max_accounts_per_user: 1`. What we wrote here on 09-07 was that this default "silently
breaks hackathon demos": the first verification succeeds, so nothing looks broken, and you
discover it during judging when the second attempt fails against a spent nullifier.

**We had not measured that.** On 09-11 we did, and neither half of it held up.

- **Re-verifying a consumed action still succeeded.** Scanning the same action a second
  time returned
  `{"success":true, …, "message":"Proof verified successfully (nullifier reuse)"}`.
  A fresh action returned the same `success: true` without the parenthetical. So
  `max_verifications: 1` did not cause the second verification to fail. We are not going to
  say what it *does* limit — we did not measure that, and guessing is how this section went
  wrong the first time.
- **A developer is never actually stuck for want of an action.**
  `POST https://developer.worldcoin.org/api/v1/precheck/{app_id}` with a randomly generated
  action string we had never created — `zzz-b3d399cdd91670da` — came back with a real,
  active action, `status: "active"`, complete with an `external_nullifier`:

  ```json
  {"action": {"id": "action_cc653b71e1a6682826ac3b5e5c0f908b",
              "action": "zzz-b3d399cdd91670da",
              "external_nullifier": "0x00cc653b71e1a6682826ac3b5e5c0f908b014b30fa0a2c1850892f924a89b926",
              "max_verifications": 1, "max_accounts_per_user": 1, "status": "active"}}
  ```

  `precheck` mints actions on demand. The Portal is not required to create one.

**What survives is a documentation complaint, and it is a real one.** Neither behaviour is
documented anywhere we could find: not that a consumed action re-verifies and reports
`(nullifier reuse)`, and not that `precheck` creates an action that does not exist. A
developer who reads `max_verifications: 1`, cannot set it anywhere in the Portal (§7.6),
and does not stumble onto the minting behaviour — we found `precheck` at all only by
reasoning about what IDKit must call before rendering (§6.2) — will conclude they have one
shot per action and no way to get another. That belief is wrong, and nothing in the product
corrects it.

**Suggested fixes, cheapest first:** (a) document what `max_verifications` counts and what
happens when it is exhausted, next to the action-creation form; (b) document `precheck`,
including that it returns an active action for an action string that does not exist yet
(§6.2 asks for a `precheck` page for other reasons too); (c) surface the value in the
Portal, where §7.6 could not find it.

### 6.4 The app configuration flow leads to an app-store listing, not to configuration

Looking for credential settings, the natural next click is the app's configuration
wizard. It opens a four-step flow — *Basic information · Availability · Localised
content · Review and confirm* — with a logo dropzone, publisher name, and an
`App Official Website` field marked required.

This is a **World App store submission flow**. Our integration is `External integration`,
not a Mini App: we never need to be listed in the store, and completing this wizard would
put the app into a review queue for no reason. Nothing labels it as optional, or as
store-listing rather than configuration, and it sits where configuration should be.

Related: our app reports `is_staging: false`. We had intended to create a Staging app and
believed we had. The environment is not shown anywhere we looked in the Portal; we
learned it from `precheck`. Whether an app is staging or production changes which World
App can verify against it, so it should be visible on the configuration page.

### 6.5 What this means for the earlier sections

Sections 1, 2, 4 and 5 describe the access gate as an unresolved blocker. **It resolved
itself at 17:30 on 09-07 in the sense that it had never actually been closed** — we were
blocked by the absence of a status display, not by the absence of access. We are leaving
those sections exactly as written, because the experience they record is real and the
timestamps matter: for five days, a developer doing everything the documentation asked
had no way to discover that they could already proceed.

If one change comes out of this document, we would like it to be the one in 6.1.

---

## 7. Integrating it: what the four official sources each got wrong

*Logged 2026-09-07, immediately after a verification that returned
`{"success": true, ..., "message": "Proof verified successfully"}`. **Corrected
2026-09-11**; the original framing is stated and marked below rather than reworded away.*

**What we claimed.** That the 09-07 run was a working Selfie Check — "Selfie Check works,
and it does exactly what we needed" — and that this section therefore records the four
hours between "the flag is on" and "Selfie Check verified".

**What we ran on 09-11.** The two verifications in §7.5, and a read of
`@worldcoin/idkit-standalone@2.2.5`'s published bundle (§7.9).

**The truth.** The 09-07 proof was a **device** credential. We requested it through the
standalone widget at `verification_level: "device"`, and that widget cannot request a face
check at all — its bundle contains no Selfie Check (§7.9). Repeating that request shape on
09-11 opened no camera and returned `identifier: "device"` (§7.5). So the four hours below
were spent getting a *device* verification to the right endpoint, not a Selfie Check one.

**What stands.** Everything in §7.1 through §7.4 and §7.7 — they are findings about the
verify endpoint, the payload shape and `signal_hash` on the legacy 3.0 path, and none of
them depended on which credential we had asked for. And Selfie Check does work and does
exactly what we needed: the run that establishes that is the 09-11 one in §7.5, where the
camera opened, a face record was enrolled, and the verify API returned
`"identifier":"selfie"`, `"success":true`.

This section is about those four hours, almost all of which went to reconciling official
sources that contradict each other.

### 7.1 Four sources, four answers, and only a real proof can tell you which is right

| Source | Says | Correct? |
|---|---|---|
| Docs (`credentials`) | Selfie Check "currently uses World ID **3.0**, with World ID 4.0 support not yet available" | **Half.** The *proof* is 3.0-shaped; the *verification* must go to **v4** |
| `precheck` (v1) | `enable_face_check: true` | ✅ |
| **v2 verify** | `invalid_action: Action not found.` | ❌ Returns this for a real action, a fake action, an empty string, **and a valid proof** |
| v4 verify | "Verifies World ID 4.0 proofs **and legacy 3.0 proofs**" | ✅ **This is the one** |

Reading the docs, the obvious inference from "Selfie Check uses World ID 3.0" is "so use
the 3.0 verification endpoint." That inference is wrong, and the error it produces —
`Action not found` — points at the *action name*, which is the one thing that was never
the problem. We created a second action to rule out a typo. It returned the same error.

**The single sentence that would have saved this:** on the Selfie Check credential page,
"Selfie Check issues a 3.0-format proof; verify it at the v4 endpoint using
`protocol_version: "3.0"`."

**Suggested fix for the error itself:** when an app is registered as a 4.0 RP, the v2
endpoint should say so — `"this app is registered for World ID 4.0; use the v4 verify
endpoint"` — exactly as v4 already does in the opposite direction. v4 returns a helpful
"This app has not been migrated to World ID 4.0. Please use the v2 verify endpoint" when
you get it backwards. **v2 has no such message.** One direction of the migration is
signposted and the other is a dead end.

### 7.2 "Forward the complete IDKit result without remapping" — you must remap

The v4 reference says, verbatim:

> Forward the complete IDKit result without remapping response identifiers.

You cannot. IDKit returns `{verification_level, nullifier_hash, proof, credential_type,
merkle_root}`. The v4 legacy request needs `responses[].nullifier` — **`nullifier_hash`
is rejected** — and does not accept `credential_type` or `verification_level` at all.
Three changes are mandatory:

| Change | Field |
|---|---|
| Rename | `nullifier_hash` → `responses[].nullifier` |
| Remove | `credential_type`, `verification_level` |
| Add | `protocol_version`, `nonce`, `environment` |

The instruction is not merely unhelpful, it is the opposite of what works. A developer who
follows it gets a validation error whose `attribute` names a field they were told to send.

### 7.3 IDKit does not return `signal_hash`, and the docs do not say you must compute it

The proof object contains no `signal_hash`. The backend has to derive it:
`keccak256(signal) >> 8` — the shift being necessary to land inside the SNARK field.

Two things make this a trap rather than a detail:

1. **It is silent.** With no signal, or with the default empty-string signal, everything
   works and you never learn the field is missing. It fails only once you use a real
   signal — which is to say, once your integration starts doing something meaningful.
2. **The obvious implementation is wrong.** Node's built-in
   `crypto.createHash("sha3-256")` is SHA3, not keccak256; the padding differs, so the
   hash differs and the proof is rejected with no indication that hashing is the cause.

**Suggested fix:** document the derivation next to the proof-response schema, with the
known-answer test — `signal_hash("")` must equal
`0x00c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4` — and an explicit
"this is keccak256, not SHA3-256" warning.

### 7.4 A failing backend is indistinguishable from a declined verification

Our first attempt died in our own backend (the missing `signal_hash` above). The World App
showed **"Verification Declined — We couldn't complete your request. Please try again."**

That message describes a *rejection by World*. What actually happened was our own server
returning 500. We spent the next stretch investigating World's gating instead of reading
our own stack trace. Later, on the attempt that failed at the v2 endpoint, the phone
showed **success** while the browser showed **declined** — the two ends of the same
verification disagreeing on the outcome.

**Suggested fix:** distinguish "the relying party's `handleVerify` threw" from "World
declined this verification". Even "The app couldn't complete verification" instead of
"We couldn't complete your request" would point the developer at their own code.

### 7.5 "The proof does not say a face was checked" — corrected 2026-09-11: it does

*Logged 2026-09-07. **Corrected 2026-09-11**, after finally running the experiment that
should have come first. We are stating the original claim and marking it wrong rather than
quietly rewording the section into something that was never wrong, for the same reason the
Summary keeps its earlier wrong versions.*

**What we claimed on 09-07.** Our successful verification came back as
`verification_level: "device"`, `credential_type: "device"` — no `selfie`, no `face`, no
`face_check`. From that we inferred that a face *had* been checked and the proof simply
failed to say so, and therefore that the assurance "a live human face was checked" was
carried entirely by the app-level `enable_face_check` flag rather than by anything a
verifier receives. We called it the finding with real security consequences and asked
World to return the credential that was actually exercised.

**What we ran on 09-11.** Two verifications, same app, `enable_face_check: true`,
`is_staging: false`, each against a brand-new action:

1. Requested through `@worldcoin/idkit-standalone` at `verification_level: "device"`,
   action `expand-policy-facetest-1`. The human who scanned reports that **World App
   opened no camera** — it performed a device verification. World's verify API returned
   `"protocol_version":"3.0"`, `"results":[{"identifier":"device","success":true}]`.
2. Requested through `@worldcoin/idkit-core`'s credential request `selfieCheckLegacy()`,
   with `allow_legacy_proofs: false`, action `expand-policy-facetest-2`. **The front camera
   opened, took a photo, and enrolled a face record** (first scan only; the enrollment is
   one-time). World's verify API returned `"protocol_version":"3.0"`,
   `"results":[{"identifier":"selfie","success":true}]`.

**The truth: the observation was right and the inference was wrong.** No face was checked
on 09-07 — not because the proof omitted it, but because we never asked for one, and the
standalone widget we asked through cannot ask for one at all (§7.9). `enable_face_check:
true` on the app does not turn a `device` request into a face check. When a face *is*
checked, the proof says so: the `identifier` is `"selfie"`, not `"device"`.

So the fix we asked for at the end of this section already exists. **World's API reported
the truth at every step**, and we read its accurate answer to the wrong question as a
missing security property. The confusion was ours; the surface that made it easy to fall
into is §7.9.

**What this changed in our own code.** `buildSelfieVerifyPayload` now refuses any result
whose `identifier` is not `"selfie"` — a device credential is not a face — pinned by a
mutation-tested case. That check is only possible *because* the proof distinguishes them.
It also refuses a result whose `signal_hash` is not the one we computed for the digest: the
4.0 result carries its own `signal_hash`, so a caller could present a proof genuinely bound
to signal X and claim digest Y. World cannot catch that — the proof really does match its
own `signal_hash` — so the binding is checked on our side and the value we forward is the
one we computed.

**One thing worth recording for §7.1's benefit:** the 4.0 `SelfieCheckLegacy` result still
reports `protocol_version: "3.0"`, and it arrives in the same envelope shape the v4 verify
endpoint takes.

**Suggested fix, now that the API is not the problem:** say this on the credential page.
One sentence stating that Selfie Check returns `identifier: "selfie"`, and that a `device`
credential requested under an app with `enable_face_check` enabled is still a device
credential, would have stopped us writing four days of security analysis about a proof we
never requested. A second sentence telling relying parties to check `identifier` rather
than trusting app configuration would document the check we ended up writing anyway.

### 7.6 `max_verifications` cannot be changed after an action is created

Following on from §6.3: we looked for the setting. It is not on the action, not in
`World ID Configuration`, and the create-action form does not offer it either — a second
action we created for testing also came out `max_verifications: 1`. As far as we can find,
the Portal provides no way to set or change it.

The workaround we recorded on 09-07 was: create a fresh action before recording the demo.

*Corrected 2026-09-11.* Two things about that paragraph need amending, both measured in
§6.3. First, the failure it works around did not reproduce — re-verifying a consumed action
returned `success: true` with `(nullifier reuse)`. Second, the workaround is cheaper than we
described: a fresh action does not require the Portal at all, because `precheck` returns an
active action for any action string you send it.

What still stands is the part this section is actually about — the Portal offers no way to
set or change `max_verifications` — and the caveat that a fresh action carries a fresh
`external_nullifier`, so anything the integration persisted against the old nullifier is
orphaned.

### 7.7 `signal_hash` has two hashing branches depending on the signal's shape, and §7.3 only documented one

*Logged 2026-09-09, found while extending our own backend past the string signal we used
for the 2026-09-07 end-to-end run.*

§7.3 above states the derivation as `keccak256(signal) >> 8`, as if `signal` were hashed
the same way regardless of its shape. It is not, and the docs never say so. Reading
`@worldcoin/idkit-standalone@2.2.5`'s own bundle (the version the sandbox page actually
loads), the real rule is:

```js
function hashToField(input) {
  if (Bytes_exports.validate(input) || Hex_exports.validate(input)) return hashEncodedBytes(input);
  return hashString(input);
}
function hashString(input) { return hashEncodedBytes(Buffer.from(input)); }
```

A `0x`-prefixed hex string is hashed as its **decoded bytes**; every other string is
**UTF-8-encoded** first. Our first signal was a plain string
(`"widen:vendors.acme.eth:5000"`), which takes the UTF-8 branch either way and cannot
reveal the second one exists. The moment we switched to a 32-byte digest as the
signal — the shape our actual security property needs, since binding the proof to a
specific onchain digest is the whole point of the signal — the one-branch
implementation silently produced a different hash on every call:

```
digest = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121
wrong (utf8 of the 66-char string): 0x007cd56968e2972a1ea1a04ec5e7232b5e7e482109e6dcb24532d904171f6260
right (keccak of 32 raw bytes):     0x001387de0eeedc698d3e7d0be5def31c0ab49050cab7858a488ceac06df7fcf3
```

**Why this is worse than the original §7.3 finding, not just an addendum to it:** a
mismatched `signal_hash` is not a slow failure or a confusing error message — it is
`/api/attest`'s *entire* success condition. World checks `signal_hash` as a public input
against the proof, so every call fails the same way, and every failed call is a wasted
attempt against `max_verifications: 1` (§6.3). A relying party who chooses a digest or
any other `0x`-prefixed value as their signal — which is the natural choice for any
integration binding a proof to onchain state, not only ours — hits this on the very first
real call, with no indication that hashing, rather than the proof itself, is the cause.

**Suggested fix:** state the two-branch rule explicitly next to the derivation in §7.3's
location in the real docs, with a known-answer test for *each* branch — a plain string and
a `0x`-prefixed one — not only the empty-string baseline already given. The empty string
happens to take the UTF-8 branch, so on its own it documents only half the rule.

---

### 7.8 `selfieCheckLegacy` is a credential request, not a `verification_level`, and passing it to the standalone widget fails *after* the modal opens

*Logged 2026-09-11, found by driving our own demo page with Playwright rather than by
reading it.*

The credentials page names `selfieCheckLegacy()` and tells you to import it from
`@worldcoin/idkit-core` or `@worldcoin/idkit`. We were not on either: we were on
`@worldcoin/idkit-standalone@2.2.5`, the drop-in CDN widget, which has no presets and only
an options object. So we passed the one credential name we had been given into the one
place that names a credential:

```js
IDKit.init({ app_id, action, signal, verification_level: "selfieCheckLegacy", handleVerify })
IDKit.open()
```

`verification_level` is a different vocabulary. Reading the bundle,
`verification_level_to_credential_types` accepts exactly four values — `device`,
`document`, `secure_document`, `orb` — and throws on anything else.

**What makes this worth reporting is not the mistake; it is the shape of the failure.**
`IDKit.open()` mounts the widget, the Radix dialog renders, and the host page's own state
advances — our button flipped to "Cancel", and the digest the scan was supposed to bind to
was painted on screen. Only *then* does `createClient` throw, inside a promise nobody
awaits. The result is a modal that opens empty:

```
Uncaught (in promise) Error: Unknown verification level: selfieCheckLegacy
    at verification_level_to_credential_types (index.global.js:14818)
    at createClient (index.global.js:14955)
```

No visible error, no `onError` callback, nothing the page could catch and show. To an
operator — and this would have been an operator standing in front of a camera — it reads
as "the QR code did not appear", which sends you to inspect your own layout rather than
your options object. Our page has a deliberate `IDKit did not load` guard for the case
where the CDN fails; it could not help here, because IDKit *had* loaded and the widget
*had* mounted.

**Suggested fixes, cheapest first:**

1. **Validate options in `IDKit.init()`, not deep inside `createClient` at open time.**
   `init` is synchronous and its throw is catchable by the caller; a bad
   `verification_level` should never reach a rendered modal.
2. **Reject unknown keys and unknown values loudly**, naming the four accepted values in
   the message. The current message names what was wrong but not what would have been
   right.
3. **Say on the `idkit-standalone` side that it cannot request Selfie Check at all.** The
   credentials page already names `idkit-core` and `idkit`; the gap is in the other
   direction, for a reader who never visits that page because they are already holding the
   standalone widget. *Corrected 2026-09-11:* this point originally read "the value that
   works is `device`". There is no `verification_level` that works — §7.9 measures why.
   `device` makes the widget run, but it requests a device credential and opens no camera
   (§7.5).

This is the third item in this document (with §7.2 and §7.5) where the credential-request
vocabulary and the `verification_level` vocabulary differ silently — the split runs between
packages, not between React and everything else, since `idkit-core` serves both. One table
mapping credential request → package → `verification_level` (where one exists) → returned
`identifier` would close all three.

---

### 7.9 Selfie Check cannot be requested from `@worldcoin/idkit-standalone` at all

*Logged 2026-09-11. This is the root cause of §7.5 and §7.8, and the thing we would have
paid most to read in the docs.*

`@worldcoin/idkit-standalone@2.2.5` — the CDN widget, and the **latest** published version
(npm dist-tags: `latest: 2.2.5`) — **contains no Selfie Check.** Grepping its published
bundle for any form of the word "selfie" returns zero matches.

Its only credential vocabulary is `verification_level`, and the function that maps it
accepts exactly four values before throwing:

```js
var verification_level_to_credential_types = (verification_level) => {
  switch (verification_level) {
    case "device":          return ["orb", "device"];
    case "document":        return ["document", "secure_document", "orb"];
    case "secure_document": return ["secure_document", "orb"];
    case "orb":             return ["orb"];
    default: throw new Error(`Unknown verification level: ${verification_level}`);
  }
};
```

None of the four is a face check. There is no value you can pass this widget that produces
one, and §7.5 confirms the behaviour end to end: `device`, under an app with
`enable_face_check: true`, opens no camera and returns `identifier: "device"`.

**Selfie Check lives in a different package and a different vocabulary.**
`@worldcoin/idkit-core@4.2.4` defines it as a **credential request**, not a verification
level:

```js
function deviceLegacy(opts = {})      { return { type: "DeviceLegacy",      signal: opts.signal }; }
function selfieCheckLegacy(opts = {}) { return { type: "SelfieCheckLegacy", signal: opts.signal }; }
```

`@worldcoin/idkit` (the React package, v4.2.3) re-exports these from `idkit-core`; the
standalone widget does not have them. A non-React path does exist — `idkit-core` ships a
browser global build (`dist/idkit.global.js`, setting `globalThis.IDKit`) exposing
`request`, `createSession`, `proveSession`, `CredentialRequest`, `any`, `all`, `orbLegacy`,
`deviceLegacy`, `selfieCheckLegacy`, `proofOfHuman`, `passport`, `mnc` and
`identityCheck`. It loads `idkit_wasm_bg.wasm` **relative to itself**, which anyone serving
it from a CDN has to account for. Its request API:

```js
const request = await IDKit.request({ app_id, action, rp_context, allow_legacy_proofs })
  .preset(IDKit.selfieCheckLegacy({ signal }))
// request.connectorURI      — a URI for the page to render as a QR itself
// request.pollUntilCompletion()
```

Note what that means for the host page: there is no widget and no modal. You render
`connectorURI` as a QR code yourself and poll for completion. That is a different
integration shape from the one the standalone quickstart teaches, not a different argument
to the same call.

**First, the part the docs get right, because it matters to what we are actually asking
for.** The credentials page names the correct packages: it tells you to import
`selfieCheckLegacy` from `@worldcoin/idkit-core` (JavaScript) or `@worldcoin/idkit`
(React). We are not reporting that the docs sent us to the wrong place. We are reporting
that **a developer already standing somewhere else gets no signal at all.**

`@worldcoin/idkit-standalone` is its own documented integration path — the vanilla-JS,
drop-in-a-CDN-script option, which is where a project without React starts. Nothing on that
path says Selfie Check is out of reach from it. The widget's options object is the only
place a credential is named, so `selfieCheckLegacy` — the one handle you have been given —
appears to belong there. And passing it fails *after* `IDKit.open()` has mounted the widget
and the dialog has rendered, in an unawaited promise, with no `onError`:

```
Uncaught (in promise) Error: Unknown verification level: selfieCheckLegacy
    at verification_level_to_credential_types (index.global.js:14818)
    at createClient (index.global.js:14955)
```

§7.8 describes what that looks like from the operator's side. The point here is the one
step earlier: there was never a correct value to pass. A developer can only discover that
by reading the bundle, which is what we ended up doing.

**And here is the sentence that actively kept us on the wrong path,** which we want to be
precise about because the statement itself is true. The credential page says:

> "The preset currently uses World ID 3.0; World ID 4.0 support is not yet available."

That is correct — E5's result reports `protocol_version: "3.0"`. But **"World ID 3.0" is
describing the proof, while the thing you cannot reach without 4.0 is the API shape.**
Selfie Check is requested through the 4.0-style surface (`IDKit.request({ ..., rp_context })
.preset(...)`) and comes back as a 3.0-protocol proof. Two axes, both documented honestly,
in different places.

Reading "uses World ID 3.0" while holding a 3.0-speaking widget, we concluded the widget
was the right tool. It is the most reasonable wrong conclusion available, and nothing
corrected it: the widget accepted our call, opened its modal, and returned a valid proof
for a different credential.

**Suggested fixes, cheapest first:**

1. **One sentence, but on the `idkit-standalone` side rather than the credentials page.**
   The credentials page already names `idkit-core` and `idkit`; what is missing is the
   other direction. `@worldcoin/idkit-standalone`'s own documentation should say which
   credentials it *cannot* request — that its `verification_level` vocabulary has no face
   check in it, and that Selfie Check requires `idkit-core`. A reader on the credentials
   page is already being helped. A reader on the standalone page is not.
2. **A table mapping preset → package → `verification_level` (where one exists) →
   returned `identifier`.** §7.8 asked for a version of this table for a different reason;
   it is the same table, and it closes §7.2, §7.5, §7.8 and this section together.
3. **Show the non-React path.** `idkit-core`'s global build, `request().preset(...)`,
   `connectorURI`, `pollUntilCompletion()` — including the detail that the WASM is fetched
   relative to the script. Not every integration is React, and the standalone widget is the
   documented answer for those that are not.
4. **Make `idkit-standalone` reject the preset name by name.** Its current message names
   what was wrong but not what would have been right; "`selfieCheckLegacy` is a credential
   request from @worldcoin/idkit-core, not a verification level" would have ended this in
   one page load.

**Positive feedback, from the same day's work:** wiring the `idkit-core` path means
supplying `rp_context`, and `@worldcoin/idkit-server` has an official helper for it —
`signRequest({ signingKeyHex, action?, ttl? })` returning `{ sig, nonce, createdAt,
expiresAt }`, alongside `computeRpSignatureMessage`. Its own doc comment states the exact
byte layout:

```
version(1) || nonce(32) || createdAt_u64_be(8) || expiresAt_u64_be(8) || action?(32)
```

signed as an EIP-191 message, with session proofs omitting `action` and uniqueness proofs
appending it. It is pure JS with no WASM. We want to record this explicitly because it is
the opposite of everything else in this section: the message format is World's, stated by
World, and we did not have to reverse-engineer it from a bundle to trust it. That is how
the rest of the credential surface should feel.

---

## Summary

*Rewritten 2026-09-07. Amended 2026-09-11. Three earlier versions of this summary were
wrong in ways worth keeping visible: the first said we were blocked by "an unbounded,
un-SLA'd wait on a hard access gate"; the second said the gate had never been closed; the
third said a Selfie Check proof cannot tell a verifier that a face was checked. The first
two were about access, and the real story there is that **nothing was ever gated against
us — every hour we lost went to surfaces that could not tell us what was true.** The third
was not about World at all: we had never requested a face check, and the proof told us so
accurately (§7.5). The corrections are the most useful thing in this document.*

**Selfie Check itself is not the problem anywhere in this document.** It does precisely
what our project needs: a medium-assurance human check that gates privilege *expansion*
in an AI-agent wallet, without demanding an Orb from someone approving a payment on their
phone. We chose it on the merits, it does exactly what it says once you request the right
credential, and we would choose it again.

**What worked well:** the 3.0-vs-4.0 version story is stated plainly rather than left
implicit; the credential's limits are described honestly, including what it explicitly
does not guarantee; the Sandbox coverage matrix and the disclosed known limitations saved
us from re-reporting them; `.md` URL suffixes make the docs greppable; v4's error messages
are specific and actionable (`attribute` naming the offending field is genuinely good);
`@worldcoin/idkit-server`'s `signRequest` helper means the RP-context message format is
World's own, stated in World's own code, rather than something an integrator reverse-engineers
from a bundle (§7.9); and the Portal's **Install World ID Sandbox** panel is the best-built
thing we touched — clear steps, visible pending state, tells you what happens next. It is
exactly the pattern the credential gate needs and does not have.

**What cost us the most time,** in order:

1. **We were never blocked.** The flag was enabled on our app and no surface said so —
   not the Portal, not an email, not the docs. Five days went to the absence of a status
   display. One read-only boolean on the World ID Configuration page prevents all of it.
   (§6.1, §6.2)
2. **Four official sources disagreed about how to verify**, and the docs' own inference —
   "Selfie Check is 3.0, so use the 3.0 endpoint" — is the wrong one. The resulting error,
   `Action not found`, accuses the action name, the one thing that was never wrong. v4
   tells you when you should be using v2; **v2 never tells you to use v4.** (§7.1)
3. **The iOS install instructions are stale and contradict the product** — the documented
   public link is closed, and the docs explicitly deny needing the per-email enrolment
   that actually works and is only discoverable in the Portal. (§4.3)
4. **"Forward the complete IDKit result without remapping" is the opposite of what
   works** — `nullifier_hash` must be renamed and two fields must be dropped. (§7.2)
5. **`signal_hash` must be computed by the relying party, undocumented**, and the obvious
   implementation (`sha3-256`) is silently wrong. It also fails *late*: everything works
   until you use a real signal — and the derivation itself has a second, undocumented
   branch that only a `0x`-prefixed signal (e.g. a digest) reveals: hex is hashed as
   decoded bytes, everything else as UTF-8. (§7.3, §7.7)
6. **A relying-party 500 is reported to the user as "Verification Declined"**, sending you
   to investigate World instead of your own stack trace — and the phone and the browser can
   disagree about whether the same verification succeeded. (§7.4)
7. **`max_verifications: 1` is an undocumented default whose behaviour is also
   undocumented.** It is not settable anywhere in the Portal and is visible only through an
   undocumented API. We assumed it burned the second demo run; re-verifying a consumed
   action in fact returned `success: true` with `(nullifier reuse)`, and `precheck` hands
   you a fresh active action for any string you send it. Neither behaviour is written down,
   so a developer reasonably concludes they are stuck when they are not. (§6.3, §7.6)
8. **Selfie Check cannot be requested from `@worldcoin/idkit-standalone` at all**, and
   `selfieCheckLegacy()` — the name the credentials page correctly gives for `idkit-core`
   and `idkit` — is not a value any `verification_level` accepts. The widget's bundle contains no Selfie Check; its four
   accepted values do not include a face check; and passing the preset name throws *after*
   the modal has opened — an empty dialog, no `onError`, a host page whose state has already
   advanced, and a failure that reads as "the QR code did not appear". Reaching Selfie Check
   means `@worldcoin/idkit-core` and a 4.0 credential request. (§7.8, §7.9)

**And one correction we think is worth more than any item above** (§7.5). This document
argued for four days that a Selfie Check proof arrives indistinguishable from a
`deviceLegacy` one, and that the assurance "a live human face was checked" therefore rested
on app configuration rather than on the proof. That was wrong. On 09-11 we measured both
paths against the same app with `enable_face_check: true`: a `device` request opens no
camera and returns `identifier: "device"`; a `selfieCheckLegacy()` credential request opens
the camera, enrolls a face, and returns `identifier: "selfie"`. **World's API reported the
truth at every step** — we had asked for the wrong credential and read its accurate answer
as an omission. Our backend now refuses any result whose `identifier` is not `"selfie"`. We
have left the original claim in §7.5 marked rather than edited away, because the mistake is
the useful part: the name the docs correctly give for `idkit-core` belongs to a vocabulary
the widget we were standing in does not speak (§7.9).

**The two changes we would ask for:**

1. **Show a developer, in the Developer Portal, which credentials their app can use.** The
   data is already public and unauthenticated — it simply is not rendered. (§6.1)
2. **Say on the `idkit-standalone` side which credentials it cannot request.**
   `@worldcoin/idkit-standalone` contains no Selfie Check at all, and none of its four
   `verification_level` values is a face check. The credentials page already names the right
   packages — it is the standalone path that says nothing, and that is the path a
   non-React project starts from. One sentence there, plus a table mapping
   preset → package → returned `identifier`, closes this and three other findings in this
   document. (§7.9)
