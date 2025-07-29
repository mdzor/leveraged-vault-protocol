// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./LeveragedVaultImplementation.sol";

/**
 * @title LeveragedVaultFactory
 * Factory contract for deploying individual leveraged vaults
 * Each vault targets a specific ERC3643 fund with configurable parameters
 */
contract LeveragedVaultFactory is Ownable, ReentrancyGuard {
    // Vault tracking
    struct VaultInfo {
        address vaultAddress;
        address fundToken;
        address owner;
        string name;
        string symbol;
        uint256 createdAt;
        bool isActive;
    }

    // State variables
    uint256 public nextVaultId = 1;
    uint256 public totalVaultsCreated;

    // Mappings
    mapping(uint256 => VaultInfo) public vaults;
    mapping(address => uint256[]) public userVaults; // vaults created by user
    mapping(address => uint256) public vaultIdByAddress; // vault address => vault ID
    mapping(address => bool) public isValidVault; // quick check for valid vaults

    // Events
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed vaultAddress,
        address indexed owner,
        address fundToken,
        string name,
        string symbol
    );

    event VaultStatusChanged(uint256 indexed vaultId, address indexed vaultAddress, bool isActive);

    // Modifiers
    modifier validVault(uint256 vaultId) {
        require(vaultId > 0 && vaultId < nextVaultId, "Invalid vault ID");
        require(vaults[vaultId].isActive, "Vault is not active");
        _;
    }

    constructor() Ownable(msg.sender) {
        // Factory constructor
    }

    /**
     * @param config Vault configuration parameters
     * @return vaultId The ID of the newly created vault
     */
    function createVault(LeveragedVaultImplementation.VaultConfig memory config)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        require(config.fundToken != address(0), "Invalid fund token");
        require(bytes(config.vaultName).length > 0, "Vault name required");
        require(bytes(config.vaultSymbol).length > 0, "Vault symbol required");
        require(config.maxLeverage >= 150 && config.maxLeverage <= 500, "Invalid max leverage");
        require(config.feeRecipient != address(0), "Invalid fee recipient");

        // Deploy new vault implementation
        LeveragedVaultImplementation newVault = new LeveragedVaultImplementation();

        // Initialize the vault
        newVault.initialize(config, msg.sender);

        // Create vault info
        vaultId = nextVaultId++;
        vaults[vaultId] = VaultInfo({
            vaultAddress: address(newVault),
            fundToken: config.fundToken,
            owner: msg.sender,
            name: config.vaultName,
            symbol: config.vaultSymbol,
            createdAt: block.timestamp,
            isActive: true
        });

        // Update mappings
        userVaults[msg.sender].push(vaultId);
        vaultIdByAddress[address(newVault)] = vaultId;
        isValidVault[address(newVault)] = true;
        totalVaultsCreated++;

        emit VaultCreated(
            vaultId,
            address(newVault),
            msg.sender,
            config.fundToken,
            config.vaultName,
            config.vaultSymbol
        );
    }

    /**
     * @param vaultId The vault to deactivate
     */
    function deactivateVault(uint256 vaultId) external nonReentrant validVault(vaultId) {
        VaultInfo storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "Not vault owner");

        vault.isActive = false;
        isValidVault[vault.vaultAddress] = false;

        emit VaultStatusChanged(vaultId, vault.vaultAddress, false);
    }

    /**
     * @param vaultId The vault to reactivate
     */
    function reactivateVault(uint256 vaultId) external nonReentrant {
        require(vaultId > 0 && vaultId < nextVaultId, "Invalid vault ID");
        VaultInfo storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "Not vault owner");
        require(!vault.isActive, "Vault is already active");

        vault.isActive = true;
        isValidVault[vault.vaultAddress] = true;

        emit VaultStatusChanged(vaultId, vault.vaultAddress, true);
    }

    /**
     * @param vaultId The vault to transfer
     * @param newOwner The new owner address
     * Note: This function requires the current vault owner to first call
     * transferOwnership directly on their vault, then call this function to update factory records
     */
    function transferVaultOwnership(uint256 vaultId, address newOwner)
        external
        nonReentrant
        validVault(vaultId)
    {
        require(newOwner != address(0), "Invalid new owner");
        VaultInfo storage vault = vaults[vaultId];
        require(vault.owner == msg.sender, "Not vault owner");

        // Verify that the vault ownership has actually been transferred
        LeveragedVaultImplementation vaultContract =
            LeveragedVaultImplementation(vault.vaultAddress);
        require(vaultContract.owner() == newOwner, "Vault ownership not transferred");

        // Update factory records
        vault.owner = newOwner;

        // Update user vault lists
        userVaults[newOwner].push(vaultId);
    }

    // View functions
    function getVault(uint256 vaultId) external view returns (VaultInfo memory) {
        return vaults[vaultId];
    }

    function getUserVaults(address user) external view returns (uint256[] memory) {
        return userVaults[user];
    }


    function getAllVaults() external view returns (VaultInfo[] memory) {
        VaultInfo[] memory allVaults = new VaultInfo[](totalVaultsCreated);
        uint256 index = 0;

        for (uint256 i = 1; i < nextVaultId; i++) {
            if (vaults[i].vaultAddress != address(0)) {
                allVaults[index] = vaults[i];
                index++;
            }
        }

        return allVaults;
    }


    function getTotalVaultsCreated() external view returns (uint256) {
        return totalVaultsCreated;
    }

    function getFactoryStats()
        external
        view
        returns (uint256 totalCreated, uint256 nextId, uint256 activeCount)
    {
        totalCreated = totalVaultsCreated;
        nextId = nextVaultId;

        // Count active vaults
        activeCount = 0;
        for (uint256 i = 1; i < nextVaultId; i++) {
            if (vaults[i].isActive) {
                activeCount++;
            }
        }
    }

    // Emergency functions
    function emergencyPauseVault(uint256 vaultId) external onlyOwner validVault(vaultId) {
        VaultInfo storage vault = vaults[vaultId];
        LeveragedVaultImplementation(vault.vaultAddress).pause();
    }

    function emergencyUnpauseVault(uint256 vaultId) external onlyOwner {
        require(vaultId > 0 && vaultId < nextVaultId, "Invalid vault ID");
        VaultInfo storage vault = vaults[vaultId];
        LeveragedVaultImplementation(vault.vaultAddress).unpause();
    }

    function emergencyWithdrawFromVault(uint256 vaultId, address token, uint256 amount)
        external
        onlyOwner
        validVault(vaultId)
    {
        VaultInfo storage vault = vaults[vaultId];
        LeveragedVaultImplementation(vault.vaultAddress).emergencyWithdraw(token, amount);
    }
}
