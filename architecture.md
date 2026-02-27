# 🏛️ Architecture — InterChain NFT Bridge

> **Chainlink CCIP Cross-Chain NFT Transfer System**  
> Detailed system architecture, design decisions, and component interactions.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Core Design Pattern: Burn-and-Mint](#2-core-design-pattern-burn-and-mint)
3. [Smart Contract Architecture](#3-smart-contract-architecture)
4. [CCIP Message Lifecycle](#4-ccip-message-lifecycle)
5. [Security Architecture](#5-security-architecture)
6. [CLI Architecture](#6-cli-architecture)
7. [Deployment Topology](#7-deployment-topology)
8. [Data Flow Diagrams](#8-data-flow-diagrams)
9. [State Machine](#9-state-machine)
10. [Network Configuration](#10-network-configuration)

---

## 1. System Overview

The InterChain NFT Bridge is a **two-contract + one-CLI** system that bridges ERC-721 NFTs between L1/L2 chains using Chainlink CCIP as the messaging layer.

```mermaid
C4Context
    title System Context — InterChain NFT Bridge

    Person(user, "NFT Owner", "Wants to move their NFT\nto another blockchain")
    Person(receiver, "Receiver", "Receives the NFT\non destination chain")

    System(bridge, "InterChain NFT Bridge", "Burn-and-mint bridge\nusing Chainlink CCIP")
    System_Ext(ccip, "Chainlink CCIP Network", "Decentralized cross-chain\nmessaging protocol")
    System_Ext(fuji, "Avalanche Fuji", "Source blockchain\n(Testnet)")
    System_Ext(arb, "Arbitrum Sepolia", "Destination blockchain\n(Testnet)")

    Rel(user, bridge, "Initiates transfer via CLI")
    Rel(bridge, fuji, "Burns NFT, sends CCIP msg")
    Rel(bridge, ccip, "Routes message cross-chain")
    Rel(ccip, arb, "Delivers message to destination")
    Rel(arb, receiver, "NFT minted to receiver")
```

### Architectural Principles

| Principle | Implementation |
|-----------|---------------|
| **Separation of Concerns** | `CrossChainNFT` = token logic; `CCIPNFTBridge` = messaging logic |
| **Least Privilege** | Bridge can only mint; owner can only configure; users can only burn their own NFTs |
| **Idempotency** | `exists(tokenId)` prevents double-minting even if message replayed |
| **Fail-Safe** | All state changes before external calls (Checks-Effects-Interactions) |
| **Auditability** | Every action emits an indexed event; CLI writes structured logs |

---

## 2. Core Design Pattern: Burn-and-Mint

### Why Burn-and-Mint over Lock-and-Wrap?

```mermaid
graph LR
    subgraph "❌ Lock-and-Wrap (Avoided)"
        A1[Original NFT] -->|locked in vault| B1[Vault Contract]
        B1 -->|creates| C1[Wrapped NFT copy]
        C1 --> D1[Supply = 2 tokens exist!]
    end

    subgraph "✅ Burn-and-Mint (Used)"
        A2[Original NFT] -->|permanently burned| B2[🔥 0x000...dead]
        B2 -->|CCIP message| C2[New NFT minted]
        C2 --> D2[Supply = 1 token always]
    end

    style D1 fill:#ff4444,color:#fff
    style D2 fill:#44aa44,color:#fff
```

**Advantages of Burn-and-Mint:**
- ✅ Constant supply across all chains — no inflation
- ✅ No vault management risk
- ✅ Simpler mental model for users
- ✅ Identical `tokenId` and `tokenURI` on both chains
- ✅ No wrapped-token fragmentation

---

## 3. Smart Contract Architecture

### 3.1 CrossChainNFT.sol

```mermaid
classDiagram
    class ERC721URIStorage {
        <<OpenZeppelin>>
        +_setTokenURI(tokenId, uri)
        +tokenURI(tokenId) string
    }

    class Ownable {
        <<OpenZeppelin>>
        -address _owner
        +owner() address
        +onlyOwner modifier
        +transferOwnership(address)
    }

    class CrossChainNFT {
        +address bridge
        +BridgeSet event
        +NFTMinted event
        +NFTBurned event
        ─────────────────
        +constructor(name, symbol, owner)
        +setBridge(address) onlyOwner
        +mint(address, uint256, string) onlyBridge
        +burn(uint256) callerOwnerOrApproved
        +ownerMint(address, uint256, string) onlyOwner
        +exists(uint256) bool
        +tokenURI(uint256) string override
        +supportsInterface(bytes4) bool override
    }

    CrossChainNFT --|> ERC721URIStorage
    CrossChainNFT --|> Ownable

    note for CrossChainNFT "Key Invariant:\nOnly bridge can mint\nOnly owner/approved can burn\nTokenId uniqueness enforced"
```

**Access Control Matrix — CrossChainNFT:**

| Function | Owner | Bridge | Token Holder | Anyone |
|----------|-------|--------|-------------|--------|
| `setBridge` | ✅ | ❌ | ❌ | ❌ |
| `mint` | ❌ | ✅ | ❌ | ❌ |
| `ownerMint` | ✅ | ❌ | ❌ | ❌ |
| `burn` | ❌ | ❌ | ✅ | ❌ |
| `tokenURI` | ✅ | ✅ | ✅ | ✅ |

### 3.2 CCIPNFTBridge.sol

```mermaid
classDiagram
    class CCIPReceiver {
        <<Chainlink Abstract>>
        -address i_ccipRouter
        +ccipReceive(Any2EVMMessage) external
        +_ccipReceive(Any2EVMMessage) internal*
        +supportsInterface(bytes4) bool
    }

    class Ownable {
        <<OpenZeppelin>>
    }

    class IERC721Receiver {
        <<Interface>>
        +onERC721Received() bytes4
    }

    class CCIPNFTBridge {
        +CrossChainNFT nft  [immutable]
        +IRouterClient router
        +IERC20 linkToken
        +mapping~uint64→address~ destinationBridges
        +mapping~bytes32→bool~ processedMessages
        ─────────────────────────────
        +NFTSent event
        +NFTReceived event
        +DestinationBridgeSet event
        ─────────────────────────────
        +constructor(router, link, nft, owner)
        +sendNFT(chainSelector, receiver, tokenId) bytes32
        +_ccipReceive(Any2EVMMessage) internal
        +estimateTransferCost(chainSelector) uint256
        +setDestinationBridge(chainSelector, addr) onlyOwner
        +withdrawLink() onlyOwner
        +onERC721Received() bytes4
    }

    CCIPNFTBridge --|> CCIPReceiver
    CCIPNFTBridge --|> Ownable
    CCIPNFTBridge ..|> IERC721Receiver
    CCIPNFTBridge --> CrossChainNFT : manages
```

---

## 4. CCIP Message Lifecycle

```mermaid
sequenceDiagram
    participant CLI as CLI Tool
    participant NFT_F as CrossChainNFT (Fuji)
    participant BRIDGE_F as CCIPNFTBridge (Fuji)
    participant LINK_F as LINK Token (Fuji)
    participant ROUTER_F as CCIP Router (Fuji)
    participant DON as Chainlink DON
    participant ROUTER_A as CCIP Router (Arb)
    participant BRIDGE_A as CCIPNFTBridge (Arb)
    participant NFT_A as CrossChainNFT (Arb)

    Note over CLI,NFT_F: === Pre-flight Checks ===
    CLI->>NFT_F: ownerOf(tokenId) → verify == signer
    CLI->>BRIDGE_F: estimateTransferCost(destSelector)
    BRIDGE_F-->>CLI: fee (in LINK wei)

    Note over CLI,LINK_F: === Approvals ===
    CLI->>LINK_F: approve(bridge, fee)
    CLI->>NFT_F: approve(bridge, tokenId)

    Note over CLI,BRIDGE_F: === Source Chain TX ===
    CLI->>BRIDGE_F: sendNFT(destSelector, receiver, tokenId)
    BRIDGE_F->>NFT_F: ownerOf(tokenId) → verify
    BRIDGE_F->>NFT_F: tokenURI(tokenId) → capture
    BRIDGE_F->>NFT_F: burn(tokenId) 🔥
    BRIDGE_F->>LINK_F: transferFrom(caller, bridge, fee)
    BRIDGE_F->>LINK_F: approve(router, fee)
    BRIDGE_F->>ROUTER_F: ccipSend(destSelector, {receiver, data, feeToken})
    ROUTER_F-->>BRIDGE_F: messageId (bytes32)
    BRIDGE_F-->>CLI: messageId
    Note over CLI: emit NFTSent event ✓

    Note over DON: === Cross-Chain Relay (5-15 min) ===
    ROUTER_F->>DON: Broadcast message
    DON->>DON: DON consensus + risk check
    DON->>ROUTER_A: Deliver message

    Note over ROUTER_A,NFT_A: === Destination Chain TX ===
    ROUTER_A->>BRIDGE_A: ccipReceive(message)
    BRIDGE_A->>BRIDGE_A: Check processedMessages[msgId]
    BRIDGE_A->>BRIDGE_A: Validate sourceChainSelector
    BRIDGE_A->>BRIDGE_A: Validate sender == registeredBridge
    BRIDGE_A->>BRIDGE_A: processedMessages[msgId] = true
    BRIDGE_A->>NFT_A: exists(tokenId) → false
    BRIDGE_A->>NFT_A: mint(receiver, tokenId, tokenURI) ✨
    Note over BRIDGE_A: emit NFTReceived event ✓
```

### CCIP Message Payload Structure

```mermaid
graph TD
    subgraph "EVM2AnyMessage (Source → CCIP Router)"
        R[receiver: abi.encode(destBridgeAddress)]
        D[data: abi.encode(receiverAddr, tokenId, tokenURI)]
        TA[tokenAmounts: empty array]
        EA[extraArgs: gasLimit=300_000]
        FT[feeToken: LINK address]
    end

    subgraph "Any2EVMMessage (CCIP Router → _ccipReceive)"
        MI[messageId: bytes32]
        SC[sourceChainSelector: uint64]
        SE[sender: abi.encode(srcBridgeAddress)]
        DA[data: abi.encode(receiver, tokenId, tokenURI)]
    end
```

---

## 5. Security Architecture

### 5.1 Threat Model and Mitigations

```mermaid
mindmap
    root((Security))
        Access Control
            onlyBridge on mint
            onlyOwner on admin
            Owner-or-approved on burn
        Message Validation
            Source chain whitelist
            Sender address matching
            processedMessages replay guard
        Asset Safety
            Burn before send
            Idempotent mint
            exists() check
        Code Safety
            CEI pattern
            Immutable router ref
            No delegatecall
        Operational
            withdrawLink escape hatch
            Events for auditability
            Indexed events for filtering
```

### 5.2 Attack Vectors & Defenses

| Attack Vector | Risk | Defense |
|--------------|------|---------|
| Unauthorized mint | Attacker calls `mint()` directly | `onlyBridge` modifier — only `CCIPNFTBridge` address can call |
| Forged CCIP message | Attacker sends fake message to `_ccipReceive` | Only CCIP Router (`i_ccipRouter`) can call `ccipReceive` |
| Wrong source chain | Message from attacker-controlled chain | `destinationBridges[sourceChainSelector]` must be set |
| Impersonating bridge | Attacker deploys fake bridge | `abi.decode(message.sender)` must match registered bridge address |
| Message replay | Re-deliver same CCIP message | `processedMessages[messageId] = true` before mint |
| Double-mint | Token already exists on dest chain | `nft.exists(tokenId)` check — skip mint if already present |
| Re-entrancy | Malicious NFT contract callbacks | State updated **before** external calls (CEI) |
| Admin takeover | Attacker calls `setDestinationBridge` | `Ownable.onlyOwner` restricts to deployer |

### 5.3 Trust Boundary Diagram

```mermaid
graph TB
    subgraph "Trusted Zone — Fuji"
        OWN[Contract Owner]
        CCIP_R_F[CCIP Router - Fuji\nTrusted by Chainlink]
        BRIDGE_F[CCIPNFTBridge\nFuji]
        NFT_F[CrossChainNFT\nFuji]
    end

    subgraph "Trustless Zone — CCIP Network"
        DON2[Chainlink DON\nDecentralized]
    end

    subgraph "Trusted Zone — Arb"
        BRIDGE_A[CCIPNFTBridge\nArbitrumSepolia]
        NFT_A[CrossChainNFT\nArbitrumSepolia]
        CCIP_R_A[CCIP Router - Arb\nTrusted by Chainlink]
    end

    OWN -->|setDestinationBridge| BRIDGE_F
    OWN -->|setDestinationBridge| BRIDGE_A

    BRIDGE_F -->|only bridge can mint| NFT_F
    CCIP_R_F -->|only router calls ccipReceive| BRIDGE_F

    CCIP_R_A -->|only router calls ccipReceive| BRIDGE_A
    BRIDGE_A -->|only bridge can mint| NFT_A

    BRIDGE_F <-.->|CCIP msg| DON2
    DON2 <-.->|CCIP msg| BRIDGE_A

    style OWN fill:#ffd700
    style DON2 fill:#375BD2,color:#fff
```

---

## 6. CLI Architecture

```mermaid
flowchart TB
    subgraph CLI ["cli/transfer.js"]
        direction TB
        ARGS[Argument Parser\n--tokenId --from --to --receiver]
        DEPLOY[Deployment Loader\ndeployment.json]
        PROVIDER[RPC Provider\nethers.JsonRpcProvider]
        SIGNER[Wallet Signer\nethers.Wallet + PRIVATE_KEY]
        CONTRACTS[Contract Instances\nNFT + Bridge + LINK]
        CHECKS[Pre-flight Checks\nownerOf + balance]
        APPROVALS[Approval Transactions\nLINK + NFT approve]
        RECORD1[Transfer Record v1\nstatus: initiated]
        SENDTX[sendNFT Transaction\nbridge.sendNFT]
        EVENTS[Event Parser\nNFTSent → messageId]
        RECORD2[Transfer Record v2\nstatus: in-progress]
        LOGGER[File Logger\nlogs/transfers.log]
        JSON[JSON Writer\ndata/nft_transfers.json]
    end

    ARGS --> DEPLOY
    DEPLOY --> PROVIDER
    PROVIDER --> SIGNER
    SIGNER --> CONTRACTS
    CONTRACTS --> CHECKS
    CHECKS --> APPROVALS
    APPROVALS --> RECORD1
    RECORD1 --> SENDTX
    SENDTX --> EVENTS
    EVENTS --> RECORD2
    RECORD2 --> LOGGER
    LOGGER --> JSON
```

### CLI Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| **Argument Parser** | Parse `--flag=value` and `--flag value` syntax; validate chain names and address format |
| **Deployment Loader** | Read `deployment.json`; validate contract addresses exist on-chain |
| **RPC Provider** | Create `ethers.JsonRpcProvider`; verify connectivity via `getBlockNumber()` |
| **Contract Instances** | Instantiate `CrossChainNFT`, `CCIPNFTBridge`, LINK ERC-20 with ABIs from `cli/*.abi.json` |
| **Pre-flight Checks** | Verify NFT ownership, LINK balance, and source contract bytecode |
| **Approval Manager** | Check existing allowances; skip if sufficient; submit approve tx if needed |
| **Transfer Executor** | Call `sendNFT`; wait for confirmation; extract CCIP `messageId` from event logs |
| **Record Manager** | Create UUID-tagged record; upsert into `data/nft_transfers.json` |
| **File Logger** | Timestamped append-only log to `logs/transfers.log` with level prefixes |

---

## 7. Deployment Topology

```mermaid
graph TB
    subgraph "Local / Developer Machine"
        DEV[Developer]
        CLI_LOCAL[Node.js CLI\nlocal or Docker]
        FOUNDRY[Foundry\nforge script]
    end

    subgraph "Testnet Infrastructure"
        subgraph "Avalanche Fuji C-Chain"
            NFT_FUJI[CrossChainNFT\nERC-721]
            BRIDGE_FUJI[CCIPNFTBridge\nSender/Receiver]
            ROUTER_FUJI[CCIP Router\n0xF694E193...]
            LINK_FUJI[LINK Token\n0x0b9d5D91...]
        end

        subgraph "Arbitrum Sepolia"
            NFT_ARB[CrossChainNFT\nERC-721]
            BRIDGE_ARB[CCIPNFTBridge\nSender/Receiver]
            ROUTER_ARB[CCIP Router\n0x2a9C5afB...]
            LINK_ARB[LINK Token\n0xb1D4538B...]
        end

        subgraph "Chainlink CCIP"
            DON3[Oracle Network]
        end
    end

    DEV -->|forge script DeployFuji| BRIDGE_FUJI
    DEV -->|forge script DeployArbitrumSepolia| BRIDGE_ARB
    DEV -->|forge script Configure| BRIDGE_FUJI
    DEV -->|forge script Configure| BRIDGE_ARB

    BRIDGE_FUJI --> NFT_FUJI
    BRIDGE_ARB --> NFT_ARB

    CLI_LOCAL -->|sendNFT| BRIDGE_FUJI
    BRIDGE_FUJI -->|ccipSend| ROUTER_FUJI
    ROUTER_FUJI --> DON3
    DON3 --> ROUTER_ARB
    ROUTER_ARB -->|_ccipReceive| BRIDGE_ARB
    BRIDGE_ARB -->|mint| NFT_ARB
```

### Deployment Sequence

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant F as Fuji Network
    participant A as Arbitrum Sepolia

    Dev->>F: DeployFuji script
    F-->>Dev: nftFuji address + bridgeFuji address
    Note over Dev,F: Pre-mints tokenId=1 to deployer

    Dev->>A: DeployArbitrumSepolia script
    A-->>Dev: nftArb address + bridgeArb address

    Dev->>Dev: Update deployment.json with both addresses

    Dev->>F: Configure script (chainId=43113)
    Note over F: bridgeFuji.setDestinationBridge(ARB_SELECTOR, bridgeArb)

    Dev->>A: Configure script (chainId=421614)
    Note over A: bridgeArb.setDestinationBridge(FUJI_SELECTOR, bridgeFuji)

    Note over Dev: System ready for cross-chain transfers ✅
```

---

## 8. Data Flow Diagrams

### 8.1 Token Metadata Preservation

```mermaid
flowchart LR
    subgraph Fuji ["Source: Avalanche Fuji"]
        T1[tokenId = 1\ntokenURI = ipfs://Qm...]
        B1[🔥 Burned\nownerOf reverts]
    end

    subgraph Payload ["CCIP Message Data Field"]
        P[abi.encode\nreceiver address\ntokenId = 1\ntokenURI = ipfs://Qm...]
    end

    subgraph Arb ["Destination: Arbitrum Sepolia"]
        T2[tokenId = 1\ntokenURI = ipfs://Qm...\nowner = receiver]
    end

    T1 -->|captured before burn| Payload
    T1 --> B1
    Payload -->|decoded in _ccipReceive| T2

    style T1 fill:#ff9944
    style B1 fill:#ff4444,color:#fff
    style T2 fill:#44cc44
```

### 8.2 Fee Flow

```mermaid
flowchart LR
    USER[User Wallet\nLINK Balance]
    BRIDGE_C[CCIPNFTBridge\nContract]
    ROUTER_C[CCIP Router\nContract]
    DON_C[Chainlink DON\nExecutor]

    USER -->|transferFrom: fee LINK| BRIDGE_C
    BRIDGE_C -->|approve: fee LINK| ROUTER_C
    ROUTER_C -->|ccipSend triggers| ROUTER_C
    ROUTER_C -->|pays gas on dest chain from| DON_C

    style USER fill:#ffd700
    style DON_C fill:#375BD2,color:#fff
```

---

## 9. State Machine

### NFT Transfer State Machine

```mermaid
stateDiagram-v2
    [*] --> Owned: ownerMint / bridge.mint

    Owned --> Approved: nft.approve(bridge, tokenId)
    Approved --> Burning: bridge.sendNFT called

    Burning --> BurnedOnSource: _burn(tokenId) ✔
    BurnedOnSource --> CCIPInFlight: ccipSend ✔\n(messageId emitted)

    CCIPInFlight --> ReceivedOnDest: CCIP finality\n(5-15 min)
    ReceivedOnDest --> MintedOnDest: _ccipReceive\nnft.mint(receiver, tokenId, uri)
    MintedOnDest --> [*]: ownerOf(tokenId) = receiver ✅

    CCIPInFlight --> Failed: CCIP failure\n(check ccip.chain.link)
    Failed --> [*]: Manual intervention required

    note right of BurnedOnSource: NFT no longer exists\non source chain
    note right of MintedOnDest: Identical tokenId + tokenURI\non destination chain
```

### CLI Transfer Record Status Machine

```mermaid
stateDiagram-v2
    [*] --> initiated: record created\nbefore sendNFT tx

    initiated --> in_progress: source tx confirmed\nccipMessageId captured

    in_progress --> completed: destination ownerOf\nverified (manual update)

    initiated --> failed: sendNFT tx reverted
    in_progress --> failed: CCIP delivery failed

    completed --> [*]
    failed --> [*]
```

---

## 10. Network Configuration

### Supported Networks

| Parameter | Avalanche Fuji | Arbitrum Sepolia |
|-----------|---------------|-----------------|
| **Chain ID** | `43113` | `421614` |
| **CCIP Selector** | `14767482510784806043` | `3478487238524512106` |
| **CCIP Router** | `0xF694E193200268f9a4868e4Aa017A0118C9a8177` | `0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165` |
| **LINK Token** | `0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846` | `0xb1D4538B4571d411F07960EF2838Ce337FE1E80E` |
| **RPC (public)** | `https://api.avax-test.network/ext/bc/C/rpc` | `https://sepolia-rollup.arbitrum.io/rpc` |
| **Explorer** | [testnet.snowtrace.io](https://testnet.snowtrace.io) | [sepolia.arbiscan.io](https://sepolia.arbiscan.io) |
| **Native Token** | AVAX | ETH |
| **Role in Bridge** | Source + Destination | Source + Destination |

---

*Architecture document for InterChain NFT Bridge v1.0.0 — Built with Chainlink CCIP + Foundry*
