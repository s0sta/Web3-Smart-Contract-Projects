// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TrustEscrow} from "../src/TrustEscrow.sol";

/// @notice Deploys the escrow platform with a 0.5% fee and opens one example deal.
contract DeployTrustEscrow is Script {
    function run() external returns (TrustEscrow escrow, uint256 exampleDealId) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);
        address exampleSeller = vm.envOr("SELLER", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address exampleArbiter = vm.envOr("ARBITER", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));

        vm.startBroadcast(deployerKey);
        escrow = new TrustEscrow(50, deployer); // 0.5% fee
        exampleDealId = escrow.openDeal{value: 1 ether}(exampleSeller, exampleArbiter);
        vm.stopBroadcast();

        console2.log("Deployer  :", deployer);
        console2.log("Escrow    :", address(escrow));
        console2.log("Fee (bps) :", escrow.feeBps());
        console2.log("Example   : deal", exampleDealId, "deposit 1 ETH");
    }
}
