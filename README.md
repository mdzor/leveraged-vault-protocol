# Leveraged Vault Protocol

A sophisticated DeFi protocol that provides leveraged exposure to ERC3643-compliant funds through synthetic tokens. Users can deposit USDC and get up to 5x leveraged exposure to institutional-grade funds while maintaining compliance with regulatory requirements.

## Overview

The Leveraged Vault Protocol combines:
- **Leveraged Investment Strategy**: Recursive borrowing to amplify exposure (1.5x - 5x)
- **ERC3643 Compliance**: Regulatory-compliant synthetic tokens for fund exposure  
- **Multi-Protocol Integration**: Prime Broker for lending, Morpho v2 for yield optimization
- **Risk Management**: Health factor monitoring, position limits, and emergency controls

## Architecture

### Core Components

1. **LeveragedVault** (`src/LeveragedVault.sol`)
   - Main contract managing user positions and leverage strategies
   - Handles opening/closing positions, fee collection, and risk management
   - Supports 1.5x to 5x leverage in 0.5x increments

2. **LeverageCalculator** (`src/libraries/LeverageCalculator.sol`)
   - Mathematical library for leverage calculations
   - Computes borrow amounts, synthetic token allocations, and fee structures
   - Optimizes recursive borrowing loops based on target leverage

3. **Protocol Interfaces** (`src/interfaces/`)
   - `IPrimeBroker.sol`: Lending protocol for borrowing/supplying
   - `IMorphoV2.sol`: Morpho v2 integration for collateral optimization
   - `IERC3643.sol`: ERC3643 compliant token standard
   - `IFundManager.sol`: Fund management interface

### Key Features

✅ **Multi-Leverage Support**: 1.5x, 2x, 2.5x, 3x, 3.5x, 4x, 4.5x, 5x leverage ratios
✅ **Recursive Borrowing**: Optimized looping strategy for capital efficiency
✅ **ERC3643 Synthetic Tokens**: Regulatory compliant tokenized fund exposure
✅ **Position Management**: Individual position tracking with P&L calculation
✅ **Fee Structure**: Management fees (2% annual) + performance fees (20% of profits)
✅ **Lock Periods**: Minimum 7-day position lock for stability
✅ **Multi-User Support**: Unlimited positions per user
✅ **Emergency Controls**: Pause functionality and emergency withdrawals
✅ **Comprehensive Testing**: 25+ test scenarios including fuzz testing

## Usage

### Opening a Position

```solidity
// Approve USDC spending
usdc.approve(address(vault), amount);

// Open leveraged position
uint256 positionId = vault.openPosition(
    fundTokenAddress,    // ERC3643 fund to invest in
    10000e6,            // 10,000 USDC deposit
    300                 // 3x leverage (300 = 3.0x)
);
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

// Get current value and P&L
(uint256 currentValue, int256 pnl) = vault.getPositionValue(positionId);
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test -vvv
```

### Deploy (Local)

```shell
# Start local node
anvil

# Deploy contracts
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Gas Optimization

```shell
forge snapshot
```

## MVP Roadmap - Missing Components

### 🔨 Core Implementation Gaps
- [ ] **Leverage Adjustment Logic**: `_increaseLeverage()` and `_decreaseLeverage()` functions are incomplete
- [ ] **Deployment Scripts**: No deployment scripts in `script/` directory  
- [ ] **Real Protocol Adapters**: Mock contracts need real Prime Broker/Morpho integrations
- [ ] **Fund Token Registry**: Dynamic fund addition/removal system
- [ ] **Liquidation Engine**: Automated liquidation for unhealthy positions

### 🛡️ Security & Risk Management
- [ ] **Oracle Integration**: Price feeds for real-time asset valuation
- [ ] **Slippage Protection**: Maximum slippage limits for position operations
- [ ] **Circuit Breakers**: Automatic pause triggers for extreme market conditions
- [ ] **Health Factor Monitoring**: Automated position monitoring and alerts
- [ ] **Multi-signature Admin**: Secure admin controls for protocol governance

### 📊 Analytics & Monitoring  
- [ ] **Position Analytics**: Advanced P&L tracking and performance metrics
- [ ] **Vault Metrics**: TVL, utilization rates, and fee collection tracking
- [ ] **Event Indexing**: Comprehensive event emission for off-chain tracking
- [ ] **User Dashboard**: Position management and analytics interface

### 🌐 Integration & Compliance
- [ ] **ERC3643 Identity Integration**: Full compliance verification system
- [ ] **Multi-chain Support**: Cross-chain deployment capability
- [ ] **Governance Token**: Protocol governance and fee sharing mechanism
- [ ] **API Endpoints**: REST/GraphQL APIs for position management

### 🧪 Testing & Quality Assurance
- [ ] **Integration Tests**: Real protocol integration testing
- [ ] **Invariant Testing**: Protocol invariant verification
- [ ] **Gas Optimization**: Detailed gas usage optimization
- [ ] **Security Audit**: Professional security audit before mainnet

## License

MIT
