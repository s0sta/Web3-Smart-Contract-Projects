// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisNFT} from "../src/GenesisNFT.sol";
import {Ownable} from "../src/Ownable.sol";
import {IERC721Receiver} from "../src/ERC721.sol";

/// A contract that correctly implements the ERC-721 receiver callback.
contract NFTReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// A contract that does NOT implement the callback — safe transfers must reject it.
contract NonReceiver {}

contract GenesisNFTTest is Test {
    GenesisNFT nft;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        nft = new GenesisNFT(owner, "Genesis", "GEN");
        vm.startPrank(owner);
        nft.setPrerevealURI("ipfs://prereveal");
        nft.setBaseURI("ipfs://base/");
        vm.stopPrank();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(mallory, 10 ether);
    }

    /* ==================== MERKLE HELPERS (mirror of off-chain tooling) ==================== */

    function _leaf(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _computeRoot(address[] memory accounts) internal pure returns (bytes32) {
        bytes32[] memory layer = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) layer[i] = _leaf(accounts[i]);
        while (layer.length > 1) {
            bytes32[] memory next = new bytes32[]((layer.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                bytes32 right = (i * 2 + 1 < layer.length) ? layer[i * 2 + 1] : layer[i * 2];
                next[i] = _hashPair(layer[i * 2], right);
            }
            layer = next;
        }
        return layer[0];
    }

    function _computeProof(address[] memory accounts, uint256 index) internal pure returns (bytes32[] memory proof) {
        uint256 levels = 0;
        uint256 n = accounts.length;
        while (n > 1) {
            levels++;
            n = (n + 1) / 2;
        }
        proof = new bytes32[](levels);
        bytes32[] memory layer = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) layer[i] = _leaf(accounts[i]);
        uint256 idx = index;
        uint256 level = 0;
        while (layer.length > 1) {
            uint256 siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1;
            proof[level] = siblingIdx < layer.length ? layer[siblingIdx] : layer[idx];
            bytes32[] memory next = new bytes32[]((layer.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                bytes32 right = (i * 2 + 1 < layer.length) ? layer[i * 2 + 1] : layer[i * 2];
                next[i] = _hashPair(layer[i * 2], right);
            }
            layer = next;
            idx /= 2;
            level++;
        }
    }

    function _configureWhitelist() internal returns (address[] memory accounts) {
        accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        vm.prank(owner);
        nft.setMerkleRoot(_computeRoot(accounts));
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Whitelist);
    }

    /* ==================== METADATA / INTROSPECTION ==================== */

    function test_Metadata() public view {
        assertEq(nft.name(), "Genesis");
        assertEq(nft.symbol(), "GEN");
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.MAX_SUPPLY(), 5000);
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    /* ==================== OWNER RESERVE ==================== */

    function test_OwnerMint_MintsSequentialIds() public {
        vm.prank(owner);
        nft.ownerMint(alice, 3);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
    }

    function test_OwnerMint_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        nft.ownerMint(alice, 1);
    }

    function test_OwnerMint_RespectsSupplyCap() public {
        uint256 maxSupply = nft.MAX_SUPPLY();
        vm.prank(owner);
        nft.ownerMint(alice, maxSupply);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.SupplyExceeded.selector, 5001, 5000));
        nft.ownerMint(alice, 1);
    }

    function test_OwnerMint_ZeroQuantityReverts() public {
        vm.prank(owner);
        vm.expectRevert(GenesisNFT.ZeroQuantity.selector);
        nft.ownerMint(alice, 0);
    }

    /* ==================== WHITELIST MINT ==================== */

    function test_MintWhitelist_ValidProofMints() public {
        address[] memory accounts = _configureWhitelist();
        bytes32[] memory proof = _computeProof(accounts, 0); // alice

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 0);
        vm.prank(alice);
        nft.mintWhitelist{value: 0.05 ether}(proof, 1);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.whitelistMinted(alice), 1);
    }

    function test_MintWhitelist_EnforcesPerWalletCap() public {
        address[] memory accounts = _configureWhitelist();
        bytes32[] memory proof = _computeProof(accounts, 0);
        vm.prank(alice);
        nft.mintWhitelist{value: 0.1 ether}(proof, 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.ExceedsMaxPerWallet.selector, 2, 2));
        nft.mintWhitelist{value: 0.05 ether}(proof, 1);
    }

    function test_MintWhitelist_InvalidProofReverts() public {
        _configureWhitelist();
        bytes32[] memory empty;
        vm.prank(mallory); // not in the tree
        vm.expectRevert(GenesisNFT.InvalidProof.selector);
        nft.mintWhitelist{value: 0.05 ether}(empty, 1);

        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        bytes32[] memory proof = _computeProof(accounts, 1); // bob's proof, used by alice
        vm.prank(alice);
        vm.expectRevert(GenesisNFT.InvalidProof.selector);
        nft.mintWhitelist{value: 0.05 ether}(proof, 1);
    }

    function test_MintWhitelist_WrongValueReverts() public {
        address[] memory accounts = _configureWhitelist();
        bytes32[] memory proof = _computeProof(accounts, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.IncorrectValue.selector, 0.04 ether, 0.05 ether));
        nft.mintWhitelist{value: 0.04 ether}(proof, 1);
    }

    function test_MintWhitelist_WrongPhaseReverts() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        vm.prank(owner);
        nft.setMerkleRoot(_computeRoot(accounts));
        // phase is still Closed
        bytes32[] memory proof = _computeProof(accounts, 0);
        vm.prank(alice);
        vm.expectRevert(GenesisNFT.PhaseNotActive.selector);
        nft.mintWhitelist{value: 0.05 ether}(proof, 1);
    }

    /* ==================== PUBLIC MINT ==================== */

    function test_MintPublic_HappyPath() public {
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 0);
        vm.prank(alice);
        nft.mintPublic{value: 0.16 ether}(2);
        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.publicMinted(alice), 2);
    }

    function test_MintPublic_WrongValueReverts() public {
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.IncorrectValue.selector, 0.08 ether, 0.16 ether));
        nft.mintPublic{value: 0.08 ether}(2);
    }

    function test_MintPublic_PerWalletCap() public {
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.prank(alice);
        nft.mintPublic{value: 0.8 ether}(10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.ExceedsMaxPerWallet.selector, 10, 10));
        nft.mintPublic{value: 0.08 ether}(1);
    }

    function test_MintPublic_WrongPhaseReverts() public {
        vm.prank(alice);
        vm.expectRevert(GenesisNFT.PhaseNotActive.selector);
        nft.mintPublic{value: 0.08 ether}(1);
    }

    function test_MintPublic_RespectsSupplyCap() public {
        uint256 maxSupply = nft.MAX_SUPPLY();
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.prank(owner);
        nft.ownerMint(alice, maxSupply); // fill the collection
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GenesisNFT.SupplyExceeded.selector, 5001, 5000));
        nft.mintPublic{value: 0.08 ether}(1);
    }

    /* ==================== PHASES ==================== */

    function test_SetPhase_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        nft.setPhase(GenesisNFT.Phase.Public);
    }

    function test_SetPhase_ClosedBlocksBothMints() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        vm.prank(owner);
        nft.setMerkleRoot(_computeRoot(accounts));
        bytes32[] memory proof = _computeProof(accounts, 0);
        vm.prank(alice);
        vm.expectRevert(GenesisNFT.PhaseNotActive.selector);
        nft.mintWhitelist{value: 0.05 ether}(proof, 1);
        vm.prank(alice);
        vm.expectRevert(GenesisNFT.PhaseNotActive.selector);
        nft.mintPublic{value: 0.08 ether}(1);
    }

    /* ==================== ROYALTIES ==================== */

    function test_RoyaltyInfo_Math() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(0, 1 ether);
        assertEq(receiver, owner); // defaults to deployer
        assertEq(amount, 0.05 ether); // 500 bps = 5%
    }

    function test_SetRoyalty_UpdatesAndCaps() public {
        vm.prank(owner);
        nft.setRoyalty(carol, 750);
        (address receiver, uint256 amount) = nft.royaltyInfo(0, 1 ether);
        assertEq(receiver, carol);
        assertEq(amount, 0.075 ether);

        vm.prank(owner);
        vm.expectRevert(GenesisNFT.InvalidRoyalty.selector);
        nft.setRoyalty(carol, 1001);
        vm.prank(owner);
        vm.expectRevert(GenesisNFT.InvalidRoyalty.selector);
        nft.setRoyalty(address(0), 500);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        nft.setRoyalty(carol, 500);
    }

    /* ==================== METADATA / REVEAL ==================== */

    function test_TokenURI_PrerevealBeforeReveal() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        assertEq(nft.tokenURI(0), "ipfs://prereveal");
    }

    function test_TokenURI_RevealedUsesBaseURI() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(owner);
        nft.setRevealed(true);
        assertEq(nft.tokenURI(0), "ipfs://base/0.json");
    }

    function test_TokenURI_NonexistentTokenReverts() public {
        vm.expectRevert();
        nft.tokenURI(42);
    }

    function test_SetRevealed_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        nft.setRevealed(true);
    }

    /* ==================== ERC-721 TRANSFERS ==================== */

    function test_ApproveAndTransferFrom() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(alice);
        nft.approve(bob, 0);
        assertEq(nft.getApproved(0), bob);
        vm.prank(bob);
        nft.transferFrom(alice, carol, 0);
        assertEq(nft.ownerOf(0), carol);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(carol), 1);
    }

    function test_TransferFrom_UnauthorizedReverts() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(mallory);
        vm.expectRevert();
        nft.transferFrom(alice, mallory, 0);
    }

    function test_SafeTransferFrom_ToReceiverContract() public {
        NFTReceiver receiver = new NFTReceiver();
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 0);
        assertEq(nft.ownerOf(0), address(receiver));
    }

    function test_SafeTransferFrom_ToNonReceiverContractReverts() public {
        NonReceiver nonReceiver = new NonReceiver();
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        nft.safeTransferFrom(alice, address(nonReceiver), 0);
    }

    function test_SafeTransferFrom_ToEOA() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 0);
        assertEq(nft.ownerOf(0), bob);
    }

    function test_SetApprovalForAll_OperatorCanTransfer() public {
        vm.prank(owner);
        nft.ownerMint(alice, 1);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        assertTrue(nft.isApprovedForAll(alice, bob));
        vm.prank(bob);
        nft.transferFrom(alice, carol, 0);
        assertEq(nft.ownerOf(0), carol);
    }

    /* ==================== WITHDRAW ==================== */

    function test_Withdraw_SendsBalanceToOwner() public {
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.prank(alice);
        nft.mintPublic{value: 0.16 ether}(2);
        assertEq(address(nft).balance, 0.16 ether);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        nft.withdraw();
        assertEq(owner.balance - ownerBefore, 0.16 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        nft.withdraw();
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_RoyaltyMath(uint256 salePrice) public view {
        salePrice = bound(salePrice, 0, type(uint128).max);
        (, uint256 amount) = nft.royaltyInfo(0, salePrice);
        assertEq(amount, (salePrice * 500) / 10_000);
    }

    function testFuzz_MintPublic_ExactPaymentMintsQuantity(uint256 quantity) public {
        quantity = bound(quantity, 1, 10);
        uint256 price = nft.PUBLIC_PRICE();
        vm.prank(owner);
        nft.setPhase(GenesisNFT.Phase.Public);
        vm.prank(alice);
        nft.mintPublic{value: price * quantity}(quantity);
        assertEq(nft.balanceOf(alice), quantity);
        assertEq(nft.publicMinted(alice), quantity);
    }
}
