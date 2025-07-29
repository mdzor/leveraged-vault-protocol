# Leveraged Vault Protocol

A sophisticated DeFi protocol that provides leveraged exposure to ERC3643-compliant funds through synthetic tokens using an asynchronous broker pattern. Users can deposit USDC and get up to 5x leveraged exposure to institutional-grade funds while maintaining compliance with regulatory requirements.

## Overview

The Leveraged Vault Protocol combines:
- **Asynchronous Broker Integration**: Two-phase position opening with broker approval workflow
- **Leveraged Investment Strategy**: Prime Broker lending + Morpho Blue collateral optimization (1.5x - 5x)
- **ERC3643 Compliance**: Regulatory-compliant synthetic tokens for fund exposure  
- **Factory Pattern**: Scalable vault deployment for multiple funds
- **Advanced Risk Management**: Position state machine, slippage protection, and comprehensive error handling

## Architecture

### Core Components

1. **LeveragedVaultFactory** (`src/LeveragedVault.sol`)
   - Factory contract for deploying individual vault instances
   - Manages vault registry, activation/deactivation, and owner permissions
   - Tracks all deployed vaults with metadata and statistics

2. **LeveragedVaultImplementation** (`src/LeveragedVaultImplementation.sol`)
   - Individual vault implementation for specific ERC3643 funds
   - Handles asynchronous position lifecycle: Request → Approval → Execution → Completion
   - Integrates Prime Broker (lending) + Morpho Blue (collateral optimization)
   - Supports 1.5x to 5x leverage in 0.5x increments

3. **LeverageCalculator** (`src/libraries/LeverageCalculator.sol`)
   - Mathematical library for leverage calculations
   - Computes borrow amounts, synthetic token allocations, and fee structures
   - Handles management and performance fee calculations

4. **Protocol Interfaces** (`src/interfaces/`)
   - `IPrimeBroker.sol`: Async lending protocol with request/approval workflow
   - `IMorpho.sol`: Morpho Blue integration for collateral management
   - `IERC3643.sol`: ERC3643 compliant token standard
   - `IERC3643Fund.sol`: Fund-specific operations (invest/redeem)

### Async Broker Workflow

The protocol uses a sophisticated asynchronous pattern for position management:

```
1. Request → User calls requestLeveragePosition()
2. Pending → Broker evaluates request off-chain  
3. Approval → Broker calls handleBrokerApproval() 
4. Execution → User calls executeLeveragePosition()
5. Active → Position earns yield, user holds synthetic tokens
6. Completion → User calls closePosition() to exit
```

### Position State Machine

```solidity
enum PositionState {
    Pending,    // Waiting for broker approval
    Approved,   // Broker approved, ready for execution  
    Rejected,   // Broker rejected, funds can be withdrawn
    Executed,   // Position executed, earning yield
    Completed,  // Position closed, loan repaid
    Expired     // Broker didn't respond in time
}
```

### Key Features

✅ **Factory Pattern**: Scalable deployment of vaults for different funds  
✅ **Async Broker Integration**: Two-phase position opening with professional risk assessment  
✅ **Multi-Leverage Support**: 1.5x, 2x, 2.5x, 3x, 3.5x, 4x, 4.5x, 5x leverage ratios  
✅ **Slippage Protection**: 0.5% tolerance on fund investment/redemption operations  
✅ **Advanced Error Handling**: Try-catch blocks on all external calls with descriptive errors  
✅ **ERC3643 Synthetic Tokens**: Regulatory compliant tokenized fund exposure  
✅ **Comprehensive Validation**: Zero address checks, balance verification, state validation  
✅ **Position Management**: Individual position tracking with real-time P&L calculation  
✅ **Fee Structure**: Management fees (configurable) + performance fees (configurable)  
✅ **Lock Periods**: Configurable minimum position lock for stability  
✅ **Multi-User Support**: Unlimited positions per user across multiple vaults  
✅ **Emergency Controls**: Pause functionality and emergency withdrawals  
✅ **Comprehensive Testing**: 23+ test scenarios including fuzz testing  

## Usage

### Deploying a New Vault

```solidity
// Deploy factory (done once)
LeveragedVaultFactory factory = new LeveragedVaultFactory();

// Create vault configuration
LeveragedVaultImplementation.VaultConfig memory config = LeveragedVaultImplementation.VaultConfig({
    depositToken: IERC20(usdcAddress),
    primeBroker: IPrimeBroker(brokerAddress),
    morpho: IMorpho(morphoAddress),
    syntheticToken: IERC3643(syntheticTokenAddress),
    fundToken: fundTokenAddress,
    morphoMarket: morphoMarketParams,
    managementFee: 200,        // 2% annual
    performanceFee: 2000,      // 20% of profits
    minLockPeriod: 7 days,
    feeRecipient: feeRecipientAddress,
    maxLeverage: 500,          // 5x max
    vaultName: "EGAF Leveraged Vault",
    vaultSymbol: "lvEGAF"
});

// Deploy new vault
uint256 vaultId = factory.createVault(config, vaultOwner);
```

### Opening a Leveraged Position (Async Flow)

```solidity
// Step 1: Request position (user)
usdc.approve(address(vault), 10000e6);
uint256 positionId = vault.requestLeveragePosition(
    10000e6,    // 10,000 USDC deposit
    300         // 3x leverage (300 = 3.0x)
);

// Step 2: Broker approval (off-chain → on-chain)
// Broker evaluates and calls: vault.handleBrokerApproval(requestId, approvedAmount)

// Step 3: Execute position (user, after approval)
vault.executeLeveragePosition(positionId);
```

### Closing a Position

```solidity
// Close position after lock period
vault.closePosition(positionId);
```

### Checking Position Status

```solidity
// Get position details
UserPosition memory position = vault.getPosition(positionId);

// Check position state
if (position.state == PositionState.Executed) {
    // Position is active and earning yield
}

// Get current value and P&L
(uint256 currentValue, int256 pnl) = vault.getPositionValue(positionId);
```

### Factory Operations

```solidity
// Get vault info
LeveragedVaultFactory.VaultInfo memory info = factory.getVault(vaultId);

// Deactivate vault (owner only)
factory.deactivateVault(vaultId);

// Get user's vaults
uint256[] memory userVaultIds = factory.getUserVaults(userAddress);
```

## Development

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Solidity ^0.8.20

### Build

```shell
forge build
```

### Test

```shell
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run specific test
forge test --match-test testOpenPosition3xLeverage

# Run fuzz tests
forge test --match-test testFuzz
```

### Test Coverage

```shell
forge coverage
```

### Gas Analysis

```shell
forge snapshot
```

### Code Formatting

```shell
forge fmt
```

## Security Features

### Input Validation
- Comprehensive zero address checks
- Balance and allowance verification
- Leverage ratio validation (MIN_LEVERAGE to maxLeverage)
- Position state validation with state machine

### Slippage Protection
- 0.5% slippage tolerance on fund investments
- 0.5% slippage tolerance on fund redemptions
- Price impact protection using fund share price

### Error Handling
- Try-catch blocks on all external protocol calls
- Descriptive error messages for debugging
- Graceful handling of failed external operations

### Access Control
- Owner-only administrative functions
- Position-owner-only operations
- Factory-only vault initialization
- Broker-only approval functions

### Reentrancy Protection
- ReentrancyGuard on all state-changing functions
- Checks-Effects-Interactions pattern
- External call isolation

## Contract Addresses

*Contracts not yet deployed to mainnet*

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Audit Status

⚠️ **This protocol has not been audited. Use at your own risk.**

For production deployment, a comprehensive security audit is strongly recommended.