// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {GovToken} from "../src/GovToken.sol";
import {Governor} from "../src/Governor.sol";

/// @notice Deploys the governance token (1,000,000 GOV to the deployer) and the governor:
///         3-day voting, 10,000 GOV proposal threshold, 4% quorum.
contract DeployDAO is Script {
    function run() external returns (GovToken token, Governor governor) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        token = new GovToken("Governance", "GOV", 1_000_000 ether, deployer);
        governor = new Governor(token, 3 days, 10_000 ether, 400);
        vm.stopBroadcast();

        console2.log("Deployer :", deployer);
        console2.log("GovToken :", address(token));
        console2.log("Governor :", address(governor));
        console2.log("Supply   :", token.totalSupply());
    }
}
