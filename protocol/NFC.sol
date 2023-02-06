// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
/**
 *  @title Non-Fungible Cowboys
 *  Copyright @ Wildlands
 *  App: https://wildlands.me
 */
contract NFC is  Context, AccessControlEnumerable, ERC721Enumerable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdTracker;
    string private _baseTokenURI;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    mapping (uint256 => bool) public nftExists;
    
    constructor (address _admin) ERC721 ("Non Fungible Cowboys", "NFC"){
        // set base URI
         _baseTokenURI = "https://nft.wildlands.me/nfcs/meta/";
        // set admin role
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        // set minter role
        _setupRole(MINTER_ROLE,  _msgSender());
    }
    
    function mint(address to) public virtual {
        require(hasRole(MINTER_ROLE, _msgSender()), "NonFungibleCowboys: must have minter role to mint");
        _mint(to, _tokenIdTracker.current());
        _tokenIdTracker.increment();
    }

    function auto_generate() external {

    }
    
    /**
     * @dev Base URI for computing {tokenURI}. If set, the resulting URI for each
     * token will be the concatenation of the `baseURI` and the `tokenId`. Empty
     * by default, can be overriden in child contracts.
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    function setBaseURI(string memory _uri) public {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "NonFungibleCowboys: must have admin role to modify");
        // set new base token uri
        _baseTokenURI = _uri;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlEnumerable, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        string memory uri = super.tokenURI(tokenId);
        string memory fileType = ".json";
        // add file type to uri
        return string(abi.encodePacked(uri, fileType));
    }
    
}