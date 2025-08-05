// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "./mocks/MockPrimeBroker.sol";

/**
 * @dev Deploy updated MockPrimeBroker with proper pending request tracking
 */
contract DeployUpdatedPrimeBroker is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Updated MockPrimeBroker from:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy updated MockPrimeBroker
        MockPrimeBroker primeBroker = new MockPrimeBroker();
        
        vm.stopBroadcast();

        console.log("\n=== UPDATED PRIME BROKER DEPLOYED ===");
        console.log("MockPrimeBroker Address:", address(primeBroker));
        console.log("\nNew functions available:");
        console.log("1. getPendingRequests() - returns array of pending request IDs");
        console.log("2. getAllRequests() - returns array of all request IDs");
        console.log("3. getTotalRequestCount() - returns total number of requests");
        console.log("\nUpdate your .env PRIME_BROKER address to:", address(primeBroker));
    }
}