// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./CrossChainNFT.sol";

/// @title CCIPNFTBridge
/// @notice Cross-chain NFT bridge using Chainlink CCIP with burn-and-mint pattern.
///         Source chain: user approves bridge, calls sendNFT → NFT burned → CCIP message sent.
///         Destination chain: CCIP router calls _ccipReceive → NFT minted to receiver.
contract CCIPNFTBridge is CCIPReceiver, IERC721Receiver, Ownable {
    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice The NFT contract this bridge manages
    CrossChainNFT public immutable nft;

    /// @notice CCIP Router client
    IRouterClient public router;

    /// @notice LINK token used for fee payment
    IERC20 public linkToken;

    /// @notice Whitelisted destination chains and their trusted bridge addresses
    mapping(uint64 => address) public destinationBridges;

    /// @notice Track processed CCIP messages to prevent replay
    mapping(bytes32 => bool) public processedMessages;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when an NFT transfer is initiated on the source chain
    event NFTSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiver,
        uint256 tokenId,
        string tokenURI
    );

    /// @notice Emitted when an NFT is received and minted on the destination chain
    event NFTReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed receiver,
        uint256 tokenId,
        string tokenURI
    );

    /// @notice Emitted when a trusted destination bridge is registered
    event DestinationBridgeSet(uint64 indexed chainSelector, address bridgeAddress);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _router,
        address _link,
        address _nft,
        address initialOwner
    ) CCIPReceiver(_router) {
        require(_router != address(0), "CCIPNFTBridge: invalid router");
        require(_link != address(0), "CCIPNFTBridge: invalid LINK token");
        require(_nft != address(0), "CCIPNFTBridge: invalid NFT contract");

        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        nft = CrossChainNFT(_nft);
        _transferOwnership(initialOwner);
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Registers a trusted bridge contract on a destination chain.
    ///         Only messages from the registered address are accepted during receive.
    /// @param chainSelector CCIP chain selector of the destination/source chain
    /// @param bridgeAddress Address of the bridge contract on that chain
    function setDestinationBridge(
        uint64 chainSelector,
        address bridgeAddress
    ) external onlyOwner {
        require(bridgeAddress != address(0), "CCIPNFTBridge: invalid bridge address");
        destinationBridges[chainSelector] = bridgeAddress;
        emit DestinationBridgeSet(chainSelector, bridgeAddress);
    }

    /// @notice Withdraws any LINK tokens held by this contract to the owner.
    function withdrawLink() external onlyOwner {
        uint256 balance = linkToken.balanceOf(address(this));
        require(balance > 0, "CCIPNFTBridge: no LINK to withdraw");
        require(linkToken.transfer(owner(), balance), "CCIPNFTBridge: LINK withdrawal failed");
    }

    // =========================================================================
    // Core Bridge: Send
    // =========================================================================

    /// @notice Initiates a cross-chain NFT transfer (burn on source, mint on destination).
    ///
    ///         Pre-conditions (caller must perform before calling):
    ///           1. nft.approve(bridgeAddress, tokenId)  — allow bridge to burn
    ///           2. linkToken.approve(bridgeAddress, estimateTransferCost(destSelector)) — allow bridge to pull LINK fees
    ///
    /// @param destinationChainSelector CCIP chain selector of the destination chain
    /// @param receiver Address that will receive the minted NFT on the destination chain
    /// @param tokenId  Token ID to transfer (must be owned by msg.sender)
    /// @return messageId CCIP message ID for tracking via https://ccip.chain.link
    function sendNFT(
        uint64 destinationChainSelector,
        address receiver,
        uint256 tokenId
    ) external returns (bytes32 messageId) {
        require(
            destinationBridges[destinationChainSelector] != address(0),
            "CCIPNFTBridge: destination chain not supported"
        );
        require(receiver != address(0), "CCIPNFTBridge: invalid receiver");
        require(
            nft.ownerOf(tokenId) == msg.sender,
            "CCIPNFTBridge: caller is not the token owner"
        );

        // Capture tokenURI BEFORE burning (ERC721URIStorage clears it on _burn)
        string memory tokenURI_ = nft.tokenURI(tokenId);

        // Burn NFT on source chain — requires caller to have approved bridge
        nft.burn(tokenId);

        // Encode payload: (receiver, tokenId, tokenURI)
        bytes memory data = abi.encode(receiver, tokenId, tokenURI_);

        // Build CCIP message
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationBridges[destinationChainSelector]),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            feeToken: address(linkToken)
        });

        // Determine fee
        uint256 fees = router.getFee(destinationChainSelector, ccipMessage);

        // Pull LINK from caller to this contract, then approve router
        require(
            linkToken.transferFrom(msg.sender, address(this), fees),
            "CCIPNFTBridge: LINK transfer failed"
        );
        require(
            linkToken.approve(address(router), fees),
            "CCIPNFTBridge: LINK approval failed"
        );

        // Send CCIP message
        messageId = router.ccipSend(destinationChainSelector, ccipMessage);

        emit NFTSent(messageId, destinationChainSelector, receiver, tokenId, tokenURI_);
    }

    // =========================================================================
    // Core Bridge: Receive
    // =========================================================================

    /// @notice Called by the CCIP Router when a cross-chain message arrives.
    ///         Validates the source, decodes the payload, and mints the NFT.
    /// @param message The CCIP message struct containing chain, sender, and data.
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        // Replay protection: each CCIP messageId is globally unique
        require(
            !processedMessages[message.messageId],
            "CCIPNFTBridge: message already processed"
        );

        // Validate source chain is whitelisted
        address expectedSender = destinationBridges[message.sourceChainSelector];
        require(
            expectedSender != address(0),
            "CCIPNFTBridge: source chain not whitelisted"
        );

        // Validate the actual sender matches registered bridge
        address actualSender = abi.decode(message.sender, (address));
        require(
            actualSender == expectedSender,
            "CCIPNFTBridge: unauthorized sender"
        );

        // Mark processed before external calls (checks-effects-interactions)
        processedMessages[message.messageId] = true;

        // Decode payload
        (address receiver, uint256 tokenId, string memory tokenURI_) =
            abi.decode(message.data, (address, uint256, string));

        // Idempotency guard: skip mint if token already exists on this chain
        if (!nft.exists(tokenId)) {
            nft.mint(receiver, tokenId, tokenURI_);
        }

        emit NFTReceived(
            message.messageId,
            message.sourceChainSelector,
            receiver,
            tokenId,
            tokenURI_
        );
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Estimates the LINK fee required for a cross-chain transfer.
    ///         Call this before sendNFT to know how much LINK to approve.
    /// @param destinationChainSelector CCIP chain selector of the destination
    /// @return fee Estimated fee in LINK (18 decimals)
    function estimateTransferCost(
        uint64 destinationChainSelector
    ) external view returns (uint256 fee) {
        bytes memory data = abi.encode(
            address(0x0000000000000000000000000000000000000001),
            uint256(1),
            "ipfs://QmEstimationPlaceholder"
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationBridges[destinationChainSelector]),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            feeToken: address(linkToken)
        });

        fee = router.getFee(destinationChainSelector, ccipMessage);
    }

    // =========================================================================
    // Required Interface Implementations
    // =========================================================================

    /// @notice Required to receive ERC-721 tokens safely via safeTransferFrom.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
