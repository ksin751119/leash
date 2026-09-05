# ENSv2 on Sepolia — 實測結果

> 實測日期:2026-09-01
> RPC:`https://ethereum-sepolia-rpc.publicnode.com`
> 工具:`cast` (foundry 1.7.1)
> **以下每一項都是實際敲鏈得到的,不是文件推測。**

ENSv2 目前**只在 Sepolia**(Beta 於 2026-08-12 啟動),主網尚未上線。
這也解釋了為什麼 ENS 的獎項規定 Sepolia only。

---

## 合約位址(全部確認有 bytecode)

| 合約 | 位址 |
|---|---|
| RootRegistry | `0x8115186e8f2e0b0281e86ab91f0f48ba90364354` |
| ETHRegistry | `0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2` |
| ETHRegistrar | `0xa88553f454b77203b0d036a05c894d555eaaa2cc` |
| UniversalResolverV2 | `0x4a1817d13e9cf196f471725176355c1234b63c70` |
| PublicResolverV2 | `0xe7b9a25607e02da8145e4eb1836ca539e53f11f7` |
| PermissionedResolverImpl | `0x9eae5c2730a7dd16bdd1dee6421a1b91e3b0365e` |
| ManagedUniversalResolverProxy | `0x6d80F2172CFdEc5730fE683860C33d26fC42e6F1` |
| **MockUSDC**(註冊付款代幣) | `0x768f42455a2d082e23ceef7d51e5787c82d67a39` |
| PriceOracle | `0x8914b66260eb8c4fff795650c3ae8cd335958987` |

RootRegistry 與 ETHRegistry 的 bytecode 長度相同(29463 chars),
符合「兩者都是 PermissionedRegistry 實例」。

MockUSDC:symbol `USDC`,6 位小數,`mint(address,uint256)`(`0x40c10f19`)
**無權限控管** —— 以隨機地址 `eth_call` 模擬鑄造成功。另有 `permit`。

---

## ⚠️ 最重要的發現:resolver 只支援 ENSIP-10

```
supportsInterface(addr    0x3b3b57de) = false
supportsInterface(text    0x59d1d43c) = false
supportsInterface(resolve 0x9061b923) = TRUE
```

**直接呼叫 `addr(bytes32)` / `text(bytes32,string)` 會 revert。實測三個全掛。**

必須改用 ENSIP-10 wildcard 介面:

```solidity
resolver.resolve(
    dnsEncodedName,                                  // 例:0x046e69636b0365746800
    abi.encodeCall(ITextResolver.text, (node, "policy"))
);
```

### 而這正是好消息

實測 `resolve()` **直接回傳資料** —— 沒有 `OffchainLookup` revert、沒有 gateway、沒有 CCIP-read。

> **原本「合約在執行當下讀不到 policy」這個會推翻整個架構的風險,現在是實測排除的。**

實作提醒:別照 ENSv1 的習慣寫 `addr()`,會白白浪費時間。

---

## 鏈上 walk 驗證(`nick.eth`)

```
RootRegistry.getSubregistry("eth")
  → 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2      ✅ 與文件的 ETHRegistry 完全一致

ETHRegistry.getResolver("nick")
  → 0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba

resolver.resolve(0x046e69636b0365746800, addr(node))
  → 0xb8c2c29ee19d8307cb7255e1cd9cbde883a267d5
```

**用 UniversalResolverV2 跑同一個查詢,回傳完全相同的位址。**
我們手動走的路徑與官方入口等價 —— 代表 7702 delegate 可以自己走,
不必依賴 UniversalResolver。

---

## 已驗證的 selector

### IRegistry / PermissionedRegistry

| 函式 | selector | 用途 |
|---|---|---|
| `getSubregistry(string)` | `0x35af6216` | walk 下一層 |
| `getResolver(string)` | `0xe4ae7d77` | 取得 resolver |
| **`setSubregistry(uint256,address)`** | **`0x341ec559`** | **全滅撤銷** |
| `setResolver(uint256,address)` | `0xbc7b6d62` | 換 policy |
| `ownerOf(uint256)` | `0x6352211e` | ERC1155Singleton |
| `getResource(uint256)` | `0x1e8fca2d` | EAC resource |

### ETHRegistrar

| 函式 | selector |
|---|---|
| `isAvailable(string)` | `0x965306aa` |
| `getRegisterPrice(string,uint64,address)` → `(base, premium)` | `0x61907b12` |
| `getRenewPrice(string,uint64,address)` | `0xddf0effc` |
| `commit(bytes32)` | `0xf14fcbc8` |
| `makeCommitment(string,address,uint256,address,address,uint64,uint256)` | `0x1e966f07` |
| `register(string,address,uint256,address,address,uint64,address,uint256)` | `0xcff3e7c2` |

常數(實測值):

| 常數 | 值 |
|---|---|
| MIN_COMMITMENT_AGE | 60 秒 |
| MAX_COMMITMENT_AGE | 86400 秒(24 小時) |
| MIN_REGISTRATION_DURATION | 2419200 秒(28 天) |

---

## 註冊流程

經典 commit-reveal:

```
makeCommitment(label, owner, secret, subregistry, resolver, duration, referrer)
  → commit(commitment)
    → 等 ≥60 秒
      → register(label, owner, secret, subregistry, resolver, duration, paymentToken, referrer)
```

### 對我們最關鍵的一點

**`register()` 的參數裡本來就有 `subregistry`。**
註冊 `acme.eth` 的當下就能把我們自己的 registry 掛上去,不需要事後再設定。

註冊者拿到的 role bitmap 包含:
`ROLE_SET_SUBREGISTRY`、`ROLE_SET_SUBREGISTRY_ADMIN`、
`ROLE_SET_RESOLVER`、`ROLE_SET_RESOLVER_ADMIN`、`ROLE_CAN_TRANSFER_ADMIN`

→ **「一筆交易讓全公司 agent 停機」確認可行。**

---

## 價格(MockUSDC,可自由鑄造 = 實質免費)

| 名字 | 1 年 | 備註 |
|---|---|---|
| `agentwallet` | **8.000021 USDC** | 5 字以上 |
| `policy-agent-demo` | **8.000021 USDC** | |
| `acme` | 160.000009 USDC | 4 字加價;28 天只要 12.27 |

**實測可註冊**:`acme` `agentwallet` `policyagent` `hackathon` `ethglobal` `company` `parent` `sub`
**已被註冊**:`nick` `test` `ens` `dao` `agent` `demo` `org` `integration-tests`

---

## 附帶觀察

**每個名字真的會拿到自己的 resolver clone。**
從一筆真實註冊交易中看到一個 78 bytes 的合約被建立(EIP-1167 minimal proxy),
且 `supportsInterface(0x9061b923)` = true。
證實文件說的「per-account Permissioned Resolver」。

**ENSv2 Sepolia 非常活躍。**
最近 5000 個區塊內有 **1813 筆** registrar 事件。
好處:網路是活的、文件有人維護。
壞處:**印證了「審計期間(8/18–9/14)可能重新部署」的風險是實的** —— 位址要集中管理。

---

## 已知的坑

官方 app-developer 教學明講:

> subname owners typically hold no roles on the parent resolver,
> so a `setText` from their wallet reverts with `EACUnauthorizedAccountRoles`

子名持有者**預設不能改父 resolver 上的記錄**。

解法:給子名自己的 resolver,或用 `authorize*Roles` 把 role 授權下去。

**對我們而言這是 feature 不是 bug** —— agent 本來就不該能改自己的 policy。

---

## 重現方式

```bash
export R=https://ethereum-sepolia-rpc.publicnode.com
ROOT=0x8115186e8f2e0b0281e86ab91f0f48ba90364354

# 1. walk 到 .eth
cast call $ROOT "getSubregistry(string)(address)" "eth" --rpc-url $R

# 2. 取得 nick.eth 的 resolver
ETHREG=0xbdc85dd5b15d7ecb354cd7cb6f2c50b4f2c4f0e2
cast call $ETHREG "getResolver(string)(address)" "nick" --rpc-url $R

# 3. 用 ENSIP-10 讀記錄(注意:直接 addr() 會 revert)
RES=0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba
NODE=$(cast namehash nick.eth)
cast call $RES "resolve(bytes,bytes)(bytes)" \
  0x046e69636b0365746800 $(cast calldata "addr(bytes32)" $NODE) --rpc-url $R
```

---

## tokenId 的推導規則(2026-09-02 實測)

`setSubregistry(uint256,address)` 和 `setResolver(uint256,address)` 都吃 **tokenId**,
不是字串。實際註冊 `leash.eth` 之後對照出來:

```
keccak256("leash") = 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011342ffc412
實際 tokenId       = 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000
                                                                              ^^^^^^^^
```

**tokenId = labelhash 的最低 32 bits 歸零。**

```solidity
uint256 tokenId = uint256(keccak256(bytes(label))) & ~uint256(type(uint32).max);
```

那 32 bits 是 `Entry.tokenVersionId`。名字被 burn / 過期重註冊時會遞增,
**tokenId 會跟著改變** —— 所以任何長期保存 tokenId 的地方都要考慮這件事。

新註冊的名字 `tokenVersionId` 是 0,所以現在剛好等於 labelhash 對齊後的值,
但**不要依賴這個巧合**。最保險是從 ERC-1155 `TransferSingle` log 讀:

```bash
cast receipt <TX> --rpc-url $R --json \
  | python3 -c "..."   # topics[0] == keccak('TransferSingle(address,address,address,uint256,uint256)')
                       # data[0:32] = id
```

## 實際註冊紀錄(可重現的基準)

| 項目 | 值 |
|---|---|
| 名稱 | `leash.eth` |
| owner | `0x36B3F5364A0dE03dc8eBaf0162C516E22D6bF959` |
| tokenId | `0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000` |
| 期間 | 31536000 秒(1 年) |
| 付款 | MockUSDC **8.000021**(= getRegisterPrice 的報價,無誤差) |
| register gas | 217,387 |
| commit tx | `0x0339df95b0b66399e3d5ff46253747551fb4ae74c2b6fff9ef0a81ecf9bc440e` |
| register tx | `0xcf6792b412f8d61cd1b00115b7c838a79a7cc76ae206f2f83f316bb5ab5a9d08` |
| 註冊時 subregistry / resolver | 皆 `address(0)`,9/4 才接上 |

**函式簽章(用 selector 反推驗證,`secret` 與 `referrer` 是 `bytes32` 不是 `uint256`):**

```
isAvailable(string)                                                       0x965306aa
getRegisterPrice(string,uint64,address)                                   0x61907b12
makeCommitment(string,address,bytes32,address,address,uint64,bytes32)     0x1e966f07
commit(bytes32)                                                           0xf14fcbc8
register(string,address,bytes32,address,address,uint64,address,bytes32)   0xcff3e7c2
renew(string,uint64,address,bytes32)                                      0x89d779c3
```

MIN_COMMITMENT_AGE = 60 秒 · MAX_COMMITMENT_AGE = 2,419,200 秒(28 天) · MIN_DURATION = 86,400 秒

---
---

# 2026-09-03 賽前研究(全部 read-only,唯二寫入是 7702 授權與撤銷)

## 一、EIP-7702 在 Sepolia 完全可用 ✅

foundry 1.7.1 支援:`cast send --auth <address>`、`cast wallet sign-auth`。

**實測(agent EOA 委派給 MockUSDC 再撤銷):**

```bash
# 委派
cast send $ADMIN_ADDR --auth $MOCK_USDC --private-key $AGENT_PK --value 0
#   tx 0xfc91071b…08fa · status 1 · type 0x4 · gas 36,800
cast code $AGENT_ADDR
#   0xef0100768f42455a2d082e23ceef7d51e5787c82d67a39
#   = 0xef0100 + delegate 位址,正是 EIP-7702 的 delegation designator

# 撤銷
cast send $ADMIN_ADDR --auth 0x0000000000000000000000000000000000000000 --private-key $AGENT_PK --value 0
#   tx 0x8c083e58…1b296 · gas 36,800
cast code $AGENT_ADDR   # → 0x
```

**⚠️ 陷阱一:交易的 `to` 不能是被委派的 EOA 自己。**
委派生效後,空 calldata 會打到 delegate 的 fallback。第一次嘗試就是這樣 revert 的
(`Failed to estimate gas: execution reverted, data: "0x"`)。
把 `to` 換成任何普通位址即可 —— 授權是掛在交易上的,跟 `to` 無關。

**⚠️ 陷阱二(對架構重要):委派後的程式碼在 EOA 自己的 storage 執行。**

委派給 MockUSDC 之後,對 EOA 位址呼叫:

```
decimals()  → 0     (不是 6)
symbol()    → ""    (不是 "USDC")
```

函式**有執行**(沒 revert),但讀到的是 EOA 的空 storage,不是 MockUSDC 的。

→ **我們的 delegate 不能依賴自己的 storage。**
policy 位址要從 ENS 走出來、policy 合約要 stateless —— 現行設計正好吻合。
如果哪天想在 delegate 裡存狀態,必須刻意規劃 EOA 的 storage layout。

**成本:委派 + 撤銷各約 36,800 gas。**

---

## 二、`PermissionedRegistry` 完整 ABI(這就是 `LeashRegistry` 的參考實作)

**RootRegistry 與 ETHRegistry 的 selector 集合完全相同** —— 同一套實作。
以下由 bytecode 抽 selector + openchain 簽章庫還原,**不是從文件抄的**。

### 名稱操作

| 函式 | selector |
|---|---|
| `register(string,address,address,address,uint256,uint64)` | `0x85f3e643` |
| `unregister(uint256)` | `0xa02b161e` |
| `renew(uint256,uint64)` | `0x5569f33d` |
| `setSubregistry(uint256,address)` | `0x341ec559` |
| `setResolver(uint256,address)` | `0xbc7b6d62` |
| `setParent(address,string)` | `0x5357263f` |
| `setURI(string,address)` | `0x48688f95` |

`register` 的第 5 個參數 `uint256` 是 **roleBitmap**,第 6 個是 expiry。
這就是 `LeashRegistry` 發 `alpha.leash.eth` 這種子名的入口。

### 查詢

| 函式 | selector | 說明 |
|---|---|---|
| `getSubregistry(string)` | `0x35af6216` | |
| `getResolver(string)` | `0xe4ae7d77` | |
| `getParent()` | `0x80f76021` | 回傳 (registry, label) |
| **`findTokenId(string)`** | **`0x91b3c037`** | **見下方** |
| `findOwner(string)` | `0x63560a8e` | |
| `findExpiry(string)` | `0x6f537c72` | |
| `getTokenId(uint256)` | `0x14ff5ea3` | |
| `getOwner(uint256)` | `0xc41a360a` | |
| `latestOwnerOf(uint256)` | `0xbd242bcb` | |
| `getExpiry(uint256)` | `0x13c72608` | |
| `getState(uint256)` | `0x44c9af28` | |
| `getStatus(uint256)` | `0x5c622a0e` | |
| `getResource(uint256)` | `0x1e8fca2d` | |
| `ROOT_RESOURCE()` | `0x1c3fc3eb` | = 0 |
| `LABEL_STORE()` | `0x9dbba19d` | |
| `isContractNamer(address)` | `0x6f3ff726` | |
| `uri(uint256)` | `0x0e89341c` | |

### Enhanced Access Control(EAC)

| 函式 | selector |
|---|---|
| `roles(uint256,address)` | `0x5adf4724` |
| `roleCount(uint256)` | `0x2f27fa24` |
| `hasRoles(uint256,uint256,address)` | `0xd3bf89b1` |
| `grantRoles(uint256,uint256,address)` | `0x7c300586` |
| `revokeRoles(uint256,uint256,address)` | `0xdfa70d8b` |
| `hasRootRoles(uint256,address)` | `0x781ef8db` |
| `grantRootRoles(uint256,address)` | `0x072d5d77` |
| `revokeRootRoles(uint256,address)` | `0xce156e82` |
| `hasAssignees(uint256,uint256)` | `0x11b8e00a` |
| `getAssigneeCount(uint256,uint256)` | `0x3634f911` |

外加標準 ERC-1155(`balanceOf`、`balanceOfBatch`、`setApprovalForAll`、
`isApprovedForAll`、`safeTransferFrom`、`safeBatchTransferFrom`、`ownerOf`)。

---

## 三、`findTokenId(string)` 讓「解 log 撈 tokenId」的做法作廢

```bash
cast call $ETH_REGISTRY 'findTokenId(string)(uint256)' "leash"
#  → 0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000
#  與從 TransferSingle log 解出來的完全一致
```

**一行 view 就拿得到,不用解交易 receipt。** 本文件前段那套 log 解析法留著當備援
(例如需要在同一筆交易裡取得),但日常查詢用 `findTokenId`。

`findOwner(string)` / `findExpiry(string)` 同理,省掉「先算 tokenId 再查」兩步。

---

## 四、`leash.eth` 的角色配置(實測解碼)

```
resource   = getResource(tokenId) = tokenId 本身
roles      = 0x1110000000000000000000000000000001100000
bits       = [20, 24, 148, 152, 156]
```

EAC 的規則是 **bit N 是角色本身,bit N+128 是該角色的 admin**:

| bit | 意義 |
|---|---|
| 20 | 基本角色(可 `setSubregistry`) |
| 24 | 基本角色(可 `setResolver`) |
| 148 | bit 20 的 admin |
| 152 | bit 24 的 admin |
| 156 | **bit 28 的 admin —— 但不持有 bit 28 本身** |

也就是說:**owner 沒有角色 28,但可以把角色 28 授予任何人(包括自己)。**

### 權限模擬(`cast call --from human`,不改狀態)

| 動作 | 結果 |
|---|---|
| `setResolver(tid, …)` | ✅ |
| `setSubregistry(tid, …)` | ✅ |
| `safeTransferFrom(human→agent)` | ✅ 可轉讓 |
| `grantRoles(res, 1<<28, human)` | ✅ 可自授 |
| `renew(tid, …)` | ❌ **REVERT** |
| `unregister(tid)` | ❌ **REVERT** |

**續約要走 `ETHRegistrar.renew(string,uint64,address,bytes32)`(`0x89d779c3`)並付款**,
不能直接對 registry 呼叫。demo 期間不會遇到(到期日 1819875720 = 2027-09-02),
但別在程式裡寫錯對象。

---

## 五、Resolver 有兩種,別搞混

先前記錄的「ENSv2 resolver 只吃 ENSIP-10」需要細分 —— 兩種都存在:

### (a) 極簡型 —— 只有 ENSIP-10

`nick.eth` 的 resolver `0xae66c62AcAE72098BdAc57d8E8AED53EF000b2Ba`:

```
resolve(bytes,bytes)                  0x9061b923   ✅ 有
addr(bytes32)                         0x3b3b57de   ❌ 沒有,直接呼叫 revert
text(bytes32,string)                  0x59d1d43c   ❌ 沒有

supportsInterface(0x9061b923) → true
supportsInterface(0x3b3b57de) → false
supportsInterface(0x59d1d43c) → false
```

### (b) `PermissionedResolverImpl` `0x9eae5c27…365e` —— 兩者都有

```
resolve(bytes,bytes)                  0x9061b923   ✅
addr(bytes32)                         0x3b3b57de   ✅
addr(bytes32,uint256)                 0xf1cb7e06   ✅
text(bytes32,string)                  0x59d1d43c   ✅
contenthash(bytes32)                  0xbc1c58d1   ✅
setAddr / setText / setContenthash                 ✅
multicall(bytes[])                    0xac9650d8   ✅
```

而且是 **UUPS 可升級**(`upgradeToAndCall` `0x4f1ef286`、`proxiableUUID` `0x52d1902d`、
`UPGRADE_INTERFACE_VERSION` `0xad3cb1cc`),並帶同一套 EAC 角色函式。

### 對我們的結論(不變)

**`LeashResolver` 只實作 `resolve(bytes,bytes)` 就夠。**

理由:UniversalResolverV2 走的是 ENSIP-10,而 `nick.eth` 這種只實作 ENSIP-10 的
resolver 在鏈上能被正常解析 —— 已於 9/1 實測確認。legacy 介面是選配,不是必需。

---

## 權限分離實測(2026-09-03)

三把 key,`cast call --from` 模擬(不改狀態):

| 動作 | ADMIN | WALLET | AGENT |
|---|---|---|---|
| `setResolver(leashTokenId, …)` | ✅ | ❌ REVERT | ❌ REVERT |
| `setSubregistry(leashTokenId, …)` | ✅ | ❌ REVERT | — |
| `grantRoles(res, …)` | ✅ | ❌ REVERT | — |

```
roles(resource, ADMIN)  = 0x1110000000000000000000000000000001100000
roles(resource, WALLET) = 0
roles(resource, AGENT)  = 0
```

**這證明了架構的核心安全性質:** 被 7702 委派、且持有資金的 WALLET
**在 ENS 上完全沒有權限**。就算 policy 寫錯、允許任意 target,
agent 透過 account 呼叫 `ETHRegistry.setResolver` 也會 revert ——
不是因為我們檢查了,而是因為那把 key 本來就沒有角色。

**壞掉的 policy 的爆炸半徑被限制在「錢」,不會擴散到「控制權」。**
