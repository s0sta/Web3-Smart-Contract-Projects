// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {WaqfFixture} from "./WaqfFixture.sol";
import {WaqfVault} from "../src/WaqfVault.sol";

contract WaqfVaultTest is WaqfFixture {
    function test_Endow_GrowsCorpusAndTracksDonor() public {
        assertEq(vault.totalCorpus(), 10_000 ether);
        assertEq(vault.contributions(donorA), 5_000 ether);
        assertEq(vault.contributions(donorB), 5_000 ether);
    }

    function test_Corpus_IsIrrevocable_NoWithdrawalPath() public {
        // the vault has no function that reduces totalCorpus; contributions only grow
        vm.prank(donorA);
        stable.approve(address(vault), 1_000 ether);
        vm.prank(donorA);
        vault.endow(1_000 ether);
        assertEq(vault.totalCorpus(), 11_000 ether);
        assertEq(vault.contributions(donorA), 6_000 ether);
    }

    function test_Endow_ZeroReverts() public {
        vm.prank(donorA);
        vm.expectRevert(WaqfVault.ZeroAmount.selector);
        vault.endow(0);
    }

    function test_RecordIncome_NazirOnly() public {
        stable.mint(nazir1, 1_000 ether);
        vm.prank(nazir1);
        stable.approve(address(vault), 1_000 ether);
        vm.prank(nazir1);
        vault.recordIncome(1_000 ether);
        assertEq(vault.distributablePool(), 1_000 ether);

        vm.prank(outsider);
        vm.expectRevert();
        vault.recordIncome(1 ether);
    }

    function test_Distribute_ProRataByWeight() public {
        _recordIncome(1_000 ether);
        (address[] memory accounts, uint256[] memory weights) = _distributionTargets();
        uint256 total = vault.distribute(accounts, weights);
        assertEq(total, 1_000 ether);
        assertEq(stable.balanceOf(beneficiary1), 600 ether);
        assertEq(stable.balanceOf(beneficiary2), 400 ether);
        assertEq(vault.distributablePool(), 0);
        assertEq(vault.totalDistributed(), 1_000 ether);
    }

    function test_Distribute_LeavesCorpusUntouched() public {
        _recordIncome(1_000 ether);
        (address[] memory accounts, uint256[] memory weights) = _distributionTargets();
        vault.distribute(accounts, weights);
        // vault still holds the corpus (10,000) even after distributing income
        assertEq(stable.balanceOf(address(vault)), 10_000 ether);
        assertEq(vault.totalCorpus(), 10_000 ether);
    }

    function test_Distribute_NoIncomeReverts() public {
        (address[] memory accounts, uint256[] memory weights) = _distributionTargets();
        vm.expectRevert(WaqfVault.NoIncome.selector);
        vault.distribute(accounts, weights);
    }

    function test_FundOperational_NazirOnly() public {
        _recordIncome(1_000 ether);
        vm.prank(nazir1);
        vault.fundOperational(100 ether);
        assertEq(vault.operationalFund(), 100 ether);
        assertEq(vault.distributablePool(), 900 ether);
    }

    function test_SpendOperational_GovernorOnly() public {
        _recordIncome(1_000 ether);
        vm.prank(nazir1);
        vault.fundOperational(100 ether);

        vm.prank(outsider);
        vm.expectRevert();
        vault.spendOperational(nazir1, 10 ether);

        vm.prank(address(governor));
        vault.spendOperational(nazir1, 40 ether);
        assertEq(vault.operationalFund(), 60 ether);
        assertEq(stable.balanceOf(nazir1), 40 ether);

        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(WaqfVault.InsufficientOperational.selector, 60 ether, 100 ether));
        vault.spendOperational(nazir1, 100 ether);
    }

    function test_Freeze_GuardianOnly_BlocksDistributionOnly() public {
        _recordIncome(1_000 ether);
        vm.prank(outsider);
        vm.expectRevert();
        vault.setFrozen(true);

        vm.prank(guardian);
        vault.setFrozen(true);
        (address[] memory accounts, uint256[] memory weights) = _distributionTargets();
        vm.expectRevert(WaqfVault.DistributionsFrozen.selector);
        vault.distribute(accounts, weights);

        // the corpus can still receive endowments while frozen
        vm.prank(donorA);
        vault.endow(100 ether);
        assertEq(vault.totalCorpus(), 10_100 ether);
    }

    function test_ContributionSnapshots() public {
        vm.roll(block.number + 1);
        vm.prank(donorA);
        vault.endow(500 ether);
        assertEq(vault.getPastContribution(donorA, block.number), 5_500 ether);
        assertEq(vault.getPastContribution(donorA, block.number - 1), 5_000 ether);
    }
}
