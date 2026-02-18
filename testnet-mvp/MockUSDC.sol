// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    // USDC uses 6 decimals
    constructor() ERC20("Mock USDC", "USDC") {}

    /**
     * @dev Simple mint function to get test tokens.
     * @param to The address receiving tokens.
     * @param amount The amount to mint (remember to add 6 zeros for decimals).
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Overriding decimals to match real USDC (6 decimals)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}