// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {RERAPropertyRegistry} from "../src/RERAPropertyRegistry.sol";
import {RentalDistributor} from "../src/RentalDistributor.sol";

/// @title DeployEstate
/// @notice Deploys the tokenized estate demo: AED-S, the property registry, and the
///         rental distributor (10% maintenance reserve). Registers "Marina Gate Tower"
///         — 1,000 shares at a 5,000,000 USD appraisal — whitelists three investors
///         and issues the shares: developer 400 · investor B 300 · investor C 300.
contract DeployEstate is Script {
    function run() external returns (RERAPropertyRegistry registry, RentalDistributor distributor, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);

        address investorB = vm.envOr("INVESTOR_B", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address investorC = vm.envOr("INVESTOR_C", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address compliance = vm.envOr("COMPLIANCE", deployer);

        vm.startBroadcast(deployerKey);

        stable = new MockStable();
        registry = new RERAPropertyRegistry();
        distributor = new RentalDistributor(registry, stable, 1000); // 10% reserve

        // the regulator operates under its own address when provided
        if (compliance != deployer) {
            registry.grantRole(registry.COMPLIANCE_ROLE(), compliance);
            distributor.grantRole(distributor.COMPLIANCE_ROLE(), compliance);
        }

        uint256 propertyId = registry.registerProperty("Marina Gate Tower", 1_000 ether, 5_000_000 ether);
        registry.setWhitelisted(propertyId, deployer, true);
        registry.setWhitelisted(propertyId, investorB, true);
        registry.setWhitelisted(propertyId, investorC, true);

        registry.issueShares(propertyId, deployer, 400 ether);
        registry.issueShares(propertyId, investorB, 300 ether);
        registry.issueShares(propertyId, investorC, 300 ether);
        vm.stopBroadcast();

        console2.log("Stable     :", address(stable));
        console2.log("Registry   :", address(registry));
        console2.log("Distributor:", address(distributor));
        console2.log("Property   :", propertyId, "| 1,000 shares");
        console2.log("Issued     :", registry.balanceOf(propertyId, deployer), "dev shares");
    }
}
