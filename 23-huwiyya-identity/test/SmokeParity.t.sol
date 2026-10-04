// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HuwiyyaMerkle} from "../src/HuwiyyaMerkle.sol";

contract SmokeParityTest is Test {
    function test_Parity_WithSmokeValues() public pure {
        bytes32 claimName = 0x1dc2338c9c41085a482ba48bb6331eef3179b93da72d4156b99eb3b87068332c;
        bytes32 claimDob = 0xc9413e6eeaa7d2dcaeaeb32dd39b6351b1aa89ce6ffb5ccf4706cb412539c9d1;
        bytes32 level1b = 0x11c3e4ffb3629483b571a5a7730ee190e682145aaae8ae3018d210f90cd3060b;
        bytes32 root = 0x848d80e585010224f47d604689d1797879ab3fabc54f105408f7b4951ac3f330;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = claimName;
        proof[1] = level1b;
        assertTrue(HuwiyyaMerkle.verify(root, claimDob, 1, proof));
    }
}
