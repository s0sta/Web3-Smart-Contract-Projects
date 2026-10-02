// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {NovaToken} from "../src/Token.sol";

/// @title DeployNovaToken
/// @notice Deployment script. Set PRIVATE_KEY in a .env file, or leave it unset to use
///         anvil's first default key for local testing.
contract DeployNovaToken is Script {
    function run() external returns (NovaToken token) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        token = new NovaToken("NovaToken", "NOVA", deployer);
        vm.stopBroadcast();

        console2.log("Deployer   :", deployer);
        console2.log("NovaToken  :", address(token));
        console2.log("Max supply :", token.MAX_SUPPLY());
    }
}
