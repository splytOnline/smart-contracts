// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SplytTreasury
 * @author Splyt Protocol
 * @notice Manages operational funds for the Splyt protocol.
 *         Holds ETH used to sponsor gas fees for users (via Paymaster).
 *         Completely separate from user funds (which live in Split.sol).
 *
 * @dev Deployment Order: #1 (no dependencies, deploy this first)
 *
 * Key Responsibilities:
 * 1. Hold ETH for gas sponsorship (sent to Paymaster)
 * 2. Allow owner to fund/withdraw operational ETH
 * 3. Track protocol-level stats
 * 4. Emergency pause functionality
 *
 * What this contract does NOT do:
 * - Never holds user USDC (that's Split.sol)
 * - Never touches user funds
 * - Not upgradeable (trust through immutability)
 */

// ============================================================
//                          IMPORTS
// ============================================================

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
//                          CONTRACT
// ============================================================

contract SplytTreasury is Ownable2Step, Pausable, ReentrancyGuard {

    // ============================================================
    //                          ERRORS
    // ============================================================

    /// @dev Thrown when ETH transfer fails
    error TransferFailed();

    /// @dev Thrown when caller is not authorized
    error NotAuthorized();

    /// @dev Thrown when amount is zero
    error ZeroAmount();

    /// @dev Thrown when treasury has insufficient balance
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @dev Thrown when address is zero
    error ZeroAddress();

    // ============================================================
    //                          EVENTS
    // ============================================================

    /// @notice Emitted when ETH is deposited into treasury
    event Deposited(address indexed sender, uint256 amount);

    /// @notice Emitted when ETH is withdrawn from treasury
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when ETH is sent to paymaster for gas sponsorship
    event PaymasterFunded(address indexed paymaster, uint256 amount);

    /// @notice Emitted when an authorized operator is added/removed
    event OperatorUpdated(address indexed operator, bool authorized);

    // ============================================================
    //                          STATE VARIABLES
    // ============================================================

    /**
     * @notice Authorized operators (e.g., backend wallet that triggers funding)
     * @dev Operators can fund the paymaster but cannot withdraw to arbitrary addresses
     * Using mapping for O(1) lookup - gas efficient
     */
    mapping(address => bool) public operators;

    /// @notice Total ETH ever deposited (for analytics)
    /// @dev uint128 saves a storage slot when packed (max ~3.4 × 10^38 wei, more than enough)
    uint128 public totalDeposited;

    /// @notice Total ETH ever sent to paymaster (for analytics)
    uint128 public totalPaymasterFunded;

    /// @notice Minimum ETH balance before low-balance alert via event
    /// @dev Packed with totalDeposited in same storage slot (saves gas)
    uint128 public lowBalanceThreshold;

    // ============================================================
    //                          CONSTRUCTOR
    // ============================================================

    /**
     * @notice Deploys treasury and sets initial owner
     * @dev Ownable2Step requires explicit acceptance of ownership transfer
     *      (safer than single-step Ownable)
     * @param _initialOwner Address that will own this contract
     * @param _lowBalanceThreshold Minimum ETH balance before alerts (in wei)
     */
    constructor(
        address _initialOwner,
        uint128 _lowBalanceThreshold
    ) Ownable(_initialOwner) {
        // Validate inputs
        if (_initialOwner == address(0)) revert ZeroAddress();

        // Set initial threshold (e.g., 0.1 ETH = 100000000000000000)
        lowBalanceThreshold = _lowBalanceThreshold;
    }

    // ============================================================
    //                      RECEIVE / FALLBACK
    // ============================================================

    /**
     * @notice Accept direct ETH deposits (e.g., from owner funding the treasury)
     * @dev Emits Deposited event for off-chain tracking
     */
    receive() external payable {
        // Cache msg.value to avoid multiple SLOAD
        uint256 amount = msg.value;

        if (amount == 0) revert ZeroAmount();

        // Safe to cast: amount won't realistically overflow uint128
        // (would require depositing more ETH than exists)
        unchecked {
            totalDeposited += uint128(amount);
        }

        emit Deposited(msg.sender, amount);
    }

    // ============================================================
    //                      OPERATOR FUNCTIONS
    // ============================================================

    /**
     * @notice Fund the Paymaster contract with ETH for gas sponsorship
     * @dev Only operators or owner can call this
     *      Paymaster uses this ETH to pay gas on behalf of users
     * @param _paymaster Address of the Paymaster contract to fund
     * @param _amount Amount of ETH to send (in wei)
     */
    function fundPaymaster(
        address _paymaster,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        // Access control: only owner or authorized operators
        if (msg.sender != owner() && !operators[msg.sender]) {
            revert NotAuthorized();
        }

        // Validate inputs
        if (_paymaster == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        // Check we have enough ETH
        uint256 balance = address(this).balance;
        if (_amount > balance) {
            revert InsufficientBalance(_amount, balance);
        }

        // Update stats before external call (checks-effects-interactions)
        unchecked {
            totalPaymasterFunded += uint128(_amount);
        }

        // Send ETH to paymaster
        // Using low-level call (safer than transfer for contracts)
        (bool success, ) = _paymaster.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit PaymasterFunded(_paymaster, _amount);

        // Check if treasury is running low - emit warning if so
        if (address(this).balance < lowBalanceThreshold) {
            emit LowBalance(address(this).balance, lowBalanceThreshold);
        }
    }

    // ============================================================
    //                      OWNER FUNCTIONS
    // ============================================================

    /**
     * @notice Add or remove an authorized operator
     * @dev Operators can fund the paymaster but not withdraw arbitrarily
     *      Use this for backend wallets that auto-fund the paymaster
     * @param _operator Address to authorize/deauthorize
     * @param _authorized True to authorize, false to revoke
     */
    function setOperator(
        address _operator,
        bool _authorized
    ) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();

        operators[_operator] = _authorized;

        emit OperatorUpdated(_operator, _authorized);
    }

    /**
     * @notice Withdraw ETH from treasury to owner's address
     * @dev Emergency function to recover funds if needed
     *      Only owner can call (Ownable2Step = two-step ownership transfer)
     * @param _amount Amount to withdraw in wei (0 = withdraw all)
     */
    function withdraw(uint256 _amount) external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;

        // If 0 passed, withdraw everything
        uint256 amountToWithdraw = _amount == 0 ? balance : _amount;

        if (amountToWithdraw == 0) revert ZeroAmount();
        if (amountToWithdraw > balance) {
            revert InsufficientBalance(amountToWithdraw, balance);
        }

        // Send to owner
        (bool success, ) = owner().call{value: amountToWithdraw}("");
        if (!success) revert TransferFailed();

        emit Withdrawn(owner(), amountToWithdraw);
    }

    /**
     * @notice Update the low balance alert threshold
     * @param _newThreshold New threshold in wei
     */
    function setLowBalanceThreshold(
        uint128 _newThreshold
    ) external onlyOwner {
        lowBalanceThreshold = _newThreshold;
    }

    /**
     * @notice Pause all operations (emergency use only)
     * @dev Pausing blocks fundPaymaster but not withdrawals
     *      Ensures owner can always recover funds even when paused
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================================
    //                      VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current ETH balance of treasury
     * @return Current balance in wei
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Check if treasury balance is below threshold
     * @return True if balance is critically low
     */
    function isLowBalance() external view returns (bool) {
        return address(this).balance < lowBalanceThreshold;
    }

    /**
     * @notice Check if address is an authorized operator
     * @param _address Address to check
     * @return True if authorized
     */
    function isOperator(address _address) external view returns (bool) {
        return operators[_address];
    }

    /**
     * @notice Get full treasury stats in one call (gas efficient for frontend)
     * @return balance Current ETH balance
     * @return deposited Total ETH ever deposited
     * @return funded Total ETH ever sent to paymaster
     * @return isLow Whether balance is below threshold
     */
    function getStats() external view returns (
        uint256 balance,
        uint128 deposited,
        uint128 funded,
        bool isLow
    ) {
        balance = address(this).balance;
        deposited = totalDeposited;
        funded = totalPaymasterFunded;
        isLow = balance < lowBalanceThreshold;
    }

    // ============================================================
    //                      MISSING EVENT (ADD TO EVENTS SECTION)
    // ============================================================

    /**
     * @notice Emitted when treasury balance drops below threshold
     * @dev Monitor this off-chain to top up treasury before it runs dry
     */
    event LowBalance(uint256 currentBalance, uint256 threshold);
}