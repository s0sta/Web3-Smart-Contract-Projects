// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "./ERC721.sol";
import {Ownable} from "./Ownable.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {MerkleProof} from "./MerkleProof.sol";

/// @title GenesisNFT
/// @notice A professional NFT drop written from scratch: Merkle-tree whitelist phase, public
///         phase, per-wallet caps, owner reserve, ERC-2981 royalties and a reveal flow
///         (placeholder metadata until the owner reveals).
contract GenesisNFT is ERC721, Ownable, ReentrancyGuard {
    /// @notice Mint gates: nothing mints while Closed.
    enum Phase {
        Closed,
        Whitelist,
        Public
    }

    uint256 public constant MAX_SUPPLY = 5000;
    uint256 public constant WHITELIST_PRICE = 0.05 ether;
    uint256 public constant PUBLIC_PRICE = 0.08 ether;
    uint256 public constant WHITELIST_MAX_PER_WALLET = 2;
    uint256 public constant PUBLIC_MAX_PER_WALLET = 10;

    /// @notice Current mint phase.
    Phase public phase;

    /// @notice Merkle root of the whitelist (leaf = keccak256(address)).
    bytes32 public merkleRoot;

    /// @notice How many whitelist tokens each address has minted.
    mapping(address => uint256) public whitelistMinted;

    /// @notice How many public tokens each address has minted.
    mapping(address => uint256) public publicMinted;

    /// @notice Metadata: revealed ? baseURI + id + ".json" : prerevealURI.
    string public baseURI;
    string public prerevealURI;
    bool public revealed;

    /// @notice ERC-2981 royalty configuration (basis points, e.g. 500 = 5%).
    address public royaltyRecipient;
    uint256 public royaltyBps;
    uint256 public constant MAX_ROYALTY_BPS = 1000; // 10%

    event PhaseChanged(Phase newPhase);
    event MerkleRootSet(bytes32 root);
    event Revealed(bool revealed);
    event RoyaltySet(address recipient, uint256 bps);
    event Withdrawn(address indexed to, uint256 amount);

    error PhaseNotActive();
    error IncorrectValue(uint256 sent, uint256 required);
    error ExceedsMaxPerWallet(uint256 minted, uint256 max);
    error InvalidProof();
    error SupplyExceeded(uint256 requested, uint256 available);
    error ZeroQuantity();
    error InvalidRoyalty();
    error EthTransferFailed();

    /// @param initialOwner Owner (phase control, reserve mints, withdrawals, royalties default).
    /// @param name_ Collection name.
    /// @param symbol_ Collection symbol.
    constructor(address initialOwner, string memory name_, string memory symbol_)
        ERC721(name_, symbol_)
        Ownable(initialOwner)
    {
        royaltyRecipient = initialOwner;
        royaltyBps = 500; // 5%
    }

    /* ==================== CONFIGURATION ==================== */

    function setPhase(Phase newPhase) external onlyOwner {
        phase = newPhase;
        emit PhaseChanged(newPhase);
    }

    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootSet(root);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        baseURI = uri;
    }

    function setPrerevealURI(string calldata uri) external onlyOwner {
        prerevealURI = uri;
    }

    function setRevealed(bool revealed_) external onlyOwner {
        revealed = revealed_;
        emit Revealed(revealed_);
    }

    function setRoyalty(address recipient, uint256 bps) external onlyOwner {
        if (recipient == address(0) || bps > MAX_ROYALTY_BPS) revert InvalidRoyalty();
        royaltyRecipient = recipient;
        royaltyBps = bps;
        emit RoyaltySet(recipient, bps);
    }

    /* ==================== MINTING ==================== */

    /// @notice Whitelist mint: proof that `msg.sender` is in the Merkle tree + exact payment.
    function mintWhitelist(bytes32[] calldata proof, uint256 quantity) external payable {
        if (phase != Phase.Whitelist) revert PhaseNotActive();
        if (msg.value != WHITELIST_PRICE * quantity) revert IncorrectValue(msg.value, WHITELIST_PRICE * quantity);
        if (whitelistMinted[msg.sender] + quantity > WHITELIST_MAX_PER_WALLET) {
            revert ExceedsMaxPerWallet(whitelistMinted[msg.sender], WHITELIST_MAX_PER_WALLET);
        }
        if (!MerkleProof.verify(proof, merkleRoot, keccak256(abi.encodePacked(msg.sender)))) {
            revert InvalidProof();
        }
        whitelistMinted[msg.sender] += quantity;
        _mintBatch(msg.sender, quantity);
    }

    /// @notice Public mint at the public price.
    function mintPublic(uint256 quantity) external payable {
        if (phase != Phase.Public) revert PhaseNotActive();
        if (msg.value != PUBLIC_PRICE * quantity) revert IncorrectValue(msg.value, PUBLIC_PRICE * quantity);
        if (publicMinted[msg.sender] + quantity > PUBLIC_MAX_PER_WALLET) {
            revert ExceedsMaxPerWallet(publicMinted[msg.sender], PUBLIC_MAX_PER_WALLET);
        }
        publicMinted[msg.sender] += quantity;
        _mintBatch(msg.sender, quantity);
    }

    /// @notice Owner reserve mint (team, marketing) — still subject to the supply cap.
    function ownerMint(address to, uint256 quantity) external onlyOwner {
        _mintBatch(to, quantity);
    }

    /// @notice Sends the contract's entire ETH balance to the owner.
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        (bool ok,) = payable(owner).call{value: balance}("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawn(owner, balance);
    }

    /* ==================== METADATA & ROYALTIES ==================== */

    /// @notice Placeholder metadata before reveal; `baseURI + tokenId + ".json"` after.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        ownerOf(tokenId); // reverts if the token does not exist
        if (!revealed) return prerevealURI;
        return string(abi.encodePacked(baseURI, _toString(tokenId), ".json"));
    }

    /// @dev ERC-721 + ERC-165 + ERC-2981 interface support.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId); // ERC-2981
    }

    /// @notice ERC-2981: royalty payout for `salePrice`.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 amount) {
        receiver = royaltyRecipient;
        amount = (salePrice * royaltyBps) / 10_000;
    }

    /* ==================== INTERNALS ==================== */

    function _mintBatch(address to, uint256 quantity) internal {
        if (to == address(0)) revert ZeroAddress();
        if (quantity == 0) revert ZeroQuantity();
        if (totalSupply + quantity > MAX_SUPPLY) revert SupplyExceeded(totalSupply + quantity, MAX_SUPPLY);
        for (uint256 i = 0; i < quantity; i++) {
            _mint(to, totalSupply); // sequential ids: 0, 1, 2, …
        }
    }

    /// @dev Minimal uint256 → decimal string (OpenZeppelin Strings.toString equivalent).
    function _toString(uint256 value) internal pure returns (string memory str) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
