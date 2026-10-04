// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TamweelFixture} from "./TamweelFixture.sol";
import {TamweelCompliance} from "../src/TamweelCompliance.sol";
import {TamweelOracle} from "../src/TamweelOracle.sol";
import {TamweelVault} from "../src/TamweelVault.sol";
import {TamweelRateModel} from "../src/TamweelRateModel.sol";

contract TamweelComplianceTest is TamweelFixture {
    function test_CreditBands() public {
        assertEq(compliance.maxBorrowFor(borrower), 25_000 ether); // score 850
    }

    function test_ValidateBorrow_DeniesOverBand() public {
        vm.expectRevert(abi.encodeWithSelector(TamweelCompliance.CreditDenied.selector, borrower, 850, 25_000 ether));
        compliance.validateBorrow(borrower, 30_000 ether);
    }

    function test_Score_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert(TamweelCompliance.NotCommittee.selector);
        compliance.setCreditScore(borrower, 900);
    }

    function test_Sanctions_Block() public {
        vm.prank(committee1);
        compliance.setSanctioned(borrower, true);
        assertFalse(compliance.canTransact(borrower));
        vm.expectRevert();
        compliance.validateBorrow(borrower, 1 ether);
    }
}

contract TamweelOracleTest is TamweelFixture {
    function test_Price_RequiresPost() public {
        TamweelOracle fresh = new TamweelOracle(1 hours, 24 hours);
        vm.expectRevert();
        fresh.price(address(stable));
    }

    function test_Ema_SmoothsSpike() public {
        // a huge spot print only moves the EMA partially
        oracle.postPrice(address(stable), 2_000 ether);
        vm.warp(block.timestamp + 30 minutes);
        oracle.postPrice(address(stable), 4_000 ether); // half the smoothing window
        uint256 ema = oracle.price(address(stable));
        assertTrue(ema > 2_000 ether && ema < 4_000 ether);
    }

    function test_Staleness_Reverts() public {
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert();
        oracle.price(address(stable));
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.pause();
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(TamweelOracle.FeedPaused.selector);
        oracle.price(address(stable));
    }
}

contract TamweelVaultTest is TamweelFixture {
    function test_Deposit_MintsShares() public {
        uint256 before = vault.balanceOf(depositor);
        vm.prank(depositor);
        uint256 shares = vault.deposit(10_000 ether);
        assertEq(shares, 10_000 ether);
        assertEq(vault.balanceOf(depositor) - before, 10_000 ether);
        assertEq(vault.totalAssets(), 110_000 ether);
    }

    function test_Withdraw_SharesProportional() public {
        uint256 before = stable.balanceOf(depositor);
        vm.prank(depositor);
        uint256 amount = vault.withdraw(10_000 ether); // 10% of shares
        assertEq(amount, 10_000 ether);
        assertEq(stable.balanceOf(depositor) - before, 10_000 ether);
    }

    function test_Withdraw_RespectsLiquidityBuffer() public {
        // borrow most of the vault's liquidity first
        vm.prank(borrower);
        markets.supply(marketId, 10 ether);
        vm.prank(borrower);
        markets.borrow(marketId, 14_000 ether);
        // the vault now holds ~86,000 − 5% buffer = 81,000 liquid; withdrawing 90,000 shares fails
        vm.prank(depositor);
        vm.expectRevert();
        vault.withdraw(90_000 ether);
    }

    function test_LendAndRecover_MarketsOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.lendToMarkets(1 ether);

        uint256 before = vault.borrowedAssets();
        vault.lendToMarkets(10_000 ether);
        assertEq(vault.borrowedAssets() - before, 10_000 ether);

        stable.approve(address(vault), 10_000 ether);
        vault.recoverFromMarkets(10_000 ether);
        assertEq(vault.borrowedAssets(), before);
    }

    function test_ShareSnapshots() public {
        vm.roll(block.number + 1);
        vm.prank(depositor);
        vault.deposit(5_000 ether);
        assertEq(vault.getPastShares(depositor, block.number), 105_000 ether);
        assertEq(vault.getPastShares(depositor, block.number - 1), 100_000 ether);
    }
}

contract TamweelRateModelTest is TamweelFixture {
    function test_UtilizationCurve() public {
        uint256 belowKink = rateModel.borrowRatePerSecond(5000); // 50%
        uint256 aboveKink = rateModel.borrowRatePerSecond(9000); // 90%
        assertTrue(aboveKink > belowKink);
        assertEq(rateModel.borrowRatePerSecond(8000), BASE + (SLOPE1 * 8000) / 10_000);
    }

    function test_SupplyRate_LessThanBorrow() public {
        uint256 supply = rateModel.supplyRatePerSecond(8000);
        uint256 borrow = rateModel.borrowRatePerSecond(8000);
        assertTrue(supply < borrow);
    }

    function test_ReserveFactor_ReducesSupply() public {
        rateModel.setParams(BASE, SLOPE1, SLOPE2, 8000, 2000); // 20% reserve
        uint256 supply = rateModel.supplyRatePerSecond(8000);
        assertEq(supply, ((rateModel.borrowRatePerSecond(8000) * 8000) / 10_000 * 8000) / 10_000);
    }

    function test_Params_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        rateModel.setParams(1, 1, 1, 8000, 1000);
    }
}
