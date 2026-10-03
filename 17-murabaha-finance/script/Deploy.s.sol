// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {MurabahaFinancing} from "../src/MurabahaFinancing.sol";

/// @title DeployMurabaha
/// @notice Deploys "Gulf Trade Finance": AED-S, the murabaha book with a charity
///         address for late penalties (never the financier), a 5% early-settlement
///         rebate, 2 tolerated missed installments and a 2% late penalty.
contract DeployMurabaha is Script {
    function run() external returns (MurabahaFinancing murabaha, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address shariahMember = vm.envOr("SHARIAH_MEMBER", deployer);
        address charity = vm.envOr("CHARITY", deployer);

        vm.startBroadcast(deployerKey);

        stable = new MockStable();
        murabaha = new MurabahaFinancing(stable, charity, 500, 2, 200);

        if (shariahMember != deployer) murabaha.grantRole(murabaha.SHARIAH_ROLE(), shariahMember);
        vm.stopBroadcast();

        console2.log("Stable  :", address(stable));
        console2.log("Murabaha:", address(murabaha));
        console2.log("Charity :", murabaha.charity(), "(late penalties are donated, never earned)");
    }
}
