// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./libraries/LeverageCalculator.sol";
import "./interfaces/IPrimeBroker.sol";
import "./interfaces/IMorpho.sol";
import "./interfaces/IERC3643.sol";
import "./interfaces/IERC3643Fund.sol";


/**
 * @title LeveragedVaultImplementation
 * @dev Individual vault implementation for leveraged fund exposure with ERC3643 synthetic tokens
 * Deployed by VaultFactory for each specific fund/configuration
 */
contract LeveragedVaultImplementation is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using LeverageCalculator for uint256;

    // Constants
    uint256 public constant MAX_LEVERAGE = 500; // 5.0x
    uint256 public constant MIN_LEVERAGE = 150; // 1.5x
    uint256 public constant LEVERAGE_PRECISION = 100; // 1.0x = 100
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant BROKER_TIMEOUT = 24 hours; // Max time for broker response
    
    // Position state machine
    enum PositionState {
        Pending,    // Waiting for broker approval
        Approved,   // Broker approved, ready for execution
        Rejected,   // Broker rejected, funds can be withdrawn
        Executed,   // Position executed, earning yield
        Completed,  // Position closed, loan repaid
        Expired     // Broker didn't respond in time
    }
    
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
        
        // New async broker fields
        PositionState state;           // Current position state
        bytes32 brokerRequestId;       // Broker's unique request identifier
        uint256 approvedAmount;        // Amount approved by broker (may differ from requested)
        uint256 requestTimestamp;      // When broker request was made
        uint256 executionDeadline;     // When broker approval expires
    }

    // Vault configuration
    struct VaultConfig {
        IERC20 depositToken;           // USDC, USDT, etc.
        IPrimeBroker primeBroker;      // Lending protocol for leverage
        IMorpho morpho;                // Morpho Blue for collateral
        IERC3643 syntheticToken;       // ERC3643 synthetic token contract
        address fundToken;             // The specific ERC3643 fund this vault targets
        MarketParams morphoMarket;     // Morpho Blue market parameters
        uint256 managementFee;         // Annual fee in basis points
        uint256 performanceFee;        // Performance fee in basis points
        uint256 minLockPeriod;         // Minimum lock period in seconds
        address feeRecipient;          // Where fees go
        uint256 maxLeverage;           // Maximum allowed leverage
        string vaultName;              // Vault name for identification
        string vaultSymbol;            // Vault symbol
    }

    // State variables
    VaultConfig public vaultConfig;
    address public factory;            // Factory that deployed this vault
    uint256 public nextPositionId = 1;
    uint256 public totalValueLocked;
    uint256 public totalBorrowed;
    
    // Mappings
    mapping(uint256 => UserPosition) public positions;
    mapping(address => uint256[]) public userPositions;
    
    // Async broker mappings
    mapping(bytes32 => uint256) public requestIdToPosition; // Broker request ID -> position ID
    mapping(uint256 => bytes32) public positionToRequestId; // Position ID -> broker request ID
    
    // Events
    event PositionRequested(
        uint256 indexed positionId,
        address indexed user,
        bytes32 indexed brokerRequestId,
        uint256 depositAmount,
        uint256 leverageRatio,
        uint256 requestedAmount
    );
    
    event PositionApproved(
        uint256 indexed positionId,
        bytes32 indexed brokerRequestId,
        uint256 approvedAmount
    );
    
    event PositionRejected(
        uint256 indexed positionId,
        bytes32 indexed brokerRequestId,
        string reason
    );
    
    event PositionExecuted(
        uint256 indexed positionId,
        address indexed user,
        uint256 fundTokensReceived,
        uint256 syntheticTokensMinted
    );
    
    event PositionClosed(
        uint256 indexed positionId,
        address indexed user,
        uint256 amountReturned,
        uint256 pnl
    );
    
    event PositionStateChanged(
        uint256 indexed positionId,
        PositionState oldState,
        PositionState newState
    );
    
    event PositionExpired(
        uint256 indexed positionId,
        bytes32 indexed brokerRequestId
    );
    
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
        require(positions[positionId].user != address(0), "Position does not exist");
        _;
    }
    
    modifier onlyPositionOwner(uint256 positionId) {
        require(positions[positionId].user == msg.sender, "Not position owner");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call");
        _;
    }

    modifier onlyBroker() {
        require(msg.sender == address(vaultConfig.primeBroker), "Only broker can call");
        _;
    }

    modifier validPositionState(uint256 positionId, PositionState expectedState) {
        require(positions[positionId].state == expectedState, "Invalid position state");
        _;
    }

    modifier positionNotExpired(uint256 positionId) {
        UserPosition memory position = positions[positionId];
        if (position.state == PositionState.Approved) {
            require(block.timestamp <= position.executionDeadline, "Position approval expired");
        }
        _;
    }

    constructor() Ownable(msg.sender) {
        // Constructor will be called by factory during deployment
        factory = msg.sender;
    }

    /**
     * @dev Initialize the vault with configuration (called by factory)
     * @param _config Vault configuration
     * @param _owner Owner of the vault
     */
    function initialize(VaultConfig memory _config, address _owner) external onlyFactory {
        require(_owner != address(0), "Owner cannot be zero address");
        require(address(_config.depositToken) != address(0), "Deposit token cannot be zero address");
        require(address(_config.primeBroker) != address(0), "Prime broker cannot be zero address");
        require(address(_config.morpho) != address(0), "Morpho cannot be zero address");
        require(address(_config.syntheticToken) != address(0), "Synthetic token cannot be zero address");
        require(_config.fundToken != address(0), "Fund token cannot be zero address");
        require(_config.feeRecipient != address(0), "Fee recipient cannot be zero address");
        require(_config.maxLeverage >= MIN_LEVERAGE && _config.maxLeverage <= MAX_LEVERAGE, "Invalid max leverage");
        require(_config.managementFee <= BASIS_POINTS, "Management fee too high");
        require(_config.performanceFee <= BASIS_POINTS, "Performance fee too high");
        require(_config.minLockPeriod > 0, "Lock period must be positive");
        
        vaultConfig = _config;
        _transferOwnership(_owner);
    }

    /**
     * @dev Request a new leveraged position (Step 1: Submit to broker)
     * @param amount Amount of deposit token to invest
     * @param leverageRatio Desired leverage (150 = 1.5x, 300 = 3x, etc.)
     * @return positionId The ID of the newly created position (in Pending state)
     */
    function requestLeveragePosition(
        uint256 amount,
        uint256 leverageRatio
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        validLeverage(leverageRatio)
        returns (uint256 positionId) 
    {
        require(amount > 0, "Amount must be greater than 0");
        require(msg.sender != address(0), "Invalid sender");
        
        // Check user has sufficient balance
        require(vaultConfig.depositToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(vaultConfig.depositToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        
        // Transfer deposit from user (held in vault until broker approval)
        vaultConfig.depositToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate requested leverage amount
        uint256 requestedLeverageAmount = LeverageCalculator.calculateBorrowAmount(amount, leverageRatio);
        
        // Create position in Pending state FIRST (before broker call)
        positionId = nextPositionId++;
        
        // Submit request to broker
        bytes32 brokerRequestId = vaultConfig.primeBroker.requestLeverage(
            msg.sender,
            address(vaultConfig.depositToken),
            amount, // collateral amount
            requestedLeverageAmount, // requested leverage amount
            leverageRatio
        );
        
        // Set up mapping after getting broker ID
        requestIdToPosition[brokerRequestId] = positionId;
        positionToRequestId[positionId] = brokerRequestId;
        
        positions[positionId] = UserPosition({
            positionId: positionId,
            user: msg.sender,
            fundToken: vaultConfig.fundToken,
            depositAmount: amount,
            leverageRatio: leverageRatio,
            syntheticTokensMinted: 0, // Will be set after execution
            fundTokensOwned: 0, // Will be set after execution
            borrowedAmount: 0, // Will be set after broker approval
            lockUntil: 0, // Will be set after execution
            entryTimestamp: block.timestamp,
            
            // Async broker fields
            state: PositionState.Pending,
            brokerRequestId: brokerRequestId,
            approvedAmount: 0, // Will be set by broker
            requestTimestamp: block.timestamp,
            executionDeadline: 0 // Will be set after broker approval
        });
        
        // Add to user positions
        userPositions[msg.sender].push(positionId);
        
        emit PositionRequested(
            positionId,
            msg.sender,
            brokerRequestId,
            amount,
            leverageRatio,
            requestedLeverageAmount
        );
    }

    /**
     * @dev Handle broker approval (Step 2: Broker approves request)
     * @param brokerRequestId The broker's request ID
     * @param approvedAmount Amount approved by broker (may differ from requested)
     */
    function handleBrokerApproval(
        bytes32 brokerRequestId,
        uint256 approvedAmount
    ) 
        external 
        onlyBroker 
    {
        require(brokerRequestId != bytes32(0), "Invalid request ID");
        require(approvedAmount > 0, "Approved amount must be positive");
        
        uint256 positionId = requestIdToPosition[brokerRequestId];
        require(positionId != 0, "Invalid broker request ID");
        
        UserPosition storage position = positions[positionId];
        require(position.state == PositionState.Pending, "Position not pending");
        
        // Update position with broker approval
        PositionState oldState = position.state;
        position.state = PositionState.Approved;
        position.approvedAmount = approvedAmount;
        position.executionDeadline = block.timestamp + BROKER_TIMEOUT; // Time to execute
        
        emit PositionStateChanged(positionId, oldState, PositionState.Approved);
        emit PositionApproved(positionId, brokerRequestId, approvedAmount);
    }

    /**
     * @dev Handle broker rejection (Step 2: Broker rejects request)
     * @param brokerRequestId The broker's request ID  
     * @param reason Rejection reason
     */
    function handleBrokerRejection(
        bytes32 brokerRequestId,
        string calldata reason
    ) 
        external 
        onlyBroker 
    {
        require(brokerRequestId != bytes32(0), "Invalid request ID");
        require(bytes(reason).length > 0, "Reason cannot be empty");
        
        uint256 positionId = requestIdToPosition[brokerRequestId];
        require(positionId != 0, "Invalid broker request ID");
        
        UserPosition storage position = positions[positionId];
        require(position.state == PositionState.Pending, "Position not pending");
        
        // Update position state to rejected
        PositionState oldState = position.state;
        position.state = PositionState.Rejected;
        
        // Return deposited funds to user
        vaultConfig.depositToken.safeTransfer(position.user, position.depositAmount);
        
        emit PositionStateChanged(positionId, oldState, PositionState.Rejected);
        emit PositionRejected(positionId, brokerRequestId, reason);
    }

    /**
     * @dev Execute approved leverage position (Step 3: User executes after approval)
     * @param positionId The position to execute
     */
    function executeLeveragePosition(uint256 positionId) 
        external 
        nonReentrant 
        positionExists(positionId) 
        onlyPositionOwner(positionId)
        validPositionState(positionId, PositionState.Approved)
        positionNotExpired(positionId)
    {
        UserPosition storage position = positions[positionId];
        
        // The vault has user's deposit (10k USDC)
        // The broker approved giving us leverage funds (5k USDC) 
        // We need to get the leverage funds and invest the total amount
        
        // Get leverage funds from broker (broker provides the leverage)
        try vaultConfig.primeBroker.borrow(address(vaultConfig.depositToken), position.approvedAmount) {
            // Success - continue
        } catch {
            revert("Failed to borrow from prime broker");
        }
        
        // Now vault has: original deposit + leverage funds
        uint256 totalInvestAmount = position.depositAmount + position.approvedAmount;
        
        // Get expected fund tokens for slippage protection
        uint256 expectedFundTokens = _getExpectedFundTokens(totalInvestAmount);
        uint256 minFundTokens = (expectedFundTokens * 9950) / 10000; // 0.5% slippage tolerance
        
        // Invest in fund with slippage protection
        vaultConfig.depositToken.approve(vaultConfig.fundToken, totalInvestAmount);
        uint256 fundTokensReceived;
        try IERC3643Fund(vaultConfig.fundToken).invest(totalInvestAmount) returns (uint256 tokens) {
            fundTokensReceived = tokens;
            require(fundTokensReceived >= minFundTokens, "Slippage: insufficient fund tokens received");
        } catch {
            revert("Failed to invest in fund");
        }
        
        // Supply fund tokens as collateral to Morpho Blue
        IERC20(vaultConfig.fundToken).approve(address(vaultConfig.morpho), fundTokensReceived);
        try vaultConfig.morpho.supplyCollateral(vaultConfig.morphoMarket, fundTokensReceived, address(this), "") {
            // Success - continue
        } catch {
            revert("Failed to supply collateral to Morpho");
        }
        
        // Borrow USDC from Morpho against the collateral
        uint256 borrowAmount = position.approvedAmount;
        try vaultConfig.morpho.borrow(vaultConfig.morphoMarket, borrowAmount, 0, address(this), address(this)) {
            // Success - continue
        } catch {
            revert("Failed to borrow from Morpho");
        }
        
        // Immediately repay Prime Broker to achieve zero debt (per spec requirement)
        vaultConfig.depositToken.approve(address(vaultConfig.primeBroker), borrowAmount);
        try vaultConfig.primeBroker.repay(address(vaultConfig.depositToken), borrowAmount) {
            // Success - continue
        } catch {
            revert("Failed to repay prime broker");
        }
        
        // Mint synthetic tokens to user
        uint256 syntheticTokens = LeverageCalculator.calculateSyntheticTokens(fundTokensReceived, position.leverageRatio);
        try vaultConfig.syntheticToken.mint(position.user, syntheticTokens) {
            // Success - continue
        } catch {
            revert("Failed to mint synthetic tokens");
        }
        
        // Update position state
        PositionState oldState = position.state;
        position.state = PositionState.Executed;
        position.borrowedAmount = position.approvedAmount;
        position.fundTokensOwned = fundTokensReceived; // Track fund tokens, not Morpho shares
        position.syntheticTokensMinted = syntheticTokens;
        position.lockUntil = block.timestamp + vaultConfig.minLockPeriod;
        
        // Update vault totals
        totalValueLocked += totalInvestAmount;
        totalBorrowed += position.approvedAmount;
        
        emit PositionStateChanged(positionId, oldState, PositionState.Executed);
        emit PositionExecuted(positionId, position.user, fundTokensReceived, syntheticTokens);
    }

    /**
     * @dev Check and handle expired positions (called by anyone)
     * @param positionId The position to check for expiry
     */
    function checkPositionExpiry(uint256 positionId) 
        external 
        positionExists(positionId) 
    {
        UserPosition storage position = positions[positionId];
        
        if (position.state == PositionState.Approved && 
            block.timestamp > position.executionDeadline) {
            
            // Mark as expired and return funds
            PositionState oldState = position.state;
            position.state = PositionState.Expired;
            
            // Return deposited funds to user
            vaultConfig.depositToken.safeTransfer(position.user, position.depositAmount);
            
            emit PositionStateChanged(positionId, oldState, PositionState.Expired);
            emit PositionExpired(positionId, position.brokerRequestId);
        }
    }

    /**
     * @dev Close a leveraged position (Step 4: Complete the loan repayment cycle)
     * @param positionId The position to close
     */
    function closePosition(uint256 positionId) 
        external 
        nonReentrant 
        positionExists(positionId) 
        onlyPositionOwner(positionId)
        validPositionState(positionId, PositionState.Executed)
    {
        UserPosition storage position = positions[positionId];
        require(block.timestamp >= position.lockUntil, "Position still locked");
        
        // Burn synthetic tokens from user
        try vaultConfig.syntheticToken.burn(msg.sender, position.syntheticTokensMinted) {
            // Success - continue
        } catch {
            revert("Failed to burn synthetic tokens");
        }
        
        // First, withdraw some fund tokens from Morpho to get USDC for repayment
        uint256 repayAmount = position.borrowedAmount;
        uint256 fundTokensToRedeem = _calculateFundTokensToRedeem(position.fundTokensOwned, repayAmount);
        
        // Withdraw the fund tokens we need to redeem from Morpho
        try vaultConfig.morpho.withdrawCollateral(vaultConfig.morphoMarket, fundTokensToRedeem, address(this), address(this)) {
            // Success - continue
        } catch {
            revert("Failed to withdraw collateral from Morpho");
        }
        
        // Calculate minimum USDC expected for slippage protection
        uint256 expectedUSDC = _getExpectedUSDCFromFundTokens(fundTokensToRedeem);
        uint256 minUSDCFromRedeem = (expectedUSDC * 9950) / 10000; // 0.5% slippage tolerance
        
        // Redeem those fund tokens for USDC with slippage protection
        uint256 underlyingReceived;
        try IERC3643Fund(position.fundToken).redeem(fundTokensToRedeem) returns (uint256 amount) {
            underlyingReceived = amount;
            require(underlyingReceived >= minUSDCFromRedeem, "Slippage: insufficient USDC from redemption");
        } catch {
            revert("Failed to redeem fund tokens");
        }
        
        // Repay borrowed USDC to Morpho Blue
        vaultConfig.depositToken.approve(address(vaultConfig.morpho), repayAmount);
        try vaultConfig.morpho.repay(vaultConfig.morphoMarket, repayAmount, 0, address(this), "") {
            // Success - continue
        } catch {
            revert("Failed to repay Morpho loan");
        }
        
        // Withdraw remaining fund tokens from Morpho as collateral
        uint256 remainingCollateral = position.fundTokensOwned - fundTokensToRedeem;
        try vaultConfig.morpho.withdrawCollateral(vaultConfig.morphoMarket, remainingCollateral, address(this), address(this)) {
            // Success - continue
        } catch {
            revert("Failed to withdraw remaining collateral from Morpho");
        }
        
        // Calculate minimum USDC expected for remaining redemption
        uint256 expectedRemainingUSDC = _getExpectedUSDCFromFundTokens(remainingCollateral);
        uint256 minRemainingUSDC = (expectedRemainingUSDC * 9950) / 10000; // 0.5% slippage tolerance
        
        // Redeem remaining fund tokens for USDC with slippage protection
        uint256 remainingUSDC;
        try IERC3643Fund(position.fundToken).redeem(remainingCollateral) returns (uint256 amount) {
            remainingUSDC = amount;
            require(remainingUSDC >= minRemainingUSDC, "Slippage: insufficient USDC from final redemption");
        } catch {
            revert("Failed to redeem remaining fund tokens");
        }
        
        // Calculate total USDC available (remaining from repayment + remaining from collateral)
        uint256 totalUSDCAvailable = (underlyingReceived - repayAmount) + remainingUSDC;
        
        // Calculate P&L (profit/loss vs original deposit)
        uint256 pnl = totalUSDCAvailable > position.depositAmount ? 
            totalUSDCAvailable - position.depositAmount : 0;
        
        // Charge fees on profits
        uint256 fees = _calculateAndChargeFees(position, pnl);
        uint256 finalAmount = totalUSDCAvailable - fees;
        
        // Return funds to user
        if (finalAmount > 0) {
            vaultConfig.depositToken.safeTransfer(msg.sender, finalAmount);
        }
        
        // Update position state to completed
        PositionState oldState = position.state;
        position.state = PositionState.Completed;
        
        // Update vault totals
        totalValueLocked -= (position.depositAmount + position.borrowedAmount);
        totalBorrowed -= position.borrowedAmount;
        
        emit PositionStateChanged(positionId, oldState, PositionState.Completed);
        emit PositionClosed(positionId, msg.sender, finalAmount, pnl);
    }

    /**
     * @dev Update vault configuration (only owner)
     * @param newConfig New vault configuration
     */
    function updateVaultConfig(VaultConfig memory newConfig) external onlyOwner {
        require(address(newConfig.depositToken) != address(0), "Deposit token cannot be zero address");
        require(address(newConfig.primeBroker) != address(0), "Prime broker cannot be zero address");
        require(address(newConfig.morpho) != address(0), "Morpho cannot be zero address");
        require(address(newConfig.syntheticToken) != address(0), "Synthetic token cannot be zero address");
        require(newConfig.fundToken != address(0), "Fund token cannot be zero address");
        require(newConfig.feeRecipient != address(0), "Fee recipient cannot be zero address");
        require(newConfig.maxLeverage >= MIN_LEVERAGE && newConfig.maxLeverage <= MAX_LEVERAGE, "Invalid max leverage");
        require(newConfig.managementFee <= BASIS_POINTS, "Management fee too high");
        require(newConfig.performanceFee <= BASIS_POINTS, "Performance fee too high");
        require(newConfig.minLockPeriod > 0, "Lock period must be positive");
        
        vaultConfig = newConfig;
        emit ConfigUpdated(newConfig);
    }

    // Internal helper functions

    function _getExpectedFundTokens(uint256 usdcAmount) internal view returns (uint256) {
        uint256 sharePrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();
        return (usdcAmount * 1e18) / sharePrice;
    }
    
    function _getExpectedUSDCFromFundTokens(uint256 fundTokens) internal view returns (uint256) {
        uint256 sharePrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();
        return (fundTokens * sharePrice) / 1e18;
    }

    function _calculateFundTokensToRedeem(uint256 totalFundTokens, uint256 usdcNeeded) internal view returns (uint256) {
        uint256 fundTokenPrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();
        uint256 fundTokensNeeded = (usdcNeeded * 1e18) / fundTokenPrice;
        
        // Add a small buffer (0.1%) to account for rounding and ensure we get enough USDC
        fundTokensNeeded = (fundTokensNeeded * 1001) / 1000;
        
        // Ensure we don't try to redeem more than we have
        return fundTokensNeeded > totalFundTokens ? totalFundTokens : fundTokensNeeded;
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

    // View functions
    function getPosition(uint256 positionId) external view returns (UserPosition memory) {
        return positions[positionId];
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    function getPositionValue(uint256 positionId) external view returns (uint256 currentValue, int256 pnl) {
        UserPosition memory position = positions[positionId];
        if (position.state != PositionState.Executed) return (0, 0);
        
        // Get current fund token price
        uint256 currentPrice = IERC3643Fund(position.fundToken).getSharePrice();
        uint256 fundValue = (position.fundTokensOwned * currentPrice) / 1e18;
        
        currentValue = fundValue - position.borrowedAmount;
        pnl = int256(currentValue) - int256(position.depositAmount);
    }

    function getVaultTVL() external view returns (uint256) {
        return totalValueLocked;
    }

    function getVaultInfo() external view returns (VaultConfig memory, uint256, uint256) {
        return (vaultConfig, totalValueLocked, totalBorrowed);
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