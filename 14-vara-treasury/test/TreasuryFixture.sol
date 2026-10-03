// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {ComplianceModule} from "../src/ComplianceModule.sol";
import {VASPTreasury} from "../src/VASPTreasury.sol";

/// @notice Shared fixture: a licensed demo VASP "Desert Exchange FZE" with a
///         compliance module (default tier limits), the treasury (20% reserve),
///         three KYC'd clients and funded house equity.
abstract contract TreasuryFixture is Test {
    MockStable internal stable;
    ComplianceModule internal compliance;
    VASPTreasury internal treasury;

    address internal operator = address(this);
    address internal complianceOfficer = address(0xC);
    address internal guardian = address(0x6);
    address internal clientA = address(0xA);
    address internal clientB = address(0xB);
    address internal clientC = address(0xD);
    address internal sanctioned = address(0xE);
    address internal bank = address(0xBEEF);
    address internal outsider = address(0x9);

    function setUp() public virtual {
        stable = new MockStable();
        address[] memory officers = new address[](1);
        officers[0] = complianceOfficer;
        compliance = new ComplianceModule(officers);
        treasury = new VASPTreasury(compliance, 2000, guardian); // 20% reserve
        compliance.grantRole(compliance.COMPLIANCE_ROLE(), address(treasury));

        treasury.grantRole(treasury.GUARDIAN_ROLE(), guardian);
        treasury.grantRole(treasury.COMPLIANCE_ROLE(), complianceOfficer);

        treasury.listAsset(address(stable));

        vm.prank(complianceOfficer);
        compliance.setKyc(clientA, ComplianceModule.KycTier.Enhanced);
        vm.prank(complianceOfficer);
        compliance.setKyc(clientB, ComplianceModule.KycTier.Standard);
        vm.prank(complianceOfficer);
        compliance.setKyc(clientC, ComplianceModule.KycTier.Standard);
        vm.prank(complianceOfficer);
        compliance.setSanctioned(sanctioned, true);
        vm.prank(complianceOfficer);
        compliance.setCounterparty(bank, true);

        // fund house equity
        stable.setMinter(address(this));
        stable.mint(address(this), 30_000 ether);
        stable.approve(address(treasury), 30_000 ether);
        treasury.operatorDeposit(address(stable), 30_000 ether);
        vm.deal(address(this), 100 ether); // the fixture itself funds house ETH
        treasury.operatorDepositEth{ value: 10 ether }();
    }

    function _fundStable(address who, uint256 amount) internal {
        stable.mint(who, amount);
        vm.prank(who);
        stable.approve(address(treasury), amount);
    }

    function _clientDeposit(address who, uint256 amount) internal {
        _fundStable(who, amount);
        vm.prank(who);
        treasury.deposit(address(stable), amount);
    }
}
