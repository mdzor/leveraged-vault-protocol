// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./libraries/LeverageCalculator.sol";

// Interfaces
interface IPrimeBroker {
    function supply(address asset, uint256 amount) external;
    function borrow(address asset, uint256 amount) external;
    function repay(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function getHealthFactor(address user) external view returns (uint256);
    function getAvailableBorrow(address user, address asset) external view returns (uint256);
}

interface IMorphoV2 {
    function supply(address asset, uint256 amount, address onBehalf) external;
    function withdraw(address asset, uint256 amount, address receiver) external;
    function getBalance(address user, address asset) external view returns (uint256);
}

interface IERC3643Fund {
    function invest(uint256 amount) external returns (uint256 shares);
    function redeem(uint256 shares) external returns (uint256 amount);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function getSharePrice() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IERC3643 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
    function isVerified(address account) external view returns (bool);
    function identityRegistry() external view returns (address);
    function compliance() external view returns (address);
}

/**
 * @title LeveragedVault
 * @dev Main contract for leveraged fund exposure with ERC3643 synthetic tokens
 * Users deposit USDC, get leveraged exposure to ERC3643 funds, receive synthetic tokens
 */
contract LeveragedVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using LeverageCalculator for uint256;

    // Constants
    uint256 public constant MAX_LEVERAGE = 500; // 5.0x
    uint256 public constant MIN_LEVERAGE = 150; // 1.5x
    uint256 public constant LEVERAGE_PRECISION = 100; // 1.0x = 100
    uint256 public constant BASIS_POINTS = 10000;
    
    // Position tracking
    struct UserPosition {
        uint256 positionId;
        address user;
        address fundToken;              // Which ERC3643 fund
        uint256 depositAmount;          // Original USDC deposit
        uint256 leverageRatio;          // 150 = 1.5x, 300 = 3x, etc.
        uint256 syntheticTokensMinted;  // ERC3643 synthetic tokens minted
        uint256 fundTokensOwned;        // Real EGAF tokens backing position
        uint256 borrowedAmount;         // Total debt to Prime Broker
        uint256 lockUntil;             // Position lock timestamp
        uint256 entryTimestamp;        // When position was opened
        bool isActive;
    }

    // Vault configuration
    struct VaultConfig {
        IERC20 depositToken;           // USDC, USDT, etc.
        IPrimeBroker primeBroker;      // Lending protocol for leverage
        IMorphoV2 morpho;              // Morpho v2 for collateral
        IERC3643 syntheticToken;       // ERC3643 synthetic token contract
        uint256 managementFee;         // Annual fee in basis points
        uint256 performanceFee;        // Performance fee in basis points
        uint256 minLockPeriod;         // Minimum lock period in seconds
        address feeRecipient;          // Where fees go
        uint256 maxLeverage;           // Maximum allowed leverage
    }

    // State variables
    VaultConfig public vaultConfig;
    uint256 public nextPositionId = 1;
    uint256 public totalValueLocked;
    uint256 public totalBorrowed;
    
    // Mappings
    mapping(uint256 => UserPosition) public positions;
    mapping(address => uint256[]) public userPositions;
    mapping(address => bool) public supportedFunds; // Supported ERC3643 funds
    mapping(address => uint256) public fundAllocations; // Allocation per fund
    
    // Events
    event PositionOpened(
        uint256 indexed positionId,
        address indexed user,
        address indexed fundToken,
        uint256 depositAmount,
        uint256 leverageRatio,
        uint256 syntheticTokens
    );
    
    event PositionClosed(
        uint256 indexed positionId,
        address indexed user,
        uint256 amountReturned,
        uint256 pnl
    );
    
    event LeverageChanged(
        uint256 indexed positionId,
        uint256 oldLeverage,
        uint256 newLeverage
    );
    
    event FundAdded(address indexed fundToken, uint256 allocation);
    
    event ConfigUpdated(VaultConfig newConfig);

    // Modifiers
    modifier validLeverage(uint256 leverageRatio) {
        require(
            leverageRatio >= MIN_LEVERAGE && 
            leverageRatio <= vaultConfig.maxLeverage &&
            leverageRatio % 50 == 0, // Must be in 0.5x increments
            "Invalid leverage ratio"
        );
        _;
    }
    
    modifier positionExists(uint256 positionId) {
        require(positions[positionId].isActive, "Position does not exist");
        _;
    }
    
    modifier onlyPositionOwner(uint256 positionId) {
        require(positions[positionId].user == msg.sender, "Not position owner");
        _;
    }

    constructor(VaultConfig memory _config) Ownable(msg.sender) {
        vaultConfig = _config;
    }

    /**
     * @dev Open a new leveraged position
     * @param fundToken The ERC3643 fund to get exposure to
     * @param amount Amount of deposit token to invest
     * @param leverageRatio Desired leverage (150 = 1.5x, 300 = 3x, etc.)
     * @return positionId The ID of the newly created position
     */
    function openPosition(
        address fundToken,
        uint256 amount,
        uint256 leverageRatio
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        validLeverage(leverageRatio)
        returns (uint256 positionId) 
    {
        require(supportedFunds[fundToken], "Fund not supported");
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer deposit from user
        vaultConfig.depositToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate leverage parameters
        uint256 totalInvestment = LeverageCalculator.calculateTotalInvestment(amount, leverageRatio);
        uint256 borrowAmount = LeverageCalculator.calculateBorrowAmount(amount, leverageRatio);
        uint256 loops = LeverageCalculator.calculateLoops(leverageRatio);
        
        // Execute leverage strategy
        uint256 fundTokensReceived = _executeLeverageStrategy(
            fundToken,
            amount,
            borrowAmount,
            loops
        );
        
        // Mint synthetic tokens to user
        uint256 syntheticTokens = LeverageCalculator.calculateSyntheticTokens(fundTokensReceived, leverageRatio);
        vaultConfig.syntheticToken.mint(msg.sender, syntheticTokens);
        
        // Create position
        positionId = nextPositionId++;
        positions[positionId] = UserPosition({
            positionId: positionId,
            user: msg.sender,
            fundToken: fundToken,
            depositAmount: amount,
            leverageRatio: leverageRatio,
            syntheticTokensMinted: syntheticTokens,
            fundTokensOwned: fundTokensReceived,
            borrowedAmount: borrowAmount,
            lockUntil: block.timestamp + vaultConfig.minLockPeriod,
            entryTimestamp: block.timestamp,
            isActive: true
        });
        
        userPositions[msg.sender].push(positionId);
        totalValueLocked += totalInvestment;
        totalBorrowed += borrowAmount;
        
        emit PositionOpened(
            positionId,
            msg.sender,
            fundToken,
            amount,
            leverageRatio,
            syntheticTokens
        );
    }

    /**
     * @dev Close a leveraged position
     * @param positionId The position to close
     */
    function closePosition(uint256 positionId) 
        external 
        nonReentrant 
        positionExists(positionId) 
        onlyPositionOwner(positionId) 
    {
        UserPosition storage position = positions[positionId];
        require(block.timestamp >= position.lockUntil, "Position still locked");
        
        // Burn synthetic tokens from user
        vaultConfig.syntheticToken.burn(msg.sender, position.syntheticTokensMinted);
        
        // Execute deleverage strategy
        uint256 amountReturned = _executeDeleverageStrategy(position);
        
        // Calculate P&L
        uint256 pnl = amountReturned > position.depositAmount ? 
            amountReturned - position.depositAmount : 0;
        
        // Charge fees
        uint256 fees = _calculateAndChargeFees(position, pnl);
        uint256 finalAmount = amountReturned - fees;
        
        // Return funds to user
        vaultConfig.depositToken.safeTransfer(msg.sender, finalAmount);
        
        // Update state
        totalValueLocked -= (position.depositAmount * position.leverageRatio) / LEVERAGE_PRECISION;
        totalBorrowed -= position.borrowedAmount;
        position.isActive = false;
        
        emit PositionClosed(positionId, msg.sender, finalAmount, pnl);
    }

    /**
     * @dev Adjust leverage of existing position
     * @param positionId The position to adjust
     * @param newLeverageRatio The new leverage ratio
     */
    function adjustLeverage(uint256 positionId, uint256 newLeverageRatio) 
        external 
        nonReentrant 
        positionExists(positionId) 
        onlyPositionOwner(positionId)
        validLeverage(newLeverageRatio)
    {
        UserPosition storage position = positions[positionId];
        require(block.timestamp >= position.lockUntil, "Position still locked");
        
        uint256 oldLeverage = position.leverageRatio;
        
        if (newLeverageRatio > oldLeverage) {
            _increaseLeverage(position, newLeverageRatio);
        } else if (newLeverageRatio < oldLeverage) {
            _decreaseLeverage(position, newLeverageRatio);
        }
        
        emit LeverageChanged(positionId, oldLeverage, newLeverageRatio);
    }

    /**
     * @dev Add a new supported fund
     * @param fundToken The ERC3643 fund token address
     * @param allocation Allocation percentage in basis points
     */
    function addSupportedFund(address fundToken, uint256 allocation) external onlyOwner {
        require(fundToken != address(0), "Invalid fund token");
        require(allocation <= BASIS_POINTS, "Invalid allocation");
        
        supportedFunds[fundToken] = true;
        fundAllocations[fundToken] = allocation;
        
        emit FundAdded(fundToken, allocation);
    }

    /**
     * @dev Update vault configuration
     * @param newConfig New vault configuration
     */
    function updateVaultConfig(VaultConfig memory newConfig) external onlyOwner {
        vaultConfig = newConfig;
        emit ConfigUpdated(newConfig);
    }

    // Internal functions for leverage execution
    function _executeLeverageStrategy(
        address fundToken,
        uint256 initialAmount,
        uint256 borrowAmount,
        uint256 loops
    ) internal returns (uint256 fundTokensReceived) {
        uint256 currentAmount = initialAmount;
        
        // Supply initial amount to Prime Broker
        vaultConfig.depositToken.approve(address(vaultConfig.primeBroker), initialAmount);
        vaultConfig.primeBroker.supply(address(vaultConfig.depositToken), initialAmount);
        
        // Execute leverage loops
        for (uint256 i = 0; i < loops; i++) {
            uint256 borrowThisLoop = LeverageCalculator.calculateBorrowPerLoop(borrowAmount, loops, i);
            
            // Borrow from Prime Broker
            vaultConfig.primeBroker.borrow(address(vaultConfig.depositToken), borrowThisLoop);
            
            // Supply borrowed amount back to Prime Broker
            vaultConfig.depositToken.approve(address(vaultConfig.primeBroker), borrowThisLoop);
            vaultConfig.primeBroker.supply(address(vaultConfig.depositToken), borrowThisLoop);
            
            currentAmount += borrowThisLoop;
        }
        
        // Invest final leveraged amount in fund
        vaultConfig.depositToken.approve(fundToken, currentAmount);
        fundTokensReceived = IERC3643Fund(fundToken).invest(currentAmount);
        
        // Deposit fund tokens to Morpho for collateral/yield
        IERC20(fundToken).approve(address(vaultConfig.morpho), fundTokensReceived);
        vaultConfig.morpho.supply(fundToken, fundTokensReceived, address(this));
        
        return fundTokensReceived;
    }

    function _executeDeleverageStrategy(UserPosition memory position) internal returns (uint256) {
        // Withdraw fund tokens from Morpho
        vaultConfig.morpho.withdraw(position.fundToken, position.fundTokensOwned, address(this));
        
        // Redeem fund tokens for underlying
        uint256 underlyingReceived = IERC3643Fund(position.fundToken).redeem(position.fundTokensOwned);
        
        // Repay borrowed amount to Prime Broker
        vaultConfig.depositToken.approve(address(vaultConfig.primeBroker), position.borrowedAmount);
        vaultConfig.primeBroker.repay(address(vaultConfig.depositToken), position.borrowedAmount);
        
        // Withdraw remaining collateral from Prime Broker
        uint256 collateralToWithdraw = position.depositAmount;
        vaultConfig.primeBroker.withdraw(address(vaultConfig.depositToken), collateralToWithdraw);
        
        return underlyingReceived - position.borrowedAmount;
    }

    function _calculateLoops(uint256 leverageRatio) internal pure returns (uint256) {
        // Simple calculation: higher leverage = more loops
        if (leverageRatio <= 200) return 1;      // 1.5x-2x: 1 loop
        if (leverageRatio <= 300) return 2;      // 2.5x-3x: 2 loops  
        if (leverageRatio <= 400) return 3;      // 3.5x-4x: 3 loops
        return 4;                                // 4.5x-5x: 4 loops
    }

    function _calculateSyntheticTokens(uint256 fundTokens, uint256 leverageRatio) internal pure returns (uint256) {
        // Synthetic tokens represent leveraged exposure
        return (fundTokens * leverageRatio) / LEVERAGE_PRECISION;
    }

    function _calculateAndChargeFees(UserPosition memory position, uint256 pnl) internal returns (uint256 totalFees) {
        uint256 managementFee = 0;
        uint256 performanceFee = 0;
        
        // Calculate management fee (time-based)
        uint256 timeHeld = block.timestamp - position.entryTimestamp;
        managementFee = LeverageCalculator.calculateManagementFee(
            position.depositAmount, 
            vaultConfig.managementFee, 
            timeHeld
        );
        
        // Calculate performance fee (profit-based)
        if (pnl > 0) {
            performanceFee = LeverageCalculator.calculatePerformanceFee(pnl, vaultConfig.performanceFee);
        }
        
        totalFees = managementFee + performanceFee;
        
        // Transfer fees to recipient
        if (totalFees > 0) {
            vaultConfig.depositToken.safeTransfer(vaultConfig.feeRecipient, totalFees);
        }
        
        return totalFees;
    }

    function _increaseLeverage(UserPosition storage position, uint256 newLeverageRatio) internal {
        // Implementation for increasing leverage
        // Would involve additional borrowing and reinvestment
    }

    function _decreaseLeverage(UserPosition storage position, uint256 newLeverageRatio) internal {
        // Implementation for decreasing leverage  
        // Would involve partial repayment and withdrawal
    }

    // View functions
    function getPosition(uint256 positionId) external view returns (UserPosition memory) {
        return positions[positionId];
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    function getPositionValue(uint256 positionId) external view returns (uint256 currentValue, int256 pnl) {
        UserPosition memory position = positions[positionId];
        if (!position.isActive) return (0, 0);
        
        // Get current fund token price
        uint256 currentPrice = IERC3643Fund(position.fundToken).getSharePrice();
        uint256 fundValue = (position.fundTokensOwned * currentPrice) / 1e18;
        
        currentValue = fundValue - position.borrowedAmount;
        pnl = int256(currentValue) - int256(position.depositAmount);
    }

    function getVaultTVL() external view returns (uint256) {
        return totalValueLocked;
    }

    function calculateRequiredLoops(uint256 leverageRatio) external pure returns (uint256) {
        return LeverageCalculator.calculateLoops(leverageRatio);
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
