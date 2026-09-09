# 部署紀錄 —— Sepolia

**鏈:** Sepolia (chain id `11155111`)
**目前有效的部署:** 2026-09-08 16:34 UTC(**第二次**,見下方「為什麼重新部署」)
**部署者:** `0x36B3F5364A0dE03dc8eBaf0162C516E22D6bF959`(ADMIN)

> 每一筆的區塊時間戳都是**以太鏈蓋的,不可偽造** —— 這也是我們對
> ETHGlobal「Start from Scratch」規則的證據之一。

---

## 目前有效的位址

| 合約 | 位址 | 部署交易 |
|---|---|---|
| `LeashRegistry` | `0x6fB6CB4a789067b2283C4d4C657d3422ce742A51` | [`0xb23a39a8…`](https://sepolia.etherscan.io/tx/0xb23a39a85cccb679f4104567f610874ca1fecdba6470d87459678b47a5828172) |
| `LeashResolver` | `0x607a4d7363d9E7511a932F82eAE1e12FB609915b` | [`0x5ef9cbbb…`](https://sepolia.etherscan.io/tx/0x5ef9cbbb1f382aa84daaad625d2545c4ac38c6ab227a49ae031d7df0c968077b) |
| `PolicyApprovals` | `0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4` | [`0x0a8a3162…`](https://sepolia.etherscan.io/tx/0x0a8a31625189c3d432413abdc3c57e00d51eccc03d3d1ab37f2fe911b501d930) |
| `StandardPolicy` | `0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b` | [`0xff667665…`](https://sepolia.etherscan.io/tx/0xff6676659802654ca4ca35d0fa17b78a310df23fb95d1543cb2d729e14640ac7) |
| `MockAttester` ⚠️ | `0x268990a91B0727E80d38d5ED4Ab10d8889754124` | [`0x3142d584…`](https://sepolia.etherscan.io/tx/0x3142d584af188eb0f40e6cb2b474ccf99e2e2ffff3f9db0942548ef75b61540c) |

### EIP-7702 執行層(2026-09-09 01:18 UTC 部署)

| 合約 | 位址 | 部署交易 |
|---|---|---|
| `LeashAccount`(impl) | `0x136b33c68439C1ee8649048bb86E3a98ACd9B83C` | [`0x1aab21e0…`](https://sepolia.etherscan.io/tx/0x1aab21e0658c060431b94a198cba6cde9c5f27bf98bab668b1b4b4c365d51538) |
| `LeashLens` | `0xB6eB4C26AF866057920f7AB6fAFf69A914067B83` | [`0x4e615801…`](https://sepolia.etherscan.io/tx/0x4e615801b448399e13611a6490ddd59ed01771189e22325a13c76cd60a0c5004) |

`LeashAccount` 是 **impl,不是實例** —— 錢包用 EIP-7702 委派到它,程式碼在錢包自己的
storage 上執行。所以「部署」和「有錢包在用它」是兩件事。

部署後立刻在鏈上驗證的四件事:

```
impl code size                              12,858 bytes
ETH_REGISTRY()                              0xBDC85dD5…F0E2   ← 與上表一致
APPROVALS()                                 0x7CB9d4Ac…25B4
ATTESTER()                                  0x268990a9…4124
SELF()                                      0x136b33c6…B83C   ← 等於自己的部署位址
resolvePolicy(vendors node, "vendors")      0x88F2bfF0…75cc   ← StandardPolicy
```

**最後一行是這個專案核心主張的第一次鏈上證據:** 一份正式部署的合約(不是測試)
從真的 ENSv2 走完三跳,解出了真的 policy 位址。

`SELF()` 等於部署位址這件事也值得記:它證明那個 `immutable` 抓到的是 **impl 自己**,
不是執行時的 `address(this)`(在 delegate 裡那會是被委派的 EOA)。
attestation 的 digest 靠這個區分「哪個錢包」和「哪一版 impl」。

> ⚠️ **目前沒有任何錢包委派到它。** 委派要錢包自己簽 authorization:
> ```bash
> cast send $WALLET_ADDR --auth 0x136b33c68439C1ee8649048bb86E3a98ACd9B83C \
>   --private-key $WALLET_PK --rpc-url $R
> ```
> 部署腳本刻意不含 `WALLET_PK` —— 那把鑰匙不該出現在部署流程裡。
> 委派後可用 `LeashLens.delegateOf(wallet)` 確認,撤銷則是再送一筆 `--auth` 指向
> `address(0)`(約 36,800 gas)。**那是錢包持有者手上的逃生口。**

> ⚠️ **`MockAttester` 不做任何驗證,對任何輸入都回 `true`。**
> 它的 `describe()` 誠實回傳 `"MockAttester (NO verification - testing only)"`,前端會顯示。
> 而且 `attester` 在 `PolicyApprovals` 和 `LeashRegistry` 裡都是 **`immutable`** ——
> 換成真的 `WorldAttester` 必須**重新部署**,那是一筆看得見的鏈上交易。
> 這是刻意的,見下方 C1。

## 接線交易

| 動作 | 交易 |
|---|---|
| `PolicyApprovals.approve(StandardPolicy, nonce=1, attestation)` | [`0xdd14b8b5…`](https://sepolia.etherscan.io/tx/0xdd14b8b53cc5bb03118d0b181d236fa6d10afcc41d8a71af7f25839bd65d2f31) |
| `LeashRegistry.register("vendors", …, 30 天, nonce=1, attestation)` | [`0xcc379643…`](https://sepolia.etherscan.io/tx/0xcc3796431fa04bda68237147063ab2d1ce42e3af078ecca8cf40b7b85dee634f) |
| `LeashResolver.setPolicy(vendors node, StandardPolicy)` | [`0x74bec557…`](https://sepolia.etherscan.io/tx/0x74bec5575c4bd355ddaa397657590c05dff3cafb1780274c14d680effdbb331c) |
| **`ETHRegistry.setSubregistry(leash.eth, LeashRegistry)`** | [`0x19b8f085…`](https://sepolia.etherscan.io/tx/0x19b8f0856434422313365e1b32ab69db8c3c4bc3ec76514b1782bb5b2b35265b) |
| **`ETHRegistry.setResolver(leash.eth, 0x0)`** ← 見 I4 | [`0xd8b434f7…`](https://sepolia.etherscan.io/tx/0xd8b434f752d30dc40f61f0531a7f102f26c7cadba8c3b25fbf3a0a9890ca2501) |
| `LeashRegistry.setParent(ETHRegistry, "leash")` | [`0xa8c274de…`](https://sepolia.etherscan.io/tx/0xa8c274deba5d56e29640ffd07e4390e414c650663caf38baf843b8d439083f59) |

---

## 為什麼重新部署(2026-09-08)

第一次部署在同日 13:31 UTC。一次 code review 找出**兩個 Critical**,兩個都推翻了
我們安全論證裡的核心句子,而且都必須改合約才能修:

**C1 —— 一把鑰匙同時開兩道鎖。** `setAttester` 是 `onlyOwner` 且不需背書,
而第一次部署把三份合約的 owner 都設成同一把 ADMIN 金鑰。所以
`setAttester(永遠回true)` → `approve(任何東西)` → `setPolicy` 一路通到底。
把 `setAttester` 鎖死也不夠 —— `LeashResolver.setApprovalsSource` 同樣是
`onlyOwner`,被偷的金鑰只要多一步:部署自己的清單加自己的 attester 再指過去。
**修法是拿掉可變性:** `attester` 與 `approvals` 全部改 `immutable`。
`PolicyApprovals` 因此完全不需要 `owner`。

**C2 —— attestation 可重放。** digest 沒有 nonce、也沒有記錄用掉的 attestation,
而 `revoke` 是公開的。所以真的 `WorldAttester` 上線後:從公開 calldata 抄下那份
attestation → `revoke(policy)` → 用**同一份** blob 重新 `approve`,不需要任何人
再刷一次臉。改成標準 EIP-712 + nonce + `attestationUsed`。

**I4 —— wildcard resolver 繞過中間那一層撤銷。** 第一次部署把 `LeashResolver`
設成 `leash.eth` 自己的 resolver(想讓 demo 可以直接查這個名字)。那讓它變成整個
子樹的 wildcard:子名沒有 resolver 時,ENS 的 `UniversalResolver` 會往上回退找到它,
而 `LeashResolver` 刻意忽略 `name` 只讀 node —— 所以 `revoke` 和 `expiry`
**攔不住官方工具的解析**。

鏈上實測(`ghost.leash.eth`,一個從沒發過的子名):

| | 第一次部署 | 現在 |
|---|---|---|
| `LeashRegistry.getResolver("ghost")` | `0x0` | `0x0` |
| `UniversalResolverV2` | **回退找到我們的 resolver** ❌ | **revert `ResolverNotFound`** ✅ |

我們自己的三跳一直是對的(停在第二跳 → `NO_POLICY` → 錢不動),
壞掉的是 demo 展示的那條路徑 —— 撤銷之後那條指令照樣印出 policy。
**修法:不設 `leash.eth` 的 resolver。** 解析**必須**走過我們的 registry,沒有旁路。

第一次部署的位址與交易仍然留在鏈上(block 11661370–11661383),不再使用。

---

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
| namehash(`leash.eth`) | `0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf` |
| namehash(`vendors.leash.eth`) | `0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121` |
| DNS 編碼(`vendors.leash.eth`) | `0x0776656e646f7273056c656173680365746800` |

> 部署腳本**不再寫死 tokenId** —— 改用 `ETHRegistry.findTokenId("leash")` 現查,
> 並加了 `require(block.chainid == 11155111)` 護欄。拿錯 RPC 會把整套控制面
> 部署到別的鏈上,而那看起來會像成功了。

---

## 鏈上驗證:自己走一次

複製貼上就能重現。`$R` 是任何一個 Sepolia RPC。

```bash
ROOT=0x8115186e8f2e0b0281e86ab91f0f48ba90364354
NODE=0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121
DNS=0x0776656e646f7273056c656173680365746800

E=$(cast call $ROOT 'getSubregistry(string)(address)' eth --rpc-url $R)          # → ETHRegistry
LR=$(cast call $E 'getSubregistry(string)(address)' leash --rpc-url $R)          # → 我們的 registry
RES=$(cast call $LR 'getResolver(string)(address)' vendors --rpc-url $R)         # → 我們的 resolver
cast call $RES 'resolve(bytes,bytes)(bytes)' $DNS "$(cast calldata 'addr(bytes32)' $NODE)" --rpc-url $R
```

2026-09-08 16:36 UTC 的實際輸出:

```
hop1  ETHRegistry.getSubregistry("leash")   = 0x6fB6CB4a789067b2283C4d4C657d3422ce742A51  ← 我們的
hop2  LeashRegistry.getResolver("vendors")  = 0x607a4d7363d9E7511a932F82eAE1e12FB609915b  ← 我們的
hop3  resolve(dns, addr(node))              = 0x…88f2bff031bb4cf2beaa28d47ada52ebeebbc33b  ← StandardPolicy
```

**拿掉 ENS,第三步就沒有答案,任何 agent 發起的花費都過不了(理由碼 3)。**

> ⚠️ **不要說「唯一的花費路徑」。** EIP-7702 只約束打到那個 EOA 的呼叫;
> WALLET 私鑰照樣能直簽 `USDC.transfer`。正確的說法是
> 「**agent 的**唯一花費路徑」,而 WALLET 不受約束**既是邊界也是逃生口** ——
> 錢包持有者永遠拿得回自己的錢。

### 每一跳的回傳長度不一樣(實作陷阱)

| 跳 | 原始 returndata | 為什麼 |
|---|---|---|
| 1 | **32 bytes** | 回傳 `address` |
| 2 | **32 bytes** | 回傳 `address` |
| 3 | **96 bytes** | 回傳 `bytes`:offset(32) + length(32) + 內層(32) |

第三跳寫成檢查 `== 32` 的話**快樂路徑永遠不成立**,而且錯誤碼會是「ENS 讀不到 policy」,
完全誤導除錯方向。

---

## 三層撤銷,都是一筆交易

| 層級 | 交易 | 效果 |
|---|---|---|
| 輕 | `LeashResolver.setPolicy(node, 更嚴的 policy)` | 換規則 |
| 中 | `LeashRegistry.revoke("vendors")` | **這一個 agent 死**,其他不受影響 |
| **重** | `ETHRegistry.setSubregistry(leash.eth, 0x0)` | **全部 agent 同時停機** |

外加一個不需要任何交易的:**agent 子名的 `expiry` 到了就自動失效**
(`getResolver` 回 `0x0`)。續期要人,**而且要一份背書**(`renew` 需要 attestation)——
免費的 dead-man's switch。上限 `MAX_DURATION = 365 days`,
所以「發一個永不過期的名字」這件事做不到。

**四種手段全程都沒有碰 agent 的帳戶。**
