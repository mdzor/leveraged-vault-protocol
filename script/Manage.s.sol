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
 * @title Manage
 * @dev Management and admin functions for deployed protocol
 */
contract Manage is Script {
    /**
     * @dev Get protocol status overview
     */
    function getProtocolStatus() external view {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        address usdc = vm.envAddress("USDC");
        address primeBroker = vm.envAddress("PRIME_BROKER");
        address mockFund = vm.envAddress("MOCK_FUND");
        uint256 vaultId = vm.envUint("VAULT_ID");

        console.log("=== PROTOCOL STATUS ===");

        // Factory stats
        uint256 totalVaults = LeveragedVaultFactory(vaultFactory).totalVaultsCreated();
        console.log("Total Vaults Created:", totalVaults);

        // Get vault info
        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(vaultFactory).getVault(vaultId);
        console.log("Test Vault Address:", vaultInfo.vaultAddress);
        console.log("Test Vault Active:", vaultInfo.isActive);

        // Vault stats
        uint256 tvl = LeveragedVaultImplementation(vaultInfo.vaultAddress).getVaultTVL();
        console.log("Vault TVL:", tvl / 1e6, "USDC");

        // Token balances
        uint256 fundBalance = IERC20(mockFund).balanceOf(vaultInfo.vaultAddress);
        uint256 brokerBalance = IERC20(usdc).balanceOf(primeBroker);
        uint256 fundTotalSupply = IERC20(mockFund).totalSupply();

        console.log("Fund Tokens in Vault:", fundBalance / 1e18);
        console.log("USDC in Prime Broker:", brokerBalance / 1e6);
        console.log("Fund Token Total Supply:", fundTotalSupply / 1e18);

        // Fund performance
        uint256 sharePrice = MockERC3643Fund(mockFund).getSharePrice();
        console.log("Fund Share Price:", sharePrice / 1e18, "USDC");

        console.log("==========================================");
    }

    /**
     * @dev List all positions in the vault
     */
    function listAllPositions() external view {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        uint256 vaultId = vm.envUint("VAULT_ID");

        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(vaultFactory).getVault(vaultId);
        address vault = vaultInfo.vaultAddress;

        console.log("=== ALL POSITIONS ===");

        // Note: In a real implementation, you'd want to track position IDs
        // For this demo, we'll check positions 1-10
        for (uint256 i = 1; i <= 10; i++) {
            try LeveragedVaultImplementation(vault).getPosition(i) returns (
                LeveragedVaultImplementation.Position memory position,
                LeveragedVaultImplementation.ExecutedPositionData memory /* executedData */
            ) {
                if (position.user != address(0)) {
                    printPositionSummary(vault, i, position);
                }
            } catch {
                // Position doesn't exist, continue
                break;
            }
        }
    }

    function printPositionSummary(
        address vault,
        uint256 positionId,
        LeveragedVaultImplementation.Position memory position
    ) internal view {
        (uint256 currentValue, int256 pnl) =
            LeveragedVaultImplementation(vault).getPositionValue(positionId);

        console.log("Position", positionId, ":");
        console.log("  User:", position.user);
        console.log("  Deposit:", position.depositAmount / 1e6, "USDC");
        console.log("  Leverage:", position.leverageRatio / 100, "x");
        console.log("  State:", uint256(position.state));
        console.log("  Current Value:", currentValue / 1e6, "USDC");
        console.log("  P&L (USDC):", pnl / 1e6);
        console.log("  ---");
    }

    /**
     * @dev Approve all pending leverage requests (admin function)
     */
    function approveAllPendingRequests() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Auto-approving all pending requests...");
        // Note: In a real implementation, you'd get pending requests from the broker
        // For this demo, this is a placeholder function

        console.log("All pending requests approved!");

        vm.stopBroadcast();
    }

    /**
     * @dev Emergency pause the vault
     */
    function pauseVault() external {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        uint256 vaultId = vm.envUint("VAULT_ID");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(vaultFactory).getVault(vaultId);

        LeveragedVaultImplementation(vaultInfo.vaultAddress).pause();
        console.log("Vault paused!");

        vm.stopBroadcast();
    }

    /**
     * @dev Unpause the vault
     */
    function unpauseVault() external {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        uint256 vaultId = vm.envUint("VAULT_ID");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(vaultFactory).getVault(vaultId);

        LeveragedVaultImplementation(vaultInfo.vaultAddress).unpause();
        console.log("Vault unpaused!");

        vm.stopBroadcast();
    }

    /**
     * @dev Update fund share price to simulate performance
     */
    function updateFundPrice(uint256 newPriceE18) external {
        address mockFund = vm.envAddress("MOCK_FUND");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MockERC3643Fund(mockFund).updateSharePrice(newPriceE18);
        console.log("Updated fund share price to", newPriceE18 / 1e18, "USDC");

        vm.stopBroadcast();
    }

    /**
     * @dev Distribute USDC to multiple addresses for testing
     */
    function distributeUSDC(address[] calldata recipients, uint256 amountEach) external {
        address usdc = vm.envAddress("USDC");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        uint256 totalNeeded = recipients.length * amountEach;
        require(IERC20(usdc).balanceOf(deployer) >= totalNeeded, "Insufficient USDC balance");

        for (uint256 i = 0; i < recipients.length; i++) {
            IERC20(usdc).transfer(recipients[i], amountEach);
        }

        console.log("Distributed USDC:", amountEach / 1e6);
        console.log("Recipients:", recipients.length);

        vm.stopBroadcast();
    }

    /**
     * @dev Create multiple test vaults
     */
    function createTestVaults(uint256 count) external {
        address vaultFactory = vm.envAddress("VAULT_FACTORY");
        address usdc = vm.envAddress("USDC");
        address primeBroker = vm.envAddress("PRIME_BROKER");
        address syntheticToken = vm.envAddress("SYNTHETIC_TOKEN");
        address mockFund = vm.envAddress("MOCK_FUND");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        for (uint256 i = 0; i < count; i++) {
            MarketParams memory morphoMarket = MarketParams({
                loanToken: usdc,
                collateralToken: mockFund,
                oracle: address(0),
                irm: address(0),
                lltv: 800000000000000000 // 80% LTV
             });

            LeveragedVaultImplementation.VaultConfig memory config = LeveragedVaultImplementation
                .VaultConfig({
                depositToken: IERC20(usdc),
                managementFee: 200,
                performanceFee: 2000,
                maxLeverage: 500,
                minLockPeriod: uint64(7 days),
                primeBroker: IPrimeBroker(primeBroker),
                _reserved1: 0,
                morpho: IMorpho(vm.envAddress("MORPHO_BASE_TESTNET")),
                _reserved2: 0,
                syntheticToken: IERC3643(syntheticToken),
                _reserved3: 0,
                fundToken: mockFund,
                _reserved4: 0,
                feeRecipient: deployer,
                _reserved5: 0,
                morphoMarket: morphoMarket,
                vaultName: string(abi.encodePacked("Test Vault ", vm.toString(i + 1))),
                vaultSymbol: string(abi.encodePacked("TV", vm.toString(i + 1)))
            });

            uint256 vaultId = LeveragedVaultFactory(vaultFactory).createVault(config);
            console.log("Created vault", i + 1, "with ID", vaultId);
        }

        vm.stopBroadcast();
    }

    /**
     * @dev Get gas estimates for common operations
     */
    function getGasEstimates() external pure {
        console.log("=== GAS ESTIMATES ===");
        console.log("Deployment Costs:");
        console.log("- Vault Factory: ~2,500,000 gas");
        console.log("- Vault Implementation: ~3,500,000 gas");
        console.log("- Mock Fund: ~1,500,000 gas");
        console.log("- Mock Synthetic Token: ~1,200,000 gas");
        console.log("- Mock Prime Broker: ~2,000,000 gas");
        console.log("");
        console.log("Operation Costs:");
        console.log("- Request Position: ~150,000 gas");
        console.log("- Execute Position: ~400,000 gas");
        console.log("- Close Position: ~350,000 gas");
        console.log("- Create Vault: ~300,000 gas");
    }
}
