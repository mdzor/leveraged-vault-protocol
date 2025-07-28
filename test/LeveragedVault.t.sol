// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LeveragedVault.sol";
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
    uint256 public constant LTV_RATIO = 80; // 80% LTV

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function supply(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        asset.transferFrom(msg.sender, address(this), amount);
        suppliedBalance[msg.sender] += amount;
    }

    function borrow(address assetAddr, uint256 amount) external override {
        require(assetAddr == address(asset), "Unsupported asset");
        require(this.getAvailableBorrow(msg.sender, assetAddr) >= amount, "Insufficient collateral");
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
        require(suppliedBalance[msg.sender] >= amount, "Insufficient balance");
        // Check if withdrawal maintains health factor
        uint256 newSupplied = suppliedBalance[msg.sender] - amount;
        uint256 maxBorrow = (newSupplied * LTV_RATIO) / 100;
        require(borrowedBalance[msg.sender] <= maxBorrow, "Would break health factor");
        
        suppliedBalance[msg.sender] -= amount;
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

    // Helper function to fund the broker
    function fundBroker(uint256 amount) external {
        asset.mint(address(this), amount);
    }
}

contract MockMorphoV2 is IMorphoV2 {
    mapping(address => mapping(address => uint256)) public balances;
    MockERC20 public asset;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function supply(address assetAddr, uint256 amount, address onBehalf) external override {
        IERC20(assetAddr).transferFrom(msg.sender, address(this), amount);
        balances[onBehalf][assetAddr] += amount;
    }

    function withdraw(address assetAddr, uint256 amount, address receiver) external override {
        require(balances[msg.sender][assetAddr] >= amount, "Insufficient balance");
        balances[msg.sender][assetAddr] -= amount;
        IERC20(assetAddr).transfer(receiver, amount);
    }

    function getBalance(address user, address assetAddr) external view override returns (uint256) {
        return balances[user][assetAddr];
    }
}

contract MockERC3643Fund is IERC3643Fund {
    MockERC20 public underlying;
    mapping(address => uint256) public shares;
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
 * @title LeveragedVaultTest
 * @dev Epic test suite for LeveragedVault with comprehensive scenarios
 */
contract LeveragedVaultTest is Test {
    LeveragedVault public vault;
    MockERC20 public usdc;
    MockPrimeBroker public primeBroker;
    MockMorphoV2 public morpho;
    MockERC3643Fund public fundToken;
    MockERC3643Token public syntheticToken;
    
    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public treasury = makeAddr("treasury");
    
    // Test constants
    uint256 public constant INITIAL_BALANCE = 100_000e6; // 100k USDC
    uint256 public constant BROKER_LIQUIDITY = 10_000_000e6; // 10M USDC for broker

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        syntheticToken = new MockERC3643Token();
        
        // Deploy mock protocols
        primeBroker = new MockPrimeBroker(usdc);
        morpho = new MockMorphoV2(usdc);
        fundToken = new MockERC3643Fund(usdc);
        
        // Fund the broker with liquidity
        primeBroker.fundBroker(BROKER_LIQUIDITY);
        
        // Fund the fund contract
        fundToken.fundContract(1_000_000e6); // 1M USDC
        
        // Create vault configuration
        LeveragedVault.VaultConfig memory config = LeveragedVault.VaultConfig({
            depositToken: usdc,
            primeBroker: primeBroker,
            morpho: morpho,
            syntheticToken: syntheticToken,
            managementFee: 200, // 2% annual
            performanceFee: 2000, // 20% of profits
            minLockPeriod: 7 days,
            feeRecipient: treasury,
            maxLeverage: 500 // 5x max
        });
        
        // Deploy vault
        vault = new LeveragedVault(config);
        
        // Transfer ownership of synthetic token to vault
        syntheticToken.transferOwnership(address(vault));
        
        // Add fund as supported
        vault.addSupportedFund(address(fundToken), 10000); // 100% allocation
        
        // Fund test users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
        
        // Approve vault to spend user tokens
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        
        vm.prank(charlie);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testInitialState() public {
        assertEq(vault.nextPositionId(), 1);
        assertEq(vault.totalValueLocked(), 0);
        assertEq(vault.totalBorrowed(), 0);
        assertTrue(vault.supportedFunds(address(fundToken)));
    }

    function testOpenPosition1_5xLeverage() public {
        uint256 depositAmount = 10_000e6; // 10k USDC
        uint256 leverageRatio = 150; // 1.5x
        
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, leverageRatio);
        
        // Check position was created
        LeveragedVault.UserPosition memory position = vault.getPosition(positionId);
        assertEq(position.user, alice);
        assertEq(position.depositAmount, depositAmount);
        assertEq(position.leverageRatio, leverageRatio);
        assertTrue(position.isActive);
        
        // Check synthetic tokens were minted
        assertTrue(syntheticToken.balanceOf(alice) > 0);
        
        // Check user positions mapping
        uint256[] memory userPositions = vault.getUserPositions(alice);
        assertEq(userPositions.length, 1);
        assertEq(userPositions[0], positionId);
        
        // Check vault state
        assertTrue(vault.totalValueLocked() > 0);
        assertTrue(vault.totalBorrowed() > 0);
    }

    function testOpenPosition3xLeverage() public {
        uint256 depositAmount = 20_000e6; // 20k USDC
        uint256 leverageRatio = 300; // 3x
        
        vm.prank(bob);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, leverageRatio);
        
        LeveragedVault.UserPosition memory position = vault.getPosition(positionId);
        assertEq(position.leverageRatio, leverageRatio);
        
        // Check that more was borrowed for higher leverage
        assertTrue(position.borrowedAmount > (depositAmount * leverageRatio) / 300); // Should be significant
        
        // Check loops calculation
        assertEq(vault.calculateRequiredLoops(leverageRatio), 2); // 3x should require 2 loops
    }

    function testOpenPosition5xMaxLeverage() public {
        uint256 depositAmount = 5_000e6; // 5k USDC
        uint256 leverageRatio = 500; // 5x (max)
        
        vm.prank(charlie);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, leverageRatio);
        
        LeveragedVault.UserPosition memory position = vault.getPosition(positionId);
        assertEq(position.leverageRatio, leverageRatio);
        
        // Check loops calculation for max leverage
        assertEq(vault.calculateRequiredLoops(leverageRatio), 4); // 5x should require 4 loops
    }

    function testMultiplePositionsSameUser() public {
        vm.startPrank(alice);
        
        // Open first position
        uint256 positionId1 = vault.openPosition(address(fundToken), 5_000e6, 150);
        
        // Open second position with different leverage
        uint256 positionId2 = vault.openPosition(address(fundToken), 8_000e6, 300);
        
        vm.stopPrank();
        
        // Check both positions exist
        assertTrue(vault.getPosition(positionId1).isActive);
        assertTrue(vault.getPosition(positionId2).isActive);
        
        // Check user has both positions
        uint256[] memory userPositions = vault.getUserPositions(alice);
        assertEq(userPositions.length, 2);
        assertTrue(userPositions[0] == positionId1 || userPositions[1] == positionId1);
        assertTrue(userPositions[0] == positionId2 || userPositions[1] == positionId2);
    }

    function testClosePositionAfterLockPeriod() public {
        uint256 depositAmount = 10_000e6;
        
        // Open position
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, 200);
        
        // Try to close immediately (should fail)
        vm.prank(alice);
        vm.expectRevert("Position still locked");
        vault.closePosition(positionId);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + 8 days);
        
        // Now closing should work
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.closePosition(positionId);
        
        // Check position is closed
        assertFalse(vault.getPosition(positionId).isActive);
        
        // Check alice got her money back (may be more or less due to fund performance)
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        assertTrue(aliceBalanceAfter != aliceBalanceBefore); // Should change
    }

    function testPositionProfitability() public {
        uint256 depositAmount = 15_000e6;
        
        // Open position
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, 250); // 2.5x
        
        // Simulate fund performance - 20% increase
        fundToken.setSharePrice(1.2e18);
        
        // Check position value
        (uint256 currentValue, int256 pnl) = vault.getPositionValue(positionId);
        assertTrue(currentValue > depositAmount);
        assertTrue(pnl > 0); // Should be profitable
        
        // Close position after lock period
        vm.warp(block.timestamp + 8 days);
        
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.closePosition(positionId);
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        
        // Should get more than deposited (minus fees)
        assertTrue(aliceBalanceAfter > aliceBalanceBefore);
    }

    function testPositionLoss() public {
        uint256 depositAmount = 12_000e6;
        
        // Open position
        vm.prank(bob);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, 300); // 3x
        
        // Simulate fund performance - 15% decrease
        fundToken.setSharePrice(0.85e18);
        
        // Check position value
        (uint256 currentValue, int256 pnl) = vault.getPositionValue(positionId);
        assertTrue(pnl < 0); // Should show loss
        
        // Close position after lock period
        vm.warp(block.timestamp + 8 days);
        
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.closePosition(positionId);
        uint256 bobBalanceAfter = usdc.balanceOf(bob);
        
        // Should get less than deposited
        assertTrue(bobBalanceAfter < bobBalanceBefore + depositAmount);
    }

    function testFeeCollection() public {
        uint256 depositAmount = 25_000e6;
        
        // Open position
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, 200);
        
        // Simulate great fund performance - 50% increase
        fundToken.setSharePrice(1.5e18);
        
        // Fast forward 1 year for management fees
        vm.warp(block.timestamp + 365 days);
        
        uint256 treasuryBalanceBefore = usdc.balanceOf(treasury);
        
        // Close position
        vm.prank(alice);
        vault.closePosition(positionId);
        
        uint256 treasuryBalanceAfter = usdc.balanceOf(treasury);
        
        // Treasury should have received fees
        assertTrue(treasuryBalanceAfter > treasuryBalanceBefore);
    }

    function testInvalidLeverageRatios() public {
        uint256 depositAmount = 10_000e6;
        
        vm.startPrank(alice);
        
        // Too low leverage
        vm.expectRevert("Invalid leverage ratio");
        vault.openPosition(address(fundToken), depositAmount, 100); // 1x
        
        // Too high leverage
        vm.expectRevert("Invalid leverage ratio");
        vault.openPosition(address(fundToken), depositAmount, 600); // 6x
        
        // Invalid increment (not 0.5x increment)
        vm.expectRevert("Invalid leverage ratio");
        vault.openPosition(address(fundToken), depositAmount, 175); // 1.75x
        
        vm.stopPrank();
    }

    function testUnsupportedFund() public {
        // Create another fund token
        MockERC3643Fund unsupportedFund = new MockERC3643Fund(usdc);
        
        vm.prank(alice);
        vm.expectRevert("Fund not supported");
        vault.openPosition(address(unsupportedFund), 10_000e6, 200);
    }

    function testUnauthorizedAccess() public {
        // Open position as Alice
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), 10_000e6, 200);
        
        // Try to close as Bob (should fail)
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        vm.expectRevert("Not position owner");
        vault.closePosition(positionId);
    }

    function testEmergencyFunctions() public {
        // Open some positions first
        vm.prank(alice);
        vault.openPosition(address(fundToken), 10_000e6, 200);
        
        // Test pause
        vault.pause();
        
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        vault.openPosition(address(fundToken), 5_000e6, 150);
        
        // Test unpause
        vault.unpause();
        
        vm.prank(alice);
        vault.openPosition(address(fundToken), 5_000e6, 150); // Should work now
    }

    function testVaultTVLTracking() public {
        uint256 tvlBefore = vault.getVaultTVL();
        assertEq(tvlBefore, 0);
        
        // Open multiple positions
        vm.prank(alice);
        vault.openPosition(address(fundToken), 10_000e6, 200); // 2x leverage = 20k total
        
        vm.prank(bob);
        vault.openPosition(address(fundToken), 15_000e6, 300); // 3x leverage = 45k total
        
        uint256 tvlAfter = vault.getVaultTVL();
        assertEq(tvlAfter, 65_000e6); // 20k + 45k = 65k total
    }

    function testLeverageCalculations() public {
        // Test different leverage ratios and their loop requirements
        assertEq(vault.calculateRequiredLoops(150), 1); // 1.5x = 1 loop
        assertEq(vault.calculateRequiredLoops(200), 1); // 2x = 1 loop
        assertEq(vault.calculateRequiredLoops(250), 2); // 2.5x = 2 loops
        assertEq(vault.calculateRequiredLoops(300), 2); // 3x = 2 loops
        assertEq(vault.calculateRequiredLoops(350), 3); // 3.5x = 3 loops
        assertEq(vault.calculateRequiredLoops(400), 3); // 4x = 3 loops
        assertEq(vault.calculateRequiredLoops(450), 4); // 4.5x = 4 loops
        assertEq(vault.calculateRequiredLoops(500), 4); // 5x = 4 loops
    }

    function testConfigUpdates() public {
        // Create new config
        LeveragedVault.VaultConfig memory newConfig = LeveragedVault.VaultConfig({
            depositToken: usdc,
            primeBroker: primeBroker,
            morpho: morpho,
            syntheticToken: syntheticToken,
            managementFee: 300, // Changed to 3%
            performanceFee: 1500, // Changed to 15%
            minLockPeriod: 14 days, // Changed to 2 weeks
            feeRecipient: treasury,
            maxLeverage: 400 // Changed to 4x max
        });
        
        vault.updateVaultConfig(newConfig);
        
        // Verify config was updated
        (,,,, uint256 managementFee, uint256 performanceFee, uint256 minLockPeriod,, uint256 maxLeverage) = vault.vaultConfig();
        assertEq(managementFee, 300);
        assertEq(performanceFee, 1500);
        assertEq(minLockPeriod, 14 days);
        assertEq(maxLeverage, 400);
    }

    // Fuzz testing for various deposit amounts and leverage ratios
    function testFuzzOpenPosition(uint256 depositAmount, uint256 leverageRatio) public {
        // Bound inputs to reasonable ranges
        depositAmount = bound(depositAmount, 1000e6, 50_000e6); // 1k to 50k USDC
        leverageRatio = bound(leverageRatio, 150, 500); // 1.5x to 5x
        
        // Ensure leverage is in 0.5x increments
        leverageRatio = (leverageRatio / 50) * 50;
        if (leverageRatio < 150) leverageRatio = 150;
        
        // Give alice enough funds
        usdc.mint(alice, depositAmount);
        vm.prank(alice);
        usdc.approve(address(vault), depositAmount);
        
        vm.prank(alice);
        uint256 positionId = vault.openPosition(address(fundToken), depositAmount, leverageRatio);
        
        // Verify position was created correctly
        LeveragedVault.UserPosition memory position = vault.getPosition(positionId);
        assertEq(position.depositAmount, depositAmount);
        assertEq(position.leverageRatio, leverageRatio);
        assertTrue(position.isActive);
    }

    function testStressTestMultipleUsers() public {
        address[] memory users = new address[](10);
        
        // Create 10 users and open positions
        for (uint i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            usdc.mint(users[i], 50_000e6);
            
            vm.prank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            
            // Varying deposits and leverage
            uint256 deposit = 1_000e6 + (i * 2_000e6); // 1k to 19k
            uint256 leverage = 150 + (i * 50); // 1.5x to 6x (capped at 5x by contract)
            if (leverage > 500) leverage = 500;
            
            vm.prank(users[i]);
            vault.openPosition(address(fundToken), deposit, leverage);
        }
        
        // Check vault state
        assertTrue(vault.getVaultTVL() > 0);
        assertTrue(vault.nextPositionId() == 11); // 10 positions + 1
        
        // Simulate fund performance
        fundToken.setSharePrice(1.3e18); // 30% gain
        
        // Fast forward and close all positions
        vm.warp(block.timestamp + 30 days);
        
        for (uint i = 0; i < 10; i++) {
            vm.prank(users[i]);
            vault.closePosition(i + 1); // Position IDs start from 1
        }
        
        // All positions should be closed
        for (uint i = 1; i <= 10; i++) {
            assertFalse(vault.getPosition(i).isActive);
        }
    }
}
