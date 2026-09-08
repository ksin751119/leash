// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";

/// @title PolicyApprovals —— 哪些 policy 位址是真人批准過的
/// @notice 這份清單是 Leash 安全模型裡的**第二把鎖**。ENS 指標(誰指向哪份 policy)
///         由 ADMIN 控制;這份清單由**真人**控制。
///
/// @dev **這份合約沒有 owner,而那是刻意的。**
///
///      初版有 `owner` 和 `setAttester(onlyOwner)`,而部署腳本把 `PolicyApprovals`、
///      `LeashResolver`、`LeashRegistry` 的 owner 都設成同一把 ADMIN 金鑰。
///      code review 指出這讓**一把鑰匙同時開兩道鎖**:
///      `setAttester(永遠回true的東西)` → `approve(任何東西)`,
///      直接推翻我們寫在 `PLAN.md` 裡的那句「ADMIN 金鑰被偷,攻擊者改得動指標,
///      但指不到一份沒被批准過的 policy」。
///
///      修法不是「換一把鑰匙持有它」——那只是把問題搬家。修法是**拿掉那個可變性**:
///      `attester` 是 `immutable`,沒有 setter,所以也就不需要 owner。
///      要換 attester 只能部署一份新的 `PolicyApprovals`,而那是一筆看得見的鏈上交易。
///
///      不對稱是刻意的,而且是整個設計的重點:
///
///      | 動作 | 要背書 | 為什麼 |
///      |---|---|---|
///      | `approve` —— 讓一份新 policy 可用 | ✅ 要 | 被入侵的 agent 最想做的就是幫自己批准一份寬鬆規則 |
///      | `revoke` —— 讓一份 policy 失效 | ❌ 不要 | 出事時你不會想先找手機刷臉 |
///
///      `revoke` 連 owner 都不限:**任何人都能撤銷**。看起來很怪,但想清楚就對了 ——
///      撤銷只會讓系統更嚴(那份 policy 從此擋下所有花費),而讓「踩煞車」需要權限,
///      是在真的出事的那一刻幫攻擊者省事。誰按都一樣,煞車就是煞車。
contract PolicyApprovals is IPolicyApprovals {
    /// @notice 唯一的批准來源。**沒有 setter** —— 見合約註解。
    IAttester public immutable attester;

    /// @notice 介面要的 `isApproved(address)` 由這個 public mapping 直接提供 getter。
    mapping(address policy => bool) public isApproved;

    /// @notice 批准當下記下的說明字串,前端拿來顯示「這條規則是什麼」。
    mapping(address policy => string) public descriptionOf;

    /// @notice 用掉的 attestation。**防重放的核心** —— 見 `approve`。
    mapping(bytes32 digest => bool) public attestationUsed;

    // --- EIP-712 ---
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant APPROVAL_TYPEHASH =
        keccak256("PolicyApproval(address policy,string description,uint256 nonce)");
    bytes32 private constant NAME_HASH = keccak256("Leash");
    bytes32 private constant VERSION_HASH = keccak256("1");

    event PolicyApproved(
        address indexed policy, string description, uint256 nonce, bytes32 attestationHash
    );
    event PolicyRevoked(address indexed policy, address indexed by);

    error ZeroPolicy();
    error ZeroAttester();
    error NotAttested();
    error AlreadyApproved();
    error AttestationReused(bytes32 digest);

    constructor(IAttester attester_) {
        // attester 不能是 0:那會讓整份清單永遠批准不了任何東西,
        // 而且沒有 setter 可以救。寧可部署時就失敗。
        if (address(attester_) == address(0)) revert ZeroAttester();
        attester = attester_;
    }

    /// @notice 批准一份 policy。**要真人背書,而且一份背書只能用一次。**
    /// @param nonce 由簽發端選;同一組 (policy, description) 換 nonce 就是換一份背書
    ///
    /// @dev **這裡沒有 sender 檢查,而那是對的** —— 門檻是背書,不是身分,
    ///      因為這是一份**全域單例**清單,「誰送這筆交易」不影響結果。
    ///      (注意:`LeashAccount` 是 per-wallet 的,那裡的擴權必須「兩個都要」——
    ///      `msg.sender == address(this)` 且 attestation。同一句註解套過去會出事,
    ///      code review 抓到過。)
    ///
    ///      **防重放:** 初版的 digest 沒有 nonce,也沒有記錄用過的 attestation。
    ///      加上公開的 `revoke`,真的 `WorldAttester` 上線後會出現這條攻擊:
    ///      從公開 calldata 抄下那份 attestation → `revoke(policy)` →
    ///      用**同一份** blob 重新 `approve`,不需要任何人再刷一次臉。
    ///      現在 digest 帶 nonce,而且 `attestationUsed` 一旦標記就永久有效 ——
    ///      **撤銷之後要重新批准,必須拿一份新 nonce 的背書。**
    function approve(
        address policy,
        string calldata description,
        uint256 nonce,
        bytes calldata attestation
    ) external {
        if (policy == address(0)) revert ZeroPolicy();
        if (isApproved[policy]) revert AlreadyApproved();

        bytes32 digest = approvalDigest(policy, description, nonce);
        if (attestationUsed[digest]) revert AttestationReused(digest);
        if (!attester.verify(digest, attestation)) revert NotAttested();

        attestationUsed[digest] = true;
        isApproved[policy] = true;
        descriptionOf[policy] = description;
        emit PolicyApproved(policy, description, nonce, keccak256(attestation));
    }

    /// @notice 撤銷一份 policy。**任何人都能做,不需要背書。**
    /// @dev 見合約註解 —— 縮權永遠不該被擋。重複撤銷不 revert,冪等。
    ///      也清掉 `descriptionOf`,否則前端會顯示一份已經失效的規則說明。
    function revoke(address policy) external {
        if (!isApproved[policy]) return;
        isApproved[policy] = false;
        delete descriptionOf[policy];
        emit PolicyRevoked(policy, msg.sender);
    }

    /// @notice 要被背書的 EIP-712 digest。前端、後端、鏈上都用這個算,確保三邊一致。
    /// @dev 初版是自製的 `keccak256(abi.encode(...))`,不是 EIP-712 —— 沒有 domain
    ///      separator、沒有 `\x19\x01` 前綴,而 `IAttester` 的註解和 sprint 項目 8
    ///      都寫 EIP-712。`WorldAttester` 的後端會用標準函式庫簽,對不上就驗不過。
    ///
    ///      `chainId` 和 `verifyingContract` 進 domain separator,所以同一份背書
    ///      挪不到另一條鏈或另一份清單上。
    function approvalDigest(address policy, string memory description, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(APPROVAL_TYPEHASH, policy, keccak256(bytes(description)), nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    /// @dev 每次現算,不快取 —— 鏈分叉之後 `block.chainid` 會變,快取的值會失效。
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }
}
