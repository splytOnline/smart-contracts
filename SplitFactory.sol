// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Split.sol";

contract SplitFactory is Ownable2Step, Pausable, ReentrancyGuard {

    error InvalidParticipantCount(uint256 provided, uint256 min, uint256 max);
    error ArrayLengthMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error EmptyDescription();
    error SplitNotFound(uint256 splitId);

    event SplitCreated(
        uint256 indexed splitId,
        address indexed creator,
        address indexed splitAddress,
        uint256 totalAmount,
        uint256 participantCount,
        string description
    );

    event LimitsUpdated(uint256 maxParticipants, uint256 maxAmount);

    IERC20 public immutable USDC;
    address public paymaster;

    uint256 public splitCounter;
    uint256 public maxParticipants;
    uint256 public maxSplitAmount;

    mapping(uint256 => address) public splits;
    mapping(address => uint256[]) public userSplits;
    mapping(address => uint256[]) public createdSplits;

    uint256 private constant MIN_PARTICIPANTS = 2;
    uint256 private constant DEFAULT_MAX_PARTICIPANTS = 20;
    uint256 private constant DEFAULT_MAX_AMOUNT = 1_000_000 * 10 ** 6;

    constructor(
        address _usdc,
        address _paymaster,
        address _owner
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_paymaster == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        USDC = IERC20(_usdc);
        paymaster = _paymaster;

        maxParticipants = DEFAULT_MAX_PARTICIPANTS;
        maxSplitAmount = DEFAULT_MAX_AMOUNT;
    }

    function createSplit(
    string calldata _description,
    address[] calldata _participants,
    uint256[] calldata _amounts,
    uint256 _expiryDays
)
    external
    whenNotPaused
    nonReentrant
    returns (uint256 splitId, address splitAddress)
{
    if (bytes(_description).length == 0) revert EmptyDescription();
    if (_participants.length != _amounts.length) revert ArrayLengthMismatch();

    uint256 count = _participants.length;

    if (count < MIN_PARTICIPANTS || count > maxParticipants) {
        revert InvalidParticipantCount(
            count,
            MIN_PARTICIPANTS,
            maxParticipants
        );
    }

    uint256 totalAmount = _calculateTotal(_participants, _amounts);

    if (totalAmount > maxSplitAmount) revert ZeroAmount();

    unchecked { splitId = ++splitCounter; }

    uint256 expiryTimestamp =
        _expiryDays > 0
            ? block.timestamp + (_expiryDays * 1 days)
            : 0;

    // Store description in memory to reduce stack pressure
    string memory desc = _description;

    Split.InitData memory init = Split.InitData({
        splitId: splitId,
        creator: msg.sender,
        usdc: address(USDC),
        participants: _participants,
        amounts: _amounts,
        totalAmount: totalAmount,
        description: desc,
        expiresAt: expiryTimestamp
    });

    Split newSplit = new Split{ salt: bytes32(splitId) }(init);

    splitAddress = address(newSplit);
    splits[splitId] = splitAddress;

    createdSplits[msg.sender].push(splitId);
    userSplits[msg.sender].push(splitId);

    for (uint256 i = 0; i < count; ) {
        if (_participants[i] != msg.sender) {
            userSplits[_participants[i]].push(splitId);
        }
        unchecked { i++; }
    }

    emit SplitCreated(
        splitId,
        msg.sender,
        splitAddress,
        totalAmount,
        count,
        desc
    );
}


function _calculateTotal(
    address[] calldata _participants,
    uint256[] calldata _amounts
) internal pure returns (uint256 totalAmount) {
    uint256 count = _participants.length;

    for (uint256 i = 0; i < count; ) {
        if (_participants[i] == address(0)) revert ZeroAddress();
        if (_amounts[i] == 0) revert ZeroAmount();
        unchecked {
            totalAmount += _amounts[i];
            i++;
        }
    }
}

    function setLimits(
        uint256 _maxParticipants,
        uint256 _maxAmount
    ) external onlyOwner {
        if (_maxParticipants < MIN_PARTICIPANTS) revert ZeroAmount();
        if (_maxAmount == 0) revert ZeroAmount();

        maxParticipants = _maxParticipants;
        maxSplitAmount = _maxAmount;

        emit LimitsUpdated(_maxParticipants, _maxAmount);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getUserSplits(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return userSplits[_user];
    }

    function getCreatedSplits(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return createdSplits[_user];
    }

    function getSplitAddress(uint256 _splitId)
        external
        view
        returns (address)
    {
        address splitAddr = splits[_splitId];
        if (splitAddr == address(0)) revert SplitNotFound(_splitId);
        return splitAddr;
    }

    function getStats()
        external
        view
        returns (uint256 totalSplits, bool isPaused)
    {
        totalSplits = splitCounter;
        isPaused = paused();
    }
}
