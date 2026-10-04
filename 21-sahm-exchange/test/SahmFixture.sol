// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {SahmCompliance} from "../src/SahmCompliance.sol";
import {SahmOracle} from "../src/SahmOracle.sol";
import {SahmCollateral} from "../src/SahmCollateral.sol";
import {SahmTreasury} from "../src/SahmTreasury.sol";
import {SahmRisk} from "../src/SahmRisk.sol";
import {SahmOrderBook} from "../src/SahmOrderBook.sol";
import {SahmAMM} from "../src/SahmAMM.sol";
import {SahmMargin} from "../src/SahmMargin.sol";
import {SahmInsuranceFund} from "../src/SahmInsuranceFund.sol";
import {SahmGovernor} from "../src/SahmGovernor.sol";

/// @notice The complete exchange wiring: AED-S quote, two compliance officers,
///         an EMA oracle, the collateral desk, the treasury (20% reserve), the
///         risk engine (ETH market: 1M position cap, 5M daily volume, 10% move
///         breaker), the order book (0.1%/0.2%), one AMM pool (0.3% fee, 20%
///         protocol share), the margin desk (5x max), the insurance fund and the
///         governor (10% quorum).
abstract contract SahmFixture is Test {
    MockStable internal stable;
    SahmCompliance internal compliance;
    SahmOracle internal oracle;
    SahmCollateral internal collateral;
    SahmTreasury internal treasury;
    SahmRisk internal risk;
    SahmOrderBook internal book;
    SahmAMM internal amm;
    SahmMargin internal margin;
    SahmInsuranceFund internal insurance;
    SahmGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal traderA = address(0xA);
    address internal traderB = address(0xB);
    address internal lp = address(0x1);
    address internal liquidator = address(0x2);
    address internal outsider = address(0x99);

    uint256 internal poolId;

    function setUp() public virtual {
        stable = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        compliance = new SahmCompliance(officers);

        oracle = new SahmOracle(1 hours, 24 hours);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        collateral = new SahmCollateral(stable);
        treasury = new SahmTreasury(stable, 2000);
        risk = new SahmRisk(oracle);
        book = new SahmOrderBook(collateral, compliance, risk, treasury, stable);
        amm = new SahmAMM(compliance, risk, treasury, stable);
        margin = new SahmMargin(collateral, oracle, compliance, risk);
        insurance = new SahmInsuranceFund(stable);
        governor = new SahmGovernor(amm, margin, book, risk, treasury, 1000);

        // wiring
        collateral.grantRole(collateral.ORDERBOOK_ROLE(), address(book));
        collateral.grantRole(collateral.MARGIN_ROLE(), address(margin));
        risk.grantRole(risk.VENUE_ROLE(), address(book));
        risk.grantRole(risk.VENUE_ROLE(), address(amm));
        risk.grantRole(risk.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        book.grantRole(book.OPERATOR_ROLE(), address(governor));
        amm.grantRole(amm.OPERATOR_ROLE(), address(governor));
        margin.grantRole(margin.OPERATOR_ROLE(), address(governor));
        insurance.grantRole(insurance.COMMITTEE_ROLE(), officer);
        insurance.grantRole(insurance.COMMITTEE_ROLE(), address(this));
        insurance.setCommitteeSize(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);

        // risk parameters for the ETH market
        risk.setMarket(address(stable), 1_000_000 ether, 5_000_000 ether, 1000);

        // KYC
        vm.prank(officer);
        compliance.setKyc(traderA, SahmCompliance.KycTier.Professional);
        vm.prank(officer);
        compliance.setKyc(traderB, SahmCompliance.KycTier.Professional);
        vm.prank(officer);
        compliance.setKyc(lp, SahmCompliance.KycTier.Professional);
        vm.prank(officer);
        compliance.setKyc(liquidator, SahmCompliance.KycTier.Professional);

        // funding
        stable.setMinter(address(this));
        stable.mint(traderA, 1_000_000 ether);
        vm.prank(traderA);
        stable.approve(address(collateral), 1_000_000 ether);
        vm.prank(traderA);
        stable.approve(address(book), 1_000_000 ether);
        vm.prank(traderA);
        stable.approve(address(amm), 1_000_000 ether);
        stable.mint(traderB, 1_000_000 ether);
        vm.prank(traderB);
        stable.approve(address(collateral), 1_000_000 ether);
        vm.prank(traderB);
        stable.approve(address(book), 1_000_000 ether);
        vm.prank(traderB);
        stable.approve(address(amm), 1_000_000 ether);
        stable.mint(lp, 1_000_000 ether);
        vm.prank(lp);
        stable.approve(address(amm), 1_000_000 ether);
        stable.mint(liquidator, 1_000_000 ether);
        vm.prank(liquidator);
        stable.approve(address(margin), 1_000_000 ether);
        vm.prank(liquidator);
        stable.approve(address(collateral), 1_000_000 ether);

        // the ETH market: the stable doubles as the traded asset
        oracle.postPrice(address(stable), 2_000 ether);

        // seed the AMM pool: 10 ETH + 20,000 quote → price 2,000
        poolId = amm.listPool(stable);
        vm.prank(lp);
        amm.addLiquidity(poolId, 10 ether, 20_000 ether);

        // traders fund their margin accounts
        vm.prank(traderA);
        collateral.deposit(100_000 ether);
        vm.prank(traderB);
        collateral.deposit(100_000 ether);
        vm.prank(liquidator);
        collateral.deposit(100_000 ether);
    }

    function _openLong(address trader, uint256 marginAmount, uint256 leverageBps) internal returns (uint256) {
        vm.prank(trader);
        return margin.openPosition(address(stable), SahmMargin.Direction.Long, marginAmount, leverageBps);
    }
}
