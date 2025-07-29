// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../src/interfaces/IPrimeBroker.sol";

/**
 * @title MockPrimeBroker
 * @dev Mock implementation of Prime Broker with async approval for testing/deployment
 */
contract MockPrimeBroker is Ownable, IPrimeBroker {
    using SafeERC20 for IERC20;

    struct LeverageRequest {
        address user;
        address asset;
        uint256 collateralAmount;
        uint256 leverageAmount;
        uint256 leverageRatio;
        uint256 requestTimestamp;
        bool isProcessed;
        bool isApproved;
    }

    mapping(bytes32 => LeverageRequest) public requests;
    mapping(address => uint256) public suppliedAssets;
    mapping(address => uint256) public borrowedAssets;

    uint256 private requestNonce;
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;
    uint256 public defaultHealthFactor = 2e18; // 200% health factor

    event LeverageRequested(bytes32 indexed requestId, address indexed user, uint256 amount);
    event LeverageApproved(bytes32 indexed requestId, uint256 approvedAmount);
    event LeverageRejected(bytes32 indexed requestId, string reason);

    constructor() Ownable(msg.sender) { }

    /**
     * @dev Supply assets to the broker
     */
    function supply(address asset, uint256 amount) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        suppliedAssets[msg.sender] += amount;
    }

    /**
     * @dev Borrow assets from the broker
     */
    function borrow(address asset, uint256 amount) external override {
        require(IERC20(asset).balanceOf(address(this)) >= amount, "Insufficient liquidity");
        IERC20(asset).safeTransfer(msg.sender, amount);
        borrowedAssets[msg.sender] += amount;
    }

    /**
     * @dev Repay borrowed assets
     */
    function repay(address asset, uint256 amount) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (borrowedAssets[msg.sender] >= amount) {
            borrowedAssets[msg.sender] -= amount;
        } else {
            borrowedAssets[msg.sender] = 0;
        }
    }

    /**
     * @dev Withdraw supplied assets
     */
    function withdraw(address asset, uint256 amount) external override {
        require(suppliedAssets[msg.sender] >= amount, "Insufficient balance");
        IERC20(asset).safeTransfer(msg.sender, amount);
        suppliedAssets[msg.sender] -= amount;
    }

    /**
     * @dev Get user's health factor
     */
    function getHealthFactor(address user) external view override returns (uint256) {
        return defaultHealthFactor; // Simplified for mock
    }

    /**
     * @dev Get available borrow amount for user
     */
    function getAvailableBorrow(address user, address asset)
        external
        view
        override
        returns (uint256)
    {
        return IERC20(asset).balanceOf(address(this)) / 2; // 50% of liquidity available
    }

    /**
     * @dev Request leverage (async pattern)
     */
    function requestLeverage(
        address user,
        address asset,
        uint256 collateralAmount,
        uint256 leverageAmount,
        uint256 leverageRatio
    ) external override returns (bytes32 requestId) {
        requestId = keccak256(
            abi.encodePacked(user, asset, collateralAmount, block.timestamp, requestNonce++)
        );

        requests[requestId] = LeverageRequest({
            user: user,
            asset: asset,
            collateralAmount: collateralAmount,
            leverageAmount: leverageAmount,
            leverageRatio: leverageRatio,
            requestTimestamp: block.timestamp,
            isProcessed: false,
            isApproved: false
        });

        emit LeverageRequested(requestId, user, leverageAmount);
        return requestId;
    }

    /**
     * @dev Check if request is valid
     */
    function isValidRequest(bytes32 requestId) public view override returns (bool) {
        return requests[requestId].user != address(0) && !requests[requestId].isProcessed;
    }

    /**
     * @dev Get request details
     */
    function getRequestDetails(bytes32 requestId)
        external
        view
        override
        returns (
            address user,
            address asset,
            uint256 collateralAmount,
            uint256 leverageAmount,
            uint256 requestTimestamp,
            bool isProcessed
        )
    {
        LeverageRequest memory request = requests[requestId];
        return (
            request.user,
            request.asset,
            request.collateralAmount,
            request.leverageAmount,
            request.requestTimestamp,
            request.isProcessed
        );
    }

    /**
     * @dev Admin function to approve leverage request
     */
    function approveLeverageRequest(bytes32 requestId, uint256 approvedAmount) external onlyOwner {
        require(isValidRequest(requestId), "Invalid request");

        LeverageRequest storage request = requests[requestId];
        request.isProcessed = true;
        request.isApproved = true;

        // Call the vault's approval handler
        (bool success,) = msg.sender.call(
            abi.encodeWithSignature(
                "handleBrokerApproval(bytes32,uint256)", requestId, approvedAmount
            )
        );
        require(success, "Vault approval call failed");

        emit LeverageApproved(requestId, approvedAmount);
    }

    /**
     * @dev Admin function to reject leverage request
     */
    function rejectLeverageRequest(bytes32 requestId, string calldata reason) external onlyOwner {
        require(isValidRequest(requestId), "Invalid request");

        LeverageRequest storage request = requests[requestId];
        request.isProcessed = true;
        request.isApproved = false;

        // Call the vault's rejection handler
        (bool success,) = msg.sender.call(
            abi.encodeWithSignature("handleBrokerRejection(bytes32,string)", requestId, reason)
        );
        require(success, "Vault rejection call failed");

        emit LeverageRejected(requestId, reason);
    }

    /**
     * @dev Auto-approve all requests (for testing convenience)
     */
    function enableAutoApproval(bool enabled) external onlyOwner {
        // Implementation would automatically approve requests
        // For simplicity, we'll handle this manually in deployment
    }

    /**
     * @dev Fund the broker with initial liquidity
     */
    function fundBroker(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Get pending requests (for admin interface)
     */
    function getPendingRequests() external view returns (bytes32[] memory) {
        // In a real implementation, you'd track all request IDs
        // For mock, we'll return empty array
        return new bytes32[](0);
    }
}
