// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CrowdFundFactory} from "../src/CrowdFundFactory.sol";
import {CrowdFundCampaign} from "../src/CrowdFundCampaign.sol";

/// @notice Deploys the factory with a 1% platform fee and one example campaign.
contract DeployCrowdFund is Script {
    function run() external returns (CrowdFundFactory factory, CrowdFundCampaign example) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        factory = new CrowdFundFactory(100, deployer); // 1% fee
        example = factory.createCampaign(10 ether, 30 days);
        vm.stopBroadcast();

        console2.log("Deployer     :", deployer);
        console2.log("Factory      :", address(factory));
        console2.log("Fee (bps)    :", factory.feeBps());
        console2.log("Example camp :", address(example));
    }
}
