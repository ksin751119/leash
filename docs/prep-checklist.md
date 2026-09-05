# 開工前準備清單(9/2 – 9/3)

> 賽道規則:**Start from Scratch,9/4 之前不可寫任何專案程式碼。**
> 這份清單裡的每一項都**不是**寫程式碼 —— 是註冊帳號、申請權限、領測試幣、
> 取得名稱資源、安裝工具、寫文件。9/4 一到就能直接開寫。
>
> 灰色地帶的判斷:
> - ✅ 註冊 ENS 名字 = 取得資源(等同買 domain),**不是**程式碼
> - ✅ 安裝 npm 套件、建空專案骨架 = 環境設定
> - ❌ 寫 `.sol`、寫 subgraph mapping、寫前端元件 = **要等 9/4**
>
> 最後更新:2026-09-02

---

## 進度總表

| # | 項目 | 阻塞誰 | 狀態 |
|---|---|---|---|
| 1 | World Sandbox 表單 | World 全線 | ✅ 已送(9/2) |
| 2 | World Developer Portal app | 步驟 3 | ✅ `app_452654c9…1c00`,已寫入 `.env`(9/2) |
| 3 | Selfie Check feature flag 申請信 | World 全線 | ✅ 已寄(9/2) |
| 4 | 安裝 Sandbox App | World demo | ⏳ Portal per-email 入組**已送出,待核准**(9/2) |
| 5 | The Graph Studio 帳號 + deploy key | subgraph 部署 | ✅ key 已驗證(`graph auth` 通過),CLI v0.98.1(9/2) |
| 6 | 產生兩把 key | 所有鏈上動作 | ✅ 已產生,寫入 `.env`(9/2) |
| 7 | 領 Sepolia ETH | 所有鏈上動作 | ✅ human 0.126 / agent 0.053 ETH(9/2) |
| 8 | mint MockUSDC | ENS 註冊 + demo 付款 | ✅ 兩邊各 1000 USDC(9/2) |
| 9 | 註冊 `leash.eth` | ENS 全線 | ✅ **已註冊**,tokenId 在 `.env`(9/2) |
| 10 | 開 feedback document | World 提交 | ✅ 已開(9/2) |
| 11 | 收掉 PLAN.md 未決事項 | 9/4 開寫 | ✅ 四項全部定案(9/2) |

**關鍵路徑是 1 → 3 → 4 → (等 World 回信)。** 回信時間不在我們手上,
所以 5–9 要平行做完,不要排隊等。

---

## A. World

### 步驟 1 — Sandbox 存取表單 ✅

網址:https://forms.gle/mqbaiwMvX5MzmKdY8
(出處:ETHGlobal World 獎項頁 → Resources → Sandbox Access)

表單名稱「World ID Sandbox Beta Access Request」,只有一個欄位:email。
給的是 **Firebase App Distribution** 的存取權。

> ⚠️ **這張表單不會開 Selfie Check 的 feature flag。**
> 它沒問 app_id,而且明講是 App Distribution。兩件事,見步驟 3。

**已於 2026-09-02 送出。**

---

### 步驟 2 — 建立 Developer Portal app ⬜

1. 開 https://developer.world.org,用 World ID 或 email 登入
2. 建立新的 app,名稱填 **`Leash`**
3. 環境選 **Staging / Sandbox**(不是 Production)
4. 建完後在 app 設定頁複製 **`app_id`** —— 格式是 `app_` 開頭的一長串
5. 如果設定頁另外有列 **`rp_id`**,一併複製
   (驗證端點是 `https://developer.world.org/api/v4/verify/${rp_id}`)
6. 把兩個值存進 `.env`(已 gitignore):

```bash
WORLD_APP_ID=app_xxxxxxxxxxxxxxxxxxxxxxxx
WORLD_RP_ID=rp_xxxxxxxxxxxxxxxxxxxxxxxx
```

**順便看一眼側邊欄有沒有「World ID Sandbox」這一項** —— Android 的 tester
存取是在那裡處理的(輸入你 Google Play 帳號的 email 送出申請)。
有沒有這一項、好不好找,**記下來寫進 feedback document**。

---

### 步驟 3 — 申請 Selfie Check (Beta) feature flag ✅

收件人:**`developers@toolsforhumanity.com`**

這道門在官方文件出現三次,全部是 Mintlify `<Warning>` 彩色框:

| 頁面 | 原文 |
|---|---|
| `world-id/idkit/credentials#selfie-check-beta` | 「Request access to enable Selfie Check (Beta) for your app.」 |
| `world-id/credentials/11` | 「Selfie Check (Beta) is **access-gated**.」 |
| `world-id/sandbox/testing-selfie-check` | 「must be enabled for your app **before you can test it**.」 |

> 💡 把任何 `docs.world.org` 網址結尾加上 `.md`,就拿得到原始 markdown,
> 可以直接 grep。網頁版的 `<Warning>` 框很容易用眼睛掃過去。

**已於 2026-09-02 寄出。**

**如果 9/5 還沒回音,加開第三條線:** hackathon Discord 的 World sponsor 頻道,
貼一句 —— 「Submitted the sandbox form + emailed developers@toolsforhumanity.com
on Sept 2 for Selfie Check (Beta) flag. app_id `app_xxx`. Anything else needed?」

---

### 步驟 4 — 安裝 Sandbox App ⬜

> ⚠️ **官方文件的 iOS 說明是錯的。** 文件叫你開公開 TestFlight 連結
> (`testflight.apple.com/join/VZEurhHe`)並說「不需要 per-email 邀請」——
> 該連結 2026-09-02 已關閉(「不接受新測試人員」),而且實際上**就是**要 per-email 邀請。
> 正確入口在 Developer Portal,文件完全沒提。

**iOS —— 走 Developer Portal,不是文件上那個連結**

1. 從 App Store 裝 TestFlight
2. Developer Portal → **Install World ID Sandbox** → **iOS** 分頁
3. 送出你的 **Apple Account email** 入組
4. 核准後會收到 email,**World ID Sandbox 會自己出現在 TestFlight 裡**

Android 分頁在同一個面板,流程一樣(送 Google Play 帳號的 email)。

**Android —— 要等**

1. 先確認你 Google Play 用的是哪個 Google 帳號
2. 到 Developer Portal → 側邊欄 **World ID Sandbox** → 填那個 email 申請 tester
3. **等到核准才點測試連結**,提早點會顯示「無法使用」
4. 核准後,手機 Google Play 確認登入的是同一個帳號,再掃 Portal 上的 QR

> 官方 troubleshooting 提到:剛第一次登入 Google Play 的帳號,
> Google 要 **至少 15 分鐘** 才認得出來。太快點會失敗。

**裝好之後先跑一次 Cold flow**(建帳號 → 生日 → 邀請碼 → enrollment),
把每一步的摩擦記進 feedback document。這一步的素材事後補不回來。

---

## B. The Graph

### 步驟 5 — Studio 帳號 + deploy key ⬜

1. 開 https://thegraph.com/studio
2. 連錢包(用**步驟 6 的 human master EOA**,保持一致)
3. 建立 subgraph,名稱 `leash-sepolia`
4. 複製 **deploy key**,存進 `.env`:

```bash
GRAPH_DEPLOY_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
```

5. 全域安裝 CLI(這是工具,不是專案程式碼):

```bash
pnpm add -g @graphprotocol/graph-cli
graph --version
```

**不需要審核,連錢包就開。**

> 獎項條件寫的是「必須吃 live data(**Subgraph Studio** 或 The Graph Market)」——
> **Studio 就符合**,不必 publish 到 decentralized network,也不必買 GRT。

subgraph 的 `schema.graphql` 和 mapping 是程式碼,**9/4 再寫**。

---

## C. 錢包與資金

### 步驟 6 — 產生兩把 key ⬜

架構上需要兩個角色:

| 角色 | 用途 | 被 7702 委派? |
|---|---|---|
| **ADMIN** | 擁有 `leash.eth` 與 ENS EAC 角色。改規則、撤銷 agent | ❌ 絕不 |
| **WALLET** | 裝錢的那個。agent 花的是這裡的錢 | ✅ 委派成 LeashAccount |
| **AGENT** | session key。什麼都不持有,只是被 policy 認得的 `msg.sender` | ❌ |

> **為什麼 ADMIN 和 WALLET 必須是兩把 key:** LeashAccount 外送呼叫時
> `msg.sender` 就是 WALLET 本身。如果 WALLET 同時持有 ENS 角色,agent 只要讓
> account 呼叫 `ETHRegistry.setResolver(...)`,就能借用錢包的權限改掉自己的 policy。
> 分開之後這條路結構性地不存在 —— **壞掉的 policy 最多花光錢,動不了控制權。**

```bash
cast wallet new
cast wallet new
```

存進 tx-mcp 那套 `.env`(**已經在 .gitignore**,確認一次):

```bash
ADMIN_PK=0x...
ADMIN_ADDR=0x...
AGENT_PK=0x...
AGENT_ADDR=0x...
SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com
```

> ⚠️ 這是測試網,但還是別把這兩把 key 用在任何主網資產上,也別 commit。

---

### 步驟 7 — 領 Sepolia ETH ⬜

**兩個地址都要領。** faucet 有 rate limit,今天領,不要 9/4 早上才發現領不到。

擇一或多領:

| 來源 | 備註 |
|---|---|
| ETHGlobal faucet(`ethglobal.com/faucet`) | 活動參加者專用,額度通常最大方 |
| Google Cloud Web3 faucet | 需要 Google 帳號 |
| Alchemy Sepolia faucet | 需要 Alchemy 帳號 |

目標:**每個地址 ≥ 0.1 ETH**。ENS 註冊 + 部署合約 + demo 交易加起來夠用。

確認:

```bash
source .env
cast balance $ADMIN_ADDR --rpc-url $SEPOLIA_RPC --ether
cast balance $AGENT_ADDR --rpc-url $SEPOLIA_RPC --ether
```

---

### 步驟 8 — mint MockUSDC ⬜

ENSv2 Sepolia 的註冊費用是拿 **MockUSDC** 付的,不是 ETH。

```
地址     0x768f42455a2d082e23ceef7d51e5787c82d67a39
symbol   USDC
decimals 6
mint     mint(address,uint256)  =  0x40c10f19   ← 沒有權限檢查,任何 EOA 都能鑄
```

鑄 1000 USDC 到 human 地址(6 位小數,所以是 `1000000000`):

```bash
source .env
export USDC=0x768f42455a2d082e23ceef7d51e5787c82d67a39

cast send $USDC 'mint(address,uint256)' $ADMIN_ADDR 1000000000 \
  --private-key $ADMIN_PK --rpc-url $SEPOLIA_RPC

cast call $USDC 'balanceOf(address)(uint256)' $ADMIN_ADDR --rpc-url $SEPOLIA_RPC
```

順便鑄一些給 agent 地址,demo 付款會用到:

```bash
cast send $USDC 'mint(address,uint256)' $AGENT_ADDR 1000000000 \
  --private-key $ADMIN_PK --rpc-url $SEPOLIA_RPC
```

---

## D. ENS

### 步驟 9 — 註冊 `leash.eth` ⬜

**2026-09-02 查證:仍未被註冊。一年 8.000021 USDC,premium 0。**

註冊時 `subregistry` 和 `resolver` **兩個參數都填 `address(0)`**。
9/4 再用 `setSubregistry` / `setResolver` 指到我們自己的合約 ——
這樣「取得名字」(今天,不是程式碼)和「接上架構」(9/4,是程式碼)乾淨分開。

#### 合約與常數(全部實測過)

```
ETHRegistrar   0xa88553f454b77203b0d036a05c894d555eaaa2cc
ETHRegistry    0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
PriceOracle    0x8914b66260eb8c4fff795650c3ae8cd335958987
MockUSDC       0x768f42455a2d082e23ceef7d51e5787c82d67a39

MIN_COMMITMENT_AGE   60 秒
MAX_COMMITMENT_AGE   2,419,200 秒(28 天)
MIN_DURATION         86,400 秒(1 天)
```

函式簽章(用 selector 反推驗證過,**secret 和 referrer 是 `bytes32` 不是 `uint256`**):

```
isAvailable(string)                                                       0x965306aa
getRegisterPrice(string,uint64,address)                                   0x61907b12
makeCommitment(string,address,bytes32,address,address,uint64,bytes32)     0x1e966f07
commit(bytes32)                                                           0xf14fcbc8
register(string,address,bytes32,address,address,uint64,address,bytes32)   0xcff3e7c2
renew(string,uint64,address,bytes32)                                      0x89d779c3
```

#### 9-1. 設定環境

```bash
source .env
export R=$SEPOLIA_RPC
export REGISTRAR=0xa88553f454b77203b0d036a05c894d555eaaa2cc
export ETHREG=0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
export USDC=0x768f42455a2d082e23ceef7d51e5787c82d67a39
export LABEL=leash
export DURATION=31536000          # 1 年
export ZERO=0x0000000000000000000000000000000000000000
export ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
```

#### 9-2. 再確認一次還沒被搶

```bash
cast call $REGISTRAR 'isAvailable(string)(bool)' "$LABEL" --rpc-url $R
# 期望 true
```

#### 9-3. 查價

```bash
cast call $REGISTRAR 'getRegisterPrice(string,uint64,address)(uint256,uint256)' \
  "$LABEL" $DURATION $USDC --rpc-url $R
# 期望 8000021 (= 8.000021 USDC) 和 0 (premium)
```

#### 9-4. 授權 registrar 扣款

多批一點,避免價格微幅浮動導致失敗:

```bash
cast send $USDC 'approve(address,uint256)' $REGISTRAR 20000000 \
  --private-key $ADMIN_PK --rpc-url $R
```

#### 9-5. 產生 secret 並算 commitment

**secret 一定要存下來** —— 第 9-7 步要用同一個值,弄丟就得重來。

```bash
export SECRET=$(cast keccak "leash-ethonline-2026-$(date +%s)-$RANDOM")
echo "SECRET=$SECRET"          # ← 存進 .env,別關掉這個 terminal

export COMMITMENT=$(cast call $REGISTRAR \
  'makeCommitment(string,address,bytes32,address,address,uint64,bytes32)(bytes32)' \
  "$LABEL" $ADMIN_ADDR $SECRET $ZERO $ZERO $DURATION $ZERO32 \
  --rpc-url $R)
echo "COMMITMENT=$COMMITMENT"
```

#### 9-6. 送出 commit,等 60 秒

```bash
cast send $REGISTRAR 'commit(bytes32)' $COMMITMENT \
  --private-key $ADMIN_PK --rpc-url $R

sleep 75      # MIN 是 60 秒,多等一點保險
```

> 時間窗:**最早 60 秒後,最晚 28 天內**。中間斷掉不用重 commit。

#### 9-7. 註冊

```bash
cast send $REGISTRAR \
  'register(string,address,bytes32,address,address,uint64,address,bytes32)' \
  "$LABEL" $ADMIN_ADDR $SECRET $ZERO $ZERO $DURATION $USDC $ZERO32 \
  --private-key $ADMIN_PK --rpc-url $R
```

#### 9-8. 驗證

```bash
# 應該變成 false
cast call $REGISTRAR 'isAvailable(string)(bool)' "$LABEL" --rpc-url $R

# 這兩個現在應該都是 0 —— 這是預期的,9/4 才接上
cast call $ETHREG 'getSubregistry(string)(address)' "$LABEL" --rpc-url $R
cast call $ETHREG 'getResolver(string)(address)'    "$LABEL" --rpc-url $R
```

**把 tokenId 找出來存好** —— `setSubregistry(uint256,address)` 和
`setResolver(uint256,address)` 都吃 tokenId,不是字串。

ENSv2 的 tokenId 混了版本號,**不要自己算 labelhash**,直接從註冊交易的
ERC-1155 `TransferSingle` log 讀:

```bash
cast receipt <REGISTER_TX_HASH> --rpc-url $R --json \
  | jq '.logs[] | select(.address|ascii_downcase == "'$ETHREG'") | .topics, .data'
```

`TransferSingle(address,address,address,uint256 id,uint256 value)` 的 `id`
就是 tokenId。存進 `.env`:

```bash
LEASH_TOKEN_ID=0x...
```

驗證擁有者:

```bash
cast call $ETHREG 'ownerOf(uint256)(address)' $LEASH_TOKEN_ID --rpc-url $R
# 期望 = $ADMIN_ADDR
```

#### 9/4 要做的(**今天不要做,那是程式碼**)

```
setResolver(tokenId, <我們的 PermissionedResolver>)
setSubregistry(tokenId, <我們的 LeashRegistry>)
```

---

## E. 文件

### 步驟 10 — feedback document ✅

已開 `docs/world-feedback.md`,第一筆已寫入。

**規則:每撞一次牆,當下補一行。** 事後補寫一定假,評審看得出來。

---

### 步驟 11 — 收掉 PLAN.md 未決事項 ⬜

| 未決事項 | 現況 |
|---|---|
| 註冊哪個 ENS 名字 | ✅ `leash.eth`,8.000021 USDC/yr,已驗證可用 |
| demo 付款 token | 建議 **MockUSDC**(反正 ENS 註冊就要用,不多引入一個東西) |
| 前端做多少 | 建議 **一頁**,只放 Selfie Check 觸發 + 改額度表單 |
| World Sandbox 流程 | ✅ 已研究,見步驟 4 |

前兩項我直接建議定案。第三項要你點頭 —— 前端是唯一會吃掉大量時間的部分。

---

## 附錄:實測數據來源

以下全部在 **2026-09-01 / 09-02** 用 `cast` 對
`https://ethereum-sepolia-rpc.publicnode.com` 實際敲出來,不是抄文件:

- `leash` 可用性、8.000021 USDC 價格、premium 0
- MIN/MAX commitment age、MIN duration
- 六個函式的精確簽章(用 selector 反推 `bytes32` vs `uint256`)
- MockUSDC 的 symbol / decimals / `mint` 無權限檢查
- ETHRegistry 上 `setSubregistry` / `setResolver` / `ownerOf` 確實存在

其餘 ENSv2 事實見 `docs/ensv2-sepolia.md`。
