// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC3643 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
    
    // ERC3643 specific functions
    function isVerified(address account) external view returns (bool);
    function identityRegistry() external view returns (address);
    function compliance() external view returns (address);
}
