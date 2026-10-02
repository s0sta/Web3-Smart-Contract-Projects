// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisNFT} from "../src/GenesisNFT.sol";

/// @notice Deploys the collection. Set MERKLE_ROOT and BASE_URI in .env when known
///         (the root is computed off-chain from the whitelist CSV/JSON).
contract DeployGenesisNFT is Script {
    function run() external returns (GenesisNFT nft) {
        uint256 deployerKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        nft = new GenesisNFT(deployer, "Genesis", "GEN");
        vm.stopBroadcast();

        console2.log("Deployer :", deployer);
        console2.log("NFT      :", address(nft));
        console2.log("Max      :", nft.MAX_SUPPLY());
        console2.log("Royalty  :", nft.royaltyBps(), "bps to", nft.royaltyRecipient());

        // Post-deploy (uncomment once the whitelist is finalized):
        // vm.startBroadcast(deployerKey);
        // nft.setMerkleRoot(vm.envBytes32("MERKLE_ROOT"));
        // nft.setPrerevealURI(vm.envString("PREREVEAL_URI"));
        // nft.setPhase(GenesisNFT.Phase.Whitelist);
        // vm.stopBroadcast();
    }
}
