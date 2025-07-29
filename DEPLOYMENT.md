# Deployment Guide - Base Testnet

This guide walks you through deploying the Leveraged Vault Protocol on Base testnet with a complete testing setup.

## Prerequisites

1. **Foundry installed**
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Base testnet ETH**
   - Get Base testnet ETH from [Base faucet](https://bridge.base.org/deposit)
   - Or use [Coinbase faucet](https://coinbase.com/faucets/base-ethereum-goerli-faucet)

3. **Base testnet USDC** (optional - script can deploy mock)
   - Bridge USDC to Base testnet or get from faucets

## Setup

1. **Clone and build**
   ```bash
   git clone <repo>
   cd leveraged-vault-protocol
   forge build
   ```

2. **Environment configuration**
   ```bash
   cp .env.example .env
   # Edit .env with your private key and RPC URL
   ```

3. **Configure .env file**
   ```bash
   # Required
   PRIVATE_KEY=your_private_key_without_0x_prefix
   BASE_TESTNET_RPC=https://sepolia.base.org
   
   # Optional (for contract verification)
   ETHERSCAN_API_KEY=your_etherscan_api_key
   ```

## Deployment

### Step 1: Deploy Protocol

```bash
# Deploy all contracts to Base testnet
forge script script/Deploy.s.sol --rpc-url base_testnet --broadcast --verify

# Or without verification
forge script script/Deploy.s.sol --rpc-url base_testnet --broadcast
```

**What gets deployed:**
- Mock ERC3643 Fund (Enhanced Growth Alpha Fund)
- Mock ERC3643 Synthetic Token (sEGAF)
- Mock Prime Broker with async approval
- Leveraged Vault Factory
- Test vault instance

### Step 2: Save Contract Addresses

After deployment, update your `.env` file with the deployed addresses:

```bash
# Copy addresses from deployment output
VAULT_FACTORY=0x...
USDC=0x...
PRIME_BROKER=0x...
SYNTHETIC_TOKEN=0x...
MOCK_FUND=0x...
VAULT_ID=1
```

## Testing the Protocol

### Step 3: Create Test Position

```bash
# Create and execute a test position
forge script script/Interact.s.sol --rpc-url base_testnet --broadcast
```

This will:
1. Verify your address in the synthetic token
2. Create a 10k USDC position with 3x leverage
3. Auto-approve the broker request
4. Execute the position
5. Print position details

### Step 4: Manual Interactions

You can also interact manually using cast:

```bash
# Get USDC from faucet (if using mock)
cast send $USDC "faucet(uint256)" 100000000000 --rpc-url base_testnet --private-key $PRIVATE_KEY

# Check USDC balance
cast call $USDC "balanceOf(address)" YOUR_ADDRESS --rpc-url base_testnet

# Request leverage position
cast send $VAULT_ADDRESS "requestLeveragePosition(uint256,uint256)" 10000000000 300 --rpc-url base_testnet --private-key $PRIVATE_KEY
```

## Protocol Architecture on Base Testnet

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   User (USDC)   │    │  Vault Factory   │    │ Mock Fund (EGAF)│
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ Vault Instance  │◄──►│  Prime Broker    │    │ Synthetic Token │
│ (lvEGAF)        │    │  (Async)         │    │ (sEGAF)         │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                                              │
         ▼                                              ▼
┌─────────────────┐                            ┌─────────────────┐
│  Morpho Blue    │                            │   User Wallet   │
│  (Base Testnet) │                            │ (Synthetic Tkns)│
└─────────────────┘                            └─────────────────┘
```

## Workflow Example

### 1. Request Position
```solidity
// User calls vault
vault.requestLeveragePosition(10000e6, 300); // 10k USDC, 3x leverage
// → Creates position in Pending state
// → Sends request to Prime Broker
```

### 2. Broker Approval (Async)
```solidity
// Prime Broker evaluates off-chain, then calls:
primeBroker.approveLeverageRequest(requestId, approvedAmount);
// → Position moves to Approved state
// → User has 24 hours to execute
```

### 3. Execute Position
```solidity
// User executes the approved position
vault.executeLeveragePosition(positionId);
// → Borrows from Prime Broker
// → Invests in EGAF fund
// → Supplies fund tokens to Morpho as collateral
// → Borrows USDC from Morpho
// → Repays Prime Broker (zero debt)
// → Mints synthetic tokens to user
```

### 4. Position Active
- User holds sEGAF tokens representing leveraged exposure
- Position earns yield through EGAF fund performance
- Morpho provides collateral optimization

### 5. Close Position
```solidity
// After lock period expires
vault.closePosition(positionId);
// → Burns synthetic tokens
// → Redeems fund tokens
// → Repays Morpho loan
// → Returns profit/loss to user
```

## Contract Addresses (Base Testnet)

After deployment, your contracts will be at:

| Contract | Address | Description |
|----------|---------|-------------|
| Vault Factory | `0x...` | Main factory contract |
| Test Vault | `0x...` | lvEGAF vault instance |
| Mock Fund | `0x...` | EGAF fund token |
| Synthetic Token | `0x...` | sEGAF synthetic token |
| Prime Broker | `0x...` | Async lending broker |
| USDC | `0x036CbD...` | Base testnet USDC |
| Morpho Blue | `0xBBBBBbb...` | Morpho Blue on Base |

## Advanced Testing

### Simulate Fund Performance
```bash
# Simulate 10% fund growth
forge script script/Interact.s.sol --sig "simulateFundPerformance()" --rpc-url base_testnet --broadcast

# Check position value after growth
cast call $VAULT_ADDRESS "getPositionValue(uint256)" 1 --rpc-url base_testnet
```

### Fund Prime Broker
```bash
# Add more liquidity to prime broker
forge script script/Interact.s.sol --sig "fundPrimeBroker()" --rpc-url base_testnet --broadcast
```

### Verify Multiple Users
```bash
# Verify users for testing
forge script script/Interact.s.sol --sig "verifyUsers(address[])" "[0x..., 0x...]" --rpc-url base_testnet --broadcast
```

## Morpho Market Creation

To create a real Morpho Blue market for your fund token:

1. **Visit Morpho Interface**: https://app.morpho.blue
2. **Connect to Base Testnet**
3. **Create Market** with parameters:
   - Loan Token: USDC (0x036CbD53842c5426634e7929541eC2318f3dCF7e)
   - Collateral Token: Your Fund Token address
   - Oracle: Price oracle for FUND/USDC
   - IRM: Interest rate model
   - LLTV: Loan-to-value ratio (e.g., 80%)

4. **Update Vault Config** with real market parameters

## Troubleshooting

### Common Issues

1. **"Insufficient balance"**
   - Get testnet ETH from Base faucet
   - Get USDC or use mock USDC faucet

2. **"User not verified"**
   - Call `MockERC3643Token.verifyUser(address)` to verify users

3. **"Insufficient liquidity"**
   - Fund prime broker with more USDC
   - Use `MockPrimeBroker.fundBroker()`

4. **Gas estimation failed**
   - Check contract addresses in .env
   - Ensure sufficient ETH balance for gas

### Verification

```bash
# Verify contracts on BaseScan
forge verify-contract --chain base-sepolia CONTRACT_ADDRESS ContractName

# Check deployment status
cast code CONTRACT_ADDRESS --rpc-url base_testnet
```

## Next Steps

1. **Create real ERC3643 fund token** with proper compliance
2. **Integrate real Prime Broker** with institutional lending
3. **Create Morpho Blue market** for your fund token
4. **Implement oracle** for fund token pricing
5. **Add frontend interface** for user interactions
6. **Conduct security audit** before mainnet deployment

## Support

For issues or questions:
1. Check contract addresses are correct
2. Verify transaction on BaseScan
3. Review deployment logs for errors
4. Test with small amounts first