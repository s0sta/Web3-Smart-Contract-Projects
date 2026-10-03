// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ComplianceModule} from "../src/ComplianceModule.sol";

contract ComplianceModuleTest is Test {
    ComplianceModule internal compliance;
    address internal officer = address(0xC);
    address internal account = address(0xA);

    function setUp() public {
        address[] memory officers = new address[](1);
        officers[0] = officer;
        compliance = new ComplianceModule(officers);
    }

    function test_Constructor_DefaultTiers() public {
        assertEq(compliance.tierDailyLimit(ComplianceModule.KycTier.Standard), 50_000 ether);
        assertEq(compliance.tierSingleLimit(ComplianceModule.KycTier.Standard), 10_000 ether);
        assertEq(compliance.tierDailyLimit(ComplianceModule.KycTier.Enhanced), 500_000 ether);
        assertEq(compliance.tierSingleLimit(ComplianceModule.KycTier.Enhanced), 100_000 ether);
    }

    function test_SetKyc_ComplianceOnly() public {
        vm.prank(account);
        vm.expectRevert(ComplianceModule.NotCompliance.selector);
        compliance.setKyc(account, ComplianceModule.KycTier.Enhanced);

        vm.prank(officer);
        compliance.setKyc(account, ComplianceModule.KycTier.Enhanced);
        (ComplianceModule.KycTier tier, , ) = compliance.accounts(account);
        assertEq(uint8(tier), uint8(ComplianceModule.KycTier.Enhanced));
    }

    function test_Sanctions_BlockAccounts() public {
        vm.prank(officer);
        compliance.setSanctioned(account, true);
        assertTrue(compliance.isBlocked(account));

        vm.prank(officer);
        compliance.setSanctioned(account, false);
        assertFalse(compliance.isBlocked(account));
    }

    function test_Freeze_BlocksAccounts() public {
        vm.prank(officer);
        compliance.setAccountFrozen(account, true);
        assertTrue(compliance.isBlocked(account));

        vm.prank(officer);
        compliance.setAccountFrozen(account, false);
        assertFalse(compliance.isBlocked(account));
    }

    function test_Counterparty_Whitelist() public {
        vm.prank(officer);
        compliance.setCounterparty(account, true);
        assertTrue(compliance.counterparties(account));

        vm.prank(officer);
        compliance.setCounterparty(account, false);
        assertFalse(compliance.counterparties(account));
    }

    function test_TierLimits_Update() public {
        vm.prank(officer);
        compliance.setTierLimits(ComplianceModule.KycTier.Standard, 20_000 ether, 5_000 ether);
        assertEq(compliance.dailyLimitFor(account), 0); // account has no tier yet
        vm.prank(officer);
        compliance.setKyc(account, ComplianceModule.KycTier.Standard);
        assertEq(compliance.dailyLimitFor(account), 20_000 ether);
        assertEq(compliance.singleLimitFor(account), 5_000 ether);
    }

    function test_TierLimits_InvalidTier() public {
        vm.prank(officer);
        (bool ok, ) = address(compliance).call(abi.encodeWithSelector(ComplianceModule.setTierLimits.selector, uint8(9), 1, 1));
        assertFalse(ok);
    }

    function test_Sanction_ZeroAddress() public {
        vm.prank(officer);
        vm.expectRevert(ComplianceModule.ZeroAddress.selector);
        compliance.setSanctioned(address(0), true);
    }
}
