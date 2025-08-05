// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultImplementation.sol";

/**
 * @title ClonesBenchmark
 * Test to demonstrate gas savings of EIP-1167 clones pattern
 */
contract ClonesBenchmarkTest is Test {
    LeveragedVaultFactory factory;
    LeveragedVaultImplementation.VaultConfig config;
    
    function setUp() public {
        // Deploy factory (which creates the implementation)
        factory = new LeveragedVaultFactory();
        
        // Create test config
        config = LeveragedVaultImplementation.VaultConfig({
            depositToken: IERC20(address(0x1)),
            managementFee: 100,
            performanceFee: 1000,
            maxLeverage: 300,
            minLockPeriod: 86400,
            primeBroker: IPrimeBroker(address(0x2)),
            _reserved1: 0,
            morpho: IMorpho(address(0x3)),
            _reserved2: 0,
            syntheticToken: IERC3643(address(0x4)),
            _reserved3: 0,
            fundToken: address(0x5),
            _reserved4: 0,
            feeRecipient: address(0x6),
            _reserved5: 0,
            morphoMarket: MarketParams({
                loanToken: address(0x1),
                collateralToken: address(0x5),
                oracle: address(0x7),
                irm: address(0x8),
                lltv: 800000000000000000
            }),
            vaultName: "Test Vault",
            vaultSymbol: "TV"
        });
    }
    
    function testDeploymentGasCosts() public {
        // Measure gas for clone deployment
        uint256 gasBefore = gasleft();
        factory.createVault(config);
        uint256 cloneGas = gasBefore - gasleft();
        
        // Measure gas for direct deployment (for comparison)
        gasBefore = gasleft();
        new LeveragedVaultImplementation();
        uint256 directGas = gasBefore - gasleft();
        
        console.log("Clone deployment gas:", cloneGas);
        console.log("Direct deployment gas:", directGas);
        console.log("Gas savings:", directGas - cloneGas);
        console.log("Percentage savings:", ((directGas - cloneGas) * 100) / directGas, "%");
        
        // Clone should use significantly less gas
        assertLt(cloneGas, directGas);
    }
    
    function testMultipleDeployments() public {
        uint256 totalCloneGas = 0;
        uint256 totalDirectGas = 0;
        
        // Deploy 5 clones
        for (uint i = 0; i < 5; i++) {
            uint256 gasBefore = gasleft();
            factory.createVault(config);
            totalCloneGas += gasBefore - gasleft();
        }
        
        // Deploy 5 direct contracts
        for (uint i = 0; i < 5; i++) {
            uint256 gasBefore = gasleft();
            new LeveragedVaultImplementation();
            totalDirectGas += gasBefore - gasleft();
        }
        
        console.log("Total clone gas (5 deployments):", totalCloneGas);
        console.log("Total direct gas (5 deployments):", totalDirectGas);
        console.log("Total gas savings:", totalDirectGas - totalCloneGas);
        console.log("Average gas per clone:", totalCloneGas / 5);
        console.log("Average gas per direct:", totalDirectGas / 5);
        
        assertLt(totalCloneGas, totalDirectGas);
    }
    
    function testImplementationIsNotInitialized() public view {
        address impl = factory.getImplementation();
        LeveragedVaultImplementation implContract = LeveragedVaultImplementation(impl);
        
        // Implementation should be initialized (locked)
        assertTrue(implContract.isInitialized());
        
        // But should not be usable (owner is address(1) - dummy address)
        assertEq(implContract.owner(), address(1));
    }
    
    function testCloneIsProperlyInitialized() public {
        uint256 vaultId = factory.createVault(config);
        LeveragedVaultFactory.VaultInfo memory vaultInfo = factory.getVault(vaultId);
        
        LeveragedVaultImplementation vault = LeveragedVaultImplementation(vaultInfo.vaultAddress);
        
        // Clone should be initialized
        assertTrue(vault.isInitialized());
        
        // Clone should have proper owner
        assertEq(vault.owner(), address(this));
        
        // Clone should have proper factory
        assertEq(vault.factory(), address(factory));
    }
}