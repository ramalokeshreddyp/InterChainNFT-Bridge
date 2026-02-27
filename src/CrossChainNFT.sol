// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrossChainNFT
/// @notice ERC-721 token with bridge-controlled minting for cross-chain transfers.
///         Uses burn-and-mint pattern: NFTs are burned on source chain and minted
///         on destination chain by the CCIP bridge contract.
contract CrossChainNFT is ERC721URIStorage, Ownable {
    /// @notice The designated bridge contract allowed to mint tokens
    address public bridge;

    /// @notice Emitted when the bridge address is updated
    event BridgeSet(address indexed oldBridge, address indexed newBridge);

    /// @notice Emitted when an NFT is minted via the bridge
    event NFTMinted(address indexed to, uint256 indexed tokenId, string tokenURI);

    /// @notice Emitted when an NFT is burned
    event NFTBurned(uint256 indexed tokenId);

    /// @notice Restricts function access to the designated bridge contract
    modifier onlyBridge() {
        require(msg.sender == bridge, "Caller is not the bridge");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner
    ) ERC721(name, symbol) {
        _transferOwnership(initialOwner);
    }

    /// @notice Sets the bridge contract address. Only callable by owner.
    /// @param _bridge Address of the CCIPNFTBridge contract
    function setBridge(address _bridge) external onlyOwner {
        require(_bridge != address(0), "CrossChainNFT: invalid bridge address");
        address old = bridge;
        bridge = _bridge;
        emit BridgeSet(old, _bridge);
    }

    /// @notice Mints a new NFT with metadata. Only callable by the bridge.
    /// @param to Recipient address
    /// @param tokenId Token ID to mint
    /// @param tokenURI_ Metadata URI for the token
    function mint(
        address to,
        uint256 tokenId,
        string memory tokenURI_
    ) external onlyBridge {
        require(!_exists(tokenId), "CrossChainNFT: token already exists");
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
        emit NFTMinted(to, tokenId, tokenURI_);
    }

    /// @notice Burns an NFT. Callable by the token owner OR an approved operator (e.g. bridge).
    ///         Uses explicit approval checks compatible with OpenZeppelin v4 and v5.
    /// @param tokenId Token ID to burn
    function burn(uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        require(
            msg.sender == tokenOwner ||
            isApprovedForAll(tokenOwner, msg.sender) ||
            getApproved(tokenId) == msg.sender,
            "ERC721: caller is not token owner or approved"
        );
        _burn(tokenId);
        emit NFTBurned(tokenId);
    }

    /// @notice Mints a token directly to an address. Only callable by owner.
    ///         Used during deployment to pre-mint test NFTs.
    /// @param to Recipient address
    /// @param tokenId Token ID to mint
    /// @param tokenURI_ Metadata URI for the token
    function ownerMint(
        address to,
        uint256 tokenId,
        string memory tokenURI_
    ) external onlyOwner {
        require(!_exists(tokenId), "CrossChainNFT: token already exists");
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
        emit NFTMinted(to, tokenId, tokenURI_);
    }

    /// @notice Checks if a token exists
    /// @param tokenId Token ID to check
    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }

    /// @dev Override required by Solidity for multiple inheritance
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @dev Override required by Solidity for multiple inheritance
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
