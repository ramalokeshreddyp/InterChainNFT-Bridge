// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/CrossChainNFT.sol";
import "../src/CCIPNFTBridge.sol";

/// @title DeployFuji
/// @notice Deploys CrossChainNFT + CCIPNFTBridge to Avalanche Fuji testnet.
///         Pre-mints tokenId=1 to the deployer as the test asset.
///
/// Run:
///   forge script script/Deploy.s.sol:DeployFuji \
///     --rpc-url $FUJI_RPC_URL --broadcast --verify -vvvv
contract DeployFuji is Script {
    // Chainlink CCIP — Avalanche Fuji
    // Ref: https://docs.chain.link/ccip/supported-networks/testnet
    address constant CCIP_ROUTER_FUJI  = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;
    address constant LINK_TOKEN_FUJI   = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;

    // Arbitrum Sepolia chain selector (destination for Fuji → Arbitrum transfers)
    uint64 constant ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;

    // Pre-minted test NFT details (documented in README.md)
    uint256 constant TEST_TOKEN_ID  = 1;
    string  constant TEST_TOKEN_URI = "ipfs://bafkreiabc123testcrosschainnftmetadatatokenid1";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying to Avalanche Fuji ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NFT contract
        CrossChainNFT nft = new CrossChainNFT("CrossChain NFT", "CCNFT", deployer);
        console.log("CrossChainNFT deployed:", address(nft));

        // 2. Deploy bridge contract
        CCIPNFTBridge bridge = new CCIPNFTBridge(
            CCIP_ROUTER_FUJI,
            LINK_TOKEN_FUJI,
            address(nft),
            deployer
        );
        console.log("CCIPNFTBridge deployed:", address(bridge));

        // 3. Authorize bridge to mint on the NFT contract
        nft.setBridge(address(bridge));
        console.log("Bridge authorized as minter");

        // 4. Pre-mint test NFT (tokenId=1) to deployer using ownerMint
        //    (ownerMint bypasses the bridge restriction for initial setup)
        nft.ownerMint(deployer, TEST_TOKEN_ID, TEST_TOKEN_URI);
        console.log("Pre-minted tokenId=1 to deployer:", deployer);

        vm.stopBroadcast();

        console.log("\n=== POST-DEPLOYMENT STEPS ===");
        console.log("1. Deploy to Arbitrum Sepolia via DeployArbitrumSepolia");
        console.log("2. Update deployment.json with both contract addresses");
        console.log("3. Call: bridge.setDestinationBridge(ARBITRUM_SEPOLIA_SELECTOR, <ArbitrumBridge>)");
        console.log("4. Fund deployer with LINK on Fuji (>= 1 LINK for bridge fees)");
        console.log("5. Approvals before transfer:");
        console.log("   nft.approve(<bridge>, 1)");
        console.log("   linkToken.approve(<bridge>, estimateTransferCost(ARBITRUM_SEPOLIA_SELECTOR))");
    }
}

/// @title DeployArbitrumSepolia
/// @notice Deploys CrossChainNFT + CCIPNFTBridge to Arbitrum Sepolia testnet.
///
/// Run:
///   forge script script/Deploy.s.sol:DeployArbitrumSepolia \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify -vvvv
contract DeployArbitrumSepolia is Script {
    // Chainlink CCIP — Arbitrum Sepolia
    address constant CCIP_ROUTER_ARBITRUM_SEPOLIA = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address constant LINK_TOKEN_ARBITRUM_SEPOLIA  = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;

    // Avalanche Fuji chain selector (source for Fuji → Arbitrum messages)
    uint64 constant FUJI_SELECTOR = 14767482510784806043;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying to Arbitrum Sepolia ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NFT contract
        CrossChainNFT nft = new CrossChainNFT("CrossChain NFT", "CCNFT", deployer);
        console.log("CrossChainNFT deployed:", address(nft));

        // 2. Deploy bridge contract
        CCIPNFTBridge bridge = new CCIPNFTBridge(
            CCIP_ROUTER_ARBITRUM_SEPOLIA,
            LINK_TOKEN_ARBITRUM_SEPOLIA,
            address(nft),
            deployer
        );
        console.log("CCIPNFTBridge deployed:", address(bridge));

        // 3. Authorize bridge to mint
        nft.setBridge(address(bridge));
        console.log("Bridge authorized as minter");

        vm.stopBroadcast();

        console.log("\n=== POST-DEPLOYMENT STEPS ===");
        console.log("1. Call: bridge.setDestinationBridge(FUJI_SELECTOR, <FujiBridgeAddress>)");
        console.log("2. Update deployment.json with this bridge address");
    }
}

/// @title Configure
/// @notice Cross-chain configuration: register each bridge as the trusted sender on the other chain.
///         Run AFTER both DeployFuji and DeployArbitrumSepolia, with addresses in env.
///
/// Required env:
///   FUJI_BRIDGE_ADDRESS, ARBITRUM_SEPOLIA_BRIDGE_ADDRESS
///
/// Run:
///   forge script script/Deploy.s.sol:Configure \
///     --rpc-url $FUJI_RPC_URL --broadcast -vvvv
///   forge script script/Deploy.s.sol:Configure \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast -vvvv
contract Configure is Script {
    uint64 constant FUJI_SELECTOR             = 14767482510784806043;
    uint64 constant ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address fujiBridge = vm.envAddress("FUJI_BRIDGE_ADDRESS");
        address arbBridge  = vm.envAddress("ARBITRUM_SEPOLIA_BRIDGE_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        if (block.chainid == 43113) {
            CCIPNFTBridge(fujiBridge).setDestinationBridge(ARBITRUM_SEPOLIA_SELECTOR, arbBridge);
            console.log("Configured Fuji bridge to trust Arbitrum bridge:", arbBridge);
        } else if (block.chainid == 421614) {
            CCIPNFTBridge(arbBridge).setDestinationBridge(FUJI_SELECTOR, fujiBridge);
            console.log("Configured Arbitrum bridge to trust Fuji bridge:", fujiBridge);
        } else {
            revert("Configure: unsupported chain for this script");
        }

        vm.stopBroadcast();
    }
}
