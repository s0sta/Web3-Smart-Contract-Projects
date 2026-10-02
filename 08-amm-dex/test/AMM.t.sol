// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMPair} from "../src/AMMPair.sol";
import {AMMRouter} from "../src/AMMRouter.sol";
import {AMMLibrary} from "../src/AMMLibrary.sol";
import {IAMMCallee} from "../src/IAMMCallee.sol";
import {MockToken} from "../src/MockToken.sol";

/// @notice Borrows tokens via flash swap and repays (with fee) inside the callback.
contract FlashSwapper is IAMMCallee {
    AMMPair pair;
    MockToken tokenA;
    MockToken tokenB;

    constructor(AMMPair pair_, MockToken a, MockToken b) {
        pair = pair_;
        tokenA = a;
        tokenB = b;
    }

    function flashSwap(uint256 amountOut, bool zeroForOne) external {
        bytes memory data = abi.encode(zeroForOne);
        if (zeroForOne) {
            pair.swap(amountOut, 0, address(this), data);
        } else {
            pair.swap(0, amountOut, address(this), data);
        }
    }

    function ammCall(address, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        bool zeroForOne = abi.decode(data, (bool));
        // Repay the borrowed amount plus the 0.3% fee (rounded up).
        if (zeroForOne) {
            uint256 repay = (amount0 * 1000) / 997 + 1;
            tokenA.transfer(address(pair), repay);
        } else {
            uint256 repay = (amount1 * 1000) / 997 + 1;
            tokenB.transfer(address(pair), repay);
        }
    }
}

contract AMMTest is Test {
    AMMFactory factory;
    AMMRouter router;
    MockToken tokenA; // GLD
    MockToken tokenB; // USD
    MockToken tokenC; // OIL (multi-hop)

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 length);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, uint256 amount0Out, uint256 amount1Out, address indexed to);

    function setUp() public {
        factory = new AMMFactory();
        router = new AMMRouter(factory);
        tokenA = new MockToken("Gold", "GLD");
        tokenB = new MockToken("US Dollar", "USD");
        tokenC = new MockToken("Oil", "OIL");

        tokenA.mint(alice, 10_000_000 ether);
        tokenB.mint(alice, 10_000_000 ether);
        tokenC.mint(alice, 10_000_000 ether);
        tokenA.mint(bob, 10_000_000 ether);
        tokenB.mint(bob, 10_000_000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// Alice seeds the A/B pool with 1M A and 2M B.
    function _seedAB() internal returns (address pair) {
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), 1_000_000 ether, 2_000_000 ether, 0, 0, alice, block.timestamp + 1 days
        );
        pair = factory.getPair(address(tokenA), address(tokenB));
    }

    /* ==================== FACTORY ==================== */

    function test_Factory_CreatePair() public {
        address expected0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address expected1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
        vm.expectEmit(true, true, false, false);
        emit PairCreated(expected0, expected1, address(0), 1);
        address pair = factory.createPair(address(tokenA), address(tokenB));

        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair); // order-independent
        assertEq(factory.allPairs(0), pair);
        assertEq(factory.allPairsLength(), 1);
        // Canonical sorted order: token0 < token1, and they are exactly the two tokens.
        assertLt(uint160(AMMPair(pair).token0()), uint160(AMMPair(pair).token1()));
        assertEq(AMMPair(pair).token0(), expected0);
        assertEq(AMMPair(pair).token1(), expected1);
    }

    function test_Factory_DuplicatePairReverts() public {
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(AMMFactory.PairExists.selector);
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_Factory_IdenticalTokensRevert() public {
        vm.expectRevert(AMMFactory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    /* ==================== ADD LIQUIDITY ==================== */

    function test_AddLiquidity_InitialMintsSqrtMinusMinimum() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);

        // LP = sqrt(1e24 × 2e24) − 1000
        uint256 expectedLp = uint256(1_414_213_562_373_095_048_801_688) - 1000;
        assertEq(pair.balanceOf(alice), expectedLp);
        assertEq(pair.totalSupply(), expectedLp + 1000);
        assertEq(pair.balanceOf(address(0)), 1000); // MINIMUM_LIQUIDITY permanently locked
        (uint112 r0, uint112 r1) = pair.getReserves();
        // Orientation-aware: token0 holds whichever token has the smaller address.
        uint256 expected0 = pair.token0() == address(tokenA) ? 1_000_000 ether : 2_000_000 ether;
        uint256 expected1 = pair.token0() == address(tokenA) ? 2_000_000 ether : 1_000_000 ether;
        assertEq(r0, expected0);
        assertEq(r1, expected1);
    }

    function test_AddLiquidity_SecondProviderProportional() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        vm.prank(alice);
        pair.approve(address(router), type(uint256).max); // approve LP token

        // Pro rata expectation must use the supply BEFORE the new liquidity is added.
        uint256 expectedLp = (100 ether * pair.totalSupply()) / 1_000_000 ether;

        vm.prank(bob);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 200 ether, 0, 0, bob, block.timestamp + 1 days
        );

        assertEq(amountA, 100 ether);
        assertEq(amountB, 200 ether);
        // Pro rata: 100 ether of A over 1M reserve → 0.0001 of the pool.
        assertApproxEqAbs(liquidity, expectedLp, 1);
        assertEq(pair.balanceOf(bob), liquidity);
    }

    function test_AddLiquidity_QuotesOptimalAmount() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);

        // Pool is 1M A : 2M B. Desiring 100 A means the optimal B is 200.
        vm.prank(bob);
        (uint256 amountA, uint256 amountB,) = router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 500 ether, 0, 0, bob, block.timestamp + 1 days
        );
        assertEq(amountA, 100 ether);
        assertEq(amountB, 200 ether); // only the optimal 200 used, not the full 500
        assertEq(tokenB.balanceOf(bob), 10_000_000 ether - 200 ether);
    }

    function test_AddLiquidity_ExpiredDeadlineReverts() public {
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AMMRouter.Expired.selector, block.timestamp - 1));
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 200 ether, 0, 0, alice, block.timestamp - 1
        );
    }

    function test_AddLiquidity_BelowMinimumReverts() public {
        address pairAddr = _seedAB();
        AMMPair(pairAddr); // ensure pair exists

        // Optimal B for 100 A is 200 B; demanding at least 300 must revert.
        vm.prank(bob);
        vm.expectRevert(AMMRouter.InsufficientBAmount.selector);
        router.addLiquidity(
            address(tokenA), address(tokenB), 100 ether, 500 ether, 0, 300 ether, bob, block.timestamp + 1 days
        );
    }

    /* ==================== SWAP ==================== */

    function test_Swap_ExactInputMatchesQuoteAndKeepsInvariant() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = router.getAmountsOut(100 ether, path);
        uint256 kBefore = _k(pair);
        uint256 bobBefore = tokenB.balanceOf(bob);

        vm.prank(bob);
        router.swapExactTokensForTokens(100 ether, 0, path, bob, block.timestamp + 1 days);

        assertEq(tokenB.balanceOf(bob) - bobBefore, expected[1]);
        // The 0.3% fee stays in the pool → k strictly grows.
        assertGt(_k(pair), kBefore);
    }

    function test_Swap_OutputBelowMinReverts() public {
        _seedAB();
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory expected = router.getAmountsOut(100 ether, path);
        vm.prank(bob);
        vm.expectRevert(AMMRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(100 ether, expected[1] + 1, path, bob, block.timestamp + 1 days);
    }

    function test_Swap_ExpiredDeadlineReverts() public {
        _seedAB();
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert();
        router.swapExactTokensForTokens(100 ether, 0, path, bob, block.timestamp - 1);
    }

    function test_Swap_MultiHopThroughThreeTokens() public {
        _seedAB();
        // Seed B/C pool: 2M B : 1M C
        vm.prank(alice);
        router.addLiquidity(
            address(tokenB), address(tokenC), 2_000_000 ether, 1_000_000 ether, 0, 0, alice, block.timestamp + 1 days
        );

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256[] memory expected = router.getAmountsOut(50 ether, path);
        uint256 carolBefore = tokenC.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(50 ether, 0, path, bob, block.timestamp + 1 days);
        assertEq(tokenC.balanceOf(bob) - carolBefore, expected[2]);
    }

    function test_Swap_WithoutPayingReverts() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        vm.expectRevert(AMMPair.InsufficientInputAmount.selector);
        pair.swap(0, 10 ether, bob, "");
    }

    /* ==================== FLASH SWAP ==================== */

    function test_FlashSwap_BorrowAndRepayInCallback() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        FlashSwapper swapper = new FlashSwapper(pair, tokenA, tokenB);
        tokenA.mint(address(swapper), 1000 ether);

        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 totalBefore = uint256(r0) + r1;
        swapper.flashSwap(50 ether, true); // borrow 50 A, repay in callback

        (uint112 r0After, uint112 r1After) = pair.getReserves();
        // Net effect on the pool: exactly the 0.3% fee stays behind, regardless of
        // which token occupies slot 0.
        uint256 repay = (uint256(50 ether) * 1000) / 997 + 1;
        uint256 fee = repay - 50 ether;
        assertApproxEqAbs(uint256(r0After) + r1After - totalBefore, fee, 2);
    }

    /* ==================== REMOVE LIQUIDITY ==================== */

    function test_RemoveLiquidity_ReturnsSharePlusFees() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        vm.prank(alice);
        pair.approve(address(router), type(uint256).max);

        // Someone swaps, generating fees for the pool.
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        router.swapExactTokensForTokens(1000 ether, 0, path, bob, block.timestamp + 1 days);

        uint256 aBefore = tokenA.balanceOf(alice);
        uint256 bBefore = tokenB.balanceOf(alice);
        uint256 lp = pair.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), lp, 0, 0, alice, block.timestamp + 1 days);

        uint256 aDelta = tokenA.balanceOf(alice) - aBefore;
        uint256 bDelta = tokenB.balanceOf(alice) - bBefore;
        // Bob's swap traded some B out of the pool, so alice ends with more A and less B —
        // but measured at the original 2:1 price her LP share GREW by the swap fees.
        assertGt(aDelta, 1_000_000 ether);
        assertLt(bDelta, 2_000_000 ether);
        int256 gain = (int256(aDelta) - int256(1_000_000 ether)) + (int256(bDelta) - int256(2_000_000 ether)) / 2;
        assertGt(gain, 0); // fee income at the original price
        assertEq(amountA, aDelta);
        assertEq(amountB, bDelta);
        assertEq(pair.balanceOf(alice), 0);
    }

    function test_RemoveLiquidity_BelowMinimumReverts() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        vm.prank(alice);
        pair.approve(address(router), type(uint256).max);
        uint256 lp = pair.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(AMMRouter.InsufficientAAmount.selector);
        router.removeLiquidity(
            address(tokenA), address(tokenB), lp, type(uint256).max, 0, alice, block.timestamp + 1 days
        );
    }

    /* ==================== SYNC / SKIM ==================== */

    function test_Skim_ReturnsExcessTokens() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);

        (uint112 r0, uint112 r1) = pair.getReserves();

        // Someone accidentally sends tokens directly to the pair.
        vm.prank(bob);
        tokenA.transfer(pairAddr, 5 ether);

        vm.prank(bob);
        pair.skim(bob);
        assertEq(tokenA.balanceOf(bob), 10_000_000 ether); // got the 5 ether back
        (uint112 r0After, uint112 r1After) = pair.getReserves();
        assertEq(r0After, r0); // reserves unchanged
        assertEq(r1After, r1);
    }

    function test_Sync_AdoptsDonatedTokens() public {
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);

        (uint112 r0, uint112 r1) = pair.getReserves();

        vm.prank(bob);
        tokenA.transfer(pairAddr, 5 ether);
        pair.sync(); // accept the donation into reserves

        (uint112 r0After, uint112 r1After) = pair.getReserves();
        if (pair.token0() == address(tokenA)) {
            assertEq(r0After, r0 + 5 ether);
            assertEq(r1After, r1);
        } else {
            assertEq(r1After, r1 + 5 ether);
            assertEq(r0After, r0);
        }
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_SwapNeverBreaksInvariant(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100 ether);
        address pairAddr = _seedAB();
        AMMPair pair = AMMPair(pairAddr);
        uint256 kBefore = _k(pair);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        vm.prank(bob);
        router.swapExactTokensForTokens(amountIn, 0, path, bob, block.timestamp + 1 days);

        assertGe(_k(pair), kBefore); // x·y never shrinks — the fee accrues to LPs
    }

    function testFuzz_AddRemoveLiquidityRoundTrip(uint256 amount) public {
        amount = bound(amount, 1 ether, 500_000 ether);
        vm.prank(alice);
        router.addLiquidity(
            address(tokenA), address(tokenB), amount, 2 * amount, 0, 0, alice, block.timestamp + 1 days
        );
        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        AMMPair pair = AMMPair(pairAddr);
        vm.prank(alice);
        pair.approve(address(router), type(uint256).max);

        uint256 aBefore = tokenA.balanceOf(alice);
        uint256 bBefore = tokenB.balanceOf(alice);
        uint256 lp = pair.balanceOf(alice);
        vm.prank(alice);
        router.removeLiquidity(address(tokenA), address(tokenB), lp, 0, 0, alice, block.timestamp + 1 days);

        // Round trip returns essentially everything (only MINIMUM_LIQUIDITY dust + sqrt rounding).
        assertApproxEqAbs(tokenA.balanceOf(alice) - aBefore, amount, 2000);
        assertApproxEqAbs(tokenB.balanceOf(alice) - bBefore, 2 * amount, 2000);
    }

    function testFuzz_LargerSwapGetsWorsePrice(uint256 small, uint256 big) public {
        small = bound(small, 1 ether, 10 ether);
        big = bound(big, 50 ether, 500 ether);
        _seedAB();

        uint256 outSmall = router.getAmountOut(small, 1_000_000 ether, 2_000_000 ether);
        uint256 outBig = router.getAmountOut(big, 1_000_000 ether, 2_000_000 ether);

        // Slippage: the marginal price worsens with size (out/ in strictly decreases).
        assertGt(outSmall * big, outBig * small);
    }

    /* ==================== HELPERS ==================== */

    function _k(AMMPair pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1) = pair.getReserves();
        return uint256(r0) * r1;
    }
}
