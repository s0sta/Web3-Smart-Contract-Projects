// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendVault} from "../src/LendVault.sol";
import {MockStable} from "../src/MockStable.sol";

contract LendVaultTest is Test {
    LendVault vault;
    MockStable stable;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);

    /// 10 ETH = 20,000 USD at the fixed price.
    uint256 constant COLLATERAL = 10 ether;
    uint256 constant USD_VALUE = 20_000 ether;
    uint256 constant MAX_BORROW = (USD_VALUE * 6600) / 10_000; // 13,200
    uint256 constant LIQ_CEILING = (USD_VALUE * 8000) / 10_000; // 16,000

    function setUp() public {
        stable = new MockStable();
        vault = new LendVault(stable);
        stable.setVault(address(vault));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(liquidator, 100 ether);

        vm.startPrank(alice);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(liquidator);
        stable.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// Alice deposits 10 ETH.
    function _depositAlice() internal {
        vm.prank(alice);
        vault.deposit{value: COLLATERAL}();
    }

    /* ==================== DEPOSIT / WITHDRAW ==================== */

    function test_Deposit_RecordsCollateral() public {
        vm.expectEmit(true, false, true, true);
        emit Deposited(alice, COLLATERAL);
        _depositAlice();

        assertEq(vault.collateral(alice), COLLATERAL);
        assertEq(vault.totalCollateral(), COLLATERAL);
        assertEq(address(vault).balance, COLLATERAL);
    }

    function test_Deposit_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(LendVault.ZeroAmount.selector);
        vault.deposit{value: 0}();
    }

    function test_Withdraw_WithinLimits() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(5000 ether);

        vm.expectEmit(true, false, true, true);
        emit Withdrawn(alice, 2 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.withdraw(2 ether);

        assertEq(alice.balance - before, 2 ether);
        assertEq(vault.collateral(alice), 8 ether);
    }

    function test_Withdraw_BeyondCollateralReverts() public {
        _depositAlice();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendVault.InsufficientCollateral.selector, COLLATERAL, 11 ether));
        vault.withdraw(11 ether);
    }

    function test_Withdraw_BreakingLtvReverts() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(MAX_BORROW); // exactly at the limit
        // Withdrawing anything now would under-collateralize the position.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1);
    }

    /* ==================== BORROW / REPAY ==================== */

    function test_Borrow_UpToLtvLimit() public {
        _depositAlice();
        vm.expectEmit(true, false, true, true);
        emit Borrowed(alice, MAX_BORROW);
        vm.prank(alice);
        vault.borrow(MAX_BORROW);

        assertEq(vault.debt(alice), MAX_BORROW);
        assertEq(vault.totalDebt(), MAX_BORROW);
        assertEq(stable.balanceOf(alice), MAX_BORROW); // freshly minted
        assertEq(vault.maxBorrow(alice), 0);
    }

    function test_Borrow_BeyondLtvReverts() public {
        _depositAlice();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendVault.BorrowLimitExceeded.selector, MAX_BORROW + 1, MAX_BORROW)
        );
        vault.borrow(MAX_BORROW + 1);
    }

    function test_Borrow_ZeroReverts() public {
        _depositAlice();
        vm.prank(alice);
        vm.expectRevert(LendVault.ZeroAmount.selector);
        vault.borrow(0);
    }

    function test_Repay_ExactAndFull() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(5000 ether);

        vm.expectEmit(true, false, true, true);
        emit Repaid(alice, 2000 ether);
        vm.prank(alice);
        vault.repay(2000 ether);
        assertEq(vault.debt(alice), 3000 ether);

        vm.prank(alice);
        vault.repay(3000 ether);
        assertEq(vault.debt(alice), 0);
        assertEq(stable.totalSupply(), 0); // repaid stable fully burned

        // Debt-free: can withdraw everything.
        vm.prank(alice);
        vault.withdraw(COLLATERAL);
        assertEq(vault.collateral(alice), 0);
    }

    function test_Repay_ExceedsDebtReverts() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(1000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendVault.RepayExceedsDebt.selector, 1000 ether, 1001 ether));
        vault.repay(1001 ether);
    }

    /* ==================== INTEREST ==================== */

    function test_Interest_AccruesOverTime() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(10_000 ether);

        // Fund alice with extra stable to cover the interest she now owes.
        vm.prank(bob);
        vault.deposit{value: 10 ether}();
        vm.prank(bob);
        vault.borrow(2000 ether);
        vm.prank(bob);
        stable.transfer(alice, 1000 ether);

        vm.warp(block.timestamp + 365 days);
        // ~10% APR: 10k → ~11k
        assertApproxEqAbs(vault.currentDebt(alice), 11_000 ether, 1e15);

        uint256 owed = vault.currentDebt(alice);
        vm.prank(alice);
        vault.repay(owed); // repaying the accrued amount works
        assertEq(vault.debt(alice), 0);
    }

    /* ==================== HEALTH / LIQUIDATION ==================== */

    function test_HealthFactor_ScalesWithDebt() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(MAX_BORROW);

        // threshold value (16k) / debt (13.2k) → 1.2121...
        assertEq(vault.healthFactor(alice), (LIQ_CEILING * 1e18) / MAX_BORROW);
        assertFalse(vault.liquidatable(alice));
    }

    function test_HealthFactor_NoDebtIsMax() public {
        _depositAlice();
        assertEq(vault.healthFactor(alice), type(uint256).max);
    }

    function test_Liquidate_SeizesCollateralWithBonus() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(MAX_BORROW); // 66% — at the borrow limit

        // 10% APR compounds until the position breaches the 80% threshold (16k).
        vm.warp(block.timestamp + 3 * 365 days);
        uint256 d = vault.currentDebt(alice);
        assertGt(d, LIQ_CEILING);
        assertTrue(vault.liquidatable(alice));

        // Fund the liquidator: alice hands over some of her borrowed stable.
        vm.prank(alice);
        stable.transfer(liquidator, MAX_BORROW);

        uint256 repayAmount = (d * 5000) / 10_000; // max close factor (50%)
        uint256 expectedSeize = repayAmount * 11_000 / 10_000 * 1e18 / vault.PRICE();

        uint256 ethBefore = liquidator.balance;
        vm.expectEmit(true, true, true, true);
        emit Liquidated(alice, liquidator, repayAmount, expectedSeize);
        vm.prank(liquidator);
        vault.liquidate(alice, repayAmount);

        assertEq(liquidator.balance - ethBefore, expectedSeize);
        assertEq(vault.debt(alice), d - repayAmount);
        assertEq(vault.collateral(alice), COLLATERAL - expectedSeize);
        // The position is healthier now (still above threshold, but closer to solvent).
        assertGt(vault.healthFactor(alice), 1e18 / 1000);
    }

    function test_Liquidate_HealthyPositionReverts() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(1000 ether); // 5% — very healthy
        vm.prank(liquidator);
        vm.expectRevert(LendVault.NotLiquidatable.selector);
        vault.liquidate(alice, 100 ether);
    }

    function test_Liquidate_NoDebtReverts() public {
        _depositAlice();
        vm.prank(liquidator);
        vm.expectRevert(LendVault.NotLiquidatable.selector);
        vault.liquidate(alice, 1 ether);
    }

    function test_Liquidate_BeyondCloseFactorReverts() public {
        _depositAlice();
        vm.prank(alice);
        vault.borrow(MAX_BORROW);
        vm.warp(block.timestamp + 3 * 365 days);
        uint256 d = vault.currentDebt(alice);
        uint256 maxRepay = (d * 5000) / 10_000;

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(LendVault.RepayExceedsCloseFactor.selector, maxRepay));
        vault.liquidate(alice, maxRepay + 1);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_BorrowNeverExceedsLtv(uint256 depositAmount, uint256 borrowAmount) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        uint256 limit = (depositAmount * vault.PRICE() / 1e18 * vault.LTV_BPS()) / 10_000;
        borrowAmount = bound(borrowAmount, 1, limit);

        vm.prank(alice);
        vault.deposit{value: depositAmount}();
        vm.prank(alice);
        vault.borrow(borrowAmount);

        assertEq(vault.debt(alice), borrowAmount);
        assertEq(vault.maxBorrow(alice), limit - borrowAmount);
        assertLe(vault.debt(alice), limit);
    }

    function testFuzz_RepayReducesDebtExactly(uint256 borrowAmount, uint256 repayAmount) public {
        borrowAmount = bound(borrowAmount, 1, MAX_BORROW);
        repayAmount = bound(repayAmount, 0, borrowAmount);

        _depositAlice();
        vm.prank(alice);
        vault.borrow(borrowAmount);
        if (repayAmount > 0) {
            vm.prank(alice);
            vault.repay(repayAmount);
        }
        assertEq(vault.debt(alice), borrowAmount - repayAmount);
    }

    function testFuzz_LiquidationSeizeMath(uint256 elapsedYears, uint256 repayAmount) public {
        elapsedYears = bound(elapsedYears, 3, 6);
        _depositAlice();
        vm.prank(alice);
        vault.borrow(MAX_BORROW);
        vm.warp(block.timestamp + elapsedYears * 365 days);

        uint256 d = vault.currentDebt(alice);
        uint256 maxRepay = (d * 5000) / 10_000;
        repayAmount = bound(repayAmount, 1, maxRepay);
        if (!vault.liquidatable(alice)) return; // guard for boundary years

        vm.prank(alice);
        stable.transfer(liquidator, MAX_BORROW);

        uint256 expectedSeize = repayAmount * 11_000 / 10_000 * 1e18 / vault.PRICE();
        uint256 ethBefore = liquidator.balance;
        vm.prank(liquidator);
        vault.liquidate(alice, repayAmount);

        assertEq(liquidator.balance - ethBefore, expectedSeize);
        assertEq(vault.debt(alice), d - repayAmount);
        assertEq(vault.collateral(alice), COLLATERAL - expectedSeize);
    }
}
