// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {WaqfVault} from "../src/WaqfVault.sol";
import {BeneficiaryRegistry} from "../src/BeneficiaryRegistry.sol";
import {WaqfGovernor} from "../src/WaqfGovernor.sol";

/// @notice Shared fixture: "Amanah Education Waqf" — corpus from two donors,
///         two beneficiaries (60/40), a three-nazir board, governor wired.
abstract contract WaqfFixture is Test {
    MockStable internal stable;
    WaqfVault internal vault;
    BeneficiaryRegistry internal registry;
    WaqfGovernor internal governor;

    address internal donorA = address(0xA);
    address internal donorB = address(0xB);
    address internal nazir1 = address(0xC);
    address internal nazir2 = address(0xD);
    address internal nazir3 = address(0xE);
    address internal beneficiary1 = address(0x1);
    address internal beneficiary2 = address(0x2);
    address internal guardian = address(0x6);
    address internal outsider = address(0x9);

    function setUp() public virtual {
        stable = new MockStable();
        vault = new WaqfVault(stable);
        registry = new BeneficiaryRegistry();

        address[] memory nazirs = new address[](3);
        nazirs[0] = nazir1;
        nazirs[1] = nazir2;
        nazirs[2] = nazir3;
        governor = new WaqfGovernor(vault, registry, nazirs, 1_000 ether, 1000, 2 days);

        vault.grantRole(vault.NAZIR_ROLE(), nazir1);
        vault.grantRole(vault.NAZIR_ROLE(), nazir2);
        vault.grantRole(vault.NAZIR_ROLE(), nazir3);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);

        // the governor spends the operational fund via spendOperational (NAZIR-gated)
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(governor));
        vault.grantRole(vault.NAZIR_ROLE(), address(governor));
        // governor controls the registry
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), address(governor));
        registry.revokeRole(registry.NAZIR_ROLE(), address(this));
        registry.grantRole(registry.NAZIR_ROLE(), nazir1);
        registry.grantRole(registry.NAZIR_ROLE(), nazir2);
        registry.grantRole(registry.NAZIR_ROLE(), nazir3);
        registry.setGovernor(address(governor));

        vm.prank(nazir1);
        registry.addBeneficiary(beneficiary1, 6000); // 60%
        vm.prank(nazir1);
        registry.addBeneficiary(beneficiary2, 4000); // 40%

        stable.setMinter(address(this));
        stable.mint(donorA, 10_000 ether);
        stable.mint(donorB, 10_000 ether);
        vm.prank(donorA);
        stable.approve(address(vault), 10_000 ether);
        vm.prank(donorB);
        stable.approve(address(vault), 10_000 ether);
        vm.prank(donorA);
        vault.endow(5_000 ether);
        vm.prank(donorB);
        vault.endow(5_000 ether);

        vm.roll(block.number + 1); // proposals measure power at block - 1
    }

    function _recordIncome(uint256 amount) internal {
        stable.mint(nazir1, amount);
        vm.prank(nazir1);
        stable.approve(address(vault), amount);
        vm.prank(nazir1);
        vault.recordIncome(amount);
    }

    function _distributionTargets() internal view returns (address[] memory a, uint256[] memory w) {
        return registry.distributionTargets();
    }
}
