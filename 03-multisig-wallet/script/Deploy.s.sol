// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

/// @notice Deploys a 2-of-3 multisig wallet. Uses the first three anvil default keys as
///         owners unless OWNER_2/OWNER_3 are set in .env.
contract DeployMultiSig is Script {
    function run() external returns (MultiSigWallet wallet) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address owner1 = vm.addr(deployerKey);
        address owner2 = vm.envOr("OWNER_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address owner3 = vm.envOr("OWNER_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        vm.startBroadcast(deployerKey);
        wallet = new MultiSigWallet(owners, 2); // 2-of-3
        vm.stopBroadcast();

        console2.log("Owners     :", owner1, owner2, owner3);
        console2.log("Threshold  :", wallet.threshold());
        console2.log("MultiSig   :", address(wallet));
    }
}
