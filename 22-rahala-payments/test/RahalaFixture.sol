// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {RahalaStable} from "../src/RahalaStable.sol";
import {RahalaCompliance} from "../src/RahalaCompliance.sol";
import {RahalaOracle} from "../src/RahalaOracle.sol";
import {RahalaAccounts} from "../src/RahalaAccounts.sol";
import {RahalaTreasury} from "../src/RahalaTreasury.sol";
import {RahalaFX} from "../src/RahalaFX.sol";
import {RahalaEscrow} from "../src/RahalaEscrow.sol";
import {RahalaInvoices} from "../src/RahalaInvoices.sol";
import {RahalaSettlement} from "../src/RahalaSettlement.sol";
import {RahalaDisputes} from "../src/RahalaDisputes.sol";
import {RahalaGovernor} from "../src/RahalaGovernor.sol";

/// @notice The complete network wiring: AED-S settlement currency, a compliance
///         officer, an EMA FX oracle (USD at 3.67, EUR at 4.02), the participant
///         ledger, the treasury (20% reserve), the FX desk (0.5% fee / 0.2%
///         spread), the escrow rail (0.25% fee), invoice factoring (3% minimum
///         discount), batch netting, a 3-arbiter dispute desk and the governor
///         (10% quorum).
abstract contract RahalaFixture is Test {
    RahalaStable internal aeds;
    MockStable internal usdToken;
    RahalaCompliance internal compliance;
    RahalaOracle internal oracle;
    RahalaAccounts internal accounts;
    RahalaTreasury internal treasury;
    RahalaFX internal fx;
    RahalaEscrow internal escrow;
    RahalaInvoices internal invoices;
    RahalaSettlement internal netting;
    RahalaDisputes internal disputes;
    RahalaGovernor internal governor;

    address internal officer = address(0xC);
    address internal arbiter1 = address(0xA1);
    address internal arbiter2 = address(0xA2);
    address internal guardian = address(0x6);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal financier = address(0xF);
    address internal outsider = address(0x99);

    uint64 internal REGION_UAE = 784;
    uint64 internal REGION_US = 840;

    function setUp() public virtual {
        aeds = new RahalaStable("Rahala AED Stable", "AED-S");
        usdToken = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        compliance = new RahalaCompliance(officers);

        oracle = new RahalaOracle(1 hours, 24 hours);
        accounts = new RahalaAccounts(aeds);
        treasury = new RahalaTreasury(aeds, 2000);
        fx = new RahalaFX(aeds, oracle, compliance, treasury);
        escrow = new RahalaEscrow(aeds, compliance, treasury);
        invoices = new RahalaInvoices(aeds, compliance);
        netting = new RahalaSettlement(aeds);
        disputes = new RahalaDisputes();
        governor = new RahalaGovernor(accounts, fx, escrow, invoices, netting, treasury, compliance, oracle, 1000);

        // wiring
        escrow.grantRole(escrow.DISPUTES_ROLE(), address(disputes));
        disputes.grantRole(disputes.ARBITER_ROLE(), arbiter1);
        disputes.grantRole(disputes.ARBITER_ROLE(), arbiter2);
        disputes.grantRole(disputes.ARBITER_ROLE(), officer);
        disputes.setArbiterCount(3);
        fx.grantRole(fx.OPERATOR_ROLE(), address(governor));
        escrow.grantRole(escrow.DEFAULT_ADMIN_ROLE(), address(governor));
        invoices.grantRole(invoices.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        // regions + KYC
        vm.prank(officer);
        compliance.setRegionAllowed(REGION_UAE, true);
        vm.prank(officer);
        compliance.setRegionAllowed(REGION_US, true);
        for (address p = address(0x1); p <= address(0xF); p = address(uint160(p) + 1)) {
            vm.prank(officer);
            compliance.setKyc(p, RahalaCompliance.KycTier.Standard);
            vm.prank(officer);
            compliance.setHomeRegion(p, REGION_UAE);
        }
        vm.prank(officer);
        compliance.setKyc(address(fx), RahalaCompliance.KycTier.Standard);

        // FX: USD at 3.67 AED (i.e. 1 USD = 3.67)
        oracle.postRate(address(usdToken), 3_670_000_000_000_000_000); // 3.67e18

        // fund the network: the issuer credits participants
        aeds.grantRole(aeds.ISSUER_ROLE(), address(accounts));
        accounts.credit(alice, 100_000 ether);
        accounts.credit(bob, 100_000 ether);
        accounts.credit(financier, 100_000 ether);
        vm.prank(alice);
        aeds.approve(address(escrow), 1_000_000 ether);
        vm.prank(bob);
        aeds.approve(address(escrow), 1_000_000 ether);
        vm.prank(financier);
        aeds.approve(address(invoices), 1_000_000 ether);
        vm.prank(alice);
        aeds.approve(address(fx), 1_000_000 ether);
        vm.prank(bob);
        aeds.approve(address(fx), 1_000_000 ether);

        // USD currency + liquidity for the FX desk
        fx.listCurrency(address(usdToken), "USD", REGION_US);
        usdToken.setMinter(address(this));
        usdToken.mint(address(this), 1_000_000 ether);
        usdToken.approve(address(fx), 1_000_000 ether);
        fx.addLiquidity(address(usdToken), 1_000_000 ether);

        // the FX desk holds settlement for outflows
        aeds.grantRole(aeds.ISSUER_ROLE(), address(this));
        aeds.mint(address(fx), 1_000_000 ether);
    }
}
