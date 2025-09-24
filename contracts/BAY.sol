// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title BAY
 * @notice Marina Protocol utility token
 * @dev Standard ERC20 token with permit functionality for gasless approvals
 */
contract BAY is ERC20 {
    /// @notice Total supply of BAY tokens (1 billion)
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;

    /**
     * @notice Initialize BAY token with full supply
     * @param recipient Address to receive the total supply
     */
    constructor(address recipient)
        ERC20("BAY", "BAY")
    {
        _mint(recipient, TOTAL_SUPPLY);
    }
}