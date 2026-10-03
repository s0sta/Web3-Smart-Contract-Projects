// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {JOPUnitRegistry} from "../src/JOPUnitRegistry.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {OwnersAssociationGovernor} from "../src/OwnersAssociationGovernor.sol";

/// @title DeployOwnersAssociation
/// @notice Deploys the full jointly-owned-property governance suite for a demo building —
///         "Marina Heights Residences": a stablecoin (AED-S), the unit registry with 8 units
///         across 5 owners, the treasury, and the governor with a 3-seat board, a compliance
///         officer and a guardian.
///
///         Two-step authority wiring:
///           1. stable + registry(authority=deployer) + treasury(authority=deployer)
///           2. governor → registry.setAuthority(governor) + treasury.setAuthority(governor)
///           3. DEFAULT_ADMIN_ROLE handed to the governor; deployer renounces it —
///              the association governs itself from block one.
contract DeployOwnersAssociation is Script {
    /// @notice Demo building data: owners, unit areas and the service-charge rate.
    struct DemoBuilding {
        address[5] owners;
        uint256[8] unitAreas; // per-unit area in sqm
        uint256 chargePerSqm; // annual AED-S per sqm
        address[3] board;
        address compliance;
        address guardian;
    }

    function run() external returns (JOPUnitRegistry registry, TreasuryVault treasury, OwnersAssociationGovernor governor, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);

        // Owner/board/compliance addresses: overridable via env, anvil defaults locally.
        address owner2 = vm.envOr("OWNER_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address owner3 = vm.envOr("OWNER_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address owner4 = vm.envOr("OWNER_4", address(0x90F79bf6EB2c4f870365E785982E1f101E93b906));
        address owner5 = vm.envOr("OWNER_5", address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65));
        address guardian = vm.envOr("GUARDIAN", deployer);

        DemoBuilding memory demo = DemoBuilding({
            owners: [deployer, owner2, owner3, owner4, owner5],
            unitAreas: [uint256(120), 120, 85, 85, 60, 60, 40, 40], // 610 sqm total
            chargePerSqm: 60 ether, // 60 AED-S per sqm per year
            board: [owner2, owner3, owner4],
            compliance: owner5,
            guardian: guardian
        });

        vm.startBroadcast(deployerKey);

        // 1) stable + registry + treasury (authority = deployer for the wiring step)
        stable = new MockStable();
        registry = new JOPUnitRegistry(stable, deployer);
        treasury = new TreasuryVault(stable, deployer);

        // 2) governor
        address[] memory boardList = new address[](3);
        boardList[0] = demo.board[0];
        boardList[1] = demo.board[1];
        boardList[2] = demo.board[2];
        governor = new OwnersAssociationGovernor(registry, treasury, demo.compliance, demo.guardian, boardList, 2 days, 5 days, 2 days);

        // 3) wire authorities and hand full admin to the governor
        registry.setTreasury(address(treasury));

        // 4) register the demo building while the deployer still holds registry authority
        for (uint256 i = 0; i < demo.unitAreas.length; i++) {
            registry.addUnit(demo.unitAreas[i], demo.owners[i % demo.owners.length]);
        }
        registry.setAnnualChargePerSqm(demo.chargePerSqm);

        // 5) hand every authority over to the association
        registry.setAuthority(address(governor));
        treasury.setAuthority(address(governor));
        governor.grantRole(governor.DEFAULT_ADMIN_ROLE(), address(governor));
        governor.renounceRole(governor.DEFAULT_ADMIN_ROLE());
        vm.stopBroadcast();

        console2.log("Stable       :", address(stable));
        console2.log("Registry     :", address(registry));
        console2.log("Treasury     :", address(treasury));
        console2.log("Governor     :", address(governor));
        console2.log("Units        :", registry.unitCount());
        console2.log("Total area   :", registry.totalAreaSqm());
        console2.log("Charge/sqm/yr:", registry.annualChargePerSqm());
    }
}
