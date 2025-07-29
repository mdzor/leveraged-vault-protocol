// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultImplementation.sol";
import "./mocks/MockPrimeBroker.sol";
import "./mocks/MockERC3643Token.sol";
import "./mocks/MockERC3643Fund.sol";

/**
 * @title Interact
 * @dev Helper script for interacting with deployed contracts
 */
contract Interact is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // You'll need to update these addresses after deployment
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        address usdc = vm.envAddress("USDC");
        address primeBroker = vm.envAddress("PRIME_BROKER");
        address syntheticToken = vm.envAddress("SYNTHETIC_TOKEN");
        address mockFund = vm.envAddress("MOCK_FUND");
        uint256 vaultId = vm.envUint("VAULT_ID");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Get vault address
        LeveragedVaultFactory.VaultInfo memory vaultInfo = LeveragedVaultFactory(vaultFactory).getVault(vaultId);
        address vault = vaultInfo.vaultAddress;
        
        console.log("Interacting with vault:", vault);
        
        // Example: Create a test position
        createTestPosition(vault, usdc, primeBroker, syntheticToken, deployer);
        
        vm.stopBroadcast();
    }
    
    function createTestPosition(
        address vault,
        address usdc,
        address primeBroker,
        address syntheticToken,
        address deployer
    ) internal {
        console.log("\n=== CREATING TEST POSITION ===");
        
        uint256 depositAmount = 10000e6; // 10k USDC
        uint256 leverageRatio = 300;     // 3x leverage
        
        // Ensure user has USDC and is verified
        require(IERC20(usdc).balanceOf(deployer) >= depositAmount, "Insufficient USDC balance");
        
        // Verify user in synthetic token
        MockERC3643Token(syntheticToken).verifyUser(deployer);
        console.log("Verified user in synthetic token");
        
        // Approve USDC spending
        IERC20(usdc).approve(vault, depositAmount);
        console.log("Approved USDC spending");
        
        // Request leverage position
        uint256 positionId = LeveragedVaultImplementation(vault).requestLeveragePosition(
            depositAmount,
            leverageRatio
        );
        
        console.log("Created position with ID:", positionId);
        
        // Get the broker request ID for approval
        LeveragedVaultImplementation.UserPosition memory position = LeveragedVaultImplementation(vault).getPosition(positionId);
        bytes32 brokerRequestId = position.brokerRequestId;
        
        console.log("Broker request ID: %s", vm.toString(brokerRequestId));
        
        // Auto-approve the request (for testing)
        uint256 approvedAmount = (depositAmount * (leverageRatio - 100)) / 100; // Calculate leverage amount
        MockPrimeBroker(primeBroker).approveLeverageRequest(brokerRequestId, approvedAmount);
        
        console.log("Auto-approved leverage request for", approvedAmount / 1e6, "USDC");
        
        // Execute the position
        LeveragedVaultImplementation(vault).executeLeveragePosition(positionId);
        
        console.log("Successfully executed position!");
        
        // Print position details
        printPositionDetails(vault, positionId);
    }
    
    function printPositionDetails(address vault, uint256 positionId) internal view {
        LeveragedVaultImplementation.UserPosition memory position = LeveragedVaultImplementation(vault).getPosition(positionId);
        (uint256 currentValue, int256 pnl) = LeveragedVaultImplementation(vault).getPositionValue(positionId);
        
        console.log("\n=== POSITION DETAILS ===");
        console.log("Position ID:", positionId);
        console.log("User:", position.user);
        console.log("Deposit Amount:", position.depositAmount / 1e6, "USDC");
        console.log("Leverage Ratio:", position.leverageRatio / 100, "x");
        console.log("Borrowed Amount:", position.borrowedAmount / 1e6, "USDC");
        console.log("Fund Tokens Owned:", position.fundTokensOwned / 1e18);
        console.log("Synthetic Tokens Minted:", position.syntheticTokensMinted / 1e18);
        console.log("Current Value:", currentValue / 1e6, "USDC");
        console.log("P&L:", pnl / 1e6, "USDC");
        console.log("State:", uint256(position.state));
        console.log("Lock Until:", position.lockUntil);
    }
    
    /**
     * @dev Simulate fund performance changes
     */
    function simulateFundPerformance() external {
        address mockFund = vm.envAddress("MOCK_FUND");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Simulating 10% fund growth...");
        MockERC3643Fund(mockFund).simulateGrowth();
        
        vm.stopBroadcast();
    }
    
    /**
     * @dev Fund the prime broker with more liquidity
     */
    function fundPrimeBroker() external {
        address usdc = vm.envAddress("USDC");
        address primeBroker = vm.envAddress("PRIME_BROKER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        uint256 fundAmount = 100000e6; // 100k USDC
        require(IERC20(usdc).balanceOf(deployer) >= fundAmount, "Insufficient balance");
        
        IERC20(usdc).transfer(primeBroker, fundAmount);
        console.log("Funded Prime Broker with", fundAmount / 1e6, "USDC");
        
        vm.stopBroadcast();
    }
    
    /**
     * @dev Verify multiple users in synthetic token
     */
    function verifyUsers(address[] calldata users) external {
        address syntheticToken = vm.envAddress("SYNTHETIC_TOKEN");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        MockERC3643Token(syntheticToken).batchVerifyUsers(users);
        console.log("Verified", users.length, "users");
        
        vm.stopBroadcast();
    }
    
    /**
     * @dev Close a position
     */
    function closePosition(uint256 positionId) external {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        uint256 vaultId = vm.envUint("VAULT_ID");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        LeveragedVaultFactory.VaultInfo memory vaultInfo = LeveragedVaultFactory(vaultFactory).getVault(vaultId);
        address vault = vaultInfo.vaultAddress;
        
        // Fast forward time if needed (for testing)
        LeveragedVaultImplementation.UserPosition memory position = LeveragedVaultImplementation(vault).getPosition(positionId);
        if (block.timestamp < position.lockUntil) {
            console.log("Position still locked. Lock expires at:", position.lockUntil);
            return;
        }
        
        LeveragedVaultImplementation(vault).closePosition(positionId);
        console.log("Successfully closed position", positionId);
        
        vm.stopBroadcast();
    }
}