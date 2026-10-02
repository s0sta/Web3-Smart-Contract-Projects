// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Callback interface every safe-transfer destination contract must implement.
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title ERC721
/// @notice A compact ERC-721 implementation written from scratch: ownership, approvals,
///         operator approvals and safe transfers with the receiver check.
/// @dev Implemented by hand on purpose (see README). OpenZeppelin's version is the
///      production-grade equivalent.
abstract contract ERC721 {
    /// @notice Collection name and symbol.
    string public name;
    string public symbol;

    /// @notice Number of tokens in existence.
    uint256 public totalSupply;

    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;

    /// @notice `bytes4(keccak256("Transfer(address,address,uint256)"))`
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    /// @notice `bytes4(keccak256("Approval(address,address,uint256)"))`
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    /// @notice `bytes4(keccak256("ApprovalForAll(address,address,bool)"))`
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error InvalidTokenId();
    error NotOwnerOrApproved();
    error NotTokenOwner();
    error TransferToZeroAddress();
    error InvalidOwnerAddress();
    error UnauthorizedOperator();
    error UnsafeRecipient();

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    /* ==================== ERC-165 ==================== */

    /// @dev ERC-165 introspection. Override in derived contracts and call `super`.
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165 itself
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f; // ERC-721 Metadata
    }

    /* ==================== QUERIES ==================== */

    function balanceOf(address owner) public view returns (uint256) {
        if (owner == address(0)) revert InvalidOwnerAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert InvalidTokenId();
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        if (_owners[tokenId] == address(0)) revert InvalidTokenId();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    /* ==================== APPROVALS ==================== */

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) revert NotOwnerOrApproved();
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert InvalidOwnerAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /* ==================== TRANSFERS ==================== */

    function transferFrom(address from, address to, uint256 tokenId) external {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotOwnerOrApproved();
        _transfer(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }

    /// @notice Metadata URI for a token. Must be implemented by the collection.
    function tokenURI(uint256 tokenId) public view virtual returns (string memory);

    /* ==================== INTERNALS ==================== */

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert InvalidOwnerAddress();
        if (_owners[tokenId] != address(0)) revert InvalidTokenId();
        _owners[tokenId] = to;
        _balances[to]++;
        totalSupply++;
        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (_owners[tokenId] != from) revert NotTokenOwner();
        if (to == address(0)) revert TransferToZeroAddress();
        // Clear approvals, then move.
        delete _tokenApprovals[tokenId];
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = _owners[tokenId];
        return spender == owner || spender == _tokenApprovals[tokenId]
            || _operatorApprovals[owner][spender];
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) internal {
        if (to.code.length == 0) return;
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            if (retval != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }
}
