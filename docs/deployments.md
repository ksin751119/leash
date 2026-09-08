# 部署紀錄 —— Sepolia

**鏈:** Sepolia (chain id `11155111`)
**部署時間:** 2026-09-08 13:31–13:34 UTC(block 11661370–11661383)
**部署者:** `0x36B3F5364A0dE03dc8eBaf0162C516E22D6bF959`(ADMIN)
**成本:** 0.005 ETH

> 每一筆的區塊時間戳都是**以太鏈蓋的,不可偽造** —— 這也是我們對
> ETHGlobal「Start from Scratch」規則的證據之一,見 `PROVENANCE.md`。

---

## 我們的合約

| 合約 | 位址 | 部署交易 |
|---|---|---|
| `LeashRegistry` | `0xd5fFf12CB229A1Ea9F2487681A627B9a3Bf73d29` | [`0x0f3e7f46…`](https://sepolia.etherscan.io/tx/0x0f3e7f468a1d35109f9ae0f53c47e61bd6ecc1907600a66dd9ad0035afd2bceb) |
| `LeashResolver` | `0x27fe60bABD73bbcdDff3f0448D3F4eB550A844F9` | [`0x75b1dcd4…`](https://sepolia.etherscan.io/tx/0x75b1dcd4fa92ba501754a2d17273c902588ca51767b893581dfae89390ada59b) |
| `PolicyApprovals` | `0x86A730e7f3B30aF6fFf01e9f3E70d9427a6a277B` | [`0xd07443ba…`](https://sepolia.etherscan.io/tx/0xd07443baa454184c9b6c11d783bc7460048906b65cc4f83b869be26df8038d01) |
| `StandardPolicy` | `0xB70F52e0FFc361E6e3c7765a58068308d4fa75cc` | [`0x58217b77…`](https://sepolia.etherscan.io/tx/0x58217b770622a743ab25f54d5203c148f6f331ecc962b2daf954a5c1d6132d0c) |
| `MockAttester` ⚠️ | `0x0989FC6859eeaE7C8Fe61db40Ea7Af17D4f374c1` | [`0x5e38635e…`](https://sepolia.etherscan.io/tx/0x5e38635ec9c72dd3f25620b52ee61b77c43815bdb93b03fb62673e7ddf2878a1) |

> ⚠️ **`MockAttester` 不做任何驗證,對任何輸入都回 `true`。** 它的 `describe()`
> 誠實回傳 `"MockAttester (NO verification - testing only)"`,前端會顯示。
> `WorldAttester`(真的刷臉)是 sprint 項目 8 的後半。

## 接線交易

| 動作 | 交易 |
|---|---|
| `PolicyApprovals.approve(StandardPolicy)` | [`0x6709b0ed…`](https://sepolia.etherscan.io/tx/0x6709b0ed00e17a117631404df9697f2b75c7b16b2b6024ceafcb2e2973038b1f) |
| `LeashRegistry.register("vendors", …, 30 天)` | [`0x7acb9aa3…`](https://sepolia.etherscan.io/tx/0x7acb9aa387728a49f0e0b56ee0803aada37e2dec3a30fec9ac0def32a85bdaaa) |
| `LeashResolver.setPolicy(vendors node, StandardPolicy)` | [`0x84a85a86…`](https://sepolia.etherscan.io/tx/0x84a85a868b6f42927b01b2091878c63d86f42e437a03285688a08c9768a64457) |
| **`ETHRegistry.setSubregistry(leash.eth, LeashRegistry)`** | [`0xc1768b17…`](https://sepolia.etherscan.io/tx/0xc1768b171a7ebc7a75e9317ffa873c00b75416ce69e58979fcd9dfcdd3f244de) |
| `ETHRegistry.setResolver(leash.eth, LeashResolver)` | [`0xc0d57eb5…`](https://sepolia.etherscan.io/tx/0xc0d57eb57eb1b8814b83468fb14ba5a01344a4095f4acf862fb47bcabfe34df3) |
| `LeashRegistry.setParent(ETHRegistry, "leash")` | [`0xb6ac3e39…`](https://sepolia.etherscan.io/tx/0xb6ac3e39b2de953dc63eb74860daf42944a981ab3a60d14be952ff76e306ba91) |

## ENSv2 的既有位址(不是我們部署的)

| 合約 | 位址 |
|---|---|
| RootRegistry | `0x8115186e8f2e0b0281e86ab91f0f48ba90364354` |
| ETHRegistry | `0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2` |
| UniversalResolverV2 | `0x4a1817d13e9cf196f471725176355c1234b63c70` |
| MockUSDC(我們 mint 的) | `0x768f42455a2d082e23ceef7d51e5787c82d67a39` |

## 名字與 node

| 名字 | 值 |
|---|---|
| `leash.eth` tokenId | `0xe5edd0e482c95985582112af99c7fa487b70360c42f108c45d55011300000000` |
| `leash.eth` 到期 | `1819875720` = 2027-09-02 |
| namehash(`vendors.leash.eth`) | `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121` |
| DNS 編碼(`vendors.leash.eth`) | `0x0776656e646f7273056c656173680365746800` |

---

## 鏈上驗證:自己走一次

複製貼上就能重現。`$R` 是任何一個 Sepolia RPC。

```bash
ROOT=0x8115186e8f2e0b0281e86ab91f0f48ba90364354
NODE=0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121
DNS=0x0776656e646f7273056c656173680365746800

# 1. root → eth
E=$(cast call $ROOT 'getSubregistry(string)(address)' eth --rpc-url $R)

# 2. eth → leash(這一步指向我們的 registry)
LR=$(cast call $E 'getSubregistry(string)(address)' leash --rpc-url $R)

# 3. leash → vendors 的 resolver
RES=$(cast call $LR 'getResolver(string)(address)' vendors --rpc-url $R)

# 4. ENSIP-10 讀出 policy 位址
cast call $RES 'resolve(bytes,bytes)(bytes)' $DNS "$(cast calldata 'addr(bytes32)' $NODE)" --rpc-url $R
```

2026-09-08 13:35 UTC 的實際輸出:

```
1. RootRegistry.getSubregistry("eth")      = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2
2. ETHRegistry.getSubregistry("leash")     = 0xD5fFf12CB229A1Ea9F2487681A627B9a3Bf73d29  ← 我們的
3. LeashRegistry.getResolver("vendors")    = 0x27fe60bABD73bbcdDff3f0448D3F4eB550A844F9  ← 我們的
4. resolve(dns, addr(node))                = 0x…b70f52e0ffc361e6e3c7765a58068308d4fa75cc  ← StandardPolicy
```

**拿掉 ENS,第 4 步就沒有答案,任何花費都過不了(理由碼 3)。**

### 官方 UniversalResolver 也解得出來

```bash
UR=0x4a1817d13e9cf196f471725176355c1234b63c70
cast call $UR 'resolve(bytes,bytes)(bytes,address)' $DNS "$(cast calldata 'addr(bytes32)' $NODE)" --rpc-url $R
#  → 0x…b70f52e0ffc361e6e3c7765a58068308d4fa75cc
#    0x27fe60bABD73bbcdDff3f0448D3F4eB550A844F9
```

**`LeashRegistry` 在 ENS 自己的解析基礎設施裡是一等公民** ——
不需要我們的程式碼、不需要我們的 RPC,任何人用官方工具都查得到 `vendors.leash.eth`
指向哪一份 policy。這不是我們自己搭一套平行系統,是真的接進 ENS。

---

## 三層撤銷,都是一筆交易

| 層級 | 交易 | 效果 |
|---|---|---|
| 輕 | `LeashResolver.setPolicy(node, 更嚴的 policy)` | 換規則 |
| 中 | `LeashRegistry.revoke("vendors")` | **這一個 agent 死**,其他不受影響 |
| **重** | `ETHRegistry.setSubregistry(leash.eth, 0x0)` | **全部 agent 同時停機** |

外加一個不需要任何交易的:**agent 子名的 `expiry` 到了就自動失效**
(`getResolver` 回 `0x0`)。續期要人 —— 免費的 dead-man's switch。

**四種手段全程都沒有碰 agent 的帳戶。**
