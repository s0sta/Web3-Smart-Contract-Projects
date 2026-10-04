// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {TamweelCompliance} from "../src/TamweelCompliance.sol";
import {TamweelOracle} from "../src/TamweelOracle.sol";
import {TamweelVault} from "../src/TamweelVault.sol";
import {TamweelRateModel} from "../src/TamweelRateModel.sol";
import {TamweelMarkets} from "../src/TamweelMarkets.sol";
import {TamweelLoans} from "../src/TamweelLoans.sol";
import {TamweelCollateral} from "../src/TamweelCollateral.sol";
import {TamweelInsuranceFund} from "../src/TamweelInsuranceFund.sol";
import {TamweelGovernor} from "../src/TamweelGovernor.sol";

/// @notice The complete bank wiring: AED-S stable, a credit committee of two,
///         an oracle (1h smoothing / 24h staleness), the vault (5% liquidity
///         buffer), a two-slope rate model, one collateral market (ETH at 70%
///         LTV / 80% threshold / 5% bonus), the loan book (5% flat interest,
///         5% settlement rebate, 2% late penalty to charity), the insurance
///         fund and the governor (10% quorum).
abstract contract TamweelFixture is Test {
    MockStable internal stable;
    TamweelCompliance internal compliance;
    TamweelOracle internal oracle;
    TamweelVault internal vault;
    TamweelRateModel internal rateModel;
    TamweelMarkets internal markets;
    TamweelLoans internal loans;
    TamweelCollateral internal collateral;
    TamweelInsuranceFund internal insurance;
    TamweelGovernor internal governor;

    address internal operator = address(this);
    address internal committee1 = address(0xC);
    address internal committee2 = address(0xD);
    address internal guardian = address(0x6);
    address internal charity = address(0x7);
    address internal depositor = address(0xA);
    address internal borrower = address(0xB);
    address internal liquidator = address(0x1);
    address internal outsider = address(0x99);

    uint256 internal marketId;

    // per-second rates: 3% base APR + 12% slope1 / 60% slope2, kink 80%, 10% reserve
    uint256 internal BASE = uint256(3e16) / uint256(365 days); // 3% APR per second
    uint256 internal SLOPE1 = uint256(12e16) / uint256(365 days);
    uint256 internal SLOPE2 = uint256(60e16) / uint256(365 days);

    function setUp() public virtual {
        stable = new MockStable();

        address[] memory members = new address[](2);
        members[0] = committee1;
        members[1] = committee2;
        compliance = new TamweelCompliance(members);

        oracle = new TamweelOracle(1 hours, 24 hours);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        vault = new TamweelVault(stable, 500); // 5% liquidity buffer
        rateModel = new TamweelRateModel(BASE, SLOPE1, SLOPE2, 8000, 1000);

        collateral = new TamweelCollateral(stable);
        markets = new TamweelMarkets(vault, oracle, rateModel, compliance, collateral, stable);
        loans = new TamweelLoans(compliance, vault, stable, charity, 500, 500, 200, 2);
        insurance = new TamweelInsuranceFund(vault, stable);
        governor = new TamweelGovernor(vault, rateModel, markets, loans, compliance, 1000);

        // wiring
        vault.grantRole(vault.MARKETS_ROLE(), address(markets));
        vault.grantRole(vault.MARKETS_ROLE(), address(loans));
        vault.grantRole(vault.INSURANCE_ROLE(), address(insurance));
        markets.grantRole(markets.OPERATOR_ROLE(), address(governor));
        markets.grantRole(markets.OPERATOR_ROLE(), operator);
        collateral.grantRole(collateral.MARKETS_ROLE(), address(markets));
        loans.grantRole(loans.FINANCIER_ROLE(), address(governor));
        loans.grantRole(loans.DEFAULT_ADMIN_ROLE(), address(governor));
        loans.grantRole(loans.COMMITTEE_ROLE(), committee1);
        loans.grantRole(loans.COMMITTEE_ROLE(), committee2);
        insurance.grantRole(insurance.COMMITTEE_ROLE(), committee1);
        insurance.grantRole(insurance.COMMITTEE_ROLE(), committee2);
        insurance.grantRole(insurance.MARKETS_ROLE(), address(markets));
        insurance.setCommitteeSize(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        compliance.grantRole(compliance.COMMITTEE_ROLE(), committee1);
        compliance.grantRole(compliance.COMMITTEE_ROLE(), committee2);

        // KYC + credit profiles
        vm.prank(committee1);
        compliance.setKyc(depositor, TamweelCompliance.KycTier.Standard);
        vm.prank(committee1);
        compliance.setKyc(borrower, TamweelCompliance.KycTier.Standard);
        vm.prank(committee1);
        compliance.setCreditScore(borrower, 850); // band: 25,000
        vm.prank(committee1);
        compliance.setKyc(liquidator, TamweelCompliance.KycTier.Standard);
        vm.prank(committee1);
        compliance.setKyc(address(markets), TamweelCompliance.KycTier.Standard);
        vm.prank(committee1);
        compliance.setKyc(address(collateral), TamweelCompliance.KycTier.Standard);

        // fund accounts
        stable.setMinter(address(this));
        stable.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        stable.approve(address(vault), 1_000_000 ether);
        stable.mint(borrower, 1_000_000 ether);
        vm.prank(borrower);
        stable.approve(address(markets), 1_000_000 ether);
        vm.prank(borrower);
        stable.approve(address(loans), 1_000_000 ether);
        vm.prank(borrower);
        stable.approve(address(vault), 1_000_000 ether);
        vm.prank(borrower);
        stable.approve(address(collateral), 1_000_000 ether);
        stable.mint(liquidator, 1_000_000 ether);
        vm.prank(liquidator);
        stable.approve(address(markets), 1_000_000 ether);
        vm.prank(liquidator);
        stable.approve(address(collateral), 1_000_000 ether);
        vm.prank(liquidator);
        stable.approve(address(vault), 1_000_000 ether);

        // list the ETH-collateral market
        marketId = markets.listMarket(stable, 7000, 8000, 500);

        // seed the oracle
        oracle.postPrice(address(stable), 2_000 ether); // 1 ETH = 2,000 AED-S

        // depositor funds the bank
        vm.prank(depositor);
        vault.deposit(100_000 ether);
    }

    function _supplyAndBorrow(uint256 collateralAmount, uint256 borrowAmount) internal {
        vm.prank(borrower);
        markets.supply(marketId, collateralAmount);
        vm.prank(borrower);
        markets.borrow(marketId, borrowAmount);
    }
}
