// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleSplitFactory
 * @notice Simplified factory for creating bill splits without gas sponsorship
 * @dev No paymaster, no complex features - just core escrow functionality
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SimpleSplit.sol";

contract SimpleSplitFactory is Ownable, ReentrancyGuard {

    // ============================================================
    //                          ERRORS
    // ============================================================

    error InvalidParticipantCount();
    error ArrayLengthMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error EmptyDescription();
    error SplitNotFound(uint256 splitId);

    // ============================================================
    //                          EVENTS
    // ============================================================

    event SplitCreated(
        uint256 indexed splitId,
        address indexed creator,
        address indexed splitAddress,
        uint256 totalAmount,
        uint256 participantCount
    );

    // ============================================================
    //                      STATE VARIABLES
    // ============================================================

    /// @notice USDC token address (immutable)
    address public immutable USDC;

    /// @notice Auto-incrementing split counter
    uint256 public splitCounter;

    /// @notice Map splitId => Split contract address
    mapping(uint256 => address) public splits;

    /// @notice Map user address => array of split IDs they're involved in
    mapping(address => uint256[]) public userSplits;

    /// @notice Map creator address => array of split IDs they created
    mapping(address => uint256[]) public createdSplits;

    // ============================================================
    //                       CONSTANTS
    // ============================================================

    uint256 private constant MIN_PARTICIPANTS = 2;
    uint256 private constant MAX_PARTICIPANTS = 20;

    // ============================================================
    //                       CONSTRUCTOR
    // ============================================================

    /**
     * @notice Deploy the factory
     * @param _usdc USDC token address on current network
     */
    constructor(address _usdc) Ownable(msg.sender) {
        if (_usdc == address(0)) revert ZeroAddress();
        USDC = _usdc;
    }

    // ============================================================
    //                      CORE FUNCTIONS
    // ============================================================

    /**
     * @notice Create a new bill split
     * @param _creator Address that will receive funds when split completes
     * @param _description What the split is for
     * @param _participants Array of wallet addresses
     * @param _amounts Array of USDC amounts (6 decimals)
     * @param _expiryDays Days until split expires (0 = no expiry)
     */
    function createSplit(
        address _creator,
        string calldata _description,
        address[] calldata _participants,
        uint256[] calldata _amounts,
        uint256 _expiryDays
    ) external nonReentrant returns (uint256 splitId, address splitAddress) {
        
        // Validate creator
        if (_creator == address(0)) revert ZeroAddress();
        
        // Validate description
        if (bytes(_description).length == 0) revert EmptyDescription();

        // Validate arrays
        if (_participants.length != _amounts.length) revert ArrayLengthMismatch();
        
        uint256 count = _participants.length;
        if (count < MIN_PARTICIPANTS || count > MAX_PARTICIPANTS) {
            revert InvalidParticipantCount();
        }

        // Calculate total and validate
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < count; ) {
            if (_amounts[i] == 0) revert ZeroAmount();
            if (_participants[i] == address(0)) revert ZeroAddress();
            
            unchecked {
                totalAmount += _amounts[i];
                i++;
            }
        }

        // Increment counter
        unchecked {
            splitId = ++splitCounter;
        }

        // Calculate expiry
        uint256 expiryTimestamp = _expiryDays > 0
            ? block.timestamp + (_expiryDays * 1 days)
            : 0;

        // Deploy Split contract
        SimpleSplit newSplit = new SimpleSplit{
            salt: bytes32(splitId)
        }(
            splitId,
            _creator,
            USDC,
            _participants,
            _amounts,
            totalAmount,
            _description,
            expiryTimestamp
        );

        splitAddress = address(newSplit);

        // Register split
        splits[splitId] = splitAddress;
        createdSplits[_creator].push(splitId);
        userSplits[_creator].push(splitId);

        // Track for all participants
        for (uint256 i = 0; i < count; ) {
            if (_participants[i] != _creator) {
                userSplits[_participants[i]].push(splitId);
            }
            unchecked { i++; }
        }

        emit SplitCreated(splitId, _creator, splitAddress, totalAmount, count);
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    function getUserSplits(address _user) external view returns (uint256[] memory) {
        return userSplits[_user];
    }

    function getCreatedSplits(address _user) external view returns (uint256[] memory) {
        return createdSplits[_user];
    }

    function getSplitAddress(uint256 _splitId) external view returns (address) {
        address splitAddr = splits[_splitId];
        if (splitAddr == address(0)) revert SplitNotFound(_splitId);
        return splitAddr;
    }

    function getTotalSplits() external view returns (uint256) {
        return splitCounter;
    }
}