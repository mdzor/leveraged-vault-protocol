// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultImplementation.sol";

/**
 * @dev Create a new vault with the updated PrimeBroker
 */
contract CreateNewVault is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Creating new vault from:", deployer);

        // Contract addresses from .env
        address vaultFactory = 0xccaC247FcC808A2eAAc081724B462AD51a6eA338;
        address usdc = 0xCbd9c307517C06Eb3a742459e335E8c0A2bb563A;
        address newPrimeBroker = 0x72c2f97114Fd1D1c55BD16B520F5f88ddfe92B04;
        address morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        address syntheticToken = 0xfBf5e7778B328066b71742234e110Fd1A70E9756;
        address mockFund = 0x88A602B79EFCed36D0218f59d0ac99e1beaC175c;

        vm.startBroadcast(deployerPrivateKey);

        // Create Morpho market params
        MarketParams memory morphoMarket = MarketParams({
            loanToken: usdc,
            collateralToken: mockFund,
            oracle: address(0),
            irm: address(0),
            lltv: 800000000000000000 // 80% LTV
        });

        // Create vault configuration
        LeveragedVaultImplementation.VaultConfig memory vaultConfig = LeveragedVaultImplementation
            .VaultConfig({
            depositToken: IERC20(usdc),
            managementFee: 200, // 2%
            performanceFee: 2000, // 20%
            maxLeverage: 500, // 5x
            minLockPeriod: uint64(7 days),
            primeBroker: IPrimeBroker(newPrimeBroker),
            _reserved1: 0,
            morpho: IMorpho(morpho),
            _reserved2: 0,
            syntheticToken: IERC3643(syntheticToken),
            _reserved3: 0,
            fundToken: mockFund,
            _reserved4: 0,
            feeRecipient: deployer,
            _reserved5: 0,
            morphoMarket: morphoMarket,
            vaultName: "EGAF Leveraged Vault v2",
            vaultSymbol: "lvEGAFv2"
        });

        // Create new vault
        uint256 newVaultId = LeveragedVaultFactory(vaultFactory).createVault(vaultConfig);

        // Get new vault address
        LeveragedVaultFactory.VaultInfo memory vaultInfo =
            LeveragedVaultFactory(vaultFactory).getVault(newVaultId);

        vm.stopBroadcast();

        console.log("\n=== NEW VAULT CREATED ===");
        console.log("New Vault ID:", newVaultId);
        console.log("New Vault Address:", vaultInfo.vaultAddress);
        console.log("Updated PrimeBroker:", newPrimeBroker);
        console.log("Vault Name: EGAF Leveraged Vault v2");
        console.log("\nUpdate your .env with:");
        console.log("VAULT_ID=", newVaultId);
        console.log("VAULT_ADDRESS=", vaultInfo.vaultAddress);
        console.log("PRIME_BROKER=", newPrimeBroker);
    }
}