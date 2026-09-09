// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { LeashAccount } from "../src/LeashAccount.sol";
import { LeashStorage } from "../src/LeashStorage.sol";
import { MockAttester } from "../src/MockAttester.sol";
import { IAttester } from "../src/IAttester.sol";
import { IPolicyApprovals } from "../src/IPolicyApprovals.sol";

contract Approvals is IPolicyApprovals {
    function isApproved(address) external pure returns (bool) {
        return true;
    }
}

contract LeashAccountDigestsTest is Test {
    LeashAccount impl;
    LeashAccount acct;
    uint256 constant WALLET_PK = 0x8A11E7;

    bytes32 constant RULE_TYPEHASH = keccak256(
        "SetRule(address impl,bytes32 node,address token,bool allowed,uint256 txLimit,uint256 periodLimit,uint64 period,uint16 windowStart,uint16 windowEnd,uint256 nonce)"
    );
    bytes32 constant RESTORE_TYPEHASH = keccak256(
        "RestoreAgent(address impl,address agent,bytes32 node,string label,uint256 nonce)"
    );

    function setUp() public {
        impl = new LeashAccount(
            address(0xE45),
            IPolicyApprovals(address(new Approvals())),
            IAttester(address(new MockAttester()))
        );
        vm.signAndAttachDelegation(address(impl), WALLET_PK);
        acct = LeashAccount(payable(vm.addr(WALLET_PK)));
    }

    function _rule() internal pure returns (LeashStorage.TokenRule memory) {
        return LeashStorage.TokenRule({
            allowed: true,
            txLimit: 500e6,
            periodLimit: 1000e6,
            period: 1 days,
            windowStart: 540,
            windowEnd: 1020,
            epoch: 0
        });
    }

    /// The digest a caller computes must equal the one `setRule` consumes. `epoch` is
    /// deliberately absent from `RULE_TYPEHASH` and so must be absent here too.
    function test_ruleDigest_matches_what_setRule_consumes() public view {
        bytes32 node = acct.nodeFor("vendors");
        address token = address(0x7ABC);
        LeashStorage.TokenRule memory r = _rule();

        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"1901",
                acct.domainSeparator(),
                keccak256(
                    abi.encode(
                        RULE_TYPEHASH,
                        acct.SELF(),
                        node,
                        token,
                        r.allowed,
                        r.txLimit,
                        r.periodLimit,
                        r.period,
                        r.windowStart,
                        r.windowEnd,
                        uint256(7)
                    )
                )
            )
        );
        assertEq(acct.ruleDigest(node, token, r, 7), expected);
    }

    function test_restoreDigest_matches_what_restoreAgent_consumes() public view {
        bytes32 node = acct.nodeFor("vendors");
        address agent = address(0xA6E7);

        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"1901",
                acct.domainSeparator(),
                keccak256(
                    abi.encode(
                        RESTORE_TYPEHASH,
                        acct.SELF(),
                        agent,
                        node,
                        keccak256(bytes("vendors")),
                        uint256(3)
                    )
                )
            )
        );
        assertEq(acct.restoreDigest(agent, node, "vendors", 3), expected);
    }

    /// The nonce has to change the digest, or replay protection is decorative.
    function test_a_different_nonce_gives_a_different_digest() public view {
        bytes32 node = acct.nodeFor("vendors");
        assertTrue(
            acct.ruleDigest(node, address(1), _rule(), 1)
                != acct.ruleDigest(node, address(1), _rule(), 2)
        );
    }

    /// Two wallets delegating to one impl must produce different digests, because
    /// `domainSeparator` binds `address(this)` — the EOA.
    function test_two_wallets_get_different_digests() public {
        uint256 otherPk = 0xB0B;
        vm.signAndAttachDelegation(address(impl), otherPk);
        LeashAccount other = LeashAccount(payable(vm.addr(otherPk)));
        bytes32 node = acct.nodeFor("vendors");
        assertTrue(
            acct.ruleDigest(node, address(1), _rule(), 1)
                != other.ruleDigest(node, address(1), _rule(), 1)
        );
    }
}
