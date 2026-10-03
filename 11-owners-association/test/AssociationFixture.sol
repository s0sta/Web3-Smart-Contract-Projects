// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {JOPUnitRegistry} from "../src/JOPUnitRegistry.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";
import {OwnersAssociationGovernor} from "../src/OwnersAssociationGovernor.sol";

/// @notice Shared fixture: a fully wired association with a demo building.
abstract contract AssociationFixture is Test {
    MockStable internal stable;
    JOPUnitRegistry internal registry;
    TreasuryVault internal treasury;
    OwnersAssociationGovernor internal governor;

    address internal admin = address(this);
    address internal owner2 = address(0x2);
    address internal owner3 = address(0x3);
    address internal owner4 = address(0x4);
    address internal owner5 = address(0x5); // compliance
    address internal guardian = address(0x6);
    address internal outsider = address(0x9);

    address[5] internal owners;
    uint256[8] internal unitAreas = [uint256(120), 120, 85, 85, 60, 60, 40, 40];

    function setUp() public virtual {
        owners = [admin, owner2, owner3, owner4, owner5];

        stable = new MockStable();
        registry = new JOPUnitRegistry(stable, admin);
        treasury = new TreasuryVault(stable, admin);

        address[] memory board = new address[](3);
        board[0] = owner2;
        board[1] = owner3;
        board[2] = owner4;
        governor = new OwnersAssociationGovernor(registry, treasury, owner5, guardian, board, 2 days, 5 days, 2 days);

        registry.setTreasury(address(treasury));

        // register the demo building while the deployer still holds registry authority
        for (uint256 i = 0; i < unitAreas.length; i++) {
            registry.addUnit(unitAreas[i], owners[i % owners.length]);
        }
        registry.setAnnualChargePerSqm(60 ether);
        vm.roll(block.number + 1); // proposals measure power at block-1

        // then hand every authority over to the association
        registry.setAuthority(address(governor));
        treasury.setAuthority(address(governor));
        governor.grantRole(governor.DEFAULT_ADMIN_ROLE(), address(governor));
        governor.renounceRole(governor.DEFAULT_ADMIN_ROLE());
    }

    function _propose(
        address proposer,
        uint8 pType,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory desc
    ) internal returns (uint256 id) {
        vm.prank(proposer);
        id = governor.propose(pType, targets, values, calldatas, desc);
    }

    function _vote(address voter, uint256 id, bool support) internal {
        vm.prank(voter);
        governor.vote(id, support);
    }
}
