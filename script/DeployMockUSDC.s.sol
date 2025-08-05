// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Simple script to deploy only Mock USDC for testing
 */
contract DeployMockUSDC is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Mock USDC from:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock USDC
        MockUSDC usdc = new MockUSDC();

        // Mint 1M USDC to deployer for testing
        usdc.mint(deployer, 1000000e6);

        vm.stopBroadcast();

        console.log("\n=== MOCK USDC DEPLOYED ===");
        console.log("Mock USDC Address:", address(usdc));
        console.log("Deployer USDC Balance:", usdc.balanceOf(deployer) / 1e6, "USDC");
        console.log("\nYou can now:");
        console.log("1. Mint more USDC: MockUSDC.mint(address, amount)");
        console.log("2. Use faucet: MockUSDC.faucet(amount)");
        console.log("3. Update your .env USDC address to:", address(usdc));
    }
}

/**
 * @dev Mock USDC contract for testing
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
