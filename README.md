# Splyt Smart Contracts

A decentralized bill splitting protocol built on Arbitrum. This repository contains the core smart contracts for creating and managing bill splits.

## Contracts Overview

### 1. SplytTreasury
Manages operational ETH funds used for gas sponsorship. Holds ETH that is sent to the Paymaster to sponsor user transactions.

**Key Functions:**
- `receive()` - Accept ETH deposits
- `fundPaymaster(address _paymaster, uint256 _amount)` - Send ETH to paymaster for gas sponsorship (owner/operators only)
- `setOperator(address _operator, bool _authorized)` - Add/remove authorized operators (owner only)
- `withdraw(uint256 _amount)` - Withdraw ETH from treasury (owner only)
- `setLowBalanceThreshold(uint128 _newThreshold)` - Update low balance alert threshold (owner only)
- `pause()` / `unpause()` - Emergency pause functionality (owner only)
- `getBalance()` - Get current ETH balance
- `isLowBalance()` - Check if balance is below threshold
- `isOperator(address _address)` - Check if address is authorized operator
- `getStats()` - Get full treasury statistics

---

### 2. SplytPaymaster
Handles gas fee sponsorship for users via ERC-4337 Account Abstraction. Validates and pays for user operations with daily spending limits.

**Key Functions:**
- `validatePaymasterUserOp(...)` - Validates user operation and checks daily limits
- `postOp(...)` - Handles refunds if actual gas cost is less than estimated
- `deposit()` - Deposit ETH to EntryPoint for gas payments (owner only)
- `withdraw(address payable to, uint256 amount)` - Withdraw ETH from EntryPoint (owner only)
- `setDailyLimit(uint128 _limit)` - Update daily spending limit per user (owner only)
- `pause()` / `unpause()` - Pause paymaster operations (owner only)

**State Variables:**
- `dailyLimit` - Maximum amount a user can spend per day
- `dailyUsed[address]` - Daily usage tracking per user
- `lastDay[address]` - Last day a user made a transaction

---

### 3. SplitFactory
Factory contract that creates and manages individual Split contracts. Tracks all splits and provides query functions.

**Key Functions:**
- `createSplit(string _description, address[] _participants, uint256[] _amounts, uint256 _expiryDays)` - Create a new bill split
- `setLimits(uint256 _maxParticipants, uint256 _maxAmount)` - Update max participants and max split amount (owner only)
- `pause()` / `unpause()` - Pause split creation (owner only)
- `getUserSplits(address _user)` - Get all split IDs a user is involved in
- `getCreatedSplits(address _user)` - Get all split IDs created by a user
- `getSplitAddress(uint256 _splitId)` - Get the address of a split contract by ID
- `getStats()` - Get total splits created and pause status

**State Variables:**
- `maxParticipants` - Maximum number of participants per split (default: 20)
- `maxSplitAmount` - Maximum total amount per split (default: 1,000,000 USDC)
- `splitCounter` - Total number of splits created

---

### 4. Split
Individual bill split contract deployed by SplitFactory. Manages payments from participants and releases funds to creator when complete.

**Key Functions:**
- `payShare(bytes32 _txHash)` - Pay your share of the bill (participants only)
- `cancelSplit()` - Cancel the split and refund paid participants (creator only)
- `settleExpired()` - Settle expired splits by sending collected funds to creator
- `getParticipants()` - Get array of all participants and their payment status
- `getSplitStatus()` - Get comprehensive split status information

**States:**
- `ACTIVE` - Split is active and accepting payments
- `COMPLETED` - All participants have paid, funds released to creator
- `CANCELLED` - Split was cancelled by creator
- `EXPIRED` - Split expired before completion

**Key Features:**
- Automatic fund release when all participants pay
- Optional expiration timestamp
- Refund mechanism for cancelled splits
- Reentrancy protection
- USDC token support

---

## Contract Relationships

```
SplytTreasury → funds → SplytPaymaster → sponsors gas → Users
                                                           ↓
SplitFactory → creates → Split contracts ← users pay USDC
```

## Security Features

- ReentrancyGuard on all contracts
- Pausable functionality for emergency stops
- Access control via Ownable/Ownable2Step
- Input validation and zero-address checks
- SafeERC20 for token transfers
