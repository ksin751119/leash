# Pre-work checklist (9/2 - 9/3)

> Track rule: **Start from Scratch — no project code may be written before 9/4.**
> Nothing on this list **is** writing code: it is registering accounts, requesting access,
> claiming testnet funds, acquiring name resources, installing tools, and writing documents.
> The moment 9/4 arrives, work can start immediately.
>
> How the grey areas were judged:
> - ✅ Registering an ENS name = acquiring a resource (like buying a domain), **not** code
> - ✅ Installing npm packages and creating an empty project skeleton = environment setup
> - ❌ Writing `.sol`, subgraph mappings, or frontend components = **wait for 9/4**
>
> Last updated: 2026-09-02

---

## Status table

| # | Item | What it blocks | Status |
|---|---|---|---|
| 1 | The World Sandbox form | the whole World line | ✅ submitted (9/2) |
| 2 | The World Developer Portal app | step 3 | ✅ `app_452654c9…1c00`, written into `.env` (9/2). **Note it is production (`is_staging: false`), not Staging** |
| 3 | The Selfie Check feature flag | the whole World line | ✅ **enabled, and verified end to end** (9/7). Nobody ever answered the email, yet the flag had been on all along |
| 4 | ~~Install the Sandbox App~~ | — | ✅ **not needed; established** (9/7) — full verification succeeded with the production World App and a real selfie. The whole TestFlight / Firebase dependency is cut |
| 5 | A The Graph Studio account and deploy key | deploying the subgraph | ✅ key verified (`graph auth` passes), CLI v0.98.1 (9/2) |
| 6 | Generate two keys | everything onchain | ✅ generated and written into `.env` (9/2) |
| 7 | Claim Sepolia ETH | everything onchain | ✅ human 0.126 / agent 0.053 ETH (9/2) |
| 8 | Mint MockUSDC | ENS registration and demo payments | ✅ 1000 USDC on each side (9/2) |
| 9 | Register `leash.eth` | the whole ENS line | ✅ **registered**; the tokenId is in `.env` (9/2) |
| 10 | Start the feedback document | the World submission | ✅ started (9/2) |
| 11 | Close out PLAN.md's open questions | starting work on 9/4 | ✅ all four settled (9/2) |

> **Closed 2026-09-07: the World line is no longer a blocker.** The flag is on, the team is
> created (Albert Lin, a team of one), and no external approval is outstanding. What was
> written here — "the critical path is 1 → 3 → 4 → wait for World to reply" — is void: we
> were never actually blocked; the product simply displays the status nowhere. The full
> account is in `world-feedback.md` §6.

---

## A. World

### Step 1 — the Sandbox access form ✅

URL: https://forms.gle/mqbaiwMvX5MzmKdY8
(Source: ETHGlobal's World prize page → Resources → Sandbox Access)

Titled "World ID Sandbox Beta Access Request", with a single field: email.
What it grants is **Firebase App Distribution** access.

> ⚠️ **This form does not enable Selfie Check's feature flag.**
> It never asks for an app_id and says outright that it is App Distribution. Two separate
> things; see step 3.

**Submitted 2026-09-02.**

---

### Step 2 — create the Developer Portal app ✅

1. Open https://developer.world.org and sign in with World ID or email
2. Create a new app named **`Leash`**
3. Choose the **Staging / Sandbox** environment (not Production)
4. Once created, copy the **`app_id`** from the app's settings page — a long string
   beginning with `app_`
5. If the settings page also lists an **`rp_id`**, copy that too
   (⚠️ **The v4 endpoint is wrong for Selfie Check** — Selfie Check currently runs World ID
   **3.0**, and the documentation says outright "World ID 4.0 support not yet available".
   v4 answers "This app has not been migrated to World ID 4.0. Please use the v2 verify
   endpoint". So use the **v2 endpoint, which takes an `app_id`**, not v4 with an `rp_id`.
   Keep the `rp_id` and signer key for when Selfie Check migrates to 4.0.)

   ⚠️ **All of the above is wrong, and measurement on 09-07 disproved it.** v2 answers this
   app with `invalid_action` for every action, real or fake, because the app was created as a
   4.0 RP. Verification must go to **v4** with `protocol_version: "3.0"`, and the `rp_id` is
   needed after all. See `world/README.md`.
6. Save both values into `.env` (already gitignored):

```bash
WORLD_APP_ID=app_xxxxxxxxxxxxxxxxxxxxxxxx
WORLD_RP_ID=rp_xxxxxxxxxxxxxxxxxxxxxxxx
```

**While there, check whether the sidebar has a "World ID Sandbox" entry** — Android tester
access is handled there (submit the email of your Google Play account). Whether that entry
exists and how easy it is to find **goes into the feedback document**.

---

### Step 3 — request the Selfie Check (Beta) feature flag ✅

Recipient: **`developers@toolsforhumanity.com`**

This gate appears three times in the documentation, always as a coloured Mintlify
`<Warning>` box:

| Page | Their words |
|---|---|
| `world-id/idkit/credentials#selfie-check-beta` | 「Request access to enable Selfie Check (Beta) for your app.」 |
| `world-id/credentials/11` | 「Selfie Check (Beta) is **access-gated**.」 |
| `world-id/sandbox/testing-selfie-check` | 「must be enabled for your app **before you can test it**.」 |

> 💡 Append `.md` to any `docs.world.org` URL to get the raw markdown, which can be grepped
> directly. The `<Warning>` boxes on the rendered page are very easy to skim past.

**Sent 2026-09-02.**

**If there is still no reply by 9/5, open a third channel:** the World sponsor channel in
the hackathon Discord,
posting: "Submitted the sandbox form + emailed developers@toolsforhumanity.com
on Sept 2 for Selfie Check (Beta) flag. app_id `app_xxx`. Anything else needed?"

---

### Step 4 — install the Sandbox App ⬜

> ⚠️ **The documentation's iOS instructions are wrong.** It tells you to open a public
> TestFlight link (`testflight.apple.com/join/VZEurhHe`) and says "no per-email invitation is
> needed" — that link was closed as of 2026-09-02 ("not accepting new testers"), and a
> per-email invitation **is** in fact required. The correct entry point is in the Developer
> Portal, which the documentation never mentions.

**iOS — go through the Developer Portal, not the link in the docs**

1. Install TestFlight from the App Store
2. Developer Portal → **Install World ID Sandbox** → the **iOS** tab
3. Submit your **Apple Account email** to join the group
4. On approval you receive an email and **World ID Sandbox appears in TestFlight on its own**

The Android tab is in the same panel and works the same way (submit your Google Play
account's email).

**Android — expect to wait**

1. First confirm which Google account your Google Play uses
2. Developer Portal → sidebar **World ID Sandbox** → enter that email to request tester
   access
3. **Wait for approval before clicking the test link**; clicking early shows "unavailable"
4. After approval, confirm the phone's Google Play is signed in to the same account, then
   scan the QR code in the Portal

> The official troubleshooting notes that for an account that has just signed in to Google
> Play for the first time, Google takes **at least 15 minutes** to recognise it. Clicking too
> soon fails.

**Once installed, run the cold flow once** (create an account → date of birth → invite code
→ enrollment),
Record the friction at every step in the feedback document. This material cannot be
reconstructed afterwards.

---

### Step 4b — confirm the configuration through the precheck API (invisible in the Portal) ✅

**The Developer Portal has no surface anywhere that shows credential enablement status.**
The entire `World ID Configuration` page holds only App ID / RP ID / Signer address / Rotate
key / Danger zone, and `Verification` is a log of verifications rather than settings. **The
only place an answer can be obtained is this undocumented endpoint:**

```bash
curl -s -X POST \
  "https://developer.worldcoin.org/api/v1/precheck/$WORLD_APP_ID" \
  -H 'Content-Type: application/json' \
  -d '{"action":"expand-policy"}' | jq
```

Unauthenticated and immediate. The response on 2026-09-07:

| Field | Value | Meaning |
|---|---|---|
| `enable_face_check` | **`true`** | **Selfie Check is enabled** |
| `can_user_verify` | `yes` | verification works right now |
| `engine` | `cloud` | cloud verification (do not press Switch to self-managed) |
| `is_staging` | `false` | **production**, not Staging |
| `action.status` | `active` | `expand-policy` is usable |
| `action.external_nullifier` | `0x00b5b5ab…6084` | derived from app_id + action; a fixed value |
| `action.max_verifications` | **`1`** | 🔴 **see below** |

> 🔴 **`max_verifications: 1` is a default that can destroy the demo.**
> Each person can verify against this action **once, ever**. The first attempt succeeds, so
> nothing looks wrong at the time — scan once to record a video and again for a live demo,
> and the second one simply fails with the nullifier burned and **no way to reset it**.
>
> ⚠️ **The instruction that used to be here — "Portal → action settings → change max
> verifications to 0 (unlimited)" — was wrong. No such setting exists anywhere in the
> Portal.** What is true is that `max_verifications` binds to the **action**, not to the
> person, so **creating a fresh action resets it**. Do that before recording a video or
> running a live demo.

---

## B. The Graph

### Step 5 — a Studio account and deploy key ✅

1. Open https://thegraph.com/studio
2. Connect a wallet (use **step 6's human master EOA**, for consistency)
3. Create a subgraph named `leash-sepolia`
4. Copy the **deploy key** into `.env`:

```bash
GRAPH_DEPLOY_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
```

5. Install the CLI globally (a tool, not project code):

```bash
pnpm add -g @graphprotocol/graph-cli
graph --version
```

**No review is required; connecting a wallet is enough.**

> The prize requirement says "must consume live data (**Subgraph Studio** or The Graph
> Market)" — **Studio qualifies**, so there is no need to publish to the decentralized
> network and no need to buy GRT.

The subgraph's `schema.graphql` and mappings are code; **write them on 9/4**.

---

## C. Wallets and funds

### Step 6 — generate the keys ✅

The architecture needs these roles:

| Role | Purpose | 7702-delegated? |
|---|---|---|
| **ADMIN** | Owns `leash.eth` and its ENS EAC roles. Changes rules, revokes agents | ❌ never |
| **WALLET** | The one with the money. What the agent spends comes from here | ✅ delegated to LeashAccount |
| **AGENT** | A session key. Holds nothing; only a `msg.sender` the policy recognises | ❌ |

> **Why ADMIN and WALLET must be two separate keys:** when LeashAccount makes an outbound
> call, `msg.sender` *is* WALLET. If WALLET also held ENS roles, an agent would only have to
> get the account to call `ETHRegistry.setResolver(...)` to borrow the wallet's authority and
> rewrite its own policy. Separated, that path structurally does not exist — **a broken
> policy can at most drain the funds and can never reach control.**

```bash
cast wallet new
cast wallet new
```

Save them into the tx-mcp `.env` (**already in .gitignore**; confirm once):

```bash
ADMIN_PK=0x...
ADMIN_ADDR=0x...
AGENT_PK=0x...
AGENT_ADDR=0x...
SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
```

> ⚠️ This is a testnet, but still: never use these keys for any mainnet asset, and never
> commit them.

---

### Step 7 — claim Sepolia ETH ✅

**Claim for both addresses.** Faucets are rate-limited, so claim today rather than
discovering on the morning of 9/4 that you cannot.

Pick one or several:

| Source | Note |
|---|---|
| The ETHGlobal faucet (`ethglobal.com/faucet`) | Participants only, and usually the most generous |
| The Google Cloud Web3 faucet | Requires a Google account |
| The Alchemy Sepolia faucet | Requires an Alchemy account |

Target: **≥ 0.1 ETH per address**. Enough for ENS registration, contract deployment and the
demo transactions combined.

Confirm:

```bash
source .env
cast balance $ADMIN_ADDR --rpc-url $SEPOLIA_RPC --ether
cast balance $AGENT_ADDR --rpc-url $SEPOLIA_RPC --ether
```

---

### Step 8 — mint MockUSDC ✅

Registration fees on ENSv2 Sepolia are paid in **MockUSDC**, not ETH.

```
address  0x768f42455a2d082e23ceef7d51e5787c82d67a39
symbol   USDC
decimals 6
mint     mint(address,uint256)  =  0x40c10f19   ← no access control; any EOA can mint
```

Mint 1000 USDC to the human address (6 decimals, so `1000000000`):

```bash
source .env
export USDC=0x768f42455a2d082e23ceef7d51e5787c82d67a39

cast send $USDC 'mint(address,uint256)' $ADMIN_ADDR 1000000000 \
  --private-key $ADMIN_PK --rpc-url $SEPOLIA_RPC

cast call $USDC 'balanceOf(address)(uint256)' $ADMIN_ADDR --rpc-url $SEPOLIA_RPC
```

Mint some to the agent address too; the demo payments need it:

```bash
cast send $USDC 'mint(address,uint256)' $AGENT_ADDR 1000000000 \
  --private-key $ADMIN_PK --rpc-url $SEPOLIA_RPC
```

---

## D. ENS

### Step 9 — register `leash.eth` ✅

**Checked 2026-09-02: still unregistered. 8.000021 USDC for a year, premium 0.**

At registration, pass **`address(0)` for both `subregistry` and `resolver`**.
On 9/4, point them at our own contracts with `setSubregistry` / `setResolver` — which keeps
"acquiring the name" (today, and not code) cleanly separate from "wiring it into the
architecture" (9/4, and code).

#### Contracts and constants (all measured)

```
ETHRegistrar   0xa88553f454b77203b0d036a05c894d555eaaa2cc
ETHRegistry    0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
PriceOracle    0x8914b66260eb8c4fff795650c3ae8cd335958987
MockUSDC       0x768f42455a2d082e23ceef7d51e5787c82d67a39

MIN_COMMITMENT_AGE   60 s
MAX_COMMITMENT_AGE   2,419,200 s (28 days)
MIN_DURATION         86,400 s (1 day)
```

Function signatures (verified by reversing the selectors; **secret and referrer are
`bytes32`, not `uint256`**):

```
isAvailable(string)                                                       0x965306aa
getRegisterPrice(string,uint64,address)                                   0x61907b12
makeCommitment(string,address,bytes32,address,address,uint64,bytes32)     0x1e966f07
commit(bytes32)                                                           0xf14fcbc8
register(string,address,bytes32,address,address,uint64,address,bytes32)   0xcff3e7c2
renew(string,uint64,address,bytes32)                                      0x89d779c3
```

#### 9-1. Set up the environment

```bash
source .env
export R=$SEPOLIA_RPC
export REGISTRAR=0xa88553f454b77203b0d036a05c894d555eaaa2cc
export ETHREG=0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
export USDC=0x768f42455a2d082e23ceef7d51e5787c82d67a39
export LABEL=leash
export DURATION=31536000          # 1 year
export ZERO=0x0000000000000000000000000000000000000000
export ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
```

#### 9-2. Confirm once more that it is still free

```bash
cast call $REGISTRAR 'isAvailable(string)(bool)' "$LABEL" --rpc-url $R
# expect true
```

#### 9-3. Check the price

```bash
cast call $REGISTRAR 'getRegisterPrice(string,uint64,address)(uint256,uint256)' \
  "$LABEL" $DURATION $USDC --rpc-url $R
# expect 8000021 (= 8.000021 USDC) and 0 (premium)
```

#### 9-4. Approve the registrar to take payment

Approve a little extra, so a small price movement does not cause a failure:

```bash
cast send $USDC 'approve(address,uint256)' $REGISTRAR 20000000 \
  --private-key $ADMIN_PK --rpc-url $R
```

#### 9-5. Generate a secret and compute the commitment

**Save the secret** — step 9-7 needs the same value, and losing it means starting over.

```bash
export SECRET=$(cast keccak "leash-ethonline-2026-$(date +%s)-$RANDOM")
echo "SECRET=$SECRET"          # ← save into .env; do not close this terminal

export COMMITMENT=$(cast call $REGISTRAR \
  'makeCommitment(string,address,bytes32,address,address,uint64,bytes32)(bytes32)' \
  "$LABEL" $ADMIN_ADDR $SECRET $ZERO $ZERO $DURATION $ZERO32 \
  --rpc-url $R)
echo "COMMITMENT=$COMMITMENT"
```

#### 9-6. Send the commit, then wait 60 seconds

```bash
cast send $REGISTRAR 'commit(bytes32)' $COMMITMENT \
  --private-key $ADMIN_PK --rpc-url $R

sleep 75      # the minimum is 60 s; a little margin
```

> The window: **no sooner than 60 seconds, no later than 28 days**. An interruption in
> between does not require re-committing.

#### 9-7. Register

```bash
cast send $REGISTRAR \
  'register(string,address,bytes32,address,address,uint64,address,bytes32)' \
  "$LABEL" $ADMIN_ADDR $SECRET $ZERO $ZERO $DURATION $USDC $ZERO32 \
  --private-key $ADMIN_PK --rpc-url $R
```

#### 9-8. Verify

```bash
# should now be false
cast call $REGISTRAR 'isAvailable(string)(bool)' "$LABEL" --rpc-url $R

# both should be 0 for now - that is expected; they get wired on 9/4
cast call $ETHREG 'getSubregistry(string)(address)' "$LABEL" --rpc-url $R
cast call $ETHREG 'getResolver(string)(address)'    "$LABEL" --rpc-url $R
```

**Find the tokenId and save it** — `setSubregistry(uint256,address)` and
`setResolver(uint256,address)` both take a tokenId, not a string.

An ENSv2 tokenId has a version mixed into it, so **do not compute the labelhash yourself**;
read it from the registration transaction's ERC-1155 `TransferSingle` log:

```bash
cast receipt <REGISTER_TX_HASH> --rpc-url $R --json \
  | jq '.logs[] | select(.address|ascii_downcase == "'$ETHREG'") | .topics, .data'
```

The `id` in `TransferSingle(address,address,address,uint256 id,uint256 value)` is the
tokenId. Save it into `.env`:

```bash
LEASH_TOKEN_ID=0x...
```

Verify the owner:

```bash
cast call $ETHREG 'ownerOf(uint256)(address)' $LEASH_TOKEN_ID --rpc-url $R
# expect = $ADMIN_ADDR
```

#### What to do on 9/4 (**not today — that would be code**)

```
setResolver(tokenId, <our PermissionedResolver>)
setSubregistry(tokenId, <our LeashRegistry>)
```

---

## E. Documents

### Step 10 — the feedback document ✅

`docs/world-feedback.md` is started, with the first entry written.

**The rule: every time you hit a wall, add a line right then.** Written up afterwards it
reads as invented, and a judge can tell.

---

### Step 11 — close out PLAN.md's open questions ✅

| Open question | Where it stands |
|---|---|
| Which ENS name to register | ✅ `leash.eth`, 8.000021 USDC/yr, confirmed available |
| Which token the demo pays in | Recommend **MockUSDC** (ENS registration needs it anyway, so nothing new is introduced) |
| How much frontend to build | Recommend **one page**, carrying only the Selfie Check trigger and a change-limit form |
| The World Sandbox flow | ✅ researched; see step 4 |

I recommend settling the first two outright. The third needs your agreement — the frontend
is the only part that can consume a large amount of time.

---

## Appendix: where the measurements came from

All of the following was obtained on **2026-09-01 / 09-02** by hitting
`https://ethereum-sepolia-rpc.publicnode.com` with `cast`, not by copying documentation:

- `leash`'s availability, the 8.000021 USDC price, and premium 0
- MIN/MAX commitment age、MIN duration
- The exact signatures of six functions (reversing the selectors to settle `bytes32` vs
  `uint256`)
- MockUSDC's symbol, decimals, and that `mint` has no access control
- That `setSubregistry`, `setResolver` and `ownerOf` really exist on ETHRegistry

The remaining ENSv2 facts are in `docs/ensv2-sepolia.md`.
