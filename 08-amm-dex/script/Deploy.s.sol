// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMRouter} from "../src/AMMRouter.sol";
import {MockToken} from "../src/MockToken.sol";

/// @notice Deploys the factory, two demo tokens and the router, then seeds the GLD/USD pool
///         with 1,000,000 / 2,000,000 tokens of liquidity.
contract DeployAMM is Script {
    function run() external returns (AMMFactory factory, AMMRouter router, MockToken gold, MockToken usd) {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        factory = new AMMFactory();
        router = new AMMRouter(factory);
        gold = new MockToken("Gold", "GLD");
        usd = new MockToken("US Dollar", "USD");

        gold.mint(deployer, 10_000_000 ether);
        usd.mint(deployer, 10_000_000 ether);
        gold.approve(address(router), type(uint256).max);
        usd.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(gold), address(usd), 1_000_000 ether, 2_000_000 ether, 0, 0, deployer, block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        console2.log("Deployer :", deployer);
        console2.log("Factory  :", address(factory));
        console2.log("Router   :", address(router));
        console2.log("GLD      :", address(gold));
        console2.log("USD      :", address(usd));
        console2.log("Pool     :", factory.getPair(address(gold), address(usd)));
    }
}
