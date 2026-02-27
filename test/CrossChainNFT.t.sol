// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CrossChainNFT.sol";

contract CrossChainNFTTest is Test {
    CrossChainNFT public nft;
    address public owner = makeAddr("owner");
    address public bridge = makeAddr("bridge");
    address public user = makeAddr("user");
    address public other = makeAddr("other");

    function setUp() public {
        vm.prank(owner);
        nft = new CrossChainNFT("TestNFT", "TNFT", owner);
    }

    // =========================================================================
    // setBridge
    // =========================================================================

    function test_setBridge_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert();
        nft.setBridge(bridge);
    }

    function test_setBridge_success() public {
        vm.prank(owner);
        nft.setBridge(bridge);
        assertEq(nft.bridge(), bridge);
    }

    function test_setBridge_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit CrossChainNFT.BridgeSet(address(0), bridge);
        nft.setBridge(bridge);
    }

    function test_setBridge_rejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("CrossChainNFT: invalid bridge address");
        nft.setBridge(address(0));
    }

    // =========================================================================
    // mint (bridge-only)
    // =========================================================================

    function test_mint_onlyBridge() public {
        vm.prank(owner);
        nft.setBridge(bridge);

        vm.prank(other);
        vm.expectRevert("Caller is not the bridge");
        nft.mint(user, 1, "ipfs://test");
    }

    function test_mint_success() public {
        vm.prank(owner);
        nft.setBridge(bridge);

        vm.prank(bridge);
        nft.mint(user, 1, "ipfs://test-uri");

        assertEq(nft.ownerOf(1), user);
        assertEq(nft.tokenURI(1), "ipfs://test-uri");
    }

    function test_mint_rejectsDuplicate() public {
        vm.prank(owner);
        nft.setBridge(bridge);

        vm.startPrank(bridge);
        nft.mint(user, 1, "ipfs://test-uri");

        vm.expectRevert("CrossChainNFT: token already exists");
        nft.mint(user, 1, "ipfs://other-uri");
        vm.stopPrank();
    }

    function test_mint_emitsEvent() public {
        vm.prank(owner);
        nft.setBridge(bridge);

        vm.prank(bridge);
        vm.expectEmit(true, true, false, true);
        emit CrossChainNFT.NFTMinted(user, 1, "ipfs://test-uri");
        nft.mint(user, 1, "ipfs://test-uri");
    }

    // =========================================================================
    // ownerMint
    // =========================================================================

    function test_ownerMint_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert();
        nft.ownerMint(user, 1, "ipfs://test");
    }

    function test_ownerMint_success() public {
        vm.prank(owner);
        nft.ownerMint(user, 1, "ipfs://owner-uri");

        assertEq(nft.ownerOf(1), user);
        assertEq(nft.tokenURI(1), "ipfs://owner-uri");
    }

    // =========================================================================
    // burn
    // =========================================================================

    function test_burn_byOwner() public {
        vm.prank(owner);
        nft.ownerMint(user, 1, "ipfs://test");

        vm.prank(user);
        nft.burn(1);

        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_burn_byApprovedOperator() public {
        vm.prank(owner);
        nft.ownerMint(user, 1, "ipfs://test");

        vm.prank(user);
        nft.approve(other, 1);

        vm.prank(other);
        nft.burn(1);

        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_burn_byApprovedForAll() public {
        vm.prank(owner);
        nft.ownerMint(user, 1, "ipfs://test");

        vm.prank(user);
        nft.setApprovalForAll(other, true);

        vm.prank(other);
        nft.burn(1);

        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_burn_revertsUnauthorized() public {
        vm.prank(owner);
        nft.ownerMint(user, 1, "ipfs://test");

        vm.prank(other);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        nft.burn(1);
    }

    // =========================================================================
    // exists
    // =========================================================================

    function test_exists_returnsTrue() public {
        vm.prank(owner);
        nft.ownerMint(user, 42, "ipfs://42");
        assertTrue(nft.exists(42));
    }

    function test_exists_returnsFalse() public view {
        assertFalse(nft.exists(999));
    }

    // =========================================================================
    // ERC-721 Standard Compliance
    // =========================================================================

    function test_supportsERC721() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
    }

    function test_supportsERC721Metadata() public view {
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
    }

    function test_nameAndSymbol() public view {
        assertEq(nft.name(), "TestNFT");
        assertEq(nft.symbol(), "TNFT");
    }
}
