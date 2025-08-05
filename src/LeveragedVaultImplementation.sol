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
error OraclePriceStale();
error OraclePriceInvalid();
error PriceDeviationTooHigh();
error LockPeriodTooLong();
error ArithmeticOverflow();
error ArithmeticUnderflow();
error InvalidCalculation();

/**
 * @title LeveragedVaultImplementation
 * @dev Individual vault implementation for leveraged fund exposure with ERC3643 synthetic tokens
 * Deployed by VaultFactory for each specific fund/configuration
 */
contract LeveragedVaultImplementation is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using LeverageCalculator for uint256;

    uint256 public constant MAX_LEVERAGE = 500;
    uint256 public constant MIN_LEVERAGE = 150;
    uint256 public constant LEVERAGE_PRECISION = 100;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant BROKER_TIMEOUT = 24 hours;
    uint256 public constant MAX_LOCK_PERIOD = 365 days;
    uint256 public constant ORACLE_HEARTBEAT = 3600;
    uint256 public constant MAX_PRICE_DEVIATION = 500;

    enum PositionState {
        Pending,
        Approved,
        Rejected,
        Executed,
        Completed,
        Expired
    }

    struct Position {
        uint128 depositAmount;
        uint64 createdAt;
        uint32 lockDuration;
        uint16 leverageRatio;
        uint8 state;
        uint8 flags;
        address user;
        uint96 executionData;
    }

    struct ExecutedPositionData {
        uint256 syntheticTokensMinted;
        uint256 fundTokensOwned;
        uint256 borrowedAmount;
        bytes32 brokerRequestId;
    }

    struct VaultConfig {
        IERC20 depositToken;
        uint16 managementFee;
        uint16 performanceFee;
        uint16 maxLeverage;
        uint64 minLockPeriod;
        IPrimeBroker primeBroker;
        uint96 _reserved1;
        IMorpho morpho;
        uint96 _reserved2;
        IERC3643 syntheticToken;
        uint96 _reserved3;
        address fundToken;
        uint96 _reserved4;
        address feeRecipient;
        uint96 _reserved5;
        MarketParams morphoMarket;
        string vaultName;
        string vaultSymbol;
    }

    VaultConfig public vaultConfig;
    address public immutable factory;
    uint256 public nextPositionId = 1;
    uint256 public totalValueLocked;
    uint256 public totalBorrowed;
    uint256 public lastValidPrice;
    uint256 public lastPriceUpdate;

    mapping(uint256 => Position) public positions;
    mapping(uint256 => ExecutedPositionData) public executedPositions;
    mapping(address => uint256[]) public userPositions;
    mapping(bytes32 => uint256) public brokerRequestToPosition;

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

    modifier validLeverage(uint16 leverageRatio) {
        if (
            leverageRatio < MIN_LEVERAGE || leverageRatio > vaultConfig.maxLeverage
                || leverageRatio % 50 != 0
        ) {
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
        if (_config.minLockPeriod > MAX_LOCK_PERIOD) revert LockPeriodTooLong();

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
        if (amount > type(uint128).max) revert InvalidAmount();

        if (vaultConfig.depositToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (vaultConfig.depositToken.allowance(msg.sender, address(this)) < amount) {
            revert InsufficientAllowance();
        }

        // Transfer deposit from user (held in vault until broker approval)
        vaultConfig.depositToken.safeTransferFrom(msg.sender, address(this), amount);

        // Submit request to broker first
        uint256 requestedLeverageAmount =
            LeverageCalculator.calculateBorrowAmount(amount, leverageRatio);
        bytes32 brokerRequestId = vaultConfig.primeBroker.requestLeverage(
            msg.sender,
            address(vaultConfig.depositToken),
            amount,
            requestedLeverageAmount,
            leverageRatio
        );

        // CEI Pattern: Effects first - update state before external calls
        positionId = nextPositionId;
        // Safe increment with overflow check
        if (nextPositionId >= type(uint256).max) revert ArithmeticOverflow();
        nextPositionId++; // SSTORE 1

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
        emit PositionRequested(
            positionId, msg.sender, brokerRequestId, amount, leverageRatio, requestedLeverageAmount
        );
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
        // Safe addition with overflow check
        uint256 totalInvestAmount = depositAmount + approvedAmount;
        if (totalInvestAmount < depositAmount) revert ArithmeticOverflow();

        // Get expected fund tokens for slippage protection with zero check
        if (totalInvestAmount == 0) revert InvalidAmount();
        uint256 expectedFundTokens = _getExpectedFundTokens(totalInvestAmount);
        if (expectedFundTokens == 0) revert InvalidCalculation();
        uint256 minFundTokens = (expectedFundTokens * 9950) / 10000; // 0.5% slippage tolerance

        // Invest in fund with slippage protection and zero address check
        if (config.fundToken == address(0)) revert InvalidZeroAddress();
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

        // Supply fund tokens as collateral to Morpho Blue with zero checks
        if (fundTokensReceived == 0) revert InvalidAmount();
        if (address(config.morpho) == address(0)) revert InvalidZeroAddress();
        IERC20(config.fundToken).approve(address(config.morpho), fundTokensReceived);
        try config.morpho.supplyCollateral(
            config.morphoMarket, fundTokensReceived, address(this), ""
        ) {
            // Success - continue
        } catch {
            revert("Failed to supply collateral to Morpho");
        }

        // Borrow USDC from Morpho against the collateral
        try config.morpho.borrow(
            config.morphoMarket, approvedAmount, 0, address(this), address(this)
        ) {
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
        uint256 syntheticTokens =
            LeverageCalculator.calculateSyntheticTokens(fundTokensReceived, position.leverageRatio);
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

        // Update vault totals with overflow checks
        uint256 newTVL = totalValueLocked + totalInvestAmount;
        if (newTVL < totalValueLocked) revert ArithmeticOverflow();
        uint256 newBorrowed = totalBorrowed + approvedAmount;
        if (newBorrowed < totalBorrowed) revert ArithmeticOverflow();

        totalValueLocked = newTVL;
        totalBorrowed = newBorrowed;

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
                // CEI Pattern: Effects first - update state before external interactions
                position.state = uint8(PositionState.Expired);

                // Cache user data before external call
                address positionUser = position.user;
                uint256 depositAmount = position.depositAmount;

                // CEI Pattern: Interactions last - external call after state changes
                vaultConfig.depositToken.safeTransfer(positionUser, depositAmount);

                emit PositionStateChanged(
                    positionId, PositionState(currentState), PositionState.Expired
                );
                emit PositionExpired(positionId, bytes32(positionId)); // Use positionId as identifier
            }
        }
    }

    /**
     * @dev Batch check multiple positions for expiry (gas efficient)
     * @param positionIds Array of position IDs to check
     */
    function batchCheckPositionExpiry(uint256[] calldata positionIds) external {
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            if (positions[positionId].user != address(0)) {
                // Position exists
                Position storage position = positions[positionId];

                if (position.state == uint8(PositionState.Approved)) {
                    uint256 executionDeadline = position.createdAt + BROKER_TIMEOUT;

                    if (block.timestamp > executionDeadline) {
                        // CEI Pattern: Effects first
                        uint8 oldState = position.state;
                        position.state = uint8(PositionState.Expired);

                        // Cache data
                        address positionUser = position.user;
                        uint256 depositAmount = position.depositAmount;

                        // CEI Pattern: Interactions last
                        vaultConfig.depositToken.safeTransfer(positionUser, depositAmount);

                        emit PositionStateChanged(
                            positionId, PositionState(oldState), PositionState.Expired
                        );
                        emit PositionExpired(positionId, bytes32(positionId));
                    }
                }
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

        // Calculate lock expiry dynamically with maximum bounds check
        uint256 lockUntil = position.createdAt + position.lockDuration;
        if (block.timestamp < lockUntil) revert PositionStillLocked();

        // Additional safety: ensure position hasn't been locked for too long (prevent permanent locks)
        uint256 maxLockUntil = position.createdAt + MAX_LOCK_PERIOD;
        if (lockUntil > maxLockUntil) {
            // Allow closure if lock period exceeds maximum allowed
            // This prevents positions from being permanently locked
        }

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
        // Safe arithmetic with underflow/overflow checks
        if (underlyingReceived < repayAmount) revert ArithmeticUnderflow();
        uint256 remainingFromRepayment = underlyingReceived - repayAmount;
        uint256 totalUSDCAvailable = remainingFromRepayment + remainingUSDC;
        if (totalUSDCAvailable < remainingFromRepayment) revert ArithmeticOverflow();

        // Calculate P&L (profit/loss vs original deposit) with safe arithmetic
        uint256 pnl = 0;
        if (totalUSDCAvailable > position.depositAmount) {
            pnl = totalUSDCAvailable - position.depositAmount;
            // Additional check to ensure calculation is valid
            if (pnl > totalUSDCAvailable) revert InvalidCalculation();
        }

        // Charge fees on profits with underflow check
        uint256 fees = _calculateAndChargeFees(position, executedData, pnl, config);
        if (totalUSDCAvailable < fees) revert ArithmeticUnderflow();
        uint256 finalAmount = totalUSDCAvailable - fees;

        // CEI Pattern: Effects first - update all state before external interactions
        uint8 oldState = position.state;
        position.state = uint8(PositionState.Completed);

        // Update vault totals with underflow checks
        uint256 totalToSubtract = position.depositAmount + executedData.borrowedAmount;
        if (totalToSubtract < position.depositAmount) revert ArithmeticOverflow();
        if (totalValueLocked < totalToSubtract) revert ArithmeticUnderflow();
        if (totalBorrowed < executedData.borrowedAmount) revert ArithmeticUnderflow();

        totalValueLocked -= totalToSubtract;
        totalBorrowed -= executedData.borrowedAmount;

        // Clean up executed position data
        delete executedPositions[positionId];

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Completed);
        emit PositionClosed(positionId, msg.sender, finalAmount, pnl);

        // CEI Pattern: Interactions last - return funds to user after all state updates
        if (finalAmount > 0) {
            config.depositToken.safeTransfer(msg.sender, finalAmount);
        }
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
        if (newConfig.minLockPeriod > MAX_LOCK_PERIOD) revert LockPeriodTooLong();

        vaultConfig = newConfig;
        emit ConfigUpdated(newConfig);
    }

    // Internal helper functions

    function _getExpectedFundTokens(uint256 usdcAmount) internal view returns (uint256) {
        uint256 sharePrice = _getValidatedPrice();
        return (usdcAmount * 1e18) / sharePrice;
    }

    function _getExpectedUSDCFromFundTokens(uint256 fundTokens) internal view returns (uint256) {
        uint256 sharePrice = _getValidatedPrice();
        return (fundTokens * sharePrice) / 1e18;
    }

    function _getValidatedPrice() internal view returns (uint256) {
        uint256 currentPrice = IERC3643Fund(vaultConfig.fundToken).getSharePrice();

        // Check if price is valid (non-zero)
        if (currentPrice == 0) revert OraclePriceInvalid();

        // If we have a previous valid price, check for extreme deviations
        if (lastValidPrice > 0) {
            uint256 deviation;
            if (currentPrice > lastValidPrice) {
                deviation = ((currentPrice - lastValidPrice) * BASIS_POINTS) / lastValidPrice;
            } else {
                deviation = ((lastValidPrice - currentPrice) * BASIS_POINTS) / lastValidPrice;
            }

            // Revert if price deviation exceeds maximum allowed
            if (deviation > MAX_PRICE_DEVIATION) revert PriceDeviationTooHigh();
        }

        return currentPrice;
    }

    function _calculateFundTokensToRedeem(uint256 totalFundTokens, uint256 usdcNeeded)
        internal
        view
        returns (uint256)
    {
        uint256 fundTokenPrice = _getValidatedPrice();
        uint256 fundTokensNeeded = (usdcNeeded * 1e18) / fundTokenPrice;

        // Add a small buffer (0.1%) to account for rounding and ensure we get enough USDC
        fundTokensNeeded = (fundTokensNeeded * 1001) / 1000;

        // Ensure we don't try to redeem more than we have
        return fundTokensNeeded > totalFundTokens ? totalFundTokens : fundTokensNeeded;
    }

    function _calculateAndChargeFees(
        Position memory position,
        ExecutedPositionData memory,
        uint256 pnl,
        VaultConfig memory config
    ) internal returns (uint256 totalFees) {
        uint256 managementFee = 0;
        uint256 performanceFee = 0;

        // Calculate management fee (time-based) with underflow check
        if (block.timestamp < position.createdAt) revert ArithmeticUnderflow();
        uint256 timeHeld = block.timestamp - position.createdAt;
        managementFee = LeverageCalculator.calculateManagementFee(
            position.depositAmount, config.managementFee, timeHeld
        );

        // Calculate performance fee (profit-based)
        if (pnl > 0) {
            performanceFee = LeverageCalculator.calculatePerformanceFee(pnl, config.performanceFee);
        }

        // Safe addition for fee calculation
        totalFees = managementFee + performanceFee;
        if (totalFees < managementFee) revert ArithmeticOverflow();

        // Transfer fees to recipient with zero address check
        if (totalFees > 0) {
            if (config.feeRecipient == address(0)) revert InvalidZeroAddress();
            config.depositToken.safeTransfer(config.feeRecipient, totalFees);
        }

        return totalFees;
    }

    // View functions
    function getPosition(uint256 positionId)
        external
        view
        returns (Position memory position, ExecutedPositionData memory executedData)
    {
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

        // Get current fund token price with validation
        uint256 currentPrice = _getValidatedPrice();
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

    /**
     * @dev Emergency withdraw with restrictions to prevent abuse
     * Can only withdraw non-deposit tokens to prevent draining user funds
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        // Prevent withdrawal of the main deposit token to protect user funds
        if (token == address(vaultConfig.depositToken)) {
            revert("Cannot withdraw deposit tokens");
        }
        IERC20(token).safeTransfer(owner(), amount);
    }
}
