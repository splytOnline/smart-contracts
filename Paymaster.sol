// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://raw.githubusercontent.com/eth-infinitism/account-abstraction/v0.7.0/contracts/interfaces/IPaymaster.sol";
import "https://raw.githubusercontent.com/eth-infinitism/account-abstraction/v0.7.0/contracts/interfaces/IEntryPoint.sol";
import "https://raw.githubusercontent.com/eth-infinitism/account-abstraction/v0.7.0/contracts/interfaces/PackedUserOperation.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract SplytPaymaster is IPaymaster, Ownable, Pausable {

    IEntryPoint public immutable entryPoint;

    mapping(address => uint128) public dailyUsed;
    mapping(address => uint32) public lastDay;

    uint128 public dailyLimit;

    constructor(
    IEntryPoint _entryPoint,
    uint128 _dailyLimit
) Ownable(msg.sender) {
    require(address(_entryPoint) != address(0), "zero entrypoint");

    entryPoint = _entryPoint;
    dailyLimit = _dailyLimit;
}

    receive() external payable {}

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    )
        external
        override
        whenNotPaused
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "not entrypoint");

        address sender = userOp.sender;

        require(
            entryPoint.balanceOf(address(this)) >= maxCost,
            "insufficient deposit"
        );

        uint32 today = uint32(block.timestamp / 1 days);

        if (lastDay[sender] != today) {
            lastDay[sender] = today;
            dailyUsed[sender] = 0;
        }

        uint128 newUsage = dailyUsed[sender] + uint128(maxCost);
        require(newUsage <= dailyLimit, "daily limit exceeded");

        dailyUsed[sender] = newUsage;

        context = abi.encode(sender, maxCost);

        return (context, 0);
    }

    function postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256
    )
        external
        override
    {
        require(msg.sender == address(entryPoint), "not entrypoint");

        (address sender, uint256 maxCost) =
            abi.decode(context, (address, uint256));

        if (actualGasCost < maxCost) {
            uint256 refund = maxCost - actualGasCost;
            dailyUsed[sender] -= uint128(refund);
        }
    }

    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdraw(address payable to, uint256 amount)
        external
        onlyOwner
    {
        entryPoint.withdrawTo(to, amount);
    }

    function setDailyLimit(uint128 _limit) external onlyOwner {
        dailyLimit = _limit;
    }
}
