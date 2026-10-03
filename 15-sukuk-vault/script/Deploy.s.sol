// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {SukukVault} from "../src/SukukVault.sol";

/// @title DeploySukuk
/// @notice Deploys "Green Ijarah Sukuk — Series 1": 1,000 certificates at
///         100 AED-S face value, 365-day maturity, 8% indicative profit,
///         10% profit-smoothing reserve. The deployer is issuer + Shariah
///         board; an optional second Shariah member and guardian can be set.
contract DeploySukuk is Script {
    function run() external returns (SukukVault vault, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address shariahMember = vm.envOr("SHARIAH_MEMBER", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        stable = new MockStable();
        vault = new SukukVault(stable, 1000); // 10% smoothing reserve

        if (shariahMember != deployer) vault.grantRole(vault.SHARIAH_ROLE(), shariahMember);
        if (guardian != deployer) vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        vault.issueSeries(
            "Green Ijarah Sukuk - Series 1",
            100 ether, // face value per certificate
            1000, // total certificates
            uint64(block.timestamp + 365 days), // maturity
            "Solar rooftop array, Al Quoz - 1.2 MWp",
            800 // 8% indicative annual profit
        );
        vm.stopBroadcast();

        console2.log("Stable:", address(stable));
        console2.log("Vault  :", address(vault));
        console2.log("Series :", 0, "| 1,000 certificates x 100 AED-S | 365-day maturity");
    }
}
