// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {AtaaStable} from "../src/AtaaStable.sol";
import {AtaaRegistry} from "../src/AtaaRegistry.sol";
import {AtaaOracle} from "../src/AtaaOracle.sol";
import {AtaaZakat} from "../src/AtaaZakat.sol";
import {AtaaVault} from "../src/AtaaVault.sol";
import {AtaaDonations} from "../src/AtaaDonations.sol";
import {AtaaAllocations} from "../src/AtaaAllocations.sol";
import {AtaaEmergency} from "../src/AtaaEmergency.sol";
import {AtaaSponsorships} from "../src/AtaaSponsorships.sol";
import {AtaaGovernor} from "../src/AtaaGovernor.sol";

/// @notice The complete giving platform: AED-S payments, a registry with a
///         donor, a KYC'd beneficiary (orphans, 1,000/month) and two committee
///         members, the EMA oracle (gold/silver feeds), the zakat core (cash
///         nisab 25,000), the FIFO-provenance vault, the sadaqa desk, the
///         2-of-3 allocations desk with category budgets, emergency campaigns,
///         monthly sponsorships and the donor-weighted governor.
abstract contract AtaaFixture is Test {
    AtaaStable internal aeds;
    AtaaRegistry internal registry;
    AtaaOracle internal oracle;
    AtaaZakat internal zakat;
    AtaaVault internal vault;
    AtaaDonations internal donations;
    AtaaAllocations internal allocations;
    AtaaEmergency internal emergencyDesk;
    AtaaSponsorships internal sponsorships;
    AtaaGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal donor = address(0xA);
    address internal donor2 = address(0xB);
    address internal committee1 = address(0xF1);
    address internal committee2 = address(0xF2);
    address internal beneficiaryWallet = address(0x77);
    address internal outsider = address(0x99);

    uint256 internal beneficiaryId;

    function setUp() public virtual {
        aeds = new AtaaStable("Ataa Saudi Riyal", "SAR-S");
        registry = new AtaaRegistry();
        oracle = new AtaaOracle(1 hours, 24 hours);
        vault = new AtaaVault(aeds);
        zakat = new AtaaZakat(registry, oracle, vault, aeds);
        donations = new AtaaDonations(registry, vault, aeds);
        allocations = new AtaaAllocations(registry, vault);
        emergencyDesk = new AtaaEmergency(registry, vault, aeds);
        sponsorships = new AtaaSponsorships(registry, vault, aeds);
        governor = new AtaaGovernor(registry, zakat, vault, allocations, emergencyDesk, sponsorships, oracle, 0);

        // wiring
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        registry.grantRole(registry.COMMITTEE_ROLE(), committee1);
        registry.grantRole(registry.COMMITTEE_ROLE(), committee2);
        allocations.grantRole(allocations.DEFAULT_ADMIN_ROLE(), address(governor));
        allocations.grantRole(allocations.COMMITTEE_ROLE(), committee1);
        allocations.grantRole(allocations.COMMITTEE_ROLE(), committee2);
        emergencyDesk.grantRole(emergencyDesk.COMMITTEE_ROLE(), committee1);
        emergencyDesk.grantRole(emergencyDesk.COMMITTEE_ROLE(), committee2);
        zakat.grantRole(zakat.COMMITTEE_ROLE(), committee1);
        zakat.grantRole(zakat.COMMITTEE_ROLE(), committee2);
        vault.grantRole(vault.ALLOCATIONS_ROLE(), address(allocations));
        vault.grantRole(vault.ALLOCATIONS_ROLE(), address(emergencyDesk));
        vault.grantRole(vault.ALLOCATIONS_ROLE(), address(donations));
        vault.grantRole(vault.ALLOCATIONS_ROLE(), address(sponsorships));
        vault.setZakatModule(zakat);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        // gold/silver feeds
        oracle.setAssets(address(0x60), address(0x51)); // placeholder tokens
        oracle.postPrice(address(0x60), 300 ether); // 300 AED per gram of gold
        oracle.postPrice(address(0x51), 5 ether); // 5 AED per gram of silver

        // nisab: 85g gold × 300 = 25,500 AED
        vm.prank(committee1);
        zakat.setCashNisab(25_000 ether);

        // participants
        vm.prank(donor);
        registry.registerDonor();
        vm.prank(donor2);
        registry.registerDonor();
        vm.prank(officer);
        beneficiaryId = registry.registerBeneficiary(bytes32("orphan-center"), AtaaRegistry.Category.Orphans, 1_000 ether, "orphan sponsorship");

        // funds
        // the test contract holds ISSUER_ROLE (constructor grant)
        aeds.mint(donor, 1_000_000 ether);
        vm.prank(donor);
        aeds.approve(address(vault), 1_000_000 ether);
        vm.prank(donor);
        aeds.approve(address(zakat), 1_000_000 ether);
        vm.prank(donor);
        aeds.approve(address(donations), 1_000_000 ether);
        vm.prank(donor);
        aeds.approve(address(sponsorships), 1_000_000 ether);
        vm.prank(donor);
        aeds.approve(address(emergencyDesk), 1_000_000 ether);
        aeds.mint(donor2, 1_000_000 ether);
        vm.prank(donor2);
        aeds.approve(address(zakat), 1_000_000 ether);
        vm.prank(donor2);
        aeds.approve(address(vault), 1_000_000 ether);
        vm.prank(donor2);
        aeds.approve(address(donations), 1_000_000 ether);
    }
}
