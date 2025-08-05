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

// Custom errors for gas efficiency
error InvalidLeverageRatio();
error PositionNotFound();
error NotPositionOwner();
error OnlyFactoryCanCall();
error OnlyBrokerCanCall();
error InvalidPositionState();
error PositionApprovalExpired();
error InvalidAmount();
error InvalidSender();
error InsufficientBalance();
error InsufficientAllowance();
error InvalidRequestId();
error AmountMustBePositive();
error PositionNotPending();
error ReasonCannotBeEmpty();
error PositionStillLocked();
error InvalidZeroAddress();
error InvalidMaxLeverage();
error ManagementFeeTooHigh();
error PerformanceFeeTooHigh();
error LockPeriodMustBePositive();
error TransferFailed();

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
        Pending, // Waiting for broker approval
        Approved, // Broker approved, ready for execution
        Rejected, // Broker rejected, funds can be withdrawn
        Executed, // Position executed, earning yield
        Completed, // Position closed, loan repaid
        Expired // Broker didn't respond in time

    }

    // Minimal position storage - only essential data
    struct Position {
        // Slot 1 (32 bytes) - Core position data
        uint128 depositAmount; // Original deposit (sufficient for most amounts)
        uint64 createdAt; // Creation timestamp (replaces multiple timestamps)
        uint32 lockDuration; // Lock period in seconds (not absolute timestamp)
        uint16 leverageRatio; // 150 = 1.5x, 300 = 3x, etc.
        uint8 state; // PositionState enum
        uint8 flags; // Bit flags for various boolean states
        
        // Slot 2 (32 bytes) - User and amounts
        address user; // 20 bytes - Position owner
        uint96 executionData; // 12 bytes - packed execution amounts when needed
    }
    
    // Extended position data - only stored when position is executed
    struct ExecutedPositionData {
        uint256 syntheticTokensMinted;
        uint256 fundTokensOwned; 
        uint256 borrowedAmount;
        bytes32 brokerRequestId;
    }

    // Vault configuration - optimized struct packing
    struct VaultConfig {
        // Slot 1 (32 bytes)
        IERC20 depositToken; // 20 bytes - USDC, USDT, etc.
        uint16 managementFee; // 2 bytes - Annual fee in basis points (max 65535)
        uint16 performanceFee; // 2 bytes - Performance fee in basis points (max 65535) 
        uint16 maxLeverage; // 2 bytes - Maximum allowed leverage (max 65535)
        uint64 minLockPeriod; // 8 bytes - Minimum lock period in seconds
        // Slot 2 (32 bytes)
        IPrimeBroker primeBroker; // 20 bytes - Lending protocol for leverage
        uint96 _reserved1; // 12 bytes - reserved for future use
        // Slot 3 (32 bytes)
        IMorpho morpho; // 20 bytes - Morpho Blue for collateral
        uint96 _reserved2; // 12 bytes - reserved for future use
        // Slot 4 (32 bytes)
        IERC3643 syntheticToken; // 20 bytes - ERC3643 synthetic token contract
        uint96 _reserved3; // 12 bytes - reserved for future use
        // Slot 5 (32 bytes)
        address fundToken; // 20 bytes - The specific ERC3643 fund this vault targets
        uint96 _reserved4; // 12 bytes - reserved for future use  
        // Slot 6 (32 bytes)
        address feeRecipient; // 20 bytes - Where fees go
        uint96 _reserved5; // 12 bytes - reserved for future use
        // Slot 7 (32 bytes)
        MarketParams morphoMarket; // 32 bytes - Morpho Blue market parameters
        // Slot 8+ (dynamic)
        string vaultName; // Vault name for identification
        // Slot 9+ (dynamic)
        string vaultSymbol; // Vault symbol
    }

    // State variables
    VaultConfig public vaultConfig;
    address public immutable factory; // Factory that deployed this vault
    uint256 public nextPositionId = 1;
    uint256 public totalValueLocked;
    uint256 public totalBorrowed;

    // Mappings - dramatically reduced
    mapping(uint256 => Position) public positions;
    mapping(uint256 => ExecutedPositionData) public executedPositions; // Only for executed positions
    mapping(address => uint256[]) public userPositions;
    
    // Single broker mapping - eliminate redundancy
    mapping(bytes32 => uint256) public brokerRequestToPosition;

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
        uint256 indexed positionId, bytes32 indexed brokerRequestId, uint256 approvedAmount
    );

    event PositionRejected(
        uint256 indexed positionId, bytes32 indexed brokerRequestId, string reason
    );

    event PositionExecuted(
        uint256 indexed positionId,
        address indexed user,
        uint256 fundTokensReceived,
        uint256 syntheticTokensMinted
    );

    event PositionClosed(
        uint256 indexed positionId, address indexed user, uint256 amountReturned, uint256 pnl
    );

    event PositionStateChanged(
        uint256 indexed positionId, PositionState oldState, PositionState newState
    );

    event PositionExpired(uint256 indexed positionId, bytes32 indexed brokerRequestId);

    event ConfigUpdated(VaultConfig newConfig);

    // Modifiers
    modifier validLeverage(uint16 leverageRatio) {
        if (leverageRatio < MIN_LEVERAGE || leverageRatio > vaultConfig.maxLeverage || leverageRatio % 50 != 0) {
            revert InvalidLeverageRatio();
        }
        _;
    }

    modifier positionExists(uint256 positionId) {
        if (positions[positionId].user == address(0)) {
            revert PositionNotFound();
        }
        _;
    }

    modifier onlyPositionOwner(uint256 positionId) {
        if (positions[positionId].user != msg.sender) {
            revert NotPositionOwner();
        }
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactoryCanCall();
        }
        _;
    }

    modifier onlyBroker() {
        if (msg.sender != address(vaultConfig.primeBroker)) {
            revert OnlyBrokerCanCall();
        }
        _;
    }

    modifier validPositionState(uint256 positionId, PositionState expectedState) {
        if (positions[positionId].state != uint8(expectedState)) {
            revert InvalidPositionState();
        }
        _;
    }

    modifier positionNotExpired(uint256 positionId) {
        Position memory position = positions[positionId];
        if (position.state == uint8(PositionState.Approved)) {
            uint256 executionDeadline = position.createdAt + BROKER_TIMEOUT;
            if (block.timestamp > executionDeadline) {
                revert PositionApprovalExpired();
            }
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
        if (_owner == address(0)) revert InvalidZeroAddress();
        if (address(_config.depositToken) == address(0)) revert InvalidZeroAddress();
        if (address(_config.primeBroker) == address(0)) revert InvalidZeroAddress();
        if (address(_config.morpho) == address(0)) revert InvalidZeroAddress();
        if (address(_config.syntheticToken) == address(0)) revert InvalidZeroAddress();
        if (_config.fundToken == address(0)) revert InvalidZeroAddress();
        if (_config.feeRecipient == address(0)) revert InvalidZeroAddress();
        if (_config.maxLeverage < MIN_LEVERAGE || _config.maxLeverage > MAX_LEVERAGE) {
            revert InvalidMaxLeverage();
        }
        if (_config.managementFee > BASIS_POINTS) revert ManagementFeeTooHigh();
        if (_config.performanceFee > BASIS_POINTS) revert PerformanceFeeTooHigh();
        if (_config.minLockPeriod == 0) revert LockPeriodMustBePositive();

        vaultConfig = _config;
        _transferOwnership(_owner);
    }

    /**
     * @dev Request a new leveraged position (Step 1: Submit to broker)
     * @param amount Amount of deposit token to invest
     * @param leverageRatio Desired leverage (150 = 1.5x, 300 = 3x, etc.)
     * @return positionId The ID of the newly created position (in Pending state)
     */
    function requestLeveragePosition(uint256 amount, uint16 leverageRatio)
        external
        nonReentrant
        whenNotPaused
        validLeverage(leverageRatio)
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (amount > type(uint128).max) revert InvalidAmount(); // Ensure fits in uint128

        // Check user has sufficient balance
        if (vaultConfig.depositToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (vaultConfig.depositToken.allowance(msg.sender, address(this)) < amount) {
            revert InsufficientAllowance();
        }

        // Transfer deposit from user (held in vault until broker approval)
        vaultConfig.depositToken.safeTransferFrom(msg.sender, address(this), amount);

        // Submit request to broker first
        uint256 requestedLeverageAmount = LeverageCalculator.calculateBorrowAmount(amount, leverageRatio);
        bytes32 brokerRequestId = vaultConfig.primeBroker.requestLeverage(
            msg.sender,
            address(vaultConfig.depositToken),
            amount,
            requestedLeverageAmount,
            leverageRatio
        );

        // MINIMAL STORAGE WRITES - Only 3 storage operations total!
        positionId = nextPositionId;
        unchecked {
            nextPositionId++; // SSTORE 1
        }
        
        // Store minimal position data - only 2 storage slots
        positions[positionId] = Position({
            depositAmount: uint128(amount),
            createdAt: uint64(block.timestamp),
            lockDuration: uint32(vaultConfig.minLockPeriod),
            leverageRatio: leverageRatio,
            state: uint8(PositionState.Pending),
            flags: 0,
            user: msg.sender,
            executionData: 0 // Will be set later if needed
        }); // SSTORE 2 (2 slots)

        brokerRequestToPosition[brokerRequestId] = positionId; // SSTORE 3
        
        // Add to user positions for tracking (only if needed)
        userPositions[msg.sender].push(positionId); // SSTORE 4 - but only grows array
        
        // Use events for historical tracking instead of storage
        emit PositionRequested(positionId, msg.sender, brokerRequestId, amount, leverageRatio, requestedLeverageAmount);
    }

    /**
     * @dev Handle broker approval (Step 2: Broker approves request)
     * @param brokerRequestId The broker's request ID
     * @param approvedAmount Amount approved by broker (may differ from requested)
     */
    function handleBrokerApproval(bytes32 brokerRequestId, uint256 approvedAmount)
        external
        onlyBroker
    {
        if (brokerRequestId == bytes32(0)) revert InvalidRequestId();
        if (approvedAmount == 0) revert AmountMustBePositive();

        uint256 positionId = brokerRequestToPosition[brokerRequestId];
        if (positionId == 0) revert InvalidRequestId();

        Position storage position = positions[positionId];
        if (position.state != uint8(PositionState.Pending)) revert PositionNotPending();

        // Update position state only - store approved amount in executionData
        uint8 oldState = position.state;
        position.state = uint8(PositionState.Approved);
        
        // Pack approved amount into executionData (12 bytes = 96 bits, enough for amounts)
        if (approvedAmount <= type(uint96).max) {
            position.executionData = uint96(approvedAmount);
        } else {
            revert InvalidAmount(); // Amount too large for packed storage
        }
        
        // No need to store execution deadline - use block.timestamp + BROKER_TIMEOUT in view functions

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Approved);
        emit PositionApproved(positionId, brokerRequestId, approvedAmount);
    }

    /**
     * @dev Handle broker rejection (Step 2: Broker rejects request)
     * @param brokerRequestId The broker's request ID
     * @param reason Rejection reason
     */
    function handleBrokerRejection(bytes32 brokerRequestId, string calldata reason)
        external
        onlyBroker
    {
        if (brokerRequestId == bytes32(0)) revert InvalidRequestId();
        if (bytes(reason).length == 0) revert ReasonCannotBeEmpty();

        uint256 positionId = brokerRequestToPosition[brokerRequestId];
        if (positionId == 0) revert InvalidRequestId();

        Position storage position = positions[positionId];
        if (position.state != uint8(PositionState.Pending)) revert PositionNotPending();

        // Update position state to rejected
        uint8 oldState = position.state;
        position.state = uint8(PositionState.Rejected);

        // Return deposited funds to user
        vaultConfig.depositToken.safeTransfer(position.user, position.depositAmount);

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Rejected);
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
        Position storage position = positions[positionId];
        
        // Cache frequently accessed storage variables
        VaultConfig memory config = vaultConfig;
        uint256 approvedAmount = position.executionData; // Get approved amount from packed data
        uint256 depositAmount = position.depositAmount;

        // Get leverage funds from broker (broker provides the leverage)
        try config.primeBroker.borrow(address(config.depositToken), approvedAmount) {
            // Success - continue
        } catch {
            revert("Failed to borrow from prime broker");
        }

        // Now vault has: original deposit + leverage funds
        uint256 totalInvestAmount;
        unchecked {
            totalInvestAmount = depositAmount + approvedAmount;
        }

        // Get expected fund tokens for slippage protection
        uint256 expectedFundTokens = _getExpectedFundTokens(totalInvestAmount);
        uint256 minFundTokens = (expectedFundTokens * 9950) / 10000; // 0.5% slippage tolerance

        // Invest in fund with slippage protection
        config.depositToken.approve(config.fundToken, totalInvestAmount);
        uint256 fundTokensReceived;
        try IERC3643Fund(config.fundToken).invest(totalInvestAmount) returns (uint256 tokens) {
            fundTokensReceived = tokens;
            require(
                fundTokensReceived >= minFundTokens, "Slippage: insufficient fund tokens received"
            );
        } catch {
            revert("Failed to invest in fund");
        }

        // Supply fund tokens as collateral to Morpho Blue
        IERC20(config.fundToken).approve(address(config.morpho), fundTokensReceived);
        try config.morpho.supplyCollateral(config.morphoMarket, fundTokensReceived, address(this), "") {
            // Success - continue
        } catch {
            revert("Failed to supply collateral to Morpho");
        }

        // Borrow USDC from Morpho against the collateral
        try config.morpho.borrow(config.morphoMarket, approvedAmount, 0, address(this), address(this)) {
            // Success - continue
        } catch {
            revert("Failed to borrow from Morpho");
        }

        // Immediately repay Prime Broker to achieve zero debt (per spec requirement)
        config.depositToken.approve(address(config.primeBroker), approvedAmount);
        try config.primeBroker.repay(address(config.depositToken), approvedAmount) {
            // Success - continue
        } catch {
            revert("Failed to repay prime broker");
        }

        // Mint synthetic tokens to user
        uint256 syntheticTokens = LeverageCalculator.calculateSyntheticTokens(fundTokensReceived, position.leverageRatio);
        try config.syntheticToken.mint(position.user, syntheticTokens) {
            // Success - continue
        } catch {
            revert("Failed to mint synthetic tokens");
        }

        // MINIMAL STORAGE WRITES - Only update essential data
        uint8 oldState = position.state;
        position.state = uint8(PositionState.Executed); // Update state in existing slot
        
        // Store execution data separately - only when executed
        executedPositions[positionId] = ExecutedPositionData({
            syntheticTokensMinted: syntheticTokens,
            fundTokensOwned: fundTokensReceived,
            borrowedAmount: approvedAmount,
            brokerRequestId: bytes32(0) // Can be retrieved from events if needed
        }); // This is 4 storage slots, but only stored once at execution

        // Update vault totals
        unchecked {
            totalValueLocked += totalInvestAmount;
            totalBorrowed += approvedAmount;
        }

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Executed);
        emit PositionExecuted(positionId, position.user, fundTokensReceived, syntheticTokens);
    }

    /**
     * @dev Check and handle expired positions (called by anyone)
     * @param positionId The position to check for expiry
     */
    function checkPositionExpiry(uint256 positionId) external positionExists(positionId) {
        Position storage position = positions[positionId];
        
        // Calculate execution deadline dynamically instead of storing it
        uint8 currentState = position.state;
        if (currentState == uint8(PositionState.Approved)) {
            uint256 executionDeadline = position.createdAt + BROKER_TIMEOUT;
            
            if (block.timestamp > executionDeadline) {
                // Mark as expired and return funds
                position.state = uint8(PositionState.Expired);

                // Return deposited funds to user
                vaultConfig.depositToken.safeTransfer(position.user, position.depositAmount);

                emit PositionStateChanged(positionId, PositionState(currentState), PositionState.Expired);
                emit PositionExpired(positionId, bytes32(positionId)); // Use positionId as identifier
            }
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
        Position storage position = positions[positionId];
        ExecutedPositionData memory executedData = executedPositions[positionId];
        
        // Calculate lock expiry dynamically
        uint256 lockUntil = position.createdAt + position.lockDuration;
        if (block.timestamp < lockUntil) revert PositionStillLocked();
        
        // Cache frequently accessed storage variables
        VaultConfig memory config = vaultConfig;

        // Burn synthetic tokens from user
        try config.syntheticToken.burn(msg.sender, executedData.syntheticTokensMinted) {
            // Success - continue
        } catch {
            revert("Failed to burn synthetic tokens");
        }

        // First, withdraw some fund tokens from Morpho to get USDC for repayment
        uint256 repayAmount = executedData.borrowedAmount;
        uint256 fundTokensToRedeem =
            _calculateFundTokensToRedeem(executedData.fundTokensOwned, repayAmount);

        // Withdraw the fund tokens we need to redeem from Morpho
        try config.morpho.withdrawCollateral(
            config.morphoMarket, fundTokensToRedeem, address(this), address(this)
        ) {
            // Success - continue
        } catch {
            revert("Failed to withdraw collateral from Morpho");
        }

        // Calculate minimum USDC expected for slippage protection
        uint256 expectedUSDC = _getExpectedUSDCFromFundTokens(fundTokensToRedeem);
        uint256 minUSDCFromRedeem = (expectedUSDC * 9950) / 10000; // 0.5% slippage tolerance

        // Redeem those fund tokens for USDC with slippage protection
        uint256 underlyingReceived;
        try IERC3643Fund(config.fundToken).redeem(fundTokensToRedeem) returns (uint256 amount) {
            underlyingReceived = amount;
            require(
                underlyingReceived >= minUSDCFromRedeem,
                "Slippage: insufficient USDC from redemption"
            );
        } catch {
            revert("Failed to redeem fund tokens");
        }

        // Repay borrowed USDC to Morpho Blue
        config.depositToken.approve(address(config.morpho), repayAmount);
        try config.morpho.repay(config.morphoMarket, repayAmount, 0, address(this), "") {
            // Success - continue
        } catch {
            revert("Failed to repay Morpho loan");
        }

        // Withdraw remaining fund tokens from Morpho as collateral
        uint256 remainingCollateral = executedData.fundTokensOwned - fundTokensToRedeem;
        try config.morpho.withdrawCollateral(
            config.morphoMarket, remainingCollateral, address(this), address(this)
        ) {
            // Success - continue
        } catch {
            revert("Failed to withdraw remaining collateral from Morpho");
        }

        // Calculate minimum USDC expected for remaining redemption
        uint256 expectedRemainingUSDC = _getExpectedUSDCFromFundTokens(remainingCollateral);
        uint256 minRemainingUSDC = (expectedRemainingUSDC * 9950) / 10000; // 0.5% slippage tolerance

        // Redeem remaining fund tokens for USDC with slippage protection
        uint256 remainingUSDC;
        try IERC3643Fund(config.fundToken).redeem(remainingCollateral) returns (uint256 amount) {
            remainingUSDC = amount;
            require(
                remainingUSDC >= minRemainingUSDC,
                "Slippage: insufficient USDC from final redemption"
            );
        } catch {
            revert("Failed to redeem remaining fund tokens");
        }

        // Calculate total USDC available (remaining from repayment + remaining from collateral)
        uint256 totalUSDCAvailable;
        unchecked {
            totalUSDCAvailable = (underlyingReceived - repayAmount) + remainingUSDC;
        }

        // Calculate P&L (profit/loss vs original deposit)
        uint256 pnl = totalUSDCAvailable > position.depositAmount
            ? totalUSDCAvailable - position.depositAmount
            : 0;

        // Charge fees on profits
        uint256 fees = _calculateAndChargeFees(position, executedData, pnl, config);
        uint256 finalAmount = totalUSDCAvailable - fees;

        // Return funds to user
        if (finalAmount > 0) {
            config.depositToken.safeTransfer(msg.sender, finalAmount);
        }

        // Update position state to completed
        uint8 oldState = position.state;
        position.state = uint8(PositionState.Completed);

        // Update vault totals
        unchecked {
            totalValueLocked -= (position.depositAmount + executedData.borrowedAmount);
            totalBorrowed -= executedData.borrowedAmount;
        }
        
        // Clean up executed position data
        delete executedPositions[positionId];

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Completed);
        emit PositionClosed(positionId, msg.sender, finalAmount, pnl);
    }

    /**
     * @dev Update vault configuration (only owner)
     * @param newConfig New vault configuration
     */
    function updateVaultConfig(VaultConfig memory newConfig) external onlyOwner {
        if (address(newConfig.depositToken) == address(0)) revert InvalidZeroAddress();
        if (address(newConfig.primeBroker) == address(0)) revert InvalidZeroAddress();
        if (address(newConfig.morpho) == address(0)) revert InvalidZeroAddress();
        if (address(newConfig.syntheticToken) == address(0)) revert InvalidZeroAddress();
        if (newConfig.fundToken == address(0)) revert InvalidZeroAddress();
        if (newConfig.feeRecipient == address(0)) revert InvalidZeroAddress();
        if (newConfig.maxLeverage < MIN_LEVERAGE || newConfig.maxLeverage > MAX_LEVERAGE) {
            revert InvalidMaxLeverage();
        }
        if (newConfig.managementFee > BASIS_POINTS) revert ManagementFeeTooHigh();
        if (newConfig.performanceFee > BASIS_POINTS) revert PerformanceFeeTooHigh();
        if (newConfig.minLockPeriod == 0) revert LockPeriodMustBePositive();

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

    function _calculateFundTokensToRedeem(uint256 totalFundTokens, uint256 usdcNeeded)
        internal
        view
        returns (uint256)
    {
        uint256 fundTokenPrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();
        uint256 fundTokensNeeded = (usdcNeeded * 1e18) / fundTokenPrice;

        // Add a small buffer (0.1%) to account for rounding and ensure we get enough USDC
        fundTokensNeeded = (fundTokensNeeded * 1001) / 1000;

        // Ensure we don't try to redeem more than we have
        return fundTokensNeeded > totalFundTokens ? totalFundTokens : fundTokensNeeded;
    }

    function _calculateAndChargeFees(Position memory position, ExecutedPositionData memory executedData, uint256 pnl, VaultConfig memory config)
        internal
        returns (uint256 totalFees)
    {
        uint256 managementFee = 0;
        uint256 performanceFee = 0;

        // Calculate management fee (time-based)
        uint256 timeHeld = block.timestamp - position.createdAt;
        managementFee = LeverageCalculator.calculateManagementFee(
            position.depositAmount, config.managementFee, timeHeld
        );

        // Calculate performance fee (profit-based)
        if (pnl > 0) {
            performanceFee =
                LeverageCalculator.calculatePerformanceFee(pnl, config.performanceFee);
        }

        unchecked {
            totalFees = managementFee + performanceFee;
        }

        // Transfer fees to recipient
        if (totalFees > 0) {
            config.depositToken.safeTransfer(config.feeRecipient, totalFees);
        }

        return totalFees;
    }

    // View functions
    function getPosition(uint256 positionId) external view returns (Position memory position, ExecutedPositionData memory executedData) {
        position = positions[positionId];
        if (position.state == uint8(PositionState.Executed)) {
            executedData = executedPositions[positionId];
        }
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    function getPositionValue(uint256 positionId)
        external
        view
        returns (uint256 currentValue, int256 pnl)
    {
        Position memory position = positions[positionId];
        if (position.state != uint8(PositionState.Executed)) return (0, 0);

        ExecutedPositionData memory executedData = executedPositions[positionId];
        
        // Get current fund token price
        uint256 currentPrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();
        uint256 fundValue = (executedData.fundTokensOwned * currentPrice) / 1e18;

        currentValue = fundValue - executedData.borrowedAmount;
        pnl = int256(currentValue) - int256(uint256(position.depositAmount));
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
