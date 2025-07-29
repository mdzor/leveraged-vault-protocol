// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../src/interfaces/IERC3643.sol";

/**
 * @title MockERC3643Token
 * @dev Mock implementation of ERC3643 synthetic token for testing/deployment
 */
contract MockERC3643Token is ERC20, Ownable, IERC3643 {
    address public identityRegistry;
    address public compliance;
    mapping(address => bool) public verified;

    event UserVerified(address indexed user);
    event UserUnverified(address indexed user);

    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {
        // Set deployer as identity registry and compliance for simplicity
        identityRegistry = msg.sender;
        compliance = msg.sender;
    }

    /**
     * @dev Mint tokens (only owner/vault can call)
     */
    function mint(address to, uint256 amount) external override onlyOwner {
        require(isVerified(to), "Recipient not verified");
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens (only owner/vault can call)
     */
    function burn(address from, uint256 amount) external override onlyOwner {
        _burn(from, amount);
    }

    /**
     * @dev Check if address is verified for ERC3643 compliance
     */
    function isVerified(address account) public view override returns (bool) {
        return verified[account];
    }

    /**
     * @dev Admin function to verify users (simulate KYC)
     */
    function verifyUser(address user) external onlyOwner {
        verified[user] = true;
        emit UserVerified(user);
    }

    /**
     * @dev Admin function to unverify users
     */
    function unverifyUser(address user) external onlyOwner {
        verified[user] = false;
        emit UserUnverified(user);
    }

    /**
     * @dev Batch verify users for easier testing
     */
    function batchVerifyUsers(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            verified[users[i]] = true;
            emit UserVerified(users[i]);
        }
    }

    /**
     * @dev Override transfer to check compliance
     */
    function transfer(address to, uint256 amount) public override(ERC20, IERC3643) returns (bool) {
        require(isVerified(msg.sender), "Sender not verified");
        require(isVerified(to), "Recipient not verified");
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to check compliance
     */
    function transferFrom(address from, address to, uint256 amount)
        public
        override(ERC20, IERC3643)
        returns (bool)
    {
        require(isVerified(from), "Sender not verified");
        require(isVerified(to), "Recipient not verified");
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Override balanceOf to satisfy both ERC20 and IERC3643
     */
    function balanceOf(address account) public view override(ERC20, IERC3643) returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @dev Override totalSupply to satisfy both ERC20 and IERC3643
     */
    function totalSupply() public view override(ERC20, IERC3643) returns (uint256) {
        return super.totalSupply();
    }
}
