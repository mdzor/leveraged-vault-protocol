// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultImplementation.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Mock contracts for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");
        _balances[from] -= amount;
        _balances[to] += amount;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
    }
}

contract MockPrimeBroker is IPrimeBroker {
    mapping(address => uint256) public suppliedBalance;
    mapping(address => uint256) public borrowedBalance;
    MockERC20 public immutable asset;
    
    uint256 public constant HEALTH_FACTOR = 2e18; // 200% health factor
    uint256 public constant LTV_RATIO = 95; // 95% LTV to allow higher leverage
    
    // Async request tracking
    struct LeverageRequest {
        address vault;      // The vault that made the request
        address user;
        address asset;
        uint256 collateralAmount;
        uint256 leverageAmount;
        uint256 leverageRatio;
        uint256 requestTimestamp;
        bool isProcessed;
        bool isApproved;
    }
    
    mapping(bytes32 => LeverageRequest) public leverageRequests;
    uint256 public requestCounter = 1;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function supply(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        asset.transferFrom(msg.sender, address(this), amount);
        suppliedBalance[msg.sender] += amount;
    }

    // New async leverage request function
    function requestLeverage(
        address user,
        address assetAddr,
        uint256 collateralAmount,
        uint256 leverageAmount,
        uint256 leverageRatio
    ) external override returns (bytes32 requestId) {
        require(assetAddr == address(asset), "Unsupported asset");
        
        // Generate unique request ID
        requestId = keccak256(abi.encodePacked(user, assetAddr, block.timestamp, requestCounter++));
        
        // Store request
        leverageRequests[requestId] = LeverageRequest({
            vault: msg.sender,  // Store the vault address
            user: user,
            asset: assetAddr,
            collateralAmount: collateralAmount,
            leverageAmount: leverageAmount,
            leverageRatio: leverageRatio,
            requestTimestamp: block.timestamp,
            isProcessed: false,
            isApproved: false
        });
        
        // Don't auto-approve immediately to avoid reentrancy
        // Test will call processRequests() after the transaction
        
        return requestId;
    }

    function borrow(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        
        // For approved leverage positions, allow borrowing directly
        borrowedBalance[msg.sender] += amount;
        asset.transfer(msg.sender, amount);
    }

    function repay(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        require(borrowedBalance[msg.sender] >= amount, "Repaying more than borrowed");
        asset.transferFrom(msg.sender, address(this), amount);
        borrowedBalance[msg.sender] -= amount;
    }

    function withdraw(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        
        // For leverage withdrawals, we allow withdrawing more than supplied
        // This simulates the broker providing leverage funds
        if (amount > suppliedBalance[msg.sender]) {
            // This is a leverage withdrawal - track as borrowed amount
            uint256 leverageAmount = amount - suppliedBalance[msg.sender];
            borrowedBalance[msg.sender] += leverageAmount;
            suppliedBalance[msg.sender] = 0;
        } else {
            // Regular withdrawal
            uint256 newSupplied = suppliedBalance[msg.sender] - amount;
            uint256 maxBorrow = (newSupplied * LTV_RATIO) / 100;
            require(borrowedBalance[msg.sender] <= maxBorrow, "Would break health factor");
            suppliedBalance[msg.sender] = newSupplied;
        }
        
        asset.transfer(msg.sender, amount);
    }

    function getHealthFactor(address user) external view override returns (uint256) {
        if (borrowedBalance[user] == 0) return type(uint256).max;
        return (suppliedBalance[user] * 1e18) / borrowedBalance[user];
    }

    function getAvailableBorrow(address user, address assetAddr) external view override returns (uint256) {
        require(assetAddr == address(asset), "Unsupported asset");
        uint256 maxBorrow = (suppliedBalance[user] * LTV_RATIO) / 100;
        if (maxBorrow <= borrowedBalance[user]) return 0;
        return maxBorrow - borrowedBalance[user];
    }

    // Interface implementation functions
    function isValidRequest(bytes32 requestId) external view override returns (bool) {
        return leverageRequests[requestId].requestTimestamp != 0;
    }
    
    function getRequestDetails(bytes32 requestId) external view override returns (
        address user,
        address assetAddr,
        uint256 collateralAmount,
        uint256 leverageAmount,
        uint256 requestTimestamp,
        bool isProcessed
    ) {
        LeverageRequest memory request = leverageRequests[requestId];
        return (
            request.user,
            request.asset,
            request.collateralAmount,
            request.leverageAmount,
            request.requestTimestamp,
            request.isProcessed
        );
    }

    // Helper function to fund the broker
    function fundBroker(uint256 amount) external {
        asset.mint(address(this), amount);
    }
    
    // Simulation functions for testing async behavior
    function simulateApproveRequest(bytes32 requestId, address vault, uint256 approvedAmount) external {
        require(leverageRequests[requestId].requestTimestamp != 0, "Invalid request");
        require(!leverageRequests[requestId].isProcessed, "Already processed");
        
        leverageRequests[requestId].isProcessed = true;
        leverageRequests[requestId].isApproved = true;
        
        // Call vault's approval handler
        LeveragedVaultImplementation(vault).handleBrokerApproval(requestId, approvedAmount);
    }
    
    function simulateRejectRequest(bytes32 requestId, address vault, string calldata reason) external {
        require(leverageRequests[requestId].requestTimestamp != 0, "Invalid request");
        require(!leverageRequests[requestId].isProcessed, "Already processed");
        
        leverageRequests[requestId].isProcessed = true;
        leverageRequests[requestId].isApproved = false;
        
        // Call vault's rejection handler
        LeveragedVaultImplementation(vault).handleBrokerRejection(requestId, reason);
    }
    
    // Process all pending requests (for testing)
    function processAllPendingRequests() external {
        // This is a simplified approach for testing
        // In reality, the broker would process requests asynchronously
        for (uint256 i = 1; i < requestCounter; i++) {
            bytes32 requestId = keccak256(abi.encodePacked("", address(0), uint256(0), i));
            // Find the actual request ID (this is a hack for testing)
            // In production, you'd have a proper way to iterate requests
        }
    }
    
    // Auto-approve function for simple testing 
    function enableAutoApprove(bool enabled) external {
        autoApprove = enabled;
    }
    
    // Process specific request ID
    function processRequest(bytes32 requestId) external {
        LeverageRequest storage request = leverageRequests[requestId];
        require(request.requestTimestamp != 0, "Invalid request");
        require(!request.isProcessed, "Already processed");
        
        request.isProcessed = true;
        request.isApproved = true;
        
        // Call vault's approval handler
        LeveragedVaultImplementation(request.vault).handleBrokerApproval(requestId, request.leverageAmount);
    }
    
    bool public autoApprove = false;
}

contract MockMorpho is IMorpho {
    mapping(address => mapping(address => uint256)) private _collateralBalances; // user => token => amount
    mapping(address => mapping(address => uint256)) private _borrowBalances; // user => token => amount
    address public collateralAsset;
    address public loanAsset;

    constructor(address _collateralAsset, address _loanAsset) {
        collateralAsset = _collateralAsset;
        loanAsset = _loanAsset;
    }

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory
    ) external override {
        require(marketParams.collateralToken == collateralAsset, "Invalid collateral token");
        IERC20(marketParams.collateralToken).transferFrom(msg.sender, address(this), assets);
        _collateralBalances[onBehalf][marketParams.collateralToken] += assets;
    }
    
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsBorrowed, uint256 sharesBorrowed) {
        require(marketParams.loanToken == loanAsset, "Invalid loan token");
        require(_collateralBalances[onBehalf][marketParams.collateralToken] > 0, "No collateral");
        
        _borrowBalances[onBehalf][marketParams.loanToken] += assets;
        IERC20(marketParams.loanToken).transfer(receiver, assets);
        
        return (assets, assets); // Simplified 1:1 conversion
    }
    
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256,
        address onBehalf,
        bytes memory
    ) external override returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        require(marketParams.loanToken == loanAsset, "Invalid loan token");
        require(_borrowBalances[onBehalf][marketParams.loanToken] >= assets, "Repaying more than borrowed");
        
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        _borrowBalances[onBehalf][marketParams.loanToken] -= assets;
        
        return (assets, assets); // Simplified 1:1 conversion
    }
    
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external override {
        require(marketParams.collateralToken == collateralAsset, "Invalid collateral token");
        require(_collateralBalances[onBehalf][marketParams.collateralToken] >= assets, "Insufficient collateral");
        
        _collateralBalances[onBehalf][marketParams.collateralToken] -= assets;
        IERC20(marketParams.collateralToken).transfer(receiver, assets);
    }
    
    function position(bytes32, address user) external view override returns (uint256 supplyShares, uint256 borrowShares, uint256 collateral) {
        return (0, _borrowBalances[user][loanAsset], _collateralBalances[user][collateralAsset]);
    }
    
    function market(bytes32) external pure override returns (uint128, uint128, uint128, uint128, uint256, uint128) {
        return (0, 0, 0, 0, 0, 0); // Simplified
    }

    // Helper functions for testing
    function getCollateralBalance(address user) external view returns (uint256) {
        return _collateralBalances[user][collateralAsset];
    }
    
    function getBorrowBalance(address user) external view returns (uint256) {
        return _borrowBalances[user][loanAsset];
    }
    
    function fundContract(uint256 amount) external {
        MockERC20(loanAsset).mint(address(this), amount);
    }
}

contract MockERC3643Fund is IERC3643Fund {
    MockERC20 public underlying;
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 public totalShares;
    uint256 public sharePrice = 1e18; // 1:1 initially
    
    constructor(MockERC20 _underlying) {
        underlying = _underlying;
    }

    function invest(uint256 amount) external override returns (uint256 sharesAmount) {
        underlying.transferFrom(msg.sender, address(this), amount);
        sharesAmount = (amount * 1e18) / sharePrice;
        shares[msg.sender] += sharesAmount;
        totalShares += sharesAmount;
        return sharesAmount;
    }

    function redeem(uint256 sharesAmount) external override returns (uint256 amount) {
        require(shares[msg.sender] >= sharesAmount, "Insufficient shares");
        amount = (sharesAmount * sharePrice) / 1e18;
        shares[msg.sender] -= sharesAmount;
        totalShares -= sharesAmount;
        underlying.transfer(msg.sender, amount);
        return amount;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return shares[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(shares[msg.sender] >= amount, "Insufficient shares");
        shares[msg.sender] -= amount;
        shares[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        require(shares[from] >= amount, "Insufficient shares");
        
        shares[from] -= amount;
        shares[to] += amount;
        _allowances[from][msg.sender] = currentAllowance - amount;
        return true;
    }

    function getSharePrice() external view override returns (uint256) {
        return sharePrice;
    }

    function totalAssets() external view override returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function totalSupply() external view override returns (uint256) {
        return totalShares;
    }

    // Helper to simulate fund performance
    function setSharePrice(uint256 newPrice) external {
        sharePrice = newPrice;
    }

    // Helper to fund the contract
    function fundContract(uint256 amount) external {
        underlying.mint(address(this), amount);
    }
}

contract MockERC3643Token is IERC3643, Ownable {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    
    constructor() Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external override onlyOwner {
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function burn(address from, uint256 amount) external override onlyOwner {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
        _totalSupply -= amount;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        require(_balances[from] >= amount, "Insufficient balance");
        
        _balances[from] -= amount;
        _balances[to] += amount;
        _allowances[from][msg.sender] = currentAllowance - amount;
        return true;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function isVerified(address) external pure override returns (bool) {
        return true; // All addresses verified for testing
    }

    function identityRegistry() external pure override returns (address) {
        return address(0);
    }

    function compliance() external pure override returns (address) {
        return address(0);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * @title LeveragedVaultFactoryTest
 * @dev Epic test suite for LeveragedVaultFactory with comprehensive scenarios
 */
contract LeveragedVaultFactoryTest is Test {
    LeveragedVaultFactory public factory;
    LeveragedVaultImplementation public testVault;
    uint256 public testVaultId;
    MockERC20 public usdc;
    MockPrimeBroker public primeBroker;
    MockMorpho public morpho;
    MockERC3643Fund public fundToken;
    MockERC3643Token public syntheticToken;
    
    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public treasury = makeAddr("treasury");
    
    // Test constants
    uint256 public constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC per user
    uint256 public constant BROKER_LIQUIDITY = 100_000_000e6; // 100M USDC for broker

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        syntheticToken = new MockERC3643Token();
        
        // Deploy mock protocols
        primeBroker = new MockPrimeBroker(usdc);
        fundToken = new MockERC3643Fund(usdc);
        morpho = new MockMorpho(address(fundToken), address(usdc)); // Morpho: fundToken as collateral, USDC as loan asset
        
        // Fund the broker with liquidity
        primeBroker.fundBroker(BROKER_LIQUIDITY);
        
        // Fund the fund contract
        fundToken.fundContract(1_000_000e6); // 1M USDC
        
        // Fund Morpho with USDC for lending
        morpho.fundContract(100_000_000e6); // 100M USDC
        
        // Deploy factory
        factory = new LeveragedVaultFactory();
        
        // Create Morpho market params
        MarketParams memory morphoMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(fundToken),
            oracle: address(0), // Mock oracle
            irm: address(0), // Mock IRM
            lltv: 86e16 // 86% LTV
        });

        // Create a test vault through factory
        LeveragedVaultImplementation.VaultConfig memory config = LeveragedVaultImplementation.VaultConfig({
            depositToken: usdc,
            primeBroker: primeBroker,
            morpho: morpho,
            syntheticToken: syntheticToken,
            fundToken: address(fundToken),
            morphoMarket: morphoMarket,
            managementFee: 200, // 2% annual
            performanceFee: 2000, // 20% of profits
            minLockPeriod: 7 days,
            feeRecipient: treasury,
            maxLeverage: 500, // 5x max
            vaultName: "Test Vault",
            vaultSymbol: "TV"
        });
        
        vm.prank(alice);
        testVaultId = factory.createVault(config);
        LeveragedVaultFactory.VaultInfo memory vaultInfo = factory.getVault(testVaultId);
        testVault = LeveragedVaultImplementation(vaultInfo.vaultAddress);
        
        // Transfer ownership of synthetic token to test vault
        syntheticToken.transferOwnership(address(testVault));
        
        // Fund test users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
        
        // Approve test vault to spend user tokens
        vm.prank(alice);
        usdc.approve(address(testVault), type(uint256).max);
        
        vm.prank(bob);
        usdc.approve(address(testVault), type(uint256).max);
        
        vm.prank(charlie);
        usdc.approve(address(testVault), type(uint256).max);
    }

    // Helper function to open a position with the new async flow
    function openPositionHelper(address user, uint256 amount, uint256 leverageRatio) internal returns (uint256 positionId) {
        // Step 1: Request leverage position 
        vm.prank(user);
        positionId = testVault.requestLeveragePosition(amount, leverageRatio);
        
        // Step 2: Get the broker request ID and process it
        bytes32 requestId = testVault.positionToRequestId(positionId);
        primeBroker.processRequest(requestId);
        
        // Step 3: Execute the approved position
        vm.prank(user);
        testVault.executeLeveragePosition(positionId);
    }

    function testInitialState() public {
        assertEq(factory.nextVaultId(), 2); // Should be 2 since we created one vault
        assertEq(factory.totalVaultsCreated(), 1);
        assertEq(testVault.getVaultTVL(), 0);
        
        // Test vault should be properly configured
        (LeveragedVaultImplementation.VaultConfig memory config,,) = testVault.getVaultInfo();
        assertEq(address(config.depositToken), address(usdc));
        assertEq(address(config.fundToken), address(fundToken));
    }

    function testOpenPosition1_5xLeverage() public {
        uint256 depositAmount = 10_000e6; // 10k USDC
        uint256 leverageRatio = 150; // 1.5x
        
        uint256 positionId = openPositionHelper(alice, depositAmount, leverageRatio);
        
        // Check position was created
        LeveragedVaultImplementation.UserPosition memory position = testVault.getPosition(positionId);
        assertEq(position.user, alice);
        assertEq(position.depositAmount, depositAmount);
        assertEq(position.leverageRatio, leverageRatio);
        assertTrue(position.state == LeveragedVaultImplementation.PositionState.Executed);
        
        // Check synthetic tokens were minted
        assertTrue(syntheticToken.balanceOf(alice) > 0);
        
        // Check user positions mapping
        uint256[] memory userPositions = testVault.getUserPositions(alice);
        assertEq(userPositions.length, 1);
        assertEq(userPositions[0], positionId);
        
        // Check vault state
        assertTrue(testVault.getVaultTVL() > 0);
    }

    function testOpenPosition3xLeverage() public {
        uint256 depositAmount = 20_000e6; // 20k USDC
        uint256 leverageRatio = 300; // 3x
        
        uint256 positionId = openPositionHelper(alice, depositAmount, leverageRatio);
        
        LeveragedVaultImplementation.UserPosition memory position = testVault.getPosition(positionId);
        assertEq(position.leverageRatio, leverageRatio);
        
        // Check that more was borrowed for higher leverage
        assertTrue(position.borrowedAmount > (depositAmount * leverageRatio) / 300); // Should be significant
        
        // Check loops calculation
        // 3x leverage should require 2 loops (internal calculation)
    }

    function testOpenPosition5xMaxLeverage() public {
        uint256 depositAmount = 5_000e6; // 5k USDC
        uint256 leverageRatio = 500; // 5x (max)
        
        uint256 positionId = openPositionHelper(alice, depositAmount, leverageRatio);
        
        LeveragedVaultImplementation.UserPosition memory position = testVault.getPosition(positionId);
        assertEq(position.leverageRatio, leverageRatio);
        
        // Check loops calculation for max leverage
        // 5x leverage should require 4 loops (internal calculation)
    }

    function testMultiplePositionsSameUser() public {
        // Open first position using helper (complete async flow)
        uint256 positionId1 = openPositionHelper(alice, 5_000e6, 150);
        
        // Open second position with different leverage
        uint256 positionId2 = openPositionHelper(alice, 8_000e6, 300);
        
        // Check both positions are executed (active)
        assertEq(uint256(testVault.getPosition(positionId1).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
        assertEq(uint256(testVault.getPosition(positionId2).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
        
        // Check both positions have Executed state
        assertEq(uint256(testVault.getPosition(positionId1).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
        assertEq(uint256(testVault.getPosition(positionId2).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
        
        // Check user has both positions
        uint256[] memory userPositions = testVault.getUserPositions(alice);
        assertEq(userPositions.length, 2);
        assertTrue(userPositions[0] == positionId1 || userPositions[1] == positionId1);
        assertTrue(userPositions[0] == positionId2 || userPositions[1] == positionId2);
    }

    function testClosePositionAfterLockPeriod() public {
        uint256 depositAmount = 10_000e6;
        
        // Open position
        uint256 positionId = openPositionHelper(alice, depositAmount, 200);
        
        // Try to close immediately (should fail)
        vm.prank(alice);
        vm.expectRevert("Position still locked");
        testVault.closePosition(positionId);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + 8 days);
        
        // Now closing should work
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        testVault.closePosition(positionId);
        
        // Check position is closed
        assertEq(uint256(testVault.getPosition(positionId).state), uint256(LeveragedVaultImplementation.PositionState.Completed));
        
        // Check alice got her money back (may be more or less due to fund performance)
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        assertTrue(aliceBalanceAfter != aliceBalanceBefore); // Should change
    }

    function testPositionProfitability() public {
        uint256 depositAmount = 15_000e6;
        
        // Open position
        uint256 positionId = openPositionHelper(alice, depositAmount, 250); // 2.5x
        
        // Simulate fund performance - 20% increase
        fundToken.setSharePrice(1.2e18);
        
        // Check position value
        (uint256 currentValue, int256 pnl) = testVault.getPositionValue(positionId);
        assertTrue(currentValue > depositAmount);
        assertTrue(pnl > 0); // Should be profitable
        
        // Close position after lock period
        vm.warp(block.timestamp + 8 days);
        
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        testVault.closePosition(positionId);
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        
        // Should get more than deposited (minus fees)
        assertTrue(aliceBalanceAfter > aliceBalanceBefore);
    }

    function testPositionLoss() public {
        uint256 depositAmount = 12_000e6;
        
        // Open position using helper (complete async flow)
        uint256 positionId = openPositionHelper(bob, depositAmount, 300); // 3x
        
        // Simulate fund performance - 15% decrease
        fundToken.setSharePrice(0.85e18);
        
        // Check position value
        (uint256 currentValue, int256 pnl) = testVault.getPositionValue(positionId);
        assertTrue(pnl < 0); // Should show loss
        
        // Close position after lock period
        vm.warp(block.timestamp + 8 days);
        
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        testVault.closePosition(positionId);
        uint256 bobBalanceAfter = usdc.balanceOf(bob);
        
        // Should get less than deposited
        assertTrue(bobBalanceAfter < bobBalanceBefore + depositAmount);
    }

    function testFeeCollection() public {
        uint256 depositAmount = 25_000e6;
        
        // Open position
        uint256 positionId = openPositionHelper(alice, depositAmount, 200);
        
        // Simulate great fund performance - 50% increase
        fundToken.setSharePrice(1.5e18);
        
        // Fast forward 1 year for management fees
        vm.warp(block.timestamp + 365 days);
        
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        
        // Close position
        vm.prank(alice);
        testVault.closePosition(positionId);
        
        uint256 treasuryBalanceAfter = usdc.balanceOf(treasury);
        
        // Treasury should have received fees
        assertTrue(treasuryBalanceAfter > treasuryBalanceBefore);
    }

    function testInvalidLeverageRatios() public {
        uint256 depositAmount = 10_000e6;
        
        vm.startPrank(alice);
        
        // Too low leverage
        vm.expectRevert("Invalid leverage ratio");
        testVault.requestLeveragePosition(depositAmount, 100); // 1x
        
        // Too high leverage
        vm.expectRevert("Invalid leverage ratio");
        testVault.requestLeveragePosition(depositAmount, 600); // 6x
        
        // Invalid increment (not 0.5x increment)
        vm.expectRevert("Invalid leverage ratio");
        testVault.requestLeveragePosition(depositAmount, 175); // 1.75x
        
        vm.stopPrank();
    }

    function testCreateMultipleVaults() public {
        // Create another vault with different fund
        MockERC3643Fund newFund = new MockERC3643Fund(usdc);
        MockERC3643Token newSyntheticToken = new MockERC3643Token();
        
        MarketParams memory newMorphoMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(newFund),
            oracle: address(0), // Mock oracle
            irm: address(0), // Mock IRM
            lltv: 86e16 // 86% LTV
        });
        
        LeveragedVaultImplementation.VaultConfig memory config = LeveragedVaultImplementation.VaultConfig({
            depositToken: usdc,
            primeBroker: primeBroker,
            morpho: morpho,
            syntheticToken: newSyntheticToken,
            fundToken: address(newFund),
            morphoMarket: newMorphoMarket,
            managementFee: 300,
            performanceFee: 1500,
            minLockPeriod: 14 days,
            feeRecipient: treasury,
            maxLeverage: 400,
            vaultName: "Second Vault",
            vaultSymbol: "SV"
        });
        
        vm.prank(bob);
        uint256 vaultId = factory.createVault(config);
        
        // Verify second vault exists
        LeveragedVaultFactory.VaultInfo memory vaultInfo = factory.getVault(vaultId);
        assertEq(vaultInfo.owner, bob);
        assertEq(vaultInfo.name, "Second Vault");
        
        // Verify factory stats
        assertEq(factory.totalVaultsCreated(), 2);
    }

    function testUnauthorizedAccess() public {
        // Open position as Alice
        uint256 positionId = openPositionHelper(alice, 10_000e6, 200);
        
        // Try to close as Bob (should fail)
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        vm.expectRevert("Not position owner");
        testVault.closePosition(positionId);
    }

    function testEmergencyFunctions() public {
        // Open some positions first
        vm.prank(alice);
        testVault.requestLeveragePosition(10_000e6, 200);
        
        // Test pause (alice is the owner)
        vm.prank(alice);
        testVault.pause();
        
        vm.prank(alice);
        vm.expectRevert();
        testVault.requestLeveragePosition(5_000e6, 150);
        
        // Test unpause (alice is the owner)
        vm.prank(alice);
        testVault.unpause();
        
        vm.prank(alice);
        testVault.requestLeveragePosition(5_000e6, 150); // Should work now
    }

    function testVaultTVLTracking() public {
        uint256 tvlBefore = testVault.getVaultTVL();
        assertEq(tvlBefore, 0);
        
        // Open multiple positions using helper (which includes execution)
        uint256 positionId1 = openPositionHelper(alice, 10_000e6, 200); // 2x leverage = 20k total
        uint256 positionId2 = openPositionHelper(bob, 15_000e6, 300); // 3x leverage = 45k total
        
        uint256 tvlAfter = testVault.getVaultTVL();
        assertEq(tvlAfter, 65_000e6); // 20k + 45k = 65k total
    }

    function testFactoryVaultManagement() public {
        // Test deactivating vault
        vm.prank(alice); // alice is the owner of testVaultId
        factory.deactivateVault(testVaultId);
        
        LeveragedVaultFactory.VaultInfo memory vaultInfo = factory.getVault(testVaultId);
        assertFalse(vaultInfo.isActive);
        
        // Test reactivating vault
        vm.prank(alice);
        factory.reactivateVault(testVaultId);
        
        vaultInfo = factory.getVault(testVaultId);
        assertTrue(vaultInfo.isActive);
    }

    function testConfigUpdates() public {
        // Create new config with all required fields
        MarketParams memory updatedMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(fundToken),
            oracle: address(0), // Mock oracle
            irm: address(0), // Mock IRM
            lltv: 80e16 // Changed to 80% LTV
        });
        
        LeveragedVaultImplementation.VaultConfig memory newConfig = LeveragedVaultImplementation.VaultConfig({
            depositToken: usdc,
            primeBroker: primeBroker,
            morpho: morpho,
            syntheticToken: syntheticToken,
            fundToken: address(fundToken),
            morphoMarket: updatedMarket,
            managementFee: 300, // Changed to 3%
            performanceFee: 1500, // Changed to 15%
            minLockPeriod: 14 days, // Changed to 2 weeks
            feeRecipient: treasury,
            maxLeverage: 400, // Changed to 4x max
            vaultName: "Updated Test Vault",
            vaultSymbol: "UTV"
        });
        
        // Only vault owner can update config
        vm.prank(alice); // alice is the owner
        testVault.updateVaultConfig(newConfig);
        
        // Verify config was updated
        (LeveragedVaultImplementation.VaultConfig memory config,,) = testVault.getVaultInfo();
        assertEq(config.managementFee, 300);
        assertEq(config.performanceFee, 1500);
        assertEq(config.minLockPeriod, 14 days);
        assertEq(config.maxLeverage, 400);
        assertEq(config.vaultName, "Updated Test Vault");
    }

    // Fuzz testing for various deposit amounts and leverage ratios
    function testFuzzOpenPosition(uint256 depositAmount, uint256 leverageRatio) public {
        // Bound inputs to reasonable ranges
        depositAmount = bound(depositAmount, 1000e6, 100_000e6); // 1k to 100k USDC
        leverageRatio = bound(leverageRatio, 150, 500); // 1.5x to 5x
        
        // Ensure leverage is in 0.5x increments (150, 200, 250, 300, 350, 400, 450, 500)
        uint256 steps = (leverageRatio - 150) / 50;
        leverageRatio = 150 + (steps * 50);
        if (leverageRatio > 500) leverageRatio = 500;
        
        // Give alice enough funds
        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        usdc.approve(address(testVault), depositAmount);
        
        uint256 positionId = openPositionHelper(alice, depositAmount, leverageRatio);
        
        // Verify position was created correctly
        LeveragedVaultImplementation.UserPosition memory position = testVault.getPosition(positionId);
        assertEq(position.depositAmount, depositAmount);
        assertEq(position.leverageRatio, leverageRatio);
        assertTrue(position.state == LeveragedVaultImplementation.PositionState.Executed);
    }

    function testStressTestMultipleUsers() public {
        address[] memory users = new address[](10);
        uint256[] memory positionIds = new uint256[](10);
        
        // Create 10 users and open positions using async flow
        for (uint i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            usdc.mint(users[i], 50_000e6);
            
            vm.prank(users[i]);
            usdc.approve(address(testVault), type(uint256).max);
            
            // Varying deposits and leverage
            uint256 deposit = 1_000e6 + (i * 2_000e6); // 1k to 19k
            uint256 leverage = 150 + (i * 50); // 1.5x to 6x (capped at 5x by contract)
            if (leverage > 500) leverage = 500;
            
            // Use openPositionHelper to complete the full async flow
            positionIds[i] = openPositionHelper(users[i], deposit, leverage);
        }
        
        // Check vault state after all positions are executed
        assertTrue(testVault.getVaultTVL() > 0);
        assertTrue(testVault.nextPositionId() == 11); // 10 positions + 1
        
        // Verify all positions are executed
        for (uint i = 0; i < 10; i++) {
            assertEq(uint256(testVault.getPosition(positionIds[i]).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
            assertEq(uint256(testVault.getPosition(positionIds[i]).state), uint256(LeveragedVaultImplementation.PositionState.Executed));
        }
        
        // Simulate fund performance
        fundToken.setSharePrice(1.3e18); // 30% gain
        
        // Fast forward and close all positions
        vm.warp(block.timestamp + 30 days);
        
        for (uint i = 0; i < 10; i++) {
            vm.prank(users[i]);
            testVault.closePosition(positionIds[i]);
        }
        
        // All positions should be closed
        for (uint i = 0; i < 10; i++) {
            assertEq(uint256(testVault.getPosition(positionIds[i]).state), uint256(LeveragedVaultImplementation.PositionState.Completed));
        }
    }

    // Factory-specific tests
    function testFactoryVaultCreation() public {
        uint256 initialCount = factory.totalVaultsCreated();
        
        // Create multiple vaults
        for (uint i = 0; i < 3; i++) {
            MockERC3643Fund newFund = new MockERC3643Fund(usdc);
            MockERC3643Token newToken = new MockERC3643Token();
            
            MarketParams memory newMarket = MarketParams({
                loanToken: address(usdc),
                collateralToken: address(newFund),
                oracle: address(0), // Mock oracle
                irm: address(0), // Mock IRM
                lltv: 86e16 // 86% LTV
            });
            
            LeveragedVaultImplementation.VaultConfig memory config = LeveragedVaultImplementation.VaultConfig({
                depositToken: usdc,
                primeBroker: primeBroker,
                morpho: morpho,
                syntheticToken: newToken,
                fundToken: address(newFund),
                morphoMarket: newMarket,
                managementFee: 200 + (i * 100),
                performanceFee: 2000,
                minLockPeriod: 7 days,
                feeRecipient: treasury,
                maxLeverage: 500,
                vaultName: string(abi.encodePacked("Vault ", i)),
                vaultSymbol: string(abi.encodePacked("V", i))
            });
            
            vm.prank(alice);
            factory.createVault(config);
        }
        
        assertEq(factory.totalVaultsCreated(), initialCount + 3);
        
        // Test getting all vaults
        LeveragedVaultFactory.VaultInfo[] memory allVaults = factory.getAllVaults();
        assertEq(allVaults.length, initialCount + 3);
    }

    function testFactoryOwnershipTransfer() public {
        // First, alice transfers ownership directly on the vault
        vm.prank(alice);
        testVault.transferOwnership(bob);
        
        // Then, alice updates the factory records
        vm.prank(alice);
        factory.transferVaultOwnership(testVaultId, bob);
        
        // Verify ownership changed
        LeveragedVaultFactory.VaultInfo memory vaultInfo = factory.getVault(testVaultId);
        assertEq(vaultInfo.owner, bob);
        
        // Verify vault ownership also changed
        assertEq(testVault.owner(), bob);
    }

    function testFactoryStats() public {
        (uint256 totalCreated, uint256 nextId, uint256 activeCount) = factory.getFactoryStats();
        
        assertEq(totalCreated, 1); // We created one vault in setup
        assertEq(nextId, 2); // Next vault will have ID 2
        assertEq(activeCount, 1); // One active vault
    }
}
