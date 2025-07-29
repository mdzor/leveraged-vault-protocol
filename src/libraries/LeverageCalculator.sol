// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LeverageCalculator
 * @dev Library for calculating leverage-related parameters
 */
library LeverageCalculator {
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @dev Calculate the number of recursive loops needed for target leverage
     * @param leverageRatio The target leverage ratio (150 = 1.5x, 300 = 3x, etc.)
     * @return loops Number of borrow/supply loops required
     */
    function calculateLoops(uint256 leverageRatio) internal pure returns (uint256 loops) {
        if (leverageRatio <= 200) return 1; // 1.5x-2x: 1 loop
        if (leverageRatio <= 300) return 2; // 2.5x-3x: 2 loops
        if (leverageRatio <= 400) return 3; // 3.5x-4x: 3 loops
        return 4; // 4.5x-5x: 4 loops
    }

    /**
     * @dev Calculate total investment amount from deposit and leverage
     * @param depositAmount Original deposit amount
     * @param leverageRatio Target leverage ratio
     * @return totalInvestment Total amount to invest (deposit + borrowed)
     */
    function calculateTotalInvestment(uint256 depositAmount, uint256 leverageRatio)
        internal
        pure
        returns (uint256 totalInvestment)
    {
        return (depositAmount * leverageRatio) / LEVERAGE_PRECISION;
    }

    /**
     * @dev Calculate how much to borrow for target leverage
     * @param depositAmount Original deposit amount
     * @param leverageRatio Target leverage ratio
     * @return borrowAmount Amount to borrow
     */
    function calculateBorrowAmount(uint256 depositAmount, uint256 leverageRatio)
        internal
        pure
        returns (uint256 borrowAmount)
    {
        uint256 totalInvestment = calculateTotalInvestment(depositAmount, leverageRatio);
        return totalInvestment - depositAmount;
    }

    /**
     * @dev Calculate synthetic tokens to mint based on fund tokens and leverage
     * @param fundTokens Amount of fund tokens received
     * @param leverageRatio Leverage ratio used
     * @return syntheticTokens Amount of synthetic tokens to mint
     */
    function calculateSyntheticTokens(uint256 fundTokens, uint256 leverageRatio)
        internal
        pure
        returns (uint256 syntheticTokens)
    {
        // Synthetic tokens represent leveraged exposure
        return (fundTokens * leverageRatio) / LEVERAGE_PRECISION;
    }

    /**
     * @dev Calculate borrow amount per loop for even distribution
     * @param totalBorrowAmount Total amount to borrow
     * @param loops Number of loops to execute
     * @param currentLoop Current loop index (0-based)
     * @return borrowThisLoop Amount to borrow in this specific loop
     */
    function calculateBorrowPerLoop(uint256 totalBorrowAmount, uint256 loops, uint256 currentLoop)
        internal
        pure
        returns (uint256 borrowThisLoop)
    {
        require(currentLoop < loops, "Invalid loop index");

        // Distribute borrowing evenly across loops
        uint256 baseAmount = totalBorrowAmount / loops;
        uint256 remainder = totalBorrowAmount % loops;

        // Add remainder to the last loop
        if (currentLoop == loops - 1) {
            return baseAmount + remainder;
        }
        return baseAmount;
    }

    /**
     * @dev Calculate management fee based on time held
     * @param depositAmount Original deposit amount
     * @param annualFeeRate Annual fee rate in basis points
     * @param timeHeld Time position was held in seconds
     * @return managementFee Management fee amount
     */
    function calculateManagementFee(uint256 depositAmount, uint256 annualFeeRate, uint256 timeHeld)
        internal
        pure
        returns (uint256 managementFee)
    {
        return (depositAmount * annualFeeRate * timeHeld) / (BASIS_POINTS * 365 days);
    }

    /**
     * @dev Calculate performance fee based on profits
     * @param profit Profit amount (must be > 0)
     * @param performanceFeeRate Performance fee rate in basis points
     * @return performanceFee Performance fee amount
     */
    function calculatePerformanceFee(uint256 profit, uint256 performanceFeeRate)
        internal
        pure
        returns (uint256 performanceFee)
    {
        return (profit * performanceFeeRate) / BASIS_POINTS;
    }

    /**
     * @dev Calculate health factor for a position
     * @param collateralValue Value of collateral
     * @param borrowedAmount Amount borrowed
     * @return healthFactor Health factor (1e18 = 100%)
     */
    function calculateHealthFactor(uint256 collateralValue, uint256 borrowedAmount)
        internal
        pure
        returns (uint256 healthFactor)
    {
        if (borrowedAmount == 0) return type(uint256).max;
        return (collateralValue * 1e18) / borrowedAmount;
    }

    /**
     * @dev Validate leverage ratio is within acceptable bounds and increments
     * @param leverageRatio Leverage ratio to validate
     * @param minLeverage Minimum allowed leverage
     * @param maxLeverage Maximum allowed leverage
     * @return isValid Whether the leverage ratio is valid
     */
    function validateLeverageRatio(uint256 leverageRatio, uint256 minLeverage, uint256 maxLeverage)
        internal
        pure
        returns (bool isValid)
    {
        return
            leverageRatio >= minLeverage && leverageRatio <= maxLeverage && leverageRatio % 50 == 0; // Must be in 0.5x increments
    }
}
