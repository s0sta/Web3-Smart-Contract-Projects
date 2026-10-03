// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {MawaridAssetRegistry} from "../src/MawaridAssetRegistry.sol";
import {MawaridCompliance} from "../src/MawaridCompliance.sol";
import {MawaridShares} from "../src/MawaridShares.sol";
import {MawaridPrimaryMarket} from "../src/MawaridPrimaryMarket.sol";
import {MawaridSecondaryMarket} from "../src/MawaridSecondaryMarket.sol";
import {MawaridRentalDistributor} from "../src/MawaridRentalDistributor.sol";
import {MawaridTreasury} from "../src/MawaridTreasury.sol";
import {MawaridInsuranceFund} from "../src/MawaridInsuranceFund.sol";
import {MawaridAssetGovernor} from "../src/MawaridAssetGovernor.sol";

/// @notice The full platform wiring: one live asset ("Marina Gate Tower — Floor 21",
///         1,000 shares, 5,000,000 USD appraisal), KYC'd investors, a primary phase,
///         the secondary market, the distributor (10% maintenance reserve), the
///         treasury (20% reserve) and the insurance fund.
abstract contract MawaridFixture is Test {
    MockStable internal stable;
    MawaridAssetRegistry internal registry;
    MawaridCompliance internal compliance;
    MawaridShares internal shares;
    MawaridPrimaryMarket internal primary;
    MawaridSecondaryMarket internal secondary;
    MawaridRentalDistributor internal distributor;
    MawaridTreasury internal treasury;
    MawaridInsuranceFund internal insurance;
    MawaridAssetGovernor internal governor;

    address internal manager = address(this);
    address internal officer = address(0xC);
    address internal assessor1 = address(0xD);
    address internal assessor2 = address(0xE);
    address internal guardian = address(0x6);
    address internal investorA = address(0xA);
    address internal investorB = address(0xB);
    address internal investorC = address(0x1);
    address internal outsider = address(0x99);

    uint256 internal assetId;
    uint256 internal phaseId;

    function setUp() public virtual {
        stable = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        compliance = new MawaridCompliance(officers);

        registry = new MawaridAssetRegistry();
        assetId = registry.registerAsset("Marina Gate Tower - Floor 21", "Residential", bytes32("docs-bundle"), 1_000 ether, 5_000_000 ether);
        registry.setStatus(assetId, MawaridAssetRegistry.Status.Live);

        shares = new MawaridShares(compliance, assetId, "Marina Gate Shares", "MGS");
        shares.setTransfersEnabled(true);

        primary = new MawaridPrimaryMarket(shares, compliance, registry, stable);
        secondary = new MawaridSecondaryMarket(shares, compliance, stable, address(this), 100); // 1% fee
        distributor = new MawaridRentalDistributor(shares, registry, stable, 1000); // 10% reserve
        treasury = new MawaridTreasury(stable, 2000); // 20% reserve
        insurance = new MawaridInsuranceFund(distributor, stable);
        distributor.grantRole(distributor.MANAGER_ROLE(), address(insurance));
        governor = new MawaridAssetGovernor(shares, registry, distributor, treasury);

        // wiring
        registry.grantRole(registry.MANAGER_ROLE(), address(primary));
        registry.grantRole(registry.MANAGER_ROLE(), address(governor));
        shares.grantRole(shares.ISSUER_ROLE(), address(primary));
        secondary.setTreasury(address(treasury));
        secondary.grantRole(secondary.OPERATOR_ROLE(), address(treasury));
        secondary.grantRole(secondary.OPERATOR_ROLE(), manager);
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.GUARDIAN_ROLE(), guardian);
        insurance.grantRole(insurance.ASSESSOR_ROLE(), assessor1);
        insurance.grantRole(insurance.ASSESSOR_ROLE(), assessor2);
        insurance.setAssessorCount(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        compliance.grantRole(compliance.COMPLIANCE_ROLE(), officer);

        for (uint256 i = 1; i < 6; i++) {
            vm.prank(officer);
            compliance.setKyc(address(uint160(i)), MawaridCompliance.KycTier.Standard);
        }
        vm.prank(officer);
        compliance.setKyc(investorA, MawaridCompliance.KycTier.Accredited);
        vm.prank(officer);
        compliance.setKyc(investorB, MawaridCompliance.KycTier.Standard);
        vm.prank(officer);
        compliance.setKyc(address(secondary), MawaridCompliance.KycTier.Standard);
        vm.prank(officer);
        compliance.setExposureLimit(assetId, 1_000 ether);

        stable.setMinter(address(this));
        for (uint256 i = 1; i < 6; i++) {
            stable.mint(address(uint160(i)), 1_000_000 ether);
            vm.prank(address(uint160(i)));
            stable.approve(address(primary), 1_000_000 ether);
            vm.prank(address(uint160(i)));
            stable.approve(address(secondary), 1_000_000 ether);
        }
        stable.mint(investorA, 1_000_000 ether);
        vm.prank(investorA);
        stable.approve(address(primary), 1_000_000 ether);
        vm.prank(investorA);
        stable.approve(address(secondary), 1_000_000 ether);
        vm.prank(investorA);
        shares.approve(address(secondary), type(uint256).max);
        stable.mint(investorB, 1_000_000 ether);
        vm.prank(investorB);
        stable.approve(address(primary), 1_000_000 ether);
        vm.prank(investorB);
        stable.approve(address(secondary), 1_000_000 ether);
        vm.prank(investorB);
        shares.approve(address(secondary), type(uint256).max);

        // a primary phase: 1,000 shares at 100 each
        phaseId = primary.openPhase(assetId, 100 ether, 1_000 ether, uint64(block.timestamp), uint64(block.timestamp + 7 days));
    }

    function _subscribe(address who, uint256 amount) internal {
        vm.prank(who);
        primary.subscribe(phaseId, amount);
    }

    function _runPrimaryRound() internal {
        _subscribe(investorA, 400 ether);
        _subscribe(investorB, 300 ether);
        vm.warp(block.timestamp + 8 days);
        primary.finalizePhase(phaseId);
        vm.prank(investorA);
        primary.claimAllocation(phaseId);
        vm.prank(investorB);
        primary.claimAllocation(phaseId);
        vm.roll(block.number + 1);
    }
}
