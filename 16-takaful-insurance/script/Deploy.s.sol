// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {TakafulPool} from "../src/TakafulPool.sol";

/// @title DeployTakaful
/// @notice Deploys "Amanah Mutual" takaful: the AED-S stable and the pool with
///         three demo risk pools (Motor / Health / Property), a 3-member claims
///         committee and the guardian.
contract DeployTakaful is Script {
    function run() external returns (TakafulPool pool, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address assessor2 = vm.envOr("ASSESSOR_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address assessor3 = vm.envOr("ASSESSOR_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        stable = new MockStable();
        pool = new TakafulPool(stable);
        pool.grantRole(pool.ASSESSOR_ROLE(), assessor2);
        pool.grantRole(pool.ASSESSOR_ROLE(), assessor3);
        if (guardian != deployer) pool.grantRole(pool.GUARDIAN_ROLE(), guardian);
        pool.setAssessorCount(3);

        pool.registerPool("Motor", 500 ether, 1000, 2_000 ether, 90 days, 30 days);
        pool.registerPool("Health", 300 ether, 1000, 5_000 ether, 180 days, 30 days);
        pool.registerPool("Property", 1_000 ether, 1000, 20_000 ether, 365 days, 90 days);
        vm.stopBroadcast();

        console2.log("Stable:", address(stable));
        console2.log("Pool   :", address(pool));
        console2.log("Pools  : Motor 500 | Health 300 | Property 1,000 AED-S per policy");
    }
}
