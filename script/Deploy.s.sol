// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { LeashRegistry } from "../src/LeashRegistry.sol";
import { LeashResolver } from "../src/LeashResolver.sol";
import { PolicyApprovals } from "../src/PolicyApprovals.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { StandardPolicy } from "../src/StandardPolicy.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { IRegistry } from "../src/IRegistry.sol";

/// @dev ENSv2 `PermissionedRegistry` 上我們要用到的兩個函式。
///      selector 已對過 Sepolia 實測:`0x341ec559` / `0xbc7b6d62`。
interface IEnsV2Registry {
    function setSubregistry(uint256 tokenId, address subregistry) external;
    function setResolver(uint256 tokenId, address resolver) external;
    function getSubregistry(string calldata label) external view returns (address);
    function getResolver(string calldata label) external view returns (address);
    /// @dev `docs/ensv2-sepolia.md` 的建議:一行 view 就拿得到 tokenId,不要寫死。
    function findTokenId(string calldata label) external view returns (uint256);
}

/// @title Deploy —— 把 Leash 掛上 Sepolia 的 ENSv2
/// @notice 五份合約 + 三筆接線 + 兩筆設定。跑完之後鏈上解析應該完整走通:
///
///         RootRegistry.getSubregistry("eth")
///           → ETHRegistry.getSubregistry("leash")   ← 這一步指向我們的 registry
///             → LeashRegistry.getResolver("vendors") ← 我們發的 agent 子名
///               → LeashResolver.resolve(dnsName, addr(node))
///                 → StandardPolicy 位址
///
/// @dev **先跑不帶 `--broadcast` 的模擬**,確認每一步都不 revert 再真的送。
///      `setSubregistry` 需要 ADMIN 在 `leash.eth` 上持有 EAC 角色 bit 20 ——
///      2026-09-03 已用 `cast call --from` 實測過可行。
contract Deploy is Script {
    // Sepolia ENSv2(2026-09-01 實測位址;審計期間可能變動,變了這裡要改)
    address constant ETH_REGISTRY = 0xBDC85dD5b15D7ecb354cd7cb6f2c50b4f2c4F0E2;

    /// @dev Sepolia 的 chain id。**部署腳本一定要有這道護欄** ——
    ///      拿錯 RPC 就會把整套控制面部署到別的鏈上,而位址是決定性的,
    ///      事後看起來「好像成功了」。
    uint256 constant SEPOLIA = 11155111;

    /// @dev `namehash("leash.eth")`。`LeashRegistry` 用它算子名的 node。
    bytes32 constant LEASH_NODE =
        0x91fbe3f2c79f13bf641a8f388bc00cc7b13192a0a6c5a986e9ceb50456706fbf;

    /// @dev namehash("vendors.leash.eth")。resolver 的記錄以 node 為 key。
    bytes32 constant VENDORS_NODE =
        0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    string constant AGENT_LABEL = "vendors";

    /// @dev demo 用 30 天。真實部署會用 24 小時,靠續期當 dead-man's switch。
    uint64 constant AGENT_DURATION = 30 days;

    function run() external {
        address admin = vm.envAddress("ADMIN_ADDR");
        uint256 pk = vm.envUint("ADMIN_PK");

        require(block.chainid == SEPOLIA, "wrong chain - this script is Sepolia only");

        // 不要寫死 —— 照 docs/ensv2-sepolia.md 的建議現查
        uint256 leashTokenId = IEnsV2Registry(ETH_REGISTRY).findTokenId("leash");
        require(leashTokenId != 0, "leash.eth not registered on this chain");

        console.log("=== Leash deploy ===");
        console.log("admin        ", admin);
        console.log("chain id     ", block.chainid);
        console.log("eth registry ", ETH_REGISTRY);

        vm.startBroadcast(pk);

        // --- 1. 五份合約 ---
        //     attester 在 PolicyApprovals 和 LeashRegistry 裡都是 immutable ——
        //     沒有 setter,所以一把被偷的 ADMIN 金鑰開不了第二道鎖。
        MockAttester attester = new MockAttester();
        PolicyApprovals approvals = new PolicyApprovals(IAttester(address(attester)));
        StandardPolicy policy = new StandardPolicy();
        LeashResolver resolver = new LeashResolver(admin, IPolicyApprovals(address(approvals)));
        LeashRegistry registry = new LeashRegistry(admin, IAttester(address(attester)), LEASH_NODE);

        // --- 2. 批准那份 policy。要背書 + 一個沒用過的 nonce ---
        //     MockAttester 什麼都收;正式版換 WorldAttester,後端用 EIP-712 簽。
        approvals.approve(address(policy), policy.describe(), 1, hex"00");

        // --- 3. 發 agent 子名。**這一步也要背書** ---
        //     PLAN 的不對稱表寫「開新 agent 子名 → 要刷臉」,現在程式碼真的如此。
        registry.register(
            AGENT_LABEL, admin, address(0), address(resolver), AGENT_DURATION, 1, hex"00"
        );

        // --- 4. 那個 agent 該過哪一份 policy ---
        resolver.setPolicy(VENDORS_NODE, address(policy));

        // --- 5. 把 leash.eth 的子樹交給我們的 registry ---
        //     這一筆是 demo 第 4 幕的拉桿:改回別的位址 = 全部 agent 同時停機
        IEnsV2Registry(ETH_REGISTRY).setSubregistry(leashTokenId, address(registry));

        // --- 6. leash.eth 自己**不設** resolver ---
        //
        //     初版把 LeashResolver 設成 leash.eth 自己的 resolver,想讓 demo 可以
        //     直接查這個名字。那讓它變成整個子樹的 **wildcard resolver**:
        //     子名沒有 resolver 時,ENS 的 UniversalResolver 會往上回退找到它,
        //     而 LeashResolver 刻意忽略 `name` 只讀 node —— 所以
        //     **`revoke(label)` 和 `expiry` 都攔不住官方工具的解析。**
        //
        //     鏈上實測(ghost.leash.eth,一個從沒發過的子名):
        //       LeashRegistry.getResolver("ghost") = 0x0
        //       UniversalResolverV2 卻仍然找到 LeashResolver
        //
        //     我們自己的三跳會停在第二跳(NO_POLICY,錢不動),所以**強制路徑是對的**;
        //     壞掉的是 demo 展示的那條路徑 —— 撤銷之後那條指令照樣印出 policy。
        //
        //     修法:不設 leash.eth 的 resolver。解析**必須**走過我們的 registry,
        //     沒有旁路,兩條路徑因此一致。
        IEnsV2Registry(ETH_REGISTRY).setResolver(leashTokenId, address(0));

        // --- 7. 告知 registry 自己掛在哪(只影響索引,不影響解析)---
        registry.setParent(IRegistry(ETH_REGISTRY), "leash");

        vm.stopBroadcast();

        console.log("");
        console.log("MockAttester    ", address(attester));
        console.log("PolicyApprovals ", address(approvals));
        console.log("StandardPolicy  ", address(policy));
        console.log("LeashResolver   ", address(resolver));
        console.log("LeashRegistry   ", address(registry));
        console.log("");

        // --- 驗證:鏈上解析真的走通了嗎 ---
        address sub = IEnsV2Registry(ETH_REGISTRY).getSubregistry("leash");
        console.log("ETHRegistry.getSubregistry('leash')  ", sub);
        require(sub == address(registry), "subregistry not wired");

        address agentResolver = registry.getResolver(AGENT_LABEL);
        console.log("LeashRegistry.getResolver('vendors') ", agentResolver);
        require(agentResolver == address(resolver), "agent resolver not wired");

        (address p, bool approved) = resolver.policyAndApproval(VENDORS_NODE);
        console.log("policy resolved                     ", p);
        console.log("policy approved                     ", approved);
        require(p == address(policy), "policy pointer wrong");
        require(approved, "policy not approved");

        console.log("");
        console.log("OK - vendors.leash.eth resolves to an approved policy onchain");
    }
}
