// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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

/// @title DeployAtaa
contract DeployAtaaStruct {
    struct Data {
        AtaaStable aeds;
        AtaaRegistry registry;
        AtaaOracle oracle;
        AtaaZakat zakat;
        AtaaVault vault;
        AtaaDonations donations;
        AtaaAllocations allocations;
        AtaaEmergency emergencyDesk;
        AtaaSponsorships sponsorships;
        AtaaGovernor governor;
    }
}

/// @notice Deploys the complete giving platform: the registry, the EMA oracle
///         (gold 300 AED/g, silver 5 AED/g), the zakat core (cash nisab 25,000),
///         the FIFO-provenance vault, the sadaqa desk, the 2-of-3 allocations
///         desk, emergency campaigns, monthly sponsorships and the governor.
contract DeployAtaa is Script {
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
        address committee2 = vm.envOr("COMMITTEE_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address committee3 = vm.envOr("COMMITTEE_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);
        DeployAtaaStruct.Data memory d = _deploy();
        _wire(d, officer, committee2, committee3, guardian);

        if (officer == deployer) {
            d.registry.registerDonor();
        }
        vm.stopBroadcast();

        console2.log("SAR-S       :", address(d.aeds));
        console2.log("Registry    :", address(d.registry));
        console2.log("Oracle      :", address(d.oracle));
        console2.log("Zakat       :", address(d.zakat), "| nisab 25,000");
        console2.log("Vault       :", address(d.vault));
        console2.log("Donations   :", address(d.donations));
        console2.log("Allocations :", address(d.allocations));
        console2.log("Emergency   :", address(d.emergencyDesk));
        console2.log("Sponsorships:", address(d.sponsorships));
        console2.log("Governor    :", address(d.governor));
    }

    function _deploy() internal returns (DeployAtaaStruct.Data memory d) {
        d.aeds = new AtaaStable("Ataa Saudi Riyal", "SAR-S");
        d.registry = new AtaaRegistry();
        d.oracle = new AtaaOracle(1 hours, 24 hours);
        d.vault = new AtaaVault(d.aeds);
        d.zakat = new AtaaZakat(d.registry, d.oracle, d.vault, d.aeds);
        d.donations = new AtaaDonations(d.registry, d.vault, d.aeds);
        d.allocations = new AtaaAllocations(d.registry, d.vault);
        d.emergencyDesk = new AtaaEmergency(d.registry, d.vault, d.aeds);
        d.sponsorships = new AtaaSponsorships(d.registry, d.vault, d.aeds);
        d.governor = new AtaaGovernor(d.registry, d.zakat, d.vault, d.allocations, d.emergencyDesk, d.sponsorships, d.oracle, 100);
    }

    function _wire(DeployAtaaStruct.Data memory d, address officer, address committee2, address committee3, address guardian) internal {
        d.registry.grantRole(d.registry.OFFICER_ROLE(), officer);
        d.registry.grantRole(d.registry.COMMITTEE_ROLE(), committee2);
        d.registry.grantRole(d.registry.COMMITTEE_ROLE(), committee3);
        d.allocations.grantRole(d.allocations.COMMITTEE_ROLE(), committee2);
        d.allocations.grantRole(d.allocations.COMMITTEE_ROLE(), committee3);
        d.allocations.grantRole(d.allocations.DEFAULT_ADMIN_ROLE(), address(d.governor));
        d.emergencyDesk.grantRole(d.emergencyDesk.COMMITTEE_ROLE(), committee2);
        d.emergencyDesk.grantRole(d.emergencyDesk.COMMITTEE_ROLE(), committee3);
        d.zakat.grantRole(d.zakat.COMMITTEE_ROLE(), committee2);
        d.zakat.grantRole(d.zakat.COMMITTEE_ROLE(), committee3);
        d.vault.grantRole(d.vault.ALLOCATIONS_ROLE(), address(d.allocations));
        d.vault.grantRole(d.vault.ALLOCATIONS_ROLE(), address(d.emergencyDesk));
        d.vault.grantRole(d.vault.ALLOCATIONS_ROLE(), address(d.donations));
        d.vault.grantRole(d.vault.ALLOCATIONS_ROLE(), address(d.sponsorships));
        d.vault.setZakatModule(d.zakat);
        d.governor.grantRole(d.governor.GUARDIAN_ROLE(), guardian);
        d.oracle.grantRole(d.oracle.GUARDIAN_ROLE(), guardian);

        d.oracle.setAssets(address(0x60), address(0x51));
        d.oracle.postPrice(address(0x60), 300 ether); // 300 SAR per gram of gold
        d.oracle.postPrice(address(0x51), 5 ether);
        d.zakat.setCashNisab(25_000 ether);
    }
}
