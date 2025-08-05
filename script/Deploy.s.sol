// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultImplementation.sol";
import "../src/libraries/LeverageCalculator.sol";
import "./mocks/MockERC3643Fund.sol";
import "./mocks/MockERC3643Token.sol";
import "./mocks/MockPrimeBroker.sol";

/**
 * @title Deploy
 * @dev Comprehensive deployment script for Base testnet
 */
contract Deploy is Script {
    // Base network addresses
    address constant USDC_BASE_TESTNET = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Base testnet USDC
    address constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base mainnet USDC
    address constant MORPHO_BASE_TESTNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue on Base testnet
    address constant MORPHO_BASE_MAINNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue on Base mainnet

    // Deployment configuration
    struct DeployConfig {
        string vaultName;
        string vaultSymbol;
        string fundName;
        string fundSymbol;
        string syntheticName;
        string syntheticSymbol;
        uint256 managementFee; // basis points (200 = 2%)
        uint256 performanceFee; // basis points (2000 = 20%)
        uint256 minLockPeriod; // seconds (7 days)
        uint256 maxLeverage; // 500 = 5x
        uint256 initialFunding; // USDC amount for broker funding
    }

    // Deployed contract addresses
    struct DeployedContracts {
        address usdc;
        address morpho;
        address mockFund;
        address syntheticToken;
        address primeBroker;
        address vaultFactory;
        address vaultImplementation;
        uint256 testVaultId;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        DeployConfig memory config = DeployConfig({
            vaultName: "EGAF Leveraged Vault",
            vaultSymbol: "lvEGAF",
            fundName: "Enhanced Growth Alpha Fund",
            fundSymbol: "EGAF",
            syntheticName: "Synthetic EGAF Token",
            syntheticSymbol: "sEGAF",
            managementFee: 200, // 2% annual
            performanceFee: 2000, // 20% of profits
            minLockPeriod: 7 days,
            maxLeverage: 500, // 5x max
            initialFunding: 100000e6 // 100k USDC for broker
         });

        DeployedContracts memory contracts = deployProtocol(config, deployer);
        setupProtocol(contracts, config, deployer);

        vm.stopBroadcast();

        printDeploymentSummary(contracts, config);
    }

    function deployProtocol(DeployConfig memory config, address deployer)
        internal
        returns (DeployedContracts memory)
    {
        console.log("\n=== DEPLOYING PROTOCOL CONTRACTS ===");

        DeployedContracts memory contracts;

        // Check if we're on testnet (chain ID 84532) and deploy mock USDC for testing
        if (block.chainid == 84532) {
            console.log("Base testnet detected - deploying mock USDC for testing...");
            contracts.usdc = address(new MockUSDC());
            MockUSDC(contracts.usdc).mint(deployer, 1000000e6); // 1M USDC for testing
        } else {
            // Use existing USDC on mainnet
            contracts.usdc = USDC_BASE_MAINNET;
            console.log("Using existing USDC on mainnet");
        }
        console.log("USDC:", contracts.usdc);

        // Use appropriate Morpho address based on network
        if (block.chainid == 84532) {
            contracts.morpho = MORPHO_BASE_TESTNET;
        } else {
            contracts.morpho = MORPHO_BASE_MAINNET;
        }
        console.log("Morpho:", contracts.morpho);

        // Deploy mock ERC3643 fund
        contracts.mockFund =
            address(new MockERC3643Fund(config.fundName, config.fundSymbol, contracts.usdc));
        console.log("Mock Fund:", contracts.mockFund);

        // Deploy ERC3643 synthetic token
        contracts.syntheticToken =
            address(new MockERC3643Token(config.syntheticName, config.syntheticSymbol));
        console.log("Synthetic Token:", contracts.syntheticToken);

        // Deploy mock prime broker
        contracts.primeBroker = address(new MockPrimeBroker());
        console.log("Prime Broker:", contracts.primeBroker);

        // Deploy vault factory
        contracts.vaultFactory = address(new LeveragedVaultFactory());
        console.log("Vault Factory:", contracts.vaultFactory);

        return contracts;
    }

    function setupProtocol(
        DeployedContracts memory contracts,
        DeployConfig memory config,
        address deployer
    ) internal {
        console.log("\n=== SETTING UP PROTOCOL ===");

        // Fund the prime broker with USDC
        if (IERC20(contracts.usdc).balanceOf(deployer) >= config.initialFunding) {
            IERC20(contracts.usdc).transfer(contracts.primeBroker, config.initialFunding);
            console.log("Funded Prime Broker with", config.initialFunding / 1e6, "USDC");
        }

        // Verify the deployer in the synthetic token contract
        MockERC3643Token(contracts.syntheticToken).verifyUser(deployer);
        console.log("Verified deployer in synthetic token");

        // Create a test vault using the factory
        MarketParams memory morphoMarket = MarketParams({
            loanToken: contracts.usdc,
            collateralToken: contracts.mockFund,
            oracle: address(0), // Will need to be set for real Morpho integration
            irm: address(0), // Will need to be set for real Morpho integration
            lltv: 800000000000000000 // 80% LTV (in 18 decimals)
         });

        LeveragedVaultImplementation.VaultConfig memory vaultConfig = LeveragedVaultImplementation
            .VaultConfig({
            depositToken: IERC20(contracts.usdc),
            managementFee: uint16(config.managementFee),
            performanceFee: uint16(config.performanceFee),
            maxLeverage: uint16(config.maxLeverage),
            minLockPeriod: uint64(config.minLockPeriod),
            primeBroker: IPrimeBroker(contracts.primeBroker),
            _reserved1: 0,
            morpho: IMorpho(contracts.morpho),
            _reserved2: 0,
            syntheticToken: IERC3643(contracts.syntheticToken),
            _reserved3: 0,
            fundToken: contracts.mockFund,
            _reserved4: 0,
            feeRecipient: deployer,
            _reserved5: 0,
            morphoMarket: morphoMarket,
            vaultName: config.vaultName,
            vaultSymbol: config.vaultSymbol
        });

        contracts.testVaultId =
            LeveragedVaultFactory(contracts.vaultFactory).createVault(vaultConfig);

        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(contracts.vaultFactory).getVault(contracts.testVaultId);
        contracts.vaultImplementation = vaultInfo.vaultAddress;

        console.log("Created test vault with ID:", contracts.testVaultId);
        console.log("Vault implementation:", contracts.vaultImplementation);

        // Set vault as owner of synthetic token so it can mint/burn
        MockERC3643Token(contracts.syntheticToken).transferOwnership(contracts.vaultImplementation);
        console.log("Transferred synthetic token ownership to vault");

        // Add some initial liquidity to the mock fund
        if (IERC20(contracts.usdc).balanceOf(deployer) >= 50000e6) {
            IERC20(contracts.usdc).approve(contracts.mockFund, 50000e6);
            MockERC3643Fund(contracts.mockFund).invest(50000e6);
            console.log("Added 50k USDC initial liquidity to mock fund");
        }
    }

    function printDeploymentSummary(DeployedContracts memory contracts, DeployConfig memory config)
        internal
        view
    {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base Testnet");
        console.log("Deployer: %s", msg.sender);
        console.log("");
        console.log("Core Contracts:");
        console.log("- USDC: %s", contracts.usdc);
        console.log("- Morpho: %s", contracts.morpho);
        console.log("- Vault Factory: %s", contracts.vaultFactory);
        console.log("");
        console.log("Mock Contracts:");
        console.log("- Mock Fund (%s): %s", config.fundSymbol, contracts.mockFund);
        console.log("- Synthetic Token (%s): %s", config.syntheticSymbol, contracts.syntheticToken);
        console.log("- Prime Broker: %s", contracts.primeBroker);
        console.log("");
        console.log("Test Vault:");
        console.log("- Vault ID: %s", contracts.testVaultId);
        console.log("- Vault Address: %s", contracts.vaultImplementation);
        console.log("- Vault Name: %s", config.vaultName);
        console.log("");
        console.log("Configuration:");
        console.log("- Management Fee: %s%% annual", config.managementFee / 100);
        console.log("- Performance Fee: %s%% of profits", config.performanceFee / 100);
        console.log("- Max Leverage: %sx", config.maxLeverage / 100);
        console.log("- Lock Period: %s days", config.minLockPeriod / 1 days);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Verify deployer address in synthetic token: MockERC3643Token.verifyUser()");
        console.log("2. Fund prime broker if needed: MockPrimeBroker.fundBroker()");
        console.log(
            "3. Create test position: LeveragedVaultImplementation.requestLeveragePosition()"
        );
        console.log("4. Approve position: MockPrimeBroker.approveLeverageRequest()");
        console.log("5. Execute position: LeveragedVaultImplementation.executeLeveragePosition()");
    }
}

/**
 * @dev Mock USDC contract for testing if real USDC not available
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
