// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import "../src/CCIPNFTBridge.sol";
import "../src/CrossChainNFT.sol";

// ===========================================================================
// Mock Contracts
// ===========================================================================

/// @notice Minimal mock CCIP Router
contract MockCCIPRouter {
    uint256 public constant MOCK_FEE = 0.1 ether; // 0.1 LINK
    bytes32 public constant MOCK_MESSAGE_ID = keccak256("mock-ccip-message");

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure returns (uint256) {
        return MOCK_FEE;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure returns (bytes32) {
        return MOCK_MESSAGE_ID;
    }
}

/// @notice Minimal mock ERC-20 token (for LINK)
contract MockLinkToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ===========================================================================
// Test Harness — exposes _ccipReceive
// ===========================================================================

/// @notice Wraps CCIPNFTBridge to expose internal _ccipReceive for unit testing
contract BridgeHarness is CCIPNFTBridge {
    constructor(address _router, address _link, address _nft, address _owner)
        CCIPNFTBridge(_router, _link, _nft, _owner)
    {}

    function exposed_ccipReceive(Client.Any2EVMMessage memory message) external {
        _ccipReceive(message);
    }
}

// ===========================================================================
// Tests
// ===========================================================================

contract CCIPNFTBridgeTest is Test {
    MockCCIPRouter public mockRouter;
    MockLinkToken public mockLink;
    CrossChainNFT public nft;
    BridgeHarness public bridge;

    address public owner = makeAddr("owner");
    address public sender = makeAddr("sender");
    address public receiver = makeAddr("receiver");
    address public remoteBridge = makeAddr("remoteBridge");

    // Testnet chain selectors (arbitrary values for unit tests)
    uint64 constant DEST_CHAIN = 12532609583862916517;
    uint64 constant SRC_CHAIN  = 14767482510784806043;

    function setUp() public {
        mockRouter = new MockCCIPRouter();
        mockLink   = new MockLinkToken();

        vm.startPrank(owner);
        nft    = new CrossChainNFT("BridgeNFT", "BNFT", owner);
        bridge = new BridgeHarness(
            address(mockRouter),
            address(mockLink),
            address(nft),
            owner
        );
        nft.setBridge(address(bridge));
        bridge.setDestinationBridge(DEST_CHAIN, remoteBridge);
        bridge.setDestinationBridge(SRC_CHAIN, remoteBridge);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _setupForSend(uint256 tokenId) internal {
        // Mint token to sender via owner
        vm.prank(owner);
        nft.ownerMint(sender, tokenId, "ipfs://test-metadata");

        // Give sender LINK
        mockLink.mint(sender, 10 ether);

        vm.startPrank(sender);
        // Approve bridge to burn token
        nft.approve(address(bridge), tokenId);
        // Approve bridge to pull LINK
        mockLink.approve(address(bridge), 10 ether);
        vm.stopPrank();
    }

    function _buildCCIPMessage(
        bytes32 msgId,
        uint64 srcChain,
        address srcBridge,
        address _receiver,
        uint256 tokenId,
        string memory tokenURI_
    ) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: srcChain,
            sender: abi.encode(srcBridge),
            data: abi.encode(_receiver, tokenId, tokenURI_),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    // =========================================================================
    // Constructor Tests
    // =========================================================================

    function test_constructor_setsState() public view {
        assertEq(address(bridge.nft()), address(nft));
        assertEq(address(bridge.linkToken()), address(mockLink));
        assertEq(address(bridge.router()), address(mockRouter));
    }

    // =========================================================================
    // Admin Tests
    // =========================================================================

    function test_setDestinationBridge_onlyOwner() public {
        vm.prank(sender);
        vm.expectRevert();
        bridge.setDestinationBridge(DEST_CHAIN, remoteBridge);
    }

    function test_setDestinationBridge_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert("CCIPNFTBridge: invalid bridge address");
        bridge.setDestinationBridge(DEST_CHAIN, address(0));
    }

    function test_withdrawLink_onlyOwner() public {
        vm.prank(sender);
        vm.expectRevert();
        bridge.withdrawLink();
    }

    function test_withdrawLink_success() public {
        mockLink.mint(address(bridge), 5 ether);
        vm.prank(owner);
        bridge.withdrawLink();
        assertEq(mockLink.balanceOf(owner), 5 ether);
        assertEq(mockLink.balanceOf(address(bridge)), 0);
    }

    // =========================================================================
    // sendNFT Tests
    // =========================================================================

    function test_sendNFT_burnsNFT() public {
        _setupForSend(1);

        vm.prank(sender);
        bridge.sendNFT(DEST_CHAIN, receiver, 1);

        // Token should be burned
        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_sendNFT_returnsCCIPMessageId() public {
        _setupForSend(1);

        vm.prank(sender);
        bytes32 msgId = bridge.sendNFT(DEST_CHAIN, receiver, 1);

        assertEq(msgId, mockRouter.MOCK_MESSAGE_ID());
    }

    function test_sendNFT_revertsNotOwner() public {
        _setupForSend(1);

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("CCIPNFTBridge: caller is not the token owner");
        bridge.sendNFT(DEST_CHAIN, receiver, 1);
    }

    function test_sendNFT_revertsUnsupportedChain() public {
        _setupForSend(1);

        vm.prank(sender);
        vm.expectRevert("CCIPNFTBridge: destination chain not supported");
        bridge.sendNFT(99999, receiver, 1);
    }

    function test_sendNFT_revertsZeroReceiver() public {
        _setupForSend(1);

        vm.prank(sender);
        vm.expectRevert("CCIPNFTBridge: invalid receiver");
        bridge.sendNFT(DEST_CHAIN, address(0), 1);
    }

    function test_sendNFT_emitsNFTSentEvent() public {
        _setupForSend(1);

        // Use startPrank/stopPrank so the sender context isn't consumed by
        // the intermediate mockRouter.MOCK_MESSAGE_ID() static call in vm.expectEmit setup
        vm.startPrank(sender);
        // Specify emitter so Foundry doesn't match NFTBurned from the NFT contract
        vm.expectEmit(true, true, true, false, address(bridge));
        emit CCIPNFTBridge.NFTSent(
            mockRouter.MOCK_MESSAGE_ID(),
            DEST_CHAIN,
            receiver,
            1,
            "ipfs://test-metadata"
        );
        bridge.sendNFT(DEST_CHAIN, receiver, 1);
        vm.stopPrank();
    }

    // =========================================================================
    // _ccipReceive Tests
    // =========================================================================

    function test_ccipReceive_mintsNFTToReceiver() public {
        Client.Any2EVMMessage memory message = _buildCCIPMessage(
            keccak256("msg-1"), SRC_CHAIN, remoteBridge, receiver, 42, "ipfs://meta-42"
        );

        bridge.exposed_ccipReceive(message);

        assertEq(nft.ownerOf(42), receiver);
        assertEq(nft.tokenURI(42), "ipfs://meta-42");
    }

    function test_ccipReceive_idempotent_skipsMintIfExists() public {
        // First delivery
        Client.Any2EVMMessage memory msg1 = _buildCCIPMessage(
            keccak256("msg-1"), SRC_CHAIN, remoteBridge, receiver, 43, "ipfs://meta-43"
        );
        bridge.exposed_ccipReceive(msg1);
        assertEq(nft.ownerOf(43), receiver);

        // Second delivery with different message ID but same tokenId — should not revert
        Client.Any2EVMMessage memory msg2 = _buildCCIPMessage(
            keccak256("msg-2"), SRC_CHAIN, remoteBridge, makeAddr("other"), 43, "ipfs://meta-43"
        );
        bridge.exposed_ccipReceive(msg2);

        // Original owner unchanged
        assertEq(nft.ownerOf(43), receiver);
    }

    function test_ccipReceive_rejectsReplayedMessageId() public {
        Client.Any2EVMMessage memory message = _buildCCIPMessage(
            keccak256("msg-replay"), SRC_CHAIN, remoteBridge, receiver, 50, "ipfs://uri"
        );
        bridge.exposed_ccipReceive(message);

        vm.expectRevert("CCIPNFTBridge: message already processed");
        bridge.exposed_ccipReceive(message);
    }

    function test_ccipReceive_rejectsUnauthorizedSender() public {
        Client.Any2EVMMessage memory message = _buildCCIPMessage(
            keccak256("bad-sender"), SRC_CHAIN, makeAddr("evilBridge"), receiver, 99, "ipfs://evil"
        );

        vm.expectRevert("CCIPNFTBridge: unauthorized sender");
        bridge.exposed_ccipReceive(message);
    }

    function test_ccipReceive_rejectsUnknownSourceChain() public {
        Client.Any2EVMMessage memory message = _buildCCIPMessage(
            keccak256("bad-chain"), 99999, remoteBridge, receiver, 77, "ipfs://uri"
        );

        vm.expectRevert("CCIPNFTBridge: source chain not whitelisted");
        bridge.exposed_ccipReceive(message);
    }

    function test_ccipReceive_emitsNFTReceivedEvent() public {
        bytes32 testMsgId = keccak256("emit-test");
        Client.Any2EVMMessage memory message = _buildCCIPMessage(
            testMsgId, SRC_CHAIN, remoteBridge, receiver, 55, "ipfs://emit-uri"
        );

        vm.expectEmit(true, true, true, false);
        emit CCIPNFTBridge.NFTReceived(testMsgId, SRC_CHAIN, receiver, 55, "ipfs://emit-uri");
        bridge.exposed_ccipReceive(message);
    }

    // =========================================================================
    // estimateTransferCost
    // =========================================================================

    function test_estimateTransferCost_returnsMockFee() public view {
        uint256 fee = bridge.estimateTransferCost(DEST_CHAIN);
        assertEq(fee, mockRouter.MOCK_FEE());
    }

    // =========================================================================
    // onERC721Received
    // =========================================================================

    function test_onERC721Received_returnsSelector() public view {
        bytes4 sel = bridge.onERC721Received(address(0), address(0), 0, "");
        assertEq(sel, bridge.onERC721Received.selector);
    }
}
