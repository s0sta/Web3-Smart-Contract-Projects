// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LendVault} from "../src/LendVault.sol";
import {MockStable} from "../src/MockStable.sol";

/// @notice Deploys the demo stablecoin and the lending vault, wiring the vault as the
///         sole minter/burner of the stable.
contract DeployLendVault is Script {
    function run() external returns (LendVault vault, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        stable = new MockStable();
        vault = new LendVault(stable, deployer);
        stable.setVault(address(vault));
        vm.stopBroadcast();

        console2.log("Deployer :", deployer);
        console2.log("Stable   :", address(stable));
        console2.log("Vault    :", address(vault));
        console2.log("Rate/s   :", vault.ratePerSecond(), "(1e18-scaled)");
        console2.log("LTV      :", vault.LTV_BPS(), "bps | LiqThreshold:", vault.LIQ_THRESHOLD_BPS());
    }
}
