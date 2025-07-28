// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMorphoV2 {
    function supply(address asset, uint256 amount, address onBehalf) external;
    function withdraw(address asset, uint256 amount, address receiver) external;
    function getBalance(address user, address asset) external view returns (uint256);
}
