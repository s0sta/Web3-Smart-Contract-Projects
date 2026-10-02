// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {MockToken} from "../src/MockToken.sol";

/// @notice Deploys a staking token, a reward token and the vault, then funds an emission
///         period of 1,000,000 REW over 30 days from the deployer.
contract DeployStakeVault is Script {
    function run() external returns (StakeVault vault, MockToken staking, MockToken reward) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        staking = new MockToken("Stake Token", "STAKE");
        reward = new MockToken("Reward Token", "REWARD");
        vault = new StakeVault(staking, reward, deployer);

        reward.mint(deployer, 1_000_000 ether);
        reward.approve(address(vault), 1_000_000 ether);
        vault.startRewards(1_000_000 ether, 30 days);
        vm.stopBroadcast();

        console2.log("Deployer  :", deployer);
        console2.log("StakeToken:", address(staking));
        console2.log("RewardToken:", address(reward));
        console2.log("Vault     :", address(vault));
        console2.log("RewardRate:", vault.rewardRate(), "REWARD / second");
    }
}
