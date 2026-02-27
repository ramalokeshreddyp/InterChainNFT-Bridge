<div align="center">

# 🌉 CCIP NFT Bridge

### *Production-Ready Cross-Chain NFT Transfer with Metadata Preservation*

[![Solidity](https://img.shields.io/badge/Solidity-0.8.19-363636?logo=solidity&logoColor=white)](https://soliditylang.org)
[![Node.js](https://img.shields.io/badge/Node.js-18+-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![Foundry](https://img.shields.io/badge/Foundry-latest-FF5733?logo=ethereum&logoColor=white)](https://getfoundry.sh)
[![Chainlink CCIP](https://img.shields.io/badge/Chainlink-CCIP-375BD2?logo=chainlink&logoColor=white)](https://docs.chain.link/ccip)
[![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)](https://docker.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<br/>

> Bridge NFTs across blockchains with **zero duplication** — burn on source, mint on destination.  
> Secured by Chainlink CCIP, the gold standard for cross-chain messaging.

---

[📋 Overview](#-overview) • [🏗️ Architecture](#️-architecture) • [🛠️ Tech Stack](#️-tech-stack) • [📁 Structure](#-folder-structure) • [🚀 Quick Start](#-quick-start) • [💻 CLI Usage](#-cli-usage) • [🧪 Testing](#-testing) • [🔐 Security](#-security)

</div>

---

## 📋 Overview

The **CCIP NFT Bridge** enables secure, trustless transfer of ERC-721 NFTs between **Avalanche Fuji** and **Arbitrum Sepolia** testnets using Chainlink's Cross-Chain Interoperability Protocol (CCIP).

### How It Works

Instead of locking NFTs in a vault (which creates wrapped duplicates), this bridge uses a **burn-and-mint** pattern:

1. **Source Chain** — The NFT is permanently burned. Its metadata (`tokenId`, `tokenURI`) is encoded into a CCIP message.
2. **CCIP Network** — Chainlink's decentralized oracle network securely relays the message.
3. **Destination Chain** — An identical NFT is minted to the receiver with the exact same `tokenId` and `tokenURI`.

This guarantees **no duplicates** and **constant total supply** across both chains.

---

## �️ Architecture

```
Avalanche Fuji                     Arbitrum Sepolia
┌─────────────────────┐            ┌─────────────────────┐
│  CrossChainNFT.sol  │            │  CrossChainNFT.sol  │
│  (ERC-721 Token)    │            │  (ERC-721 Token)    │
└────────┬────────────┘            └────────┬────────────┘
         │                                  │
┌────────▼────────────┐            ┌────────▼────────────┐
│  CCIPNFTBridge.sol  │            │  CCIPNFTBridge.sol  │
│  (CCIP Sender)      │            │  (CCIP Receiver)    │
└────────┬────────────┘            └────────┬────────────┘
         │                                  │
┌────────▼──────────────────────────────────▼────────────┐
│                 Chainlink CCIP Network                  │
│      (Decentralized Oracle Network + Risk Management)   │
└─────────────────────────────────────────────────────────┘
```

---

## 🛠️ Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Smart Contracts** | Solidity `^0.8.19` | ERC-721 NFT + CCIP bridge logic |
| **Cross-Chain** | Chainlink CCIP | Secure cross-chain messaging |
| **Token Standard** | OpenZeppelin ERC-721 + URIStorage | NFT with metadata storage |
| **Access Control** | OpenZeppelin Ownable | Role-based contract administration |
| **Dev Toolchain** | Foundry (forge, cast) | Compilation, testing, deployment |
| **CLI** | Node.js 18 + ethers.js v6 | Transaction submission & logging |
| **ID Generation** | uuid v9 | Unique transfer record identifiers |
| **Containerization** | Docker + Docker Compose | Reproducible CLI environment |
| **Source Networks** | Avalanche Fuji Testnet | Source chain for burns |
| **Destination** | Arbitrum Sepolia Testnet | Destination chain for mints |

---

## 📁 Folder Structure

```
week-13-bonus/
├── 📁 src/                          # Solidity smart contracts
│   ├── CrossChainNFT.sol            # ERC-721 token with bridge-controlled minting
│   └── CCIPNFTBridge.sol            # CCIP send/receive bridge contract
│
├── 📁 test/                         # Foundry unit tests
│   ├── CrossChainNFT.t.sol          # 14 tests: mint, burn, access control
│   └── CCIPNFTBridge.t.sol          # 15 tests: send, receive, mock router
│
├── 📁 script/                       # Foundry deployment scripts
│   └── Deploy.s.sol                 # DeployFuji | DeployArbitrumSepolia | Configure
│
├── 📁 cli/                          # Node.js CLI tool
│   ├── transfer.js                  # Main CLI entrypoint
│   ├── CrossChainNFT.abi.json       # NFT contract ABI
│   └── CCIPNFTBridge.abi.json       # Bridge contract ABI
│
├── 📁 data/
│   └── nft_transfers.json           # Structured transfer records (UUID schema)
│
├── 📁 logs/
│   └── transfers.log                # Operational log file
│
├── foundry.toml                     # Foundry project configuration + remappings
├── deployment.json                  # Deployed contract addresses (both chains)
├── package.json                     # Node.js deps (ethers, uuid) + npm scripts
├── Dockerfile                       # Node 18 Alpine image
├── docker-compose.yml               # CLI service orchestration
├── .env.example                     # Environment variable template
└── README.md                        # This file
```

---

## 🚀 Quick Start

### Prerequisites

| Tool | Version | Install |
|------|---------|---------| 
| Foundry | Latest | `curl -L https://foundry.paradigm.xyz \| bash` |
| Node.js | 18+ | [nodejs.org](https://nodejs.org) |
| Docker | Latest | [docker.com](https://docker.com) |

### Step 1 — Clone & Install Dependencies

```bash
# Install Foundry Solidity libraries
forge install OpenZeppelin/openzeppelin-contracts@v4.9.0 --no-commit
forge install smartcontractkit/chainlink-brownie-contracts@0.8.0 --no-commit
forge install foundry-rs/forge-std --no-commit

# Install Node.js dependencies
npm install
```

### Step 2 — Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your values:

```env
# Your wallet private key (without 0x prefix)
PRIVATE_KEY=your_private_key_here

# RPC URLs
FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
ARBITRUM_SEPOLIA_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc

# Chainlink CCIP — Avalanche Fuji
CCIP_ROUTER_FUJI=0xF694E193200268f9a4868e4Aa017A0118C9a8177
LINK_TOKEN_FUJI=0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846

# Chainlink CCIP — Arbitrum Sepolia
CCIP_ROUTER_ARBITRUM_SEPOLIA=0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165
LINK_TOKEN_ARBITRUM_SEPOLIA=0xb1D4538B4571d411F07960EF2838Ce337FE1E80E
```

### Step 3 — Compile Contracts

```bash
forge build
```

### Step 4 — Deploy Contracts

```bash
# Deploy to Avalanche Fuji
forge script script/Deploy.s.sol:DeployFuji \
  --rpc-url $FUJI_RPC_URL --broadcast --verify -vvvv

# Deploy to Arbitrum Sepolia
forge script script/Deploy.s.sol:DeployArbitrumSepolia \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

### Step 5 — Update `deployment.json`

After deploying, update `deployment.json` with the actual contract addresses:

```json
{
  "avalancheFuji": {
    "nftContractAddress": "0x<YOUR_FUJI_NFT>",
    "bridgeContractAddress": "0x<YOUR_FUJI_BRIDGE>"
  },
  "arbitrumSepolia": {
    "nftContractAddress": "0x<YOUR_ARB_NFT>",
    "bridgeContractAddress": "0x<YOUR_ARB_BRIDGE>"
  }
}
```

### Step 6 — Configure Cross-Chain Trust

```bash
# Set these in .env first:
# FUJI_BRIDGE_ADDRESS=0x...
# ARBITRUM_SEPOLIA_BRIDGE_ADDRESS=0x...

# Configure Fuji bridge to trust Arbitrum bridge
forge script script/Deploy.s.sol:Configure \
  --rpc-url $FUJI_RPC_URL --broadcast -vvvv

# Configure Arbitrum bridge to trust Fuji bridge
forge script script/Deploy.s.sol:Configure \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast -vvvv
```

### Step 7 — Fund with LINK

Get LINK tokens from the [Chainlink Faucet](https://faucets.chain.link/fuji) on both testnets.

---

## 💻 CLI Usage

### Native (Node.js)

```bash
npm run transfer -- \
  --tokenId=1 \
  --from=avalanche-fuji \
  --to=arbitrum-sepolia \
  --receiver=0xYOUR_WALLET_ADDRESS
```

### Via Docker (Recommended)

```bash
# Build and start container
docker-compose up -d --build

# (Optional) copy .env.example to .env before running real transfers
cp .env.example .env

# Execute transfer inside container
docker exec ccip-nft-bridge-cli npm run transfer -- \
  --tokenId=1 \
  --from=avalanche-fuji \
  --to=arbitrum-sepolia \
  --receiver=0xYOUR_WALLET_ADDRESS

# View logs
docker exec ccip-nft-bridge-cli cat logs/transfers.log
```

### CLI Arguments

| Argument | Type | Description | Example |
|----------|------|-------------|---------|
| `--tokenId` | integer | The NFT token ID to transfer | `--tokenId=1` |
| `--from` | string | Source chain name | `--from=avalanche-fuji` |
| `--to` | string | Destination chain name | `--to=arbitrum-sepolia` |
| `--receiver` | address | Recipient wallet on destination | `--receiver=0x1234...` |

---

## 🧪 Testing

### Run All Tests

```bash
forge test -vvvv
```

### Validate Submission Artifacts (Checklist Helper)

```bash
npm run validate:requirements
```

This verifies required files, `.env.example` keys, `deployment.json` schema/address format,
required contract signatures, and the npm transfer script wiring.

### Strict Core-Checklist Verification (1-13)

```bash
npm run verify:checklist
```

This performs strict checks for the full submission checklist, including on-chain bytecode presence
for deployment addresses and runtime readiness warnings for requirements that need a live CCIP transfer.

### Test Coverage

```bash
forge test --gas-report
```

### End-to-End Verification Flow

1. Deploy contracts on both chains and update `deployment.json`.
2. Configure cross-chain trust via `Configure` script on each chain.
3. Ensure test NFT `tokenId=1` exists on Fuji and is owned by deployer.
4. Run transfer command from Docker:

```bash
docker exec ccip-nft-bridge-cli npm run transfer -- \
  --tokenId=1 \
  --from=avalanche-fuji \
  --to=arbitrum-sepolia \
  --receiver=0xYOUR_WALLET_ADDRESS
```

5. Confirm source tx success on Fuji explorer.
6. Confirm source NFT is burned/ownership changed on Fuji.
7. Wait for CCIP finality (usually 5–15 min), then confirm destination owner on Arbitrum Sepolia.
8. Compare `tokenURI(tokenId)` on source (before transfer) and destination (after transfer).
9. Verify both logs and records:
   - `logs/transfers.log` includes start, source tx hash, CCIP message ID
   - `data/nft_transfers.json` contains structured transfer object

---

## 📡 Transfer Record Schema

Each transfer is saved to `data/nft_transfers.json` conforming to this schema:

```json
{
  "transferId": "550e8400-e29b-41d4-a716-446655440000",
  "tokenId": "1",
  "sourceChain": "avalanche-fuji",
  "destinationChain": "arbitrum-sepolia",
  "sender": "0xSenderAddress",
  "receiver": "0xReceiverAddress",
  "ccipMessageId": "0xCCIPMessageId",
  "sourceTxHash": "0xSourceTxHash",
  "destinationTxHash": null,
  "status": "in-progress",
  "metadata": {
    "name": "CrossChain NFT #1",
    "description": "A cross-chain NFT",
    "image": "ipfs://..."
  },
  "timestamp": "2026-02-25T11:00:00.000Z"
}
```

---

## 📊 Pre-Minted Test NFT

| Property | Value |
|----------|-------|
| **Chain** | Avalanche Fuji |
| **Token ID** | `1` |
| **Owner** | Deployer wallet (from `PRIVATE_KEY`) |
| **tokenURI** | `ipfs://bafkreiabc123testcrosschainnftmetadatatokenid1` |

To transfer this NFT:
```bash
npm run transfer -- --tokenId=1 --from=avalanche-fuji --to=arbitrum-sepolia --receiver=0xYOUR_ADDRESS
```

---

## 🔐 Security

| Threat | Mitigation |
|--------|-----------|
| Unauthorized minting | `onlyBridge` modifier — only `CCIPNFTBridge` can call `mint()` |
| Fake CCIP messages | `_ccipReceive` validates `sourceChainSelector` + `sender` address |
| Message replay | `processedMessages` mapping blocks duplicate `messageId`s |
| Double-mint | `nft.exists(tokenId)` check before every mint |
| Re-entrancy | Checks-Effects-Interactions pattern; state written before external calls |
| Unauthorized admin | `Ownable` pattern protects all admin functions |

---

## 🌐 Chain Configuration

| Chain | CCIP Chain Selector | CCIP Router | LINK Token |
|-------|-------------------|-------------|------------|
| Avalanche Fuji | `14767482510784806043` | `0xF694E193...` | `0x0b9d5D91...` |
| Arbitrum Sepolia | `3478487238524512106` | `0x2a9C5afB...` | `0xb1D4538B...` |

---

## 🔍 Monitoring

| Tool | URL |
|------|-----|
| CCIP Explorer | [ccip.chain.link](https://ccip.chain.link) |
| Snowtrace (Fuji) | [testnet.snowtrace.io](https://testnet.snowtrace.io) |
| Arbiscan (Sepolia) | [sepolia.arbiscan.io](https://sepolia.arbiscan.io) |
| Chainlink Faucet | [faucets.chain.link](https://faucets.chain.link) |

---

## 📜 License

MIT © 2026 — Built with ❤️ using [Chainlink CCIP](https://chain.link/cross-chain) + [Foundry](https://getfoundry.sh)

---

<div align="center">

**[⬆ Back to Top](#-ccip-nft-bridge)**

</div>
