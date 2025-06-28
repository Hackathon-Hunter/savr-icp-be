# zap-x-icp - ICP Savings Manager

A decentralized savings application built on the Internet Computer Protocol (ICP) that allows users to create savings goals, top up their savings, and track progress toward their financial goals.

## Features

- Create savings goals with target amounts and deadlines
- Top up existing savings with additional funds
- Track progress toward savings goals
- Cancel savings if needed
- Standardized ICP token handling using ICRC-1 standards
- Admin dashboard for management

## Project Structure

```
zap-x-icp/
├── src/
│   ├── SavingManager.mo    # Main canister implementing savings functionality
│   ├── Types.mo            # Type definitions for savings and transactions
│   ├── Utils.mo            # Utility functions for ICP conversion and validation
│   └── declarations/       # Auto-generated .did files and bindings
├── admin-dashboard/        # Frontend admin interface
├── scripts/               # Deployment and utility scripts
├── dfx.json              # DFX configuration
├── mops.toml             # Motoko package manager config
└── canister_ids.json     # Canister ID mappings
```

## Prerequisites

- [DFX SDK](https://internetcomputer.org/install.sh) (version 0.14.1 or higher)
- [Node.js](https://nodejs.org/) (version 16 or higher)
- [MOPS Package Manager](https://mops.one/) for Motoko dependencies
- ICP tokens for mainnet deployment

## Setup and Installation

### 1. Install DFX (if not already installed)

```bash
# Install dfx
sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"

# Load environment variables
source "$HOME/Library/Application Support/org.dfinity.dfx/env"

# Verify installation
dfx --version
```

### 2. Clone and Setup Project

```bash
git clone <repository-url>
cd zap-x-icp

# Install dependencies
npm install
mops install
```

### 3. Setup DFX Identity

```bash
# Create a new identity (recommended for mainnet)
dfx identity new secure-mainnet --storage-mode=password-protected

# Use the identity
dfx identity use secure-mainnet

# Get your account ID for receiving ICP
dfx ledger account-id
```

## Local Development

### Start Local Development Environment

```bash
# Start local Internet Computer replica
dfx start --clean --background

# Create canisters
dfx canister create --all

# Build the project (generates .did files)
dfx build

# Deploy locally
dfx deploy
```

### Check Local Deployment

```bash
# Check canister status
dfx canister status --all

# Get local canister URLs
dfx canister id saving_manager
# Access at: http://localhost:4943/?canisterId=<canister_id>
```

## Mainnet Deployment

### 1. Top Up ICP Balance

**Get your account ID:**
```bash
dfx ledger account-id
```

**Transfer ICP from exchange/wallet to your account ID**

**Check your balance:**
```bash
dfx ledger balance --network ic
```

### 2. Convert ICP to Cycles

```bash
# Convert ICP to cycles (example: 0.1 ICP)
dfx cycles convert --amount 0.1 --network ic

# Check cycles balance
dfx wallet balance --network ic
```

### 3. Deploy to Mainnet

```bash
# Deploy to Internet Computer mainnet
dfx deploy --network ic

# Check mainnet deployment
dfx canister status --all --network ic

# Get mainnet URLs
dfx canister id saving_manager --network ic
# Access at: https://<canister_id>.icp0.io
```

## API Reference

### Query Methods

- `getCanisterId(): Principal` - Get the canister ID
- `getUserSavings(userId: Text): [Saving]` - Get a user's savings
- `getSaving(savingId: SavingId): ?Saving` - Get a specific saving
- `getSavingTransactions(savingId: SavingId): [Transaction]` - Get transactions for a saving
- `getUserTransactions(userId: Text): [Transaction]` - Get a user's transactions
- `formatIcpAmount(e8s: Nat64): Text` - Format ICP amount for display

### Update Methods

- `startSaving(request: StartSavingRequest): SavingResponse` - Start a new saving
- `topUpSaving(request: TopUpRequest): TransactionResponse` - Top up an existing saving
- `cancelSaving(savingId: SavingId): SavingResponse` - Cancel a saving

### ICRC-1 Standard Methods

- `icrc1_name(): Text` - Get the token name
- `icrc1_symbol(): Text` - Get the token symbol
- `icrc1_decimals(): Nat8` - Get the token decimals
- `icrc1_fee(): Nat` - Get the transaction fee
- `icrc1_transfer(args: TransferArgs): TransferResult` - Transfer tokens (owner only)

## Usage Examples

### Start a New Saving

```bash
dfx canister call saving_manager startSaving '(record { 
  amount = 100_000_000 : nat64; 
  savingName = "Vacation Fund"; 
  deadline = 1714696949000000000 : int; 
  principalId = "YOUR_PRINCIPAL_ID"; 
  totalSaving = 500_000_000 : nat64 
})'
```

### Top Up an Existing Saving

```bash
dfx canister call saving_manager topUpSaving '(record { 
  principalId = "YOUR_PRINCIPAL_ID"; 
  savingId = 0 : nat; 
  amount = 50_000_000 : nat64 
})'
```

### Get User's Savings

```bash
dfx canister call saving_manager getUserSavings '("YOUR_PRINCIPAL_ID")'
```

## Troubleshooting

### Common Issues

**1. dfx command not found**
```bash
# Reload environment
source "$HOME/Library/Application Support/org.dfinity.dfx/env"
```

**2. .did file doesn't exist**
```bash
# Clean build
dfx build --clean
```

**3. Insufficient cycles**
```bash
# Check balance
dfx wallet balance --network ic

# Top up with more ICP
dfx cycles convert --amount 0.1 --network ic
```

**4. Canister not found**
```bash
# Create canisters first
dfx canister create --all
dfx build
dfx deploy
```

## Resources

- [Internet Computer Documentation](https://internetcomputer.org/docs)
- [Motoko Programming Language](https://internetcomputer.org/docs/current/motoko/main/motoko)
- [DFX Command Reference](https://internetcomputer.org/docs/current/references/cli-reference/dfx-parent)
- [ICRC-1 Token Standard](https://github.com/dfinity/ICRC-1)

## Security Notes

- Use password-protected identities for mainnet
- Keep your seed phrase secure
- Test thoroughly on local network before mainnet deployment
- Monitor cycles usage to prevent canister freezing

## License

This project is licensed under the MIT License.
