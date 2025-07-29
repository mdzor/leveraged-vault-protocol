// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Morpho Blue MarketParams struct
struct MarketParams {
    address loanToken;        // USDC (borrowed asset)
    address collateralToken;  // Fund token (collateral asset)
    address oracle;           // Price oracle
    address irm;              // Interest rate model
    uint256 lltv;             // Loan-to-value ratio
}

interface IMorpho {
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;
    
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;
    
    // View functions for position tracking
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint256 borrowShares, uint256 collateral);
    function market(bytes32 id) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint256 lastUpdate, uint128 fee);
}