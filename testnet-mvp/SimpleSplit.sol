// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleSplit
 * @notice Individual bill split with USDC escrow
 * @dev Simplified version - no gas sponsorship, just core functionality
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SimpleSplit is ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ============================================================
    //                          ERRORS
    // ============================================================

    error NotCreator();
    error NotParticipant(address caller);
    error AlreadyPaid(address participant);
    error InvalidStatus(Status current, Status required);
    error SplitExpired(uint256 expiredAt);
    error NotExpiredYet(uint256 expiresAt);

    // ============================================================
    //                          EVENTS
    // ============================================================

    event PaymentReceived(
        address indexed participant,
        uint256 amount,
        uint256 paidCount,
        uint256 totalCount
    );

    event SplitCompleted(
        address indexed creator,
        uint256 totalAmount
    );

    event SplitCancelled(
        address indexed creator,
        uint256 refundedCount
    );

    event SplitExpiredAndSettled(
        uint256 collectedAmount,
        uint256 refundedCount
    );

    event RefundIssued(
        address indexed participant,
        uint256 amount
    );

    // ============================================================
    //                          ENUMS
    // ============================================================

    enum Status {
        ACTIVE,
        COMPLETED,
        CANCELLED,
        EXPIRED
    }

    // ============================================================
    //                          STRUCTS
    // ============================================================

    struct Participant {
        address addr;
        uint256 amountDue;
        bool hasPaid;
        uint256 paidAt;
    }

    // ============================================================
    //                      STATE VARIABLES
    // ============================================================

    /// @notice Unique ID from factory
    uint256 public immutable splitId;

    /// @notice Creator who receives funds
    address public immutable creator;

    /// @notice USDC token
    IERC20 public immutable USDC;

    /// @notice Total USDC to collect
    uint256 public immutable totalAmount;

    /// @notice Expiry timestamp (0 = no expiry)
    uint256 public immutable expiresAt;

    /// @notice Description
    string public description;

    /// @notice Current status
    Status public status;

    /// @notice Total collected so far
    uint256 public totalCollected;

    /// @notice Number who have paid
    uint256 public paidCount;

    /// @notice When settled
    uint256 public settledAt;

    /// @notice Participants
    Participant[] public participants;

    /// @notice Quick lookup: address => index
    mapping(address => uint256) private participantIndex;

    /// @notice Marker for "not a participant"
    uint256 private constant NOT_PARTICIPANT = type(uint256).max;

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================

    constructor(
        uint256 _splitId,
        address _creator,
        address _usdc,
        address[] memory _participants,
        uint256[] memory _amounts,
        uint256 _totalAmount,
        string memory _description,
        uint256 _expiresAt
    ) {
        splitId = _splitId;
        creator = _creator;
        USDC = IERC20(_usdc);
        totalAmount = _totalAmount;
        expiresAt = _expiresAt;
        description = _description;
        status = Status.ACTIVE;

        // Initialize participants
        uint256 count = _participants.length;
        for (uint256 i = 0; i < count; ) {
            participants.push(Participant({
                addr: _participants[i],
                amountDue: _amounts[i],
                hasPaid: false,
                paidAt: 0
            }));

            participantIndex[_participants[i]] = i;

            unchecked { i++; }
        }
    }

    // ============================================================
    //                      CORE FUNCTIONS
    // ============================================================

    /**
     * @notice Pay your share
     * @dev Transfers USDC from caller to this contract
     */
    function payShare() external nonReentrant {
        
        // Check status
        if (status != Status.ACTIVE) {
            revert InvalidStatus(status, Status.ACTIVE);
        }

        // Check not expired
        if (expiresAt > 0 && block.timestamp >= expiresAt) {
            revert SplitExpired(expiresAt);
        }

        // Get participant
        uint256 idx = _getParticipantIndex(msg.sender);
        Participant storage participant = participants[idx];

        // Check not already paid
        if (participant.hasPaid) {
            revert AlreadyPaid(msg.sender);
        }

        uint256 amount = participant.amountDue;

        // Update state
        participant.hasPaid = true;
        participant.paidAt = block.timestamp;

        unchecked {
            totalCollected += amount;
            paidCount++;
        }

        // Transfer USDC
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        emit PaymentReceived(
            msg.sender,
            amount,
            paidCount,
            participants.length
        );

        // Check if complete
        if (paidCount == participants.length) {
            _releaseFunds();
        }
    }

    /**
     * @notice Cancel split and refund
     * @dev Only creator can cancel
     */
    function cancelSplit() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (status != Status.ACTIVE) {
            revert InvalidStatus(status, Status.ACTIVE);
        }

        status = Status.CANCELLED;
        settledAt = block.timestamp;

        uint256 refundedCount = _refundPaidParticipants();

        emit SplitCancelled(creator, refundedCount);
    }

    /**
     * @notice Settle expired split
     * @dev Anyone can call after expiry
     */
    function settleExpired() external nonReentrant {
        if (status != Status.ACTIVE) {
            revert InvalidStatus(status, Status.ACTIVE);
        }

        if (expiresAt == 0 || block.timestamp < expiresAt) {
            revert NotExpiredYet(expiresAt);
        }

        status = Status.EXPIRED;
        settledAt = block.timestamp;

        uint256 collected = totalCollected;
        uint256 refundedCount = 0;

        if (collected > 0) {
            USDC.safeTransfer(creator, collected);
        }

        emit SplitExpiredAndSettled(collected, refundedCount);
    }

    // ============================================================
    //                      INTERNAL FUNCTIONS
    // ============================================================

    function _releaseFunds() internal {
        status = Status.COMPLETED;
        settledAt = block.timestamp;

        uint256 balance = USDC.balanceOf(address(this));
        USDC.safeTransfer(creator, balance);

        emit SplitCompleted(creator, balance);
    }

    function _refundPaidParticipants() internal returns (uint256 count) {
        uint256 length = participants.length;

        for (uint256 i = 0; i < length; ) {
            Participant storage p = participants[i];

            if (p.hasPaid) {
                USDC.safeTransfer(p.addr, p.amountDue);
                emit RefundIssued(p.addr, p.amountDue);
                unchecked { count++; }
            }

            unchecked { i++; }
        }
    }

    function _getParticipantIndex(address _addr) internal view returns (uint256 idx) {
        idx = participantIndex[_addr];
        
        if (idx == 0 && (participants.length == 0 || participants[0].addr != _addr)) {
            revert NotParticipant(_addr);
        }
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    function getParticipants() external view returns (Participant[] memory) {
        return participants;
    }

    function getParticipant(address _addr) external view returns (Participant memory) {
        uint256 idx = _getParticipantIndex(_addr);
        return participants[idx];
    }

    function isParticipant(address _addr) external view returns (bool) {
        if (participants.length == 0) return false;
        uint256 idx = participantIndex[_addr];
        if (idx == 0) {
            return participants[0].addr == _addr;
        }
        return true;
    }

    function getSplitStatus() external view returns (
        Status currentStatus,
        uint256 collected,
        uint256 total,
        uint256 paid,
        uint256 participantCount,
        bool isExpired,
        uint256 settled
    ) {
        currentStatus = status;
        collected = totalCollected;
        total = totalAmount;
        paid = paidCount;
        participantCount = participants.length;
        isExpired = expiresAt > 0 && block.timestamp >= expiresAt;
        settled = settledAt;
    }

    function getUnpaidParticipants() external view returns (address[] memory unpaid) {
        uint256 length = participants.length;
        uint256 unpaidCount = length - paidCount;

        unpaid = new address[](unpaidCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < length; ) {
            if (!participants[i].hasPaid) {
                unpaid[idx] = participants[i].addr;
                unchecked { idx++; }
            }
            unchecked { i++; }
        }
    }

    function getEscrowBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
}