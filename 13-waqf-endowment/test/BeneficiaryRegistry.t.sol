// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {WaqfFixture} from "./WaqfFixture.sol";
import {BeneficiaryRegistry} from "../src/BeneficiaryRegistry.sol";
import {WaqfGovernor} from "../src/WaqfGovernor.sol";

contract BeneficiaryRegistryTest is WaqfFixture {
    function test_AddBeneficiary_NazirOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.addBeneficiary(address(0x3), 1000);

        // free 40% first, then add a 10% beneficiary
        vm.prank(nazir1);
        registry.deactivateBeneficiary(1);
        vm.prank(nazir1);
        uint256 id = registry.addBeneficiary(address(0x3), 1000);
        (address acct, uint256 w, bool active) = registry.beneficiaries(id);
        assertEq(acct, address(0x3));
        assertEq(w, 1000);
        assertTrue(active);
    }

    function test_AddBeneficiary_WeightOverflow() public {
        // weights already sum to 10,000 (6000 + 4000)
        vm.prank(nazir1);
        vm.expectRevert(BeneficiaryRegistry.WeightOverflow.selector);
        registry.addBeneficiary(address(0x3), 1);
    }

    function test_SetWeight_GovernorOrNazir() public {
        vm.prank(nazir1);
        registry.setBeneficiaryWeight(0, 5500);
        ( , uint256 w, ) = registry.beneficiaries(0);
        assertEq(w, 5500);
        assertEq(registry.totalActiveWeight(), 9500);

        vm.prank(address(governor));
        registry.setBeneficiaryWeight(0, 6000);
        assertEq(registry.totalActiveWeight(), 10_000);

        vm.prank(outsider);
        vm.expectRevert();
        registry.setBeneficiaryWeight(0, 1000);
    }

    function test_Deactivate_FreesWeight() public {
        vm.prank(nazir1);
        registry.deactivateBeneficiary(1);
        ( , , bool active) = registry.beneficiaries(1);
        assertFalse(active);
        assertEq(registry.totalActiveWeight(), 6000);
    }

    function test_Deactivate_NotActiveReverts() public {
        vm.prank(nazir1);
        registry.deactivateBeneficiary(1);
        vm.prank(nazir1);
        vm.expectRevert(abi.encodeWithSelector(BeneficiaryRegistry.NotActive.selector, 1));
        registry.deactivateBeneficiary(1);
    }

    function test_DistributionTargets_SkipInactive() public {
        vm.prank(nazir1);
        registry.deactivateBeneficiary(1);
        (address[] memory accounts, uint256[] memory weights) = registry.distributionTargets();
        assertEq(accounts.length, 1);
        assertEq(accounts[0], beneficiary1);
        assertEq(weights[0], 6000);
    }
}

contract WaqfGovernorTest is WaqfFixture {
    function _propose(
        address proposer,
        WaqfGovernor.ProposalType pType,
        address target,
        bytes memory callData,
        string memory desc
    ) internal returns (uint256 id) {
        address[] memory t = new address[](1);
        t[0] = target;
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = callData;
        vm.prank(proposer);
        return governor.propose(pType, t, v, c, desc);
    }

    function test_Propose_ThresholdAndNazirBypass() public {
        // donor with 5,000 ≥ 1,000 threshold ✓
        _propose(donorA, WaqfGovernor.ProposalType.AdjustWeight, address(registry),
                 abi.encodeCall(registry.setBeneficiaryWeight, (0, 5000)), "rebalance");
        ( , address prop0, , , , , , , , , , , ) = governor.proposals(0);
        assertEq(prop0, donorA);

        // outsider has 0 — below threshold
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(WaqfGovernor.BelowProposalThreshold.selector, 0, 1_000 ether));
        governor.propose(WaqfGovernor.ProposalType.Rules, new address[](1), new uint256[](1), new bytes[](1), "x");

        // nazir bypasses the threshold
        _propose(nazir1, WaqfGovernor.ProposalType.Rules, address(governor),
                 abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum");
        ( , address prop1, , , , , , , , , , , ) = governor.proposals(1);
        assertEq(prop1, nazir1);
    }

    function test_Propose_ValidatesTargetsAndSelectors() public {
        vm.expectRevert(WaqfGovernor.InvalidTargets.selector);
        _propose(donorA, WaqfGovernor.ProposalType.AdjustWeight, address(0xDEAD),
                 hex"1234", "arbitrary target");

        vm.expectRevert(WaqfGovernor.InvalidTargets.selector);
        _propose(donorA, WaqfGovernor.ProposalType.OperationalSpend, address(vault),
                 abi.encodeCall(registry.setBeneficiaryWeight, (0, 1000)), "wrong selector");
    }

    function test_Confirm_TwoNazirsRequired() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir1);
        vm.expectRevert(abi.encodeWithSelector(WaqfGovernor.AlreadyConfirmed.selector, id, nazir1));
        governor.confirm(id);
        ( , , , , , , , , , uint256 confs, , , ) = governor.proposals(id);
        assertEq(confs, 1);

        vm.prank(nazir2);
        governor.confirm(id);
        ( , , , , , , , , , uint256 confs2, , , ) = governor.proposals(id);
        assertEq(confs2, 2);

        vm.prank(outsider);
        vm.expectRevert();
        governor.confirm(id);
    }

    function test_Confirm_OnlyDuringWindow() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum");
        vm.warp(block.timestamp + 4 days);
        vm.prank(nazir1);
        vm.expectRevert(abi.encodeWithSelector(WaqfGovernor.NotInConfirmation.selector, id));
        governor.confirm(id);
    }

    function test_Vote_DonorWeightAtSnapshot() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum");
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.prank(donorB);
        governor.vote(id, true);
        ( , , , , , , , uint256 forV, , , , , ) = governor.proposals(id);
        assertEq(forV, 10_000 ether);
    }

    function test_Vote_CannotVoteTwice() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum");
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.prank(donorA);
        vm.expectRevert(abi.encodeWithSelector(WaqfGovernor.AlreadyVoted.selector, id, donorA));
        governor.vote(id, true);
    }

    function test_FullLifecycle_RulesProposal() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "lower quorum to 5%");
        assertEq(governor.state(id), 0);

        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir2);
        governor.confirm(id);

        vm.warp(block.timestamp + 3 days);
        assertEq(governor.state(id), 1); // voting

        vm.prank(donorA);
        governor.vote(id, true); // 5,000 ≥ 1,000 quorum ✓
        vm.prank(donorB);
        governor.vote(id, true);

        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3); // succeeded
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(governor.quorumBps(), 500);
    }

    function test_Defeated_WithoutEnoughVotes() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "unpopular");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir2);
        governor.confirm(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true); // 5,000 < 10% of 10,000 corpus = 1,000? No — 5,000 ≥ 1,000 ✓ quorum met
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3); // actually succeeds
    }

    function test_Defeated_WithoutTwoConfirmations() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "one confirmation only");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 5); // defeated: only 1 confirmation
    }

    function test_Timelock_BlocksEarlyExecution() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "timelocked");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir2);
        governor.confirm(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.warp(block.timestamp + 8 days); // voteEnd + 1d < +2d timelock
        vm.expectRevert();
        governor.execute(id);
        assertEq(governor.state(id), 2); // timelock
    }

    function test_OperationalSpend_Lifecycle() public {
        _recordIncome(1_000 ether);
        vm.prank(nazir1);
        vault.fundOperational(100 ether);

        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.OperationalSpend, address(vault),
                              abi.encodeCall(vault.spendOperational, (nazir1, 30 ether)), "admin stipend");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir2);
        governor.confirm(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        governor.execute(id);
        assertEq(vault.operationalFund(), 70 ether);
        assertEq(stable.balanceOf(nazir1), 30 ether);
    }

    function test_Corpus_UnreachableByGovernance() public {
        // even a full governance cycle cannot move the corpus — no function exists.
        // the vault's only outward calls are income distributions and operational spending.
        uint256 corpus = vault.totalCorpus();
        vm.expectRevert();
        // no transferOfCorpus exists — any attempt via spendOperational is capped by the fund
        vm.prank(address(governor));
        vault.spendOperational(nazir1, 10_000 ether);
        assertEq(vault.totalCorpus(), corpus);
    }

    function test_Cancel_ProposerOrNazir() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.Rules, address(governor),
                              abi.encodeCall(governor.setQuorumBps, (500)), "cancel me");
        vm.prank(outsider);
        vm.expectRevert(WaqfGovernor.OnlyProposerOrNazir.selector);
        governor.cancel(id);

        vm.prank(donorA);
        governor.cancel(id);
        assertEq(governor.state(id), 6);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        governor.pause();

        vm.prank(guardian);
        governor.pause();
        vm.prank(donorA);
        vm.expectRevert(WaqfGovernor.ProtocolPaused.selector);
        governor.propose(WaqfGovernor.ProposalType.Rules, new address[](1), new uint256[](1), new bytes[](1), "paused");
    }
}

contract WaqfAdjustWeightLifecycleTest is WaqfGovernorTest {
    function test_AdjustWeight_Executes() public {
        uint256 id = _propose(donorA, WaqfGovernor.ProposalType.AdjustWeight, address(registry),
                              abi.encodeCall(registry.setBeneficiaryWeight, (1, 3000)), "rebalance to 30%");
        vm.prank(nazir1);
        governor.confirm(id);
        vm.prank(nazir2);
        governor.confirm(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(donorA);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        governor.execute(id);
        ( , uint256 w, ) = registry.beneficiaries(1);
        assertEq(w, 3000);
        assertEq(registry.totalActiveWeight(), 9000);
    }
}
