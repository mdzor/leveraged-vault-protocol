// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/interfaces/IERC3643Fund.sol";

/**
 * @title MockERC3643Fund
 * @dev Mock implementation of ERC3643 fund for testing/deployment
 */
contract MockERC3643Fund is ERC20, IERC3643Fund {
    uint256 public sharePrice = 1e18; // Start at 1:1 with USDC
    IERC20 public immutable underlyingToken; // USDC
    
    event SharePriceUpdated(uint256 newPrice);
    event Investment(address indexed investor, uint256 usdcAmount, uint256 sharesReceived);
    event Redemption(address indexed redeemer, uint256 sharesAmount, uint256 usdcReceived);
    
    constructor(
        string memory name,
        string memory symbol,
        address _underlyingToken
    ) ERC20(name, symbol) {
        underlyingToken = IERC20(_underlyingToken);
    }
    
    /**
     * @dev Invest USDC and receive fund tokens
     */
    function invest(uint256 amount) external override returns (uint256 shares) {
        require(amount > 0, "Amount must be positive");
        
        // Transfer USDC from user
        underlyingToken.transferFrom(msg.sender, address(this), amount);
        
        // Calculate shares based on current price
        shares = (amount * 1e18) / sharePrice;
        
        // Mint fund tokens
        _mint(msg.sender, shares);
        
        emit Investment(msg.sender, amount, shares);
    }
    
    /**
     * @dev Redeem fund tokens for USDC
     */
    function redeem(uint256 shares) external override returns (uint256 amount) {
        require(shares > 0, "Shares must be positive");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");
        
        // Calculate USDC amount based on current price
        amount = (shares * sharePrice) / 1e18;
        
        // Burn fund tokens
        _burn(msg.sender, shares);
        
        // Transfer USDC to user
        underlyingToken.transfer(msg.sender, amount);
        
        emit Redemption(msg.sender, shares, amount);
    }
    
    /**
     * @dev Get current share price (in USDC terms)
     */
    function getSharePrice() external view override returns (uint256) {
        return sharePrice;
    }
    
    /**
     * @dev Get total assets under management
     */
    function totalAssets() external view override returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }
    
    /**
     * @dev Admin function to simulate fund performance by updating share price
     */
    function updateSharePrice(uint256 newPrice) external {
        require(newPrice > 0, "Price must be positive");
        sharePrice = newPrice;
        emit SharePriceUpdated(newPrice);
    }
    
    /**
     * @dev Simulate fund growth (10% increase)
     */
    function simulateGrowth() external {
        sharePrice = (sharePrice * 110) / 100; // 10% increase
        emit SharePriceUpdated(sharePrice);
    }
    
    /**
     * @dev Simulate fund loss (5% decrease)
     */
    function simulateLoss() external {
        sharePrice = (sharePrice * 95) / 100; // 5% decrease
        emit SharePriceUpdated(sharePrice);
    }
}