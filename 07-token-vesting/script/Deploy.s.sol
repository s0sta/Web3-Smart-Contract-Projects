// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {MockToken} from "../src/MockToken.sol";

/// @notice Deploys a token and a vesting contract, then creates one example schedule:
///         1,000,000 TKN for a beneficiary — 1 year cliff, then 3 years linear.
contract DeployTokenVesting is Script {
    function run() external returns (TokenVesting vesting, MockToken token, uint256 scheduleId) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);
        address beneficiary = vm.envOr("BENEFICIARY", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));

        vm.startBroadcast(deployerKey);
        token = new MockToken("Vesting Token", "VEST");
        vesting = new TokenVesting(token, deployer);

        token.mint(deployer, 1_000_000 ether);
        token.approve(address(vesting), 1_000_000 ether);
        vesting.createSchedule(beneficiary, 1_000_000 ether, block.timestamp, 365 days, 3 * 365 days);
        vm.stopBroadcast();

        console2.log("Deployer    :", deployer);
        console2.log("Token       :", address(token));
        console2.log("Vesting     :", address(vesting));
        console2.log("Beneficiary :", beneficiary);
    }
}
