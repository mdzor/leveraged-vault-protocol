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
    address public factory;
    uint256 public nextPositionId = 1;
    uint256 public totalValueLocked;
    uint256 public totalBorrowed;
    uint256 public lastValidPrice;
    uint256 public lastPriceUpdate;
    bool private _initialized;

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

    modifier onlyInitialized() {
        if (!_initialized) revert("Not initialized");
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

    constructor() Ownable(address(1)) {
        _initialized = true;
    }

    /**
     * @param _config Vault configuration
     * @param _owner Owner of the vault
     */
    function initialize(VaultConfig memory _config, address _owner) external {
        if (_initialized) revert("Already initialized");
        if (msg.sender == address(0)) revert InvalidZeroAddress();

        factory = msg.sender;
        _initialized = true;
        nextPositionId = 1;
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
     * @param amount Amount of deposit token to invest
     * @param leverageRatio Desired leverage (150 = 1.5x, 300 = 3x, etc.)
     * @return positionId The ID of the newly created position (in Pending state)
     */
    function requestLeveragePosition(uint256 amount, uint16 leverageRatio)
        external
        nonReentrant
        whenNotPaused
        onlyInitialized
        validLeverage(leverageRatio)
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (amount > type(uint128).max) revert InvalidAmount();

        if (vaultConfig.depositToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        if (vaultConfig.depositToken.allowance(msg.sender, address(this)) < amount) {
            revert InsufficientAllowance();
        }

        vaultConfig.depositToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 requestedLeverageAmount =
            LeverageCalculator.calculateBorrowAmount(amount, leverageRatio);
        bytes32 brokerRequestId = vaultConfig.primeBroker.requestLeverage(
            msg.sender,
            address(vaultConfig.depositToken),
            amount,
            requestedLeverageAmount,
            leverageRatio
        );

        positionId = nextPositionId;
        if (nextPositionId >= type(uint256).max) revert ArithmeticOverflow();
        nextPositionId++;

        positions[positionId] = Position({
            depositAmount: uint128(amount),
            createdAt: uint64(block.timestamp),
            lockDuration: uint32(vaultConfig.minLockPeriod),
            leverageRatio: leverageRatio,
            state: uint8(PositionState.Pending),
            flags: 0,
            user: msg.sender,
            executionData: 0
        });

        brokerRequestToPosition[brokerRequestId] = positionId;

        userPositions[msg.sender].push(positionId);

        emit PositionRequested(
            positionId, msg.sender, brokerRequestId, amount, leverageRatio, requestedLeverageAmount
        );
    }

    /**
     * @param brokerRequestId The broker's request ID
     * @param approvedAmount Amount approved by broker (may differ from requested)
     */
    function handleBrokerApproval(bytes32 brokerRequestId, uint256 approvedAmount)
        external
        onlyBroker
        onlyInitialized
    {
        if (brokerRequestId == bytes32(0)) revert InvalidRequestId();
        if (approvedAmount == 0) revert AmountMustBePositive();

        uint256 positionId = brokerRequestToPosition[brokerRequestId];
        if (positionId == 0) revert InvalidRequestId();

        Position storage position = positions[positionId];
        if (position.state != uint8(PositionState.Pending)) revert PositionNotPending();

        uint8 oldState = position.state;
        position.state = uint8(PositionState.Approved);

        if (approvedAmount <= type(uint96).max) {
            position.executionData = uint96(approvedAmount);
        } else {
            revert InvalidAmount();
        }

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Approved);
        emit PositionApproved(positionId, brokerRequestId, approvedAmount);
    }

    /**
     * @param brokerRequestId The broker's request ID
     * @param reason Rejection reason
     */
    function handleBrokerRejection(bytes32 brokerRequestId, string calldata reason)
        external
        onlyBroker
        onlyInitialized
    {
        if (brokerRequestId == bytes32(0)) revert InvalidRequestId();
        if (bytes(reason).length == 0) revert ReasonCannotBeEmpty();

        uint256 positionId = brokerRequestToPosition[brokerRequestId];
        if (positionId == 0) revert InvalidRequestId();

        Position storage position = positions[positionId];
        if (position.state != uint8(PositionState.Pending)) revert PositionNotPending();

        uint8 oldState = position.state;
        position.state = uint8(PositionState.Rejected);

        vaultConfig.depositToken.safeTransfer(position.user, position.depositAmount);

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Rejected);
        emit PositionRejected(positionId, brokerRequestId, reason);
    }

    /**
     * @param positionId The position to execute
     */
    function executeLeveragePosition(uint256 positionId)
        external
        nonReentrant
        onlyInitialized
        positionExists(positionId)
        onlyPositionOwner(positionId)
        validPositionState(positionId, PositionState.Approved)
        positionNotExpired(positionId)
    {
        Position storage position = positions[positionId];

        uint8 oldState = position.state;
        position.state = uint8(PositionState.Executed);

        VaultConfig memory config = vaultConfig;
        uint256 approvedAmount = position.executionData;
        uint256 depositAmount = position.depositAmount;
        address positionUser = position.user;
        uint16 leverageRatio = position.leverageRatio;

        uint256 totalInvestAmount = depositAmount + approvedAmount;
        if (totalInvestAmount < depositAmount) revert ArithmeticOverflow();

        uint256 newTVL = totalValueLocked + totalInvestAmount;
        if (newTVL < totalValueLocked) revert ArithmeticOverflow();
        uint256 newBorrowed = totalBorrowed + approvedAmount;
        if (newBorrowed < totalBorrowed) revert ArithmeticOverflow();

        totalValueLocked = newTVL;
        totalBorrowed = newBorrowed;

        try config.primeBroker.borrow(address(config.depositToken), approvedAmount) { }
        catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to borrow from prime broker");
        }

        if (totalInvestAmount == 0) revert InvalidAmount();
        uint256 expectedFundTokens = _getExpectedFundTokens(totalInvestAmount);
        if (expectedFundTokens == 0) revert InvalidCalculation();
        uint256 minFundTokens = (expectedFundTokens * 9950) / 10000;

        if (config.fundToken == address(0)) revert InvalidZeroAddress();
        config.depositToken.approve(config.fundToken, totalInvestAmount);
        uint256 fundTokensReceived;
        try IERC3643Fund(config.fundToken).invest(totalInvestAmount) returns (uint256 tokens) {
            fundTokensReceived = tokens;
            require(
                fundTokensReceived >= minFundTokens, "Slippage: insufficient fund tokens received"
            );
        } catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to invest in fund");
        }

        if (fundTokensReceived == 0) revert InvalidAmount();
        if (address(config.morpho) == address(0)) revert InvalidZeroAddress();
        IERC20(config.fundToken).approve(address(config.morpho), fundTokensReceived);
        try config.morpho.supplyCollateral(
            config.morphoMarket, fundTokensReceived, address(this), ""
        ) { } catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to supply collateral to Morpho");
        }

        try config.morpho.borrow(
            config.morphoMarket, approvedAmount, 0, address(this), address(this)
        ) { } catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to borrow from Morpho");
        }

        config.depositToken.approve(address(config.primeBroker), approvedAmount);
        try config.primeBroker.repay(address(config.depositToken), approvedAmount) { }
        catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to repay prime broker");
        }

        uint256 syntheticTokens =
            LeverageCalculator.calculateSyntheticTokens(fundTokensReceived, leverageRatio);

        try config.syntheticToken.mint(positionUser, syntheticTokens) { }
        catch {
            position.state = oldState;
            totalValueLocked -= totalInvestAmount;
            totalBorrowed -= approvedAmount;
            revert("Failed to mint synthetic tokens");
        }

        executedPositions[positionId] = ExecutedPositionData({
            syntheticTokensMinted: syntheticTokens,
            fundTokensOwned: fundTokensReceived,
            borrowedAmount: approvedAmount,
            brokerRequestId: bytes32(0)
        });

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Executed);
        emit PositionExecuted(positionId, positionUser, fundTokensReceived, syntheticTokens);
    }

    /**
     * @param positionId The position to check for expiry
     */
    function checkPositionExpiry(uint256 positionId) external positionExists(positionId) {
        Position storage position = positions[positionId];

        uint8 currentState = position.state;
        if (currentState == uint8(PositionState.Approved)) {
            uint256 executionDeadline = position.createdAt + BROKER_TIMEOUT;

            if (block.timestamp > executionDeadline) {
                position.state = uint8(PositionState.Expired);

                address positionUser = position.user;
                uint256 depositAmount = position.depositAmount;

                vaultConfig.depositToken.safeTransfer(positionUser, depositAmount);

                emit PositionStateChanged(
                    positionId, PositionState(currentState), PositionState.Expired
                );
                emit PositionExpired(positionId, bytes32(positionId));
            }
        }
    }

    /**
     * @param positionIds Array of position IDs to check
     */
    function batchCheckPositionExpiry(uint256[] calldata positionIds) external {
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            if (positions[positionId].user != address(0)) {
                Position storage position = positions[positionId];

                if (position.state == uint8(PositionState.Approved)) {
                    uint256 executionDeadline = position.createdAt + BROKER_TIMEOUT;

                    if (block.timestamp > executionDeadline) {
                        uint8 oldState = position.state;
                        position.state = uint8(PositionState.Expired);

                        address positionUser = position.user;
                        uint256 depositAmount = position.depositAmount;

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
     * @param positionId The position to close
     */
    function closePosition(uint256 positionId)
        external
        nonReentrant
        onlyInitialized
        positionExists(positionId)
        onlyPositionOwner(positionId)
        validPositionState(positionId, PositionState.Executed)
    {
        Position storage position = positions[positionId];
        ExecutedPositionData memory executedData = executedPositions[positionId];

        uint256 lockUntil = position.createdAt + position.lockDuration;
        if (block.timestamp < lockUntil) revert PositionStillLocked();

        uint256 maxLockUntil = position.createdAt + MAX_LOCK_PERIOD;
        if (lockUntil > maxLockUntil) { }

        VaultConfig memory config = vaultConfig;

        try config.syntheticToken.burn(msg.sender, executedData.syntheticTokensMinted) { }
        catch {
            revert("Failed to burn synthetic tokens");
        }

        uint256 repayAmount = executedData.borrowedAmount;
        uint256 fundTokensToRedeem =
            _calculateFundTokensToRedeem(executedData.fundTokensOwned, repayAmount);

        try config.morpho.withdrawCollateral(
            config.morphoMarket, fundTokensToRedeem, address(this), address(this)
        ) { } catch {
            revert("Failed to withdraw collateral from Morpho");
        }

        uint256 expectedUSDC = _getExpectedUSDCFromFundTokens(fundTokensToRedeem);
        uint256 minUSDCFromRedeem = (expectedUSDC * 9950) / 10000;

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

        config.depositToken.approve(address(config.morpho), repayAmount);
        try config.morpho.repay(config.morphoMarket, repayAmount, 0, address(this), "") { }
        catch {
            revert("Failed to repay Morpho loan");
        }

        uint256 remainingCollateral = executedData.fundTokensOwned - fundTokensToRedeem;
        try config.morpho.withdrawCollateral(
            config.morphoMarket, remainingCollateral, address(this), address(this)
        ) { } catch {
            revert("Failed to withdraw remaining collateral from Morpho");
        }

        uint256 expectedRemainingUSDC = _getExpectedUSDCFromFundTokens(remainingCollateral);
        uint256 minRemainingUSDC = (expectedRemainingUSDC * 9950) / 10000;

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

        if (underlyingReceived < repayAmount) revert ArithmeticUnderflow();
        uint256 remainingFromRepayment = underlyingReceived - repayAmount;
        uint256 totalUSDCAvailable = remainingFromRepayment + remainingUSDC;
        if (totalUSDCAvailable < remainingFromRepayment) revert ArithmeticOverflow();

        uint256 pnl = 0;
        if (totalUSDCAvailable > position.depositAmount) {
            pnl = totalUSDCAvailable - position.depositAmount;
            if (pnl > totalUSDCAvailable) revert InvalidCalculation();
        }

        uint256 fees = _calculateAndChargeFees(position, executedData, pnl, config);
        if (totalUSDCAvailable < fees) revert ArithmeticUnderflow();
        uint256 finalAmount = totalUSDCAvailable - fees;

        uint8 oldState = position.state;
        position.state = uint8(PositionState.Completed);

        uint256 totalToSubtract = position.depositAmount + executedData.borrowedAmount;
        if (totalToSubtract < position.depositAmount) revert ArithmeticOverflow();
        if (totalValueLocked < totalToSubtract) revert ArithmeticUnderflow();
        if (totalBorrowed < executedData.borrowedAmount) revert ArithmeticUnderflow();

        totalValueLocked -= totalToSubtract;
        totalBorrowed -= executedData.borrowedAmount;

        delete executedPositions[positionId];

        address positionUser = msg.sender;

        emit PositionStateChanged(positionId, PositionState(oldState), PositionState.Completed);
        emit PositionClosed(positionId, positionUser, finalAmount, pnl);

        if (finalAmount > 0) {
            config.depositToken.safeTransfer(positionUser, finalAmount);
        }
    }

    /**
     * @param newConfig New vault configuration
     */
    function updateVaultConfig(VaultConfig memory newConfig) external onlyOwner onlyInitialized {
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

        if (currentPrice == 0) revert OraclePriceInvalid();

        if (lastValidPrice > 0) {
            uint256 deviation;
            if (currentPrice > lastValidPrice) {
                deviation = ((currentPrice - lastValidPrice) * BASIS_POINTS) / lastValidPrice;
            } else {
                deviation = ((lastValidPrice - currentPrice) * BASIS_POINTS) / lastValidPrice;
            }

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

        fundTokensNeeded = (fundTokensNeeded * 1001) / 1000;
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

        if (block.timestamp < position.createdAt) revert ArithmeticUnderflow();
        uint256 timeHeld = block.timestamp - position.createdAt;
        managementFee = LeverageCalculator.calculateManagementFee(
            position.depositAmount, config.managementFee, timeHeld
        );

        if (pnl > 0) {
            performanceFee = LeverageCalculator.calculatePerformanceFee(pnl, config.performanceFee);
        }

        totalFees = managementFee + performanceFee;
        if (totalFees < managementFee) revert ArithmeticOverflow();

        if (totalFees > 0) {
            if (config.feeRecipient == address(0)) revert InvalidZeroAddress();
            config.depositToken.safeTransfer(config.feeRecipient, totalFees);
        }

        return totalFees;
    }

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

    function getUserPositions(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory, uint256 totalCount, bool hasMore)
    {
        require(limit > 0 && limit <= 100, "Invalid limit: must be 1-100");

        uint256[] memory userPositionList = userPositions[user];
        totalCount = userPositionList.length;

        if (offset >= totalCount) {
            return (new uint256[](0), totalCount, false);
        }

        uint256 remaining = totalCount - offset;
        uint256 actualLimit = remaining > limit ? limit : remaining;
        uint256[] memory positions_page = new uint256[](actualLimit);

        unchecked {
            for (uint256 i = 0; i < actualLimit; ++i) {
                positions_page[i] = userPositionList[offset + i];
            }
        }

        hasMore = (offset + actualLimit) < totalCount;
        return (positions_page, totalCount, hasMore);
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        (uint256[] memory positions_page,,) = this.getUserPositions(user, 0, 50);
        return positions_page;
    }

    function getPositionValue(uint256 positionId)
        external
        view
        returns (uint256 currentValue, int256 pnl)
    {
        Position memory position = positions[positionId];
        if (position.state != uint8(PositionState.Executed)) return (0, 0);

        ExecutedPositionData memory executedData = executedPositions[positionId];

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

    function pause() external onlyOwner onlyInitialized {
        _pause();
    }

    function unpause() external onlyOwner onlyInitialized {
        _unpause();
    }

    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    /**
     * Emergency withdraw with restrictions to prevent abuse
     * Can only withdraw non-deposit tokens to prevent draining user funds
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner onlyInitialized {
        if (token == address(vaultConfig.depositToken)) {
            revert("Cannot withdraw deposit tokens");
        }
        IERC20(token).safeTransfer(owner(), amount);
    }
}
