// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {WaqfVault} from "../src/WaqfVault.sol";
import {BeneficiaryRegistry} from "../src/BeneficiaryRegistry.sol";
import {WaqfGovernor} from "../src/WaqfGovernor.sol";

/// @title DeployWaqf
/// @notice Deploys the "Amanah Education Waqf" demo: the vault, the beneficiary
///         register (60/40 split), and the governor (3-nazir board, 10% donor
///         quorum, 2-day timelock, 1,000-token proposal threshold). The deployer
///         endows 10,000 AED-S as the founding corpus.
contract DeployWaqf is Script {
    function run() external returns (WaqfVault vault, BeneficiaryRegistry registry, WaqfGovernor governor, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);

        address nazir2 = vm.envOr("NAZIR_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address nazir3 = vm.envOr("NAZIR_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address beneficiary2 = vm.envOr("BENEFICIARY_2", address(0x90F79bf6EB2c4f870365E785982E1f101E93b906));

        vm.startBroadcast(deployerKey);

        stable = new MockStable();
        vault = new WaqfVault(stable);
        registry = new BeneficiaryRegistry();

        address[] memory nazirs = new address[](3);
        nazirs[0] = deployer;
        nazirs[1] = nazir2;
        nazirs[2] = nazir3;
        governor = new WaqfGovernor(vault, registry, nazirs, 1_000 ether, 1000, 2 days);

        // wire roles
        vault.grantRole(vault.NAZIR_ROLE(), nazir2);
        vault.grantRole(vault.NAZIR_ROLE(), nazir3);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(governor));
        vault.grantRole(vault.NAZIR_ROLE(), address(governor));

        registry.grantRole(registry.NAZIR_ROLE(), nazir2);
        registry.grantRole(registry.NAZIR_ROLE(), nazir3);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(governor));
        registry.setGovernor(address(governor));

        // beneficiaries: deployer's chosen cause 60% · second cause 40%
        registry.addBeneficiary(deployer, 6000);
        registry.addBeneficiary(beneficiary2, 4000);

        // then the deployer steps back — the association runs itself
        registry.revokeRole(registry.NAZIR_ROLE(), deployer);
        registry.revokeRole(registry.GOVERNOR_ROLE(), deployer);

        // founding endowment
        stable.mint(deployer, 10_000 ether);
        stable.approve(address(vault), 10_000 ether);
        vault.endow(10_000 ether);
        vm.stopBroadcast();

        console2.log("Stable   :", address(stable));
        console2.log("Vault    :", address(vault));
        console2.log("Registry :", address(registry));
        console2.log("Governor :", address(governor));
        console2.log("Corpus   :", vault.totalCorpus(), "AED-S endowed");
    }
}
