// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPolicyApprovals } from "./IPolicyApprovals.sol";
import { IAttester } from "./IAttester.sol";

/// @title PolicyApprovals —— 哪些 policy 位址是真人批准過的
/// @notice 這份清單是 Leash 安全模型裡的**第二把鎖**。ENS 指標(誰指向哪份 policy)
///         由 ADMIN 控制;這份清單由**真人**控制。兩層分開的後果是:
///         ADMIN 金鑰被偷,攻擊者改得動指標,但指不到一份沒被批准過的 policy。
///
/// @dev 不對稱是刻意的,而且是整個設計的重點:
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
    address public owner;
    IAttester public attester;

    /// @notice 介面要的 `isApproved(address)` 由這個 public mapping 直接提供 getter。
    mapping(address policy => bool) public isApproved;

    /// @notice 批准當下記下的說明字串,前端拿來顯示「這條規則是什麼」。
    mapping(address policy => string) public descriptionOf;

    event PolicyApproved(address indexed policy, string description, bytes32 attestationHash);
    event PolicyRevoked(address indexed policy, address indexed by);
    event AttesterSet(address indexed attester, address indexed by);
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroOwner();
    error ZeroPolicy();
    error NoAttester();
    error NotAttested();
    error AlreadyApproved();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, IAttester attester_) {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
        attester = attester_;
        emit OwnerTransferred(address(0), owner_);
        emit AttesterSet(address(attester_), msg.sender);
    }

    /// @notice 批准一份 policy。**要真人背書。**
    /// @param policy 要批准的 policy 位址
    /// @param description 給人看的說明,會進事件也會存起來
    /// @param attestation 背書資料,交給 `attester` 判斷
    ///
    /// @dev 被簽的 digest 綁住 policy 位址、說明、**這份合約自己的位址**和 chain id ——
    ///      所以同一張背書不能挪到另一條鏈或另一份清單上重用。
    ///
    ///      注意這裡**沒有** `onlyOwner`。門檻是背書,不是身分:拿得到有效背書的人
    ///      就是拿到真人授權的人,再檢查一次 msg.sender 只會讓「誰能代送交易」變成
    ///      另一個要管的東西。attester 沒接上時直接 revert(fail-closed),
    ///      不會因為忘了設就變成人人可批准。
    function approve(address policy, string calldata description, bytes calldata attestation)
        external
    {
        if (policy == address(0)) revert ZeroPolicy();
        if (address(attester) == address(0)) revert NoAttester();
        if (isApproved[policy]) revert AlreadyApproved();

        bytes32 digest = approvalDigest(policy, description);
        if (!attester.verify(digest, attestation)) revert NotAttested();

        isApproved[policy] = true;
        descriptionOf[policy] = description;
        emit PolicyApproved(policy, description, keccak256(attestation));
    }

    /// @notice 撤銷一份 policy。**任何人都能做,不需要背書。**
    /// @dev 見合約註解 —— 縮權永遠不該被擋。重複撤銷不 revert,冪等。
    function revoke(address policy) external {
        if (!isApproved[policy]) return;
        isApproved[policy] = false;
        emit PolicyRevoked(policy, msg.sender);
    }

    /// @notice 要被背書的 digest。前端和後端都用這個算,確保三邊一致。
    function approvalDigest(address policy, string memory description)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("LeashPolicyApproval(address policy,string description)"),
                policy,
                keccak256(bytes(description)),
                address(this),
                block.chainid
            )
        );
    }

    /// @dev 換 attester 是**擴權方向**的動作(換成一個永遠回 true 的東西就等於拆掉門),
    ///      所以限 owner。已經批准過的不受影響 —— 換門不等於重新審核。
    function setAttester(IAttester attester_) external onlyOwner {
        attester = attester_;
        emit AttesterSet(address(attester_), msg.sender);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroOwner();
        emit OwnerTransferred(owner, to);
        owner = to;
    }
}
