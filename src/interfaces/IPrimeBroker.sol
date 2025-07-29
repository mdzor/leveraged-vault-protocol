// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPrimeBroker {
    // Legacy synchronous functions (kept for repayment/withdrawal)
    function supply(address asset, uint256 amount) external;
    function borrow(address asset, uint256 amount) external; // Re-added for execution phase
    function repay(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function getHealthFactor(address user) external view returns (uint256);
    function getAvailableBorrow(address user, address asset) external view returns (uint256);

    // New async leverage functions
    function requestLeverage(
        address user,
        address asset,
        uint256 collateralAmount,
        uint256 leverageAmount,
        uint256 leverageRatio
    ) external returns (bytes32 requestId);

    // Callback functions (only broker can call these on vault)
    function isValidRequest(bytes32 requestId) external view returns (bool);
    function getRequestDetails(bytes32 requestId)
        external
        view
        returns (
            address user,
            address asset,
            uint256 collateralAmount,
            uint256 leverageAmount,
            uint256 requestTimestamp,
            bool isProcessed
        );
}
