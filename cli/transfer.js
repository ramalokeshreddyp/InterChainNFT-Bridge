#!/usr/bin/env node
// cli/transfer.js — Chainlink CCIP Cross-Chain NFT Transfer CLI
//
// Usage:
//   npm run transfer -- --tokenId=<id> --from=<chain> --to=<chain> --receiver=<address>
//
// Required .env variables:
//   PRIVATE_KEY, FUJI_RPC_URL, ARBITRUM_SEPOLIA_RPC_URL
'use strict';

// Load .env file if present (for local development; Docker passes env_file)
try { require('dotenv').config(); } catch (_) { /* dotenv optional in Docker */ }

const { ethers } = require('ethers');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');

// ============================================================================
// Paths
// ============================================================================
const ROOT = path.resolve(__dirname, '..');
const DEPLOYMENT_PATH = path.join(ROOT, 'deployment.json');
const TRANSFERS_PATH = path.join(ROOT, 'data', 'nft_transfers.json');
const LOG_PATH = path.join(ROOT, 'logs', 'transfers.log');
const ABI_DIR = __dirname;

// ============================================================================
// Chain Configuration
// ============================================================================
const CHAIN_CONFIG = {
  'avalanche-fuji': {
    rpcEnvKey: 'FUJI_RPC_URL',
    chainSelector: '14767482510784806043',
    networkKey: 'avalancheFuji',
    linkAddress: process.env.LINK_TOKEN_FUJI || '0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846',
  },
  'arbitrum-sepolia': {
    rpcEnvKey: 'ARBITRUM_SEPOLIA_RPC_URL',
    chainSelector: '3478487238524512106',
    networkKey: 'arbitrumSepolia',
    linkAddress: process.env.LINK_TOKEN_ARBITRUM_SEPOLIA || '0xb1D4538B4571d411F07960EF2838Ce337FE1E80E',
  },
};

// ============================================================================
// Minimal ABIs (loaded from JSON files, or fallback inline)
// ============================================================================
function loadAbi(filename) {
  const abiPath = path.join(ABI_DIR, filename);
  if (fs.existsSync(abiPath)) {
    return JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  }
  return null;
}

const NFT_ABI = loadAbi('CrossChainNFT.abi.json') || [
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function tokenURI(uint256 tokenId) view returns (string)',
  'function approve(address to, uint256 tokenId)',
  'function getApproved(uint256 tokenId) view returns (address)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
];

const BRIDGE_ABI = loadAbi('CCIPNFTBridge.abi.json') || [
  'function sendNFT(uint64 destinationChainSelector, address receiver, uint256 tokenId) returns (bytes32)',
  'function estimateTransferCost(uint64 destinationChainSelector) view returns (uint256)',
  'event NFTSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, address indexed receiver, uint256 tokenId, string tokenURI)',
];

const LINK_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
];

// ============================================================================
// Logging Utilities
// ============================================================================
function ensureDir(filePath) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function log(level, message, meta = {}) {
  const ts = new Date().toISOString();
  const metaStr = Object.keys(meta).length ? ' | ' + JSON.stringify(meta) : '';
  const line = `[${ts}] [${level}] ${message}${metaStr}\n`;
  ensureDir(LOG_PATH);
  fs.appendFileSync(LOG_PATH, line, 'utf8');
  const colour = level === 'ERROR' ? '\x1b[31m' : level === 'WARN' ? '\x1b[33m' : '\x1b[36m';
  process.stdout.write(`${colour}${line.trim()}\x1b[0m\n`);
}

const logInfo = (msg, meta) => log('INFO', msg, meta);
const logWarn = (msg, meta) => log('WARN', msg, meta);
const logError = (msg, meta) => log('ERROR', msg, meta);

// ============================================================================
// Argument Parsing
// ============================================================================
function parseArgs() {
  const parsed = {};
  const argv = process.argv.slice(2);
  const positional = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const withEquals = arg.match(/^--([a-zA-Z]+)=(.+)$/);
    if (withEquals) {
      parsed[withEquals[1]] = withEquals[2];
      continue;
    }

    const withSpace = arg.match(/^--([a-zA-Z]+)$/);
    if (withSpace && i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      parsed[withSpace[1]] = argv[i + 1];
      i++;
      continue;
    }

    if (!arg.startsWith('--')) positional.push(arg);
  }

  if (!parsed.tokenId && positional.length >= 1) parsed.tokenId = positional[0];
  if (!parsed.from && positional.length >= 2) parsed.from = positional[1];
  if (!parsed.to && positional.length >= 3) parsed.to = positional[2];
  if (!parsed.receiver && positional.length >= 4) parsed.receiver = positional[3];

  if (Object.values(parsed).some(v => typeof v === 'string' && v.startsWith('--'))) {
    return {};
  }

  return parsed;
}

function validateArgs(args) {
  const missing = ['tokenId', 'from', 'to', 'receiver'].filter(k => !args[k]);
  if (missing.length) {
    throw new Error(
      `Missing required arguments: ${missing.join(', ')}\n` +
      'Usage: npm run transfer -- --tokenId=<id> --from=<chain> --to=<chain> --receiver=<address>\n' +
      `Valid chains: ${Object.keys(CHAIN_CONFIG).join(', ')}`
    );
  }
  if (!CHAIN_CONFIG[args.from]) throw new Error(`Unknown source chain: "${args.from}". Valid: ${Object.keys(CHAIN_CONFIG).join(', ')}`);
  if (!CHAIN_CONFIG[args.to]) throw new Error(`Unknown destination chain: "${args.to}". Valid: ${Object.keys(CHAIN_CONFIG).join(', ')}`);
  if (!ethers.isAddress(args.receiver)) throw new Error(`Invalid receiver address: "${args.receiver}"`);
  if (args.receiver.toLowerCase() === ethers.ZeroAddress.toLowerCase()) {
    throw new Error('Receiver cannot be zero address');
  }
  if (isNaN(parseInt(args.tokenId))) throw new Error(`Invalid tokenId: "${args.tokenId}"`);
}

// ============================================================================
// JSON Transfer Records
// ============================================================================
function loadTransfers() {
  ensureDir(TRANSFERS_PATH);
  if (!fs.existsSync(TRANSFERS_PATH)) return [];
  try {
    const raw = fs.readFileSync(TRANSFERS_PATH, 'utf8').trim();
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

function saveTransfers(records) {
  fs.writeFileSync(TRANSFERS_PATH, JSON.stringify(records, null, 2), 'utf8');
}

function upsertTransfer(record) {
  const records = loadTransfers();
  const idx = records.findIndex(r => r.transferId === record.transferId);
  if (idx >= 0) records[idx] = { ...records[idx], ...record };
  else records.push(record);
  saveTransfers(records);
}

// ============================================================================
// Main
// ============================================================================
async function main() {
  logInfo('=== CCIP NFT Bridge CLI Started ===');

  // 1. Parse & validate arguments
  const args = parseArgs();
  try {
    validateArgs(args);
  } catch (err) {
    logError('Argument validation failed', { error: err.message });
    console.error('\n\x1b[31mError:\x1b[0m', err.message);
    process.exit(1);
  }

  const { tokenId: tokenIdStr, from: fromChain, to: toChain, receiver } = args;
  const tokenId = BigInt(tokenIdStr);
  const fromConfig = CHAIN_CONFIG[fromChain];
  const toConfig = CHAIN_CONFIG[toChain];

  logInfo('Transfer parameters parsed', { tokenId: tokenIdStr, from: fromChain, to: toChain, receiver });

  // 2. Load deployment.json
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    logError('deployment.json not found — please deploy contracts first');
    process.exit(1);
  }

  let deployment;
  try {
    deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_PATH, 'utf8'));
  } catch (err) {
    logError('Failed to parse deployment.json', { error: err.message });
    process.exit(1);
  }

  const sourceDeploy = deployment[fromConfig.networkKey];
  const destDeploy = deployment[toConfig.networkKey];

  if (!sourceDeploy?.nftContractAddress || !sourceDeploy?.bridgeContractAddress) {
    logError('Missing source chain addresses in deployment.json', { chain: fromChain });
    process.exit(1);
  }
  if (!destDeploy?.nftContractAddress) {
    logError('Missing destination chain addresses in deployment.json', { chain: toChain });
    process.exit(1);
  }

  // 3. Connect to RPC
  const rpcUrl = process.env[fromConfig.rpcEnvKey];
  const privateKey = process.env.PRIVATE_KEY;

  if (!rpcUrl) {
    logError(`${fromConfig.rpcEnvKey} is not set in environment`);
    process.exit(1);
  }
  if (!privateKey) {
    logError('PRIVATE_KEY is not set in environment');
    process.exit(1);
  }

  const normalizedPk = privateKey.startsWith('0x') ? privateKey : '0x' + privateKey;
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalizedPk)) {
    logError('PRIVATE_KEY format is invalid. Expected 64 hex chars (with or without 0x).');
    process.exit(1);
  }

  let provider, signer;
  try {
    provider = new ethers.JsonRpcProvider(rpcUrl);
    signer = new ethers.Wallet(normalizedPk, provider);
    // Verify connectivity
    await provider.getBlockNumber();
    logInfo('Connected to network', { chain: fromChain });
  } catch (err) {
    logError('Failed to connect to RPC endpoint', { rpcUrl: rpcUrl.slice(0, 40), error: err.message });
    process.exit(1);
  }

  const signerAddress = await signer.getAddress();
  logInfo('Signer ready', { address: signerAddress });

  // 3.5 Validate deployment addresses have contract bytecode on source chain
  try {
    const sourceNftCode = await provider.getCode(sourceDeploy.nftContractAddress);
    if (!sourceNftCode || sourceNftCode === '0x') {
      logError('Source NFT address has no deployed contract code', {
        chain: fromChain,
        nftContractAddress: sourceDeploy.nftContractAddress,
      });
      process.exit(1);
    }

    const sourceBridgeCode = await provider.getCode(sourceDeploy.bridgeContractAddress);
    if (!sourceBridgeCode || sourceBridgeCode === '0x') {
      logError('Source bridge address has no deployed contract code', {
        chain: fromChain,
        bridgeContractAddress: sourceDeploy.bridgeContractAddress,
      });
      process.exit(1);
    }
  } catch (err) {
    logError('Failed to validate source deployment addresses', { error: err.message });
    process.exit(1);
  }

  // 4. Instantiate contracts
  const nftContract = new ethers.Contract(sourceDeploy.nftContractAddress, NFT_ABI, signer);
  const bridgeContract = new ethers.Contract(sourceDeploy.bridgeContractAddress, BRIDGE_ABI, signer);
  const linkContract = new ethers.Contract(fromConfig.linkAddress, LINK_ABI, signer);

  // 5. Verify NFT ownership
  let tokenURIValue = '';
  try {
    const nftOwner = await nftContract.ownerOf(tokenId);
    if (nftOwner.toLowerCase() !== signerAddress.toLowerCase()) {
      logError('Token not owned by signer', { tokenId: tokenIdStr, owner: nftOwner, signer: signerAddress });
      console.error(`\x1b[31mError:\x1b[0m Token #${tokenIdStr} is owned by ${nftOwner}, not by signer ${signerAddress}`);
      process.exit(1);
    }
    tokenURIValue = await nftContract.tokenURI(tokenId);
    logInfo('NFT ownership verified', { tokenId: tokenIdStr, tokenURI: tokenURIValue });
  } catch (err) {
    logError('Failed to verify NFT', { tokenId: tokenIdStr, error: err.message });
    console.error(`\x1b[31mError:\x1b[0m Cannot verify NFT #${tokenIdStr}: ${err.message}`);
    process.exit(1);
  }

  // 6. Estimate CCIP fee
  let ccipFee;
  try {
    ccipFee = await bridgeContract.estimateTransferCost(BigInt(toConfig.chainSelector));
    logInfo('CCIP fee estimated', { fee: ethers.formatEther(ccipFee) + ' LINK' });
    console.log(`\n💎 CCIP fee: ${ethers.formatEther(ccipFee)} LINK`);
  } catch (err) {
    logError('Failed to estimate CCIP fee', { error: err.message });
    console.error(`\x1b[31mError:\x1b[0m Could not estimate fee: ${err.message}`);
    process.exit(1);
  }

  // 7. Check LINK balance
  const linkBal = await linkContract.balanceOf(signerAddress);
  logInfo('LINK balance', { balance: ethers.formatEther(linkBal), required: ethers.formatEther(ccipFee) });
  if (linkBal < ccipFee) {
    logError('Insufficient LINK balance', {
      have: ethers.formatEther(linkBal) + ' LINK',
      need: ethers.formatEther(ccipFee) + ' LINK',
    });
    console.error(`\x1b[31mError:\x1b[0m Not enough LINK. Have ${ethers.formatEther(linkBal)}, need ${ethers.formatEther(ccipFee)}.`);
    process.exit(1);
  }

  // 8. Approve LINK spend by bridge (if not already approved)
  try {
    const linkAllowance = await linkContract.allowance(signerAddress, sourceDeploy.bridgeContractAddress);
    if (linkAllowance < ccipFee) {
      logInfo('Approving LINK spend for bridge...');
      const tx = await linkContract.approve(sourceDeploy.bridgeContractAddress, ccipFee);
      await tx.wait(1);
      logInfo('LINK approved', { txHash: tx.hash });
    } else {
      logInfo('LINK allowance sufficient — skipping approval');
    }
  } catch (err) {
    logError('LINK approval failed', { error: err.message });
    process.exit(1);
  }

  // 9. Approve bridge to burn the NFT (if not already approved)
  try {
    const approved = await nftContract.getApproved(tokenId);
    if (approved.toLowerCase() !== sourceDeploy.bridgeContractAddress.toLowerCase()) {
      logInfo('Approving bridge to burn NFT...');
      const tx = await nftContract.approve(sourceDeploy.bridgeContractAddress, tokenId);
      await tx.wait(1);
      logInfo('NFT approved for bridge burn', { txHash: tx.hash });
    } else {
      logInfo('NFT already approved for bridge — skipping');
    }
  } catch (err) {
    logError('NFT approval failed', { error: err.message });
    process.exit(1);
  }

  // 10. Create initial transfer record
  const transferId = uuidv4();
  const transferRecord = {
    transferId,
    tokenId: tokenIdStr,
    sourceChain: fromChain,
    destinationChain: toChain,
    sender: signerAddress,
    receiver,
    ccipMessageId: null,
    sourceTxHash: null,
    destinationTxHash: null,
    status: 'initiated',
    metadata: {
      name: '',
      description: '',
      image: tokenURIValue,
    },
    timestamp: new Date().toISOString(),
  };

  // Try to parse tokenURI as JSON metadata
  if (tokenURIValue.startsWith('{')) {
    try {
      const meta = JSON.parse(tokenURIValue);
      transferRecord.metadata = {
        name: meta.name || '',
        description: meta.description || '',
        image: meta.image || tokenURIValue,
      };
    } catch { /* keep raw URI as image field */ }
  }

  upsertTransfer(transferRecord);
  logInfo('Transfer record created', { transferId, status: 'initiated' });

  // 11. Execute sendNFT
  console.log('\n🚀 Sending NFT cross-chain via Chainlink CCIP...');
  logInfo('Submitting sendNFT transaction', { tokenId: tokenIdStr, from: fromChain, to: toChain, receiver });

  let sourceTxHash, ccipMessageId;
  try {
    const tx = await bridgeContract.sendNFT(
      BigInt(toConfig.chainSelector),
      receiver,
      tokenId
    );

    logInfo('Transaction submitted — waiting for confirmation', { txHash: tx.hash });
    console.log(`📤 Tx submitted: ${tx.hash}`);

    const receipt = await tx.wait(1);
    sourceTxHash = receipt.hash;

    logInfo('Transaction confirmed', {
      txHash: sourceTxHash,
      blockNumber: receipt.blockNumber.toString(),
      gasUsed: receipt.gasUsed.toString(),
    });
    console.log(`✅ Tx confirmed in block ${receipt.blockNumber}`);

    // Extract CCIP message ID from NFTSent event
    const iface = new ethers.Interface(BRIDGE_ABI);
    for (const receiptLog of receipt.logs) {
      try {
        const parsed = iface.parseLog({ topics: receiptLog.topics, data: receiptLog.data });
        if (parsed && parsed.name === 'NFTSent') {
          ccipMessageId = parsed.args.messageId;
          logInfo('CCIP message ID captured', { ccipMessageId });
          console.log(`🔗 CCIP Message ID: ${ccipMessageId}`);
          break;
        }
      } catch { /* skip non-matching logs */ }
    }

    if (!ccipMessageId) {
      logWarn('Could not parse CCIP message ID from logs — using tx hash as fallback');
      ccipMessageId = sourceTxHash;
    }

  } catch (err) {
    logError('sendNFT transaction failed', { error: err.message });
    upsertTransfer({ ...transferRecord, status: 'failed' });
    console.error(`\x1b[31mError:\x1b[0m Transaction failed: ${err.message}`);
    process.exit(1);
  }

  // 12. Update transfer record
  const updatedRecord = {
    ...transferRecord,
    ccipMessageId,
    sourceTxHash,
    status: 'in-progress',
  };
  upsertTransfer(updatedRecord);
  logInfo('Transfer record updated', { transferId, status: 'in-progress', sourceTxHash });

  // 13. Final summary
  logInfo('=== Transfer initiated successfully ===', {
    transferId, tokenId: tokenIdStr, sourceTxHash, ccipMessageId,
    from: fromChain, to: toChain, receiver,
  });

  console.log('\n✨ ════════════════════════════════════════');
  console.log('   Cross-chain transfer initiated!');
  console.log('   ════════════════════════════════════════');
  console.log(`   Transfer ID:    ${transferId}`);
  console.log(`   Token ID:       ${tokenIdStr}`);
  console.log(`   From:           ${fromChain}`);
  console.log(`   To:             ${toChain}`);
  console.log(`   Receiver:       ${receiver}`);
  console.log(`   Source Tx:      ${sourceTxHash}`);
  console.log(`   CCIP Msg ID:    ${ccipMessageId}`);
  console.log(`\n   🔍 Track progress:`);
  console.log(`   https://ccip.chain.link/msg/${ccipMessageId}`);
  console.log('\n   ⏱  CCIP typically finalizes in 5–15 minutes.');
  console.log('   📊 Record saved to: data/nft_transfers.json');
  console.log('   📝 Logs written to: logs/transfers.log\n');
}

main().catch(err => {
  logError('Unexpected fatal error', { error: err.message, stack: err.stack });
  console.error('\x1b[31mFatal:\x1b[0m', err.message);
  process.exit(1);
});
