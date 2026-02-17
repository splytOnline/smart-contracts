// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Split
 * @notice Individual bill split contract deployed by SplitFactory
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Split is ReentrancyGuard {

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotCreator();
    error NotParticipant(address caller);
    error AlreadyPaid(address participant);
    error InvalidStatus(Status current, Status required);
    error SplitExpired(uint256 expiredAt, uint256 currentTime);
    error NotExpiredYet(uint256 expiresAt, uint256 currentTime);
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PaymentReceived(
        address indexed participant,
        uint256 amount,
        uint256 paidCount,
        uint256 totalCount,
        uint256 timestamp
    );

    event SplitCompleted(
        address indexed creator,
        uint256 totalAmount,
        uint256 timestamp
    );

    event SplitCancelled(
        address indexed creator,
        uint256 refundedCount,
        uint256 timestamp
    );

    event SplitExpiredAndSettled(
        uint256 collectedAmount,
        uint256 timestamp
    );

    event RefundIssued(
        address indexed participant,
        uint256 amount,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                                ENUM
    //////////////////////////////////////////////////////////////*/

    enum Status {
        ACTIVE,
        COMPLETED,
        CANCELLED,
        EXPIRED
    }

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Participant {
        address addr;
        uint256 amountDue;
        bool hasPaid;
        uint256 paidAt;
        bytes32 paymentTxHash;
    }

    /**
     * 🔥 STRUCT-BASED CONSTRUCTOR INPUT
     * This removes stack-too-deep permanently.
     */
    struct InitData {
        uint256 splitId;
        address creator;
        address usdc;
        address[] participants;
        uint256[] amounts;
        uint256 totalAmount;
        string description;
        uint256 expiresAt;
    }

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable splitId;
    address public immutable creator;
    IERC20 public immutable USDC;
    uint256 public immutable totalAmount;
    uint256 public immutable expiresAt;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    string public description;
    Status public status;

    uint256 public totalCollected;
    uint256 public paidCount;
    uint256 public settledAt;

    Participant[] public participants;
    mapping(address => uint256) private participantIndex;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(InitData memory data) {
        if (data.creator == address(0)) revert ZeroAddress();
        if (data.usdc == address(0)) revert ZeroAddress();

        splitId = data.splitId;
        creator = data.creator;
        USDC = IERC20(data.usdc);
        totalAmount = data.totalAmount;
        expiresAt = data.expiresAt;

        description = data.description;
        status = Status.ACTIVE;

        uint256 count = data.participants.length;

        for (uint256 i = 0; i < count; ) {
            participants.push(Participant({
                addr: data.participants[i],
                amountDue: data.amounts[i],
                hasPaid: false,
                paidAt: 0,
                paymentTxHash: bytes32(0)
            }));

            participantIndex[data.participants[i]] = i;

            unchecked { i++; }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    function payShare(bytes32 _txHash) external nonReentrant {
        if (status != Status.ACTIVE)
            revert InvalidStatus(status, Status.ACTIVE);

        if (expiresAt > 0 && block.timestamp >= expiresAt)
            revert SplitExpired(expiresAt, block.timestamp);

        uint256 idx = _getParticipantIndex(msg.sender);
        Participant storage participant = participants[idx];

        if (participant.hasPaid)
            revert AlreadyPaid(msg.sender);

        uint256 amount = participant.amountDue;

        participant.hasPaid = true;
        participant.paidAt = block.timestamp;
        participant.paymentTxHash = _txHash;

        unchecked {
            totalCollected += amount;
            paidCount++;
        }

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        emit PaymentReceived(
            msg.sender,
            amount,
            paidCount,
            participants.length,
            block.timestamp
        );

        if (paidCount == participants.length) {
            _releaseFunds();
        }
    }

    function cancelSplit() external nonReentrant {
        if (msg.sender != creator)
            revert NotCreator();

        if (status != Status.ACTIVE)
            revert InvalidStatus(status, Status.ACTIVE);

        status = Status.CANCELLED;
        settledAt = block.timestamp;

        uint256 refunded = _refundPaidParticipants();

        emit SplitCancelled(creator, refunded, block.timestamp);
    }

    function settleExpired() external nonReentrant {
        if (status != Status.ACTIVE)
            revert InvalidStatus(status, Status.ACTIVE);

        if (expiresAt == 0 || block.timestamp < expiresAt)
            revert NotExpiredYet(expiresAt, block.timestamp);

        status = Status.EXPIRED;
        settledAt = block.timestamp;

        uint256 collected = totalCollected;

        if (collected > 0) {
            USDC.safeTransfer(creator, collected);
        }

        emit SplitExpiredAndSettled(collected, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _releaseFunds() internal {
        status = Status.COMPLETED;
        settledAt = block.timestamp;

        uint256 balance = USDC.balanceOf(address(this));
        USDC.safeTransfer(creator, balance);

        emit SplitCompleted(creator, balance, block.timestamp);
    }

    function _refundPaidParticipants() internal returns (uint256 count) {
        uint256 length = participants.length;

        for (uint256 i = 0; i < length; ) {
            Participant storage p = participants[i];

            if (p.hasPaid) {
                USDC.safeTransfer(p.addr, p.amountDue);
                emit RefundIssued(p.addr, p.amountDue, block.timestamp);
                unchecked { count++; }
            }

            unchecked { i++; }
        }
    }

    function _getParticipantIndex(address _addr)
        internal
        view
        returns (uint256 idx)
    {
        idx = participantIndex[_addr];

        if (
            idx >= participants.length ||
            participants[idx].addr != _addr
        ) {
            revert NotParticipant(_addr);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getParticipants()
        external
        view
        returns (Participant[] memory)
    {
        return participants;
    }

    function getSplitStatus()
        external
        view
        returns (
            Status currentStatus,
            uint256 collected,
            uint256 total,
            uint256 paid,
            uint256 participantCount,
            bool isExpired,
            uint256 settled
        )
    {
        currentStatus = status;
        collected = totalCollected;
        total = totalAmount;
        paid = paidCount;
        participantCount = participants.length;
        isExpired = expiresAt > 0 && block.timestamp >= expiresAt;
        settled = settledAt;
    }
}
