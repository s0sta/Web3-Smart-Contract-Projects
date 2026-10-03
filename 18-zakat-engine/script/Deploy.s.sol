// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {AsnafRegistry} from "../src/AsnafRegistry.sol";
import {ZakatEngine} from "../src/ZakatEngine.sol";

/// @title DeployZakat
/// @notice Deploys "Bayt al-Mal" — the zakat engine: the asnaf registry with
///         default allocations (40/40/10/10 for the first four asnaf, the
///         remainder discretionary), the engine with a 4,000 AED-S nisab
///         (85g gold equivalent), and a 3-member committee.
contract DeployZakat is Script {
    function run() external returns (ZakatEngine engine, AsnafRegistry registry, MockStable stable) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address committee2 = vm.envOr("COMMITTEE_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address committee3 = vm.envOr("COMMITTEE_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));

        vm.startBroadcast(deployerKey);

        stable = new MockStable();

        address[] memory members = new address[](2);
        members[0] = committee2;
        members[1] = committee3;
        registry = new AsnafRegistry(members);
        engine = new ZakatEngine(registry, stable, 4_000 ether);

        engine.grantRole(engine.COMMITTEE_ROLE(), committee2);
        engine.grantRole(engine.COMMITTEE_ROLE(), committee3);
        registry.setEngine(address(engine));

        registry.setAllocation(0, 4000); // Fuqara
        registry.setAllocation(1, 4000); // Masakin
        registry.setAllocation(2, 1000); // Amil
        registry.setAllocation(3, 1000); // Muallaf
        vm.stopBroadcast();

        console2.log("Stable  :", address(stable));
        console2.log("Registry:", address(registry));
        console2.log("Engine  :", address(engine));
        console2.log("Nisab   :", engine.nisab(), "AED-S (85g gold equivalent)");
    }
}
