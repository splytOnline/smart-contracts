// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SimpleSplit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotParticipant(address caller);
    error AlreadyPaid(address participant);
    error InvalidStatus(Status current, Status required);
    error InsufficientAllowance(uint256 required, uint256 current);

    enum Status { ACTIVE, COMPLETED, CANCELLED, EXPIRED }

    struct Participant {
        address addr;
        uint256 amountDue;
        bool hasPaid;
        uint256 paidAt;
    }

    uint256 public immutable splitId;
    address public immutable creator; // This is the recipient address
    IERC20 public immutable USDC;
    uint256 public immutable totalAmount;
    uint256 public immutable expiresAt;
    string public description;
    Status public status;
    uint256 public totalCollected;
    uint256 public paidCount;
    uint256 public settledAt;

    Participant[] public participants;
    mapping(address => uint256) private participantIndex;

    constructor(
        uint256 _id, address _c, address _u, address[] memory _p, 
        uint256[] memory _a, uint256 _t, string memory _desc, uint256 _exp
    ) {
        splitId = _id;
        creator = _c; // [cite: 59]
        USDC = IERC20(_u);
        totalAmount = _t;
        expiresAt = _exp;
        description = _desc;
        status = Status.ACTIVE;

        for (uint256 i = 0; i < _p.length; i++) {
            bool isCreator = _p[i] == _c;
            participants.push(Participant({
                addr: _p[i],
                amountDue: _a[i],
                hasPaid: isCreator, // Mark creator paid automatically [cite: 62]
                paidAt: isCreator ? block.timestamp : 0
            }));
            participantIndex[_p[i]] = i;
            if (isCreator) {
                paidCount++; // [cite: 63]
                totalCollected += _a[i]; // [cite: 64]
            }
        }
    }

    function payShare() external nonReentrant {
        if (status != Status.ACTIVE) revert InvalidStatus(status, Status.ACTIVE);
        
        uint256 idx = _getParticipantIndex(msg.sender);
        Participant storage p = participants[idx];
        if (p.hasPaid) revert AlreadyPaid(msg.sender);

        uint256 allowance = USDC.allowance(msg.sender, address(this));
        if (allowance < p.amountDue) revert InsufficientAllowance(p.amountDue, allowance);

        p.hasPaid = true;
        p.paidAt = block.timestamp;
        
        unchecked {
            totalCollected += p.amountDue;
            paidCount++;
        }

        // FORCE TRANSFER TO CREATOR WALLET - NOT CONTRACT
        // If the creator is Alice, funds go to Alice's wallet.
        USDC.safeTransferFrom(msg.sender, creator, p.amountDue); // 

        // Check for completion
        if (paidCount == participants.length) { // 
            status = Status.COMPLETED;
            settledAt = block.timestamp;
        }
    }

    function getContractUSDCBalance() external view returns (uint256) {
        return USDC.balanceOf(address(this)); // Should always be 0 [cite: 108]
    }

    function _getParticipantIndex(address _addr) internal view returns (uint256 idx) {
        idx = participantIndex[_addr];
        if (idx == 0 && (participants.length == 0 || participants[0].addr != _addr)) {
            revert NotParticipant(_addr);
        }
    }

    function getParticipants() external view returns (Participant[] memory) {
        return participants;
    }
}