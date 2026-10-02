// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NovaToken} from "../src/Token.sol";
import {Ownable} from "../src/Ownable.sol";

/// @notice Full test suite for NovaToken: metadata, transfers, allowances, mint/burn,
///         pause, ownership and EIP-2612 permits — plus fuzz tests for the core invariants.
contract NovaTokenTest is Test {
    NovaToken token;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    /// A private key we control, used to sign permits in tests.
    uint256 alicePk = 0xA11CE;
    address aliceWithKey;

    // EIP-712 constants mirrored from the contract (must match exactly).
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    // Events for expectEmit checks.
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    function setUp() public {
        token = new NovaToken("NovaToken", "NOVA", owner);
        aliceWithKey = vm.addr(alicePk);
    }

    /* ==================== HELPERS ==================== */

    /// Builds and signs an EIP-712 permit digest exactly like a wallet would.
    function _signPermit(
        uint256 pk,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, vm.addr(pk), spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    /* ==================== METADATA ==================== */

    function test_Metadata() public view {
        assertEq(token.name(), "NovaToken");
        assertEq(token.symbol(), "NOVA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.MAX_SUPPLY(), 100_000_000 ether);
        assertEq(token.owner(), owner);
    }

    /* ==================== MINT ==================== */

    function test_Mint_OwnerCanMint() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1000 ether);
        vm.expectEmit(true, false, true, true);
        emit Minted(alice, 1000 ether);
        token.mint(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_Mint_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        token.mint(alice, 1 ether);
    }

    function test_Mint_CannotExceedCap() public {
        token.mint(alice, token.MAX_SUPPLY());
        vm.expectRevert(
            abi.encodeWithSelector(NovaToken.MaxSupplyExceeded.selector, token.MAX_SUPPLY() + 1, token.MAX_SUPPLY())
        );
        token.mint(alice, 1);
    }

    function test_Mint_ToZeroAddressReverts() public {
        vm.expectRevert(Ownable.ZeroAddress.selector);
        token.mint(address(0), 1 ether);
    }

    /* ==================== TRANSFER ==================== */

    function test_Transfer_MovesBalanceAndEmitsEvent() public {
        token.mint(alice, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 40 ether);
        vm.prank(alice);
        token.transfer(bob, 40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(bob), 40 ether);
    }

    function test_Transfer_InsufficientBalanceReverts() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(NovaToken.InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.transfer(bob, 11 ether);
    }

    function test_Transfer_ToZeroAddressReverts() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Ownable.ZeroAddress.selector);
        token.transfer(address(0), 1 ether);
    }

    /* ==================== APPROVE / TRANSFERFROM ==================== */

    function test_Approve_SetsAllowanceAndEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 50 ether);
        vm.prank(alice);
        token.approve(bob, 50 ether);
        assertEq(token.allowance(alice, bob), 50 ether);
    }

    function test_TransferFrom_SpendsAllowance() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 50 ether);
        vm.prank(bob);
        token.transferFrom(alice, carol, 30 ether);
        assertEq(token.balanceOf(carol), 30 ether);
        assertEq(token.allowance(alice, bob), 20 ether);
    }

    function test_IncreaseAllowance_AddsToCurrentValue() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 80 ether);
        vm.prank(alice);
        token.increaseAllowance(bob, 30 ether);
        assertEq(token.allowance(alice, bob), 80 ether);
    }

    function test_DecreaseAllowance_SubtractsAndClampsAtZero() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);
        vm.prank(alice);
        token.decreaseAllowance(bob, 20 ether);
        assertEq(token.allowance(alice, bob), 30 ether);
        // overshoot clamps to zero instead of reverting/underflowing
        vm.prank(alice);
        token.decreaseAllowance(bob, 40 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function testFuzz_IncreaseDecreaseAllowanceRoundTrip(uint256 base, uint256 add, uint256 sub) public {
        base = bound(base, 0, type(uint128).max);
        add = bound(add, 0, type(uint128).max);
        sub = bound(sub, 0, type(uint128).max);
        vm.prank(alice);
        token.approve(bob, base);
        vm.prank(alice);
        token.increaseAllowance(bob, add);
        assertEq(token.allowance(alice, bob), base + add);
        vm.prank(alice);
        token.decreaseAllowance(bob, sub);
        uint256 expected = base + add > sub ? base + add - sub : 0;
        assertEq(token.allowance(alice, bob), expected);
    }

    function test_TransferFrom_InfiniteAllowanceNotReduced() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 10 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_TransferFrom_InsufficientAllowanceReverts() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(NovaToken.InsufficientAllowance.selector, bob, 10 ether, 11 ether)
        );
        token.transferFrom(alice, carol, 11 ether);
    }

    /* ==================== BURN ==================== */

    function test_Burn_ReducesBalanceAndSupply() public {
        token.mint(alice, 100 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 30 ether);
        vm.prank(alice);
        token.burn(30 ether);
        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.totalSupply(), 70 ether);
    }

    function test_Burn_MoreThanBalanceReverts() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(NovaToken.InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        token.burn(11 ether);
    }

    function test_BurnFrom_SpendsAllowance() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 40 ether);
        vm.prank(bob);
        token.burnFrom(alice, 25 ether);
        assertEq(token.balanceOf(alice), 75 ether);
        assertEq(token.allowance(alice, bob), 15 ether);
    }

    /* ==================== PAUSE ==================== */

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        token.pause();
    }

    function test_Pause_BlocksAllTokenMovement() public {
        token.mint(alice, 100 ether);
        token.pause();
        vm.prank(alice);
        vm.expectRevert(NovaToken.TokenPaused.selector);
        token.transfer(bob, 1 ether);
        vm.expectRevert(NovaToken.TokenPaused.selector);
        token.mint(bob, 1 ether);
    }

    function test_Unpause_RestoresTransfers() public {
        token.mint(alice, 100 ether);
        token.pause();
        token.unpause();
        vm.prank(alice);
        token.transfer(bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    /* ==================== OWNERSHIP ==================== */

    function test_TransferOwnership_IsTwoStep() public {
        token.transferOwnership(alice);
        assertEq(token.pendingOwner(), alice);
        assertEq(token.owner(), owner);
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_WrongCallerReverts() public {
        token.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotPendingOwner.selector, bob));
        token.acceptOwnership();
    }

    function test_TransferOwnership_ToZeroReverts() public {
        vm.expectRevert(Ownable.ZeroAddress.selector);
        token.transferOwnership(address(0));
    }

    function test_RenounceOwnership_LocksAdminFunctions() public {
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, owner));
        token.mint(alice, 1 ether);
    }

    /* ==================== EIP-2612 PERMIT ==================== */

    function test_Permit_SetsAllowanceAndBurnsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, bob, 100 ether, 0, deadline);
        token.permit(aliceWithKey, bob, 100 ether, deadline, v, r, s);
        assertEq(token.allowance(aliceWithKey, bob), 100 ether);
        assertEq(token.nonces(aliceWithKey), 1);
    }

    function test_Permit_ReplayFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, bob, 100 ether, 0, deadline);
        token.permit(aliceWithKey, bob, 100 ether, deadline, v, r, s);
        vm.expectRevert(NovaToken.InvalidPermitSignature.selector);
        token.permit(aliceWithKey, bob, 100 ether, deadline, v, r, s);
    }

    function test_Permit_WrongSignerFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 carolPk = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(carolPk, bob, 100 ether, 0, deadline);
        vm.expectRevert(NovaToken.InvalidPermitSignature.selector);
        token.permit(aliceWithKey, bob, 100 ether, deadline, v, r, s);
    }

    function test_Permit_ExpiredDeadlineFails() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, bob, 100 ether, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(NovaToken.PermitExpired.selector, deadline));
        token.permit(aliceWithKey, bob, 100 ether, deadline, v, r, s);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        token.mint(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_TransferPreservesTotalSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, 1_000_000 ether);
        b = bound(b, 0, 1_000_000 ether);
        token.mint(alice, a);
        token.mint(bob, b);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        token.transfer(bob, a);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), supplyBefore);
    }

    function testFuzz_MintNeverExceedsCap(uint256 amount) public {
        amount = bound(amount, 0, token.MAX_SUPPLY());
        token.mint(alice, amount);
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
        token.mint(bob, token.MAX_SUPPLY() - token.totalSupply());
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function testFuzz_BurnReducesSupplySymmetrically(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        token.mint(alice, amount);
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_Permit(uint256 value, uint48 deadlineOffset) public {
        value = bound(value, 0, type(uint128).max);
        uint256 deadline = block.timestamp + uint256(deadlineOffset) + 1;
        uint256 nonce = token.nonces(aliceWithKey);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePk, bob, value, nonce, deadline);
        token.permit(aliceWithKey, bob, value, deadline, v, r, s);
        assertEq(token.allowance(aliceWithKey, bob), value);
    }
}
