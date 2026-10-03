// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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

/// @title DeployMawarid
/// @notice Deploys the complete Mawarid platform: the asset registry with the first
///         live property ("Marina Gate Tower — Floor 21": 1,000 shares, 5,000,000 USD
///         appraisal), the compliance module, the share token, the primary market
///         (phase 1: 1,000 shares at 100 AED-S, 7 days), the OTC secondary market
///         (1% fee), the rental distributor (10% maintenance reserve), the treasury
///         (20% reserve), the insurance fund and the asset governor.
contract DeployMawarid is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address officer = vm.envOr("COMPLIANCE_OFFICER", deployer);
        address assessor2 = vm.envOr("ASSESSOR_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address assessor3 = vm.envOr("ASSESSOR_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        MockStable stable = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        MawaridCompliance compliance = new MawaridCompliance(officers);

        MawaridAssetRegistry registry = new MawaridAssetRegistry();
        uint256 assetId = registry.registerAsset(
            "Marina Gate Tower - Floor 21",
            "Residential",
            bytes32("docs-bundle-001"),
            1_000 ether,
            5_000_000 ether
        );
        registry.setStatus(assetId, MawaridAssetRegistry.Status.Live);

        MawaridShares shares = new MawaridShares(compliance, assetId, "Marina Gate Shares", "MGS");
        shares.setTransfersEnabled(true);

        MawaridPrimaryMarket primary = new MawaridPrimaryMarket(shares, compliance, registry, stable);
        MawaridTreasury treasury = new MawaridTreasury(stable, 2000);
        MawaridSecondaryMarket secondary = new MawaridSecondaryMarket(shares, compliance, stable, address(treasury), 100);
        MawaridRentalDistributor distributor = new MawaridRentalDistributor(shares, registry, stable, 1000);
        MawaridInsuranceFund insurance = new MawaridInsuranceFund(distributor, stable);
        MawaridAssetGovernor governor = new MawaridAssetGovernor(shares, registry, distributor, treasury);

        // ---- wiring ----
        registry.grantRole(registry.MANAGER_ROLE(), address(primary));
        registry.grantRole(registry.MANAGER_ROLE(), address(governor));
        shares.grantRole(shares.ISSUER_ROLE(), address(primary));
        secondary.grantRole(secondary.OPERATOR_ROLE(), address(treasury));
        distributor.grantRole(distributor.MANAGER_ROLE(), address(insurance));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.GUARDIAN_ROLE(), guardian);
        insurance.grantRole(insurance.ASSESSOR_ROLE(), assessor2);
        insurance.grantRole(insurance.ASSESSOR_ROLE(), assessor3);
        insurance.setAssessorCount(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        compliance.grantRole(compliance.COMPLIANCE_ROLE(), officer);

        // the market's own escrow account must pass KYC
        if (officer == deployer) {
            compliance.setKyc(address(secondary), MawaridCompliance.KycTier.Standard);
            compliance.setKyc(deployer, MawaridCompliance.KycTier.Accredited);
        }

        primary.openPhase(assetId, 100 ether, 1_000 ether, uint64(block.timestamp), uint64(block.timestamp + 7 days));
        vm.stopBroadcast();

        console2.log("Stable     :", address(stable));
        console2.log("Registry   :", address(registry), "| asset", assetId);
        console2.log("Compliance :", address(compliance));
        console2.log("Shares     :", address(shares));
        console2.log("Primary    :", address(primary), "| phase 0 open");
        console2.log("Secondary  :", address(secondary), "| 1% fee");
        console2.log("Distributor:", address(distributor), "| 10% reserve");
        console2.log("Treasury   :", address(treasury), "| 20% reserve");
        console2.log("Insurance  :", address(insurance));
        console2.log("Governor   :", address(governor));
    }
}
