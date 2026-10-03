// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {ComplianceModule} from "../src/ComplianceModule.sol";
import {VASPTreasury} from "../src/VASPTreasury.sol";

/// @title DeployTreasury
/// @notice Deploys the demo licensed VASP "Desert Exchange FZE": the compliance
///         module (one compliance officer), the treasury (20% capital reserve,
///         recovery address = deployer), the AED-S stable, and funds 30,000
///         AED-S of house equity so client flows can start immediately.
contract DeployTreasury is Script {
    function run() external returns (VASPTreasury treasury, ComplianceModule compliance, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address complianceOfficer = vm.envOr("COMPLIANCE_OFFICER", deployer);

        vm.startBroadcast(deployerKey);

        stable = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = complianceOfficer;
        compliance = new ComplianceModule(officers);
        treasury = new VASPTreasury(compliance, 2000, deployer);

        // the treasury is the enforcement arm of the compliance module
        if (complianceOfficer != deployer) {
            compliance.grantRole(compliance.COMPLIANCE_ROLE(), address(treasury));
            treasury.grantRole(treasury.COMPLIANCE_ROLE(), complianceOfficer);
            treasury.grantRole(treasury.GUARDIAN_ROLE(), complianceOfficer);
        } else {
            compliance.grantRole(compliance.COMPLIANCE_ROLE(), address(treasury));
        }

        treasury.listAsset(address(stable));

        // house equity so the 20% reserve covers incoming client deposits
        stable.mint(deployer, 30_000 ether);
        stable.approve(address(treasury), 30_000 ether);
        treasury.operatorDeposit(address(stable), 30_000 ether);
        vm.stopBroadcast();

        console2.log("Stable    :", address(stable));
        console2.log("Compliance:", address(compliance));
        console2.log("Treasury  :", address(treasury));
        console2.log("House     :", treasury.houseBalances(address(stable)), "AED-S equity");
    }
}
