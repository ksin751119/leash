// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";
import { IAttester } from "../src/IAttester.sol";
import { MockAttester } from "../src/MockAttester.sol";

contract MockApprovals is IPolicyApprovals {
    mapping(address => bool) public approved;

    function set(address p, bool v) external {
        approved[p] = v;
    }

    function isApproved(address p) external view returns (bool) {
        return approved[p];
    }
}

contract LeashAccountBindingTest is Test {
    LeashAccount impl;
    MockApprovals approvals;
    MockAttester attester;

    uint256 walletPk = 0x8A11E7;
    address wallet;
    address constant AGENT = address(0xA6E17);
    address constant ATTACKER = address(0xBAD);
    address constant ETH_REGISTRY = address(0xE45);

    bytes constant ATT = hex"c0ffee";
    string constant LABEL = "vendors";
    bytes32 constant NODE = 0x9b4cc5763f1c6dd5f80b1dd4d6d4c968b9971c25243467394f04e9aa1145e121;

    /// 委派過的 EOA,用 LeashAccount 的介面來呼叫它。
    LeashAccount acct;

    function setUp() public {
        approvals = new MockApprovals();
        attester = new MockAttester();
        impl = new LeashAccount(ETH_REGISTRY, approvals, attester);
        wallet = vm.addr(walletPk);
        vm.signAndAttachDelegation(address(impl), walletPk);
        acct = LeashAccount(payable(wallet));
    }

    // --- 7702 語意 ---

    /// 委派後 EOA 的 code 是 23 bytes 的 `0xef0100 || impl`。
    function test_delegation_layout() public view {
        assertEq(wallet.code.length, 23);
        assertEq(uint8(wallet.code[0]), 0xef);
        assertEq(uint8(wallet.code[1]), 0x01);
        assertEq(uint8(wallet.code[2]), 0x00);
    }

    /// 🔴 **C2 迴歸:委派之後那個錢包必須收得到 ETH。**
    ///
    /// 純轉 ETH = 用**空 calldata** 呼叫 delegate。沒有 `receive()` 的話
    /// Solidity 的 dispatcher 會 revert,而那意味著 faucet、交易所、
    /// `cast send --value` 全部失效 —— 委派之後就加不了 gas。
    function test_delegated_wallet_can_still_receive_eth() public {
        deal(address(this), 1 ether);
        uint256 before = wallet.balance;
        (bool ok,) = payable(wallet).call{ value: 1 ether }("");
        assertTrue(ok, "empty calldata must hit receive()");
        assertEq(wallet.balance - before, 1 ether);
    }

    /// 打錯 selector 要明確 revert,不要靜默吞掉 ——
    /// 靜默接受會讓「打錯 selector」看起來像成功。
    function test_unknown_selector_reverts() public {
        vm.expectRevert(LeashAccount.UnknownSelector.selector);
        (bool ok,) = wallet.call(abi.encodeWithSignature("notAFunction()"));
        ok; // 由 expectRevert 判定
    }

    /// `address(this)` 在 delegate 裡是 **EOA**,而 `SELF` 是 impl 自己的位址。
    /// 這兩個是不同的值,而 attestation 的 digest 需要**兩個都有**:
    /// `address(this)` 綁住「哪個錢包」,`SELF` 綁住「哪一版 impl」。
    function test_address_this_is_the_eoa_but_self_is_the_impl() public view {
        assertEq(acct.SELF(), address(impl), "SELF is baked in at deploy time");
        // domainSeparator 用 address(this) —— 在 delegate 裡就是 wallet
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Leash"),
                keccak256("1"),
                block.chainid,
                wallet
            )
        );
        assertEq(acct.domainSeparator(), expected, "verifyingContract is the EOA");
    }

    /// 兩個 EOA 委派到同一份 impl,storage 完全獨立。
    function test_two_wallets_sharing_one_impl_are_independent() public {
        uint256 pk2 = 0xB0B;
        address w2 = vm.addr(pk2);
        vm.signAndAttachDelegation(address(impl), pk2);

        vm.prank(wallet);
        acct.bindAgent(AGENT, NODE, LABEL);

        (bytes32 n1,,) = acct.bindingOf(AGENT);
        (bytes32 n2,,) = LeashAccount(payable(w2)).bindingOf(AGENT);
        assertEq(n1, NODE);
        assertEq(n2, bytes32(0), "the other wallet knows nothing about this agent");
    }

    // --- 🔴 決定 2 迴歸:沒有 initialize,沒有搶跑面 ---

    /// **委派後 storage 是空的,而這是攻擊者唯一的窗口。**
    ///
    /// spike 證明過:如果有 `initialize()`,任何人都能搶先呼叫並把自己設成 admin。
    /// 我們的做法是**根本沒有初始化動作** —— 全域設定是 immutable,
    /// per-EOA 的權限一律是 `msg.sender == address(this)`,而只有錢包的私鑰
    /// 能讓那個 EOA 送出交易。
    ///
    /// 這條測試逐一證明攻擊者在那個窗口裡什麼都做不到。
    function test_attacker_cannot_seize_a_freshly_delegated_wallet() public {
        vm.startPrank(ATTACKER);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.bindAgent(ATTACKER, NODE, LABEL);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.allowPayee(NODE, address(0xDEAD), ATTACKER, 1, ATT);

        vm.expectRevert(LeashAccount.NotSelf.selector);
        acct.setRule(NODE, address(0xDEAD), LeashStorage.TokenRule(true, 0, 0, 0, 0, 0, 0), 1, ATT);

        vm.stopPrank();

        (bytes32 n,,) = acct.bindingOf(ATTACKER);
        assertEq(n, bytes32(0), "nothing was seized");
    }

    /// 對 **impl 本身**呼叫必須是惰性的 —— impl 沒有被任何人委派,
    /// 它的 `address(this)` 是自己,所以理論上它能對自己下指令。
    /// 那不會傷害任何錢包(狀態在 impl 自己的 storage,沒有 EOA 讀它),
    /// 但我們仍然要確認**外部人**動不了它。
    function test_calling_the_impl_directly_does_nothing_for_an_outsider() public {
        vm.expectRevert(LeashAccount.NotSelf.selector);
        vm.prank(ATTACKER);
        impl.bindAgent(ATTACKER, NODE, LABEL);
    }

    // --- attestation ---

    /// digest 必須含 `SELF`,否則重新委派到新版 impl 之後可以跨版本重放。
    function test_attestation_digest_is_bound_to_the_impl_version() public {
        LeashAccount impl2 = new LeashAccount(ETH_REGISTRY, approvals, attester);
        bytes32 d1 = acct.payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        vm.signAndAttachDelegation(address(impl2), walletPk);
        bytes32 d2 = LeashAccount(payable(wallet)).payeeDigest(NODE, address(0xDEAD), AGENT, 1);

        assertTrue(d1 != d2, "same wallet, different impl version, different digest");
    }
}
