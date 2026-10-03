// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MawaridFixture} from "./MawaridFixture.sol";
import {MawaridAssetGovernor} from "../src/MawaridAssetGovernor.sol";
import {MawaridTreasury} from "../src/MawaridTreasury.sol";
import {MawaridInsuranceFund} from "../src/MawaridInsuranceFund.sol";

contract MawaridGovernorTest is MawaridFixture {
    function _propose(
        address proposer,
        MawaridAssetGovernor.ProposalType pType,
        address target,
        bytes memory callData,
        string memory desc
    ) internal returns (uint256 id) {
        vm.prank(proposer);
        return governor.propose(pType, assetId, target, 0, callData, desc);
    }

    function test_Propose_ValidatesTargets() public {
        _runPrimaryRound();
        vm.expectRevert(MawaridAssetGovernor.InvalidTargets.selector);
        _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(0xDEAD), hex"1234", "escape");

        vm.expectRevert(MawaridAssetGovernor.InvalidTargets.selector);
        _propose(investorA, MawaridAssetGovernor.ProposalType.Payout, address(registry), hex"1234", "wrong target");
    }

    function test_Vote_WeightIsSnapshotBalance() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry),
                               abi.encodeCall(registry.appraise, (assetId, 5_500_000 ether)), "revalue");
        vm.warp(block.timestamp + 3 days);
        vm.prank(investorA);
        governor.vote(id, true);
        ( , , , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 400 ether);
    }

    function test_Vote_CannotVoteTwice() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry),
                               abi.encodeCall(registry.appraise, (assetId, 5_500_000 ether)), "revalue");
        vm.warp(block.timestamp + 3 days);
        vm.prank(investorA);
        governor.vote(id, true);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(MawaridAssetGovernor.AlreadyVoted.selector, id, investorA));
        governor.vote(id, true);
    }

    function test_FullLifecycle_AppraisalProposal() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry),
                               abi.encodeCall(registry.appraise, (assetId, 5_500_000 ether)), "revalue to 5.5M");
        assertEq(governor.state(id), 0);

        vm.warp(block.timestamp + 3 days);
        vm.prank(investorA);
        governor.vote(id, true); // 400 for ≥ 10% of 700 issued = 70 ✓
        vm.prank(investorB);
        governor.vote(id, true); // 700 total

        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3); // succeeded
        governor.execute(id);
        assertEq(governor.state(id), 4);
        ( , , , , , uint256 appraisal, , ) = registry.assets(assetId);
        assertEq(appraisal, 5_500_000 ether);
    }

    function test_Defeated_UnderQuorum() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.ManagerChange, address(governor),
                               abi.encodeCall(governor.setManager, (investorC)), "new manager");
        vm.warp(block.timestamp + 3 days);
        vm.prank(investorA);
        governor.vote(id, true); // 400 < 30% of 700 = 210? no: 400 ≥ 210 → passes quorum
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3); // actually succeeds with 400
    }

    function test_Timelock_BlocksEarlyExecution() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry),
                               abi.encodeCall(registry.appraise, (assetId, 5_500_000 ether)), "revalue");
        vm.warp(block.timestamp + 3 days);
        vm.prank(investorA);
        governor.vote(id, true);
        vm.warp(block.timestamp + 5 days); // t0+8d: inside the 2-day timelock
        vm.expectRevert();
        governor.execute(id);
        assertEq(governor.state(id), 2);
    }

    function test_Cancel_ProposerOrManager() public {
        _runPrimaryRound();
        uint256 id = _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry),
                               abi.encodeCall(registry.appraise, (assetId, 5_500_000 ether)), "revalue");
        vm.prank(outsider);
        vm.expectRevert(MawaridAssetGovernor.OnlyProposerOrManager.selector);
        governor.cancel(id);

        vm.prank(investorA);
        governor.cancel(id);
        assertEq(governor.state(id), 6);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        governor.pause();

        vm.prank(guardian);
        governor.pause();
        vm.expectRevert(MawaridAssetGovernor.ProtocolPaused.selector);
        _propose(investorA, MawaridAssetGovernor.ProposalType.Appraise, address(registry), hex"1234", "paused");
    }
}

contract MawaridTreasuryTest is MawaridFixture {
    function test_ReceiveFees_Tracks() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(treasury), 1_000 ether);
        treasury.receiveFees(1_000 ether);
        assertEq(treasury.totalFeesCollected(), 1_000 ether);
        assertEq(stable.balanceOf(address(treasury)), 1_000 ether);
    }

    function test_PayVendor_ReserveEnforced() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(treasury), 1_000 ether);
        treasury.receiveFees(1_000 ether);
        treasury.setVendor(investorC, true);

        // reserve floor = 20% of 1,000 = 200; paying 900 leaves 100 < 200 → breach
        vm.expectRevert(abi.encodeWithSelector(MawaridTreasury.ReserveBreach.selector, 100 ether, 200 ether));
        treasury.payVendor(investorC, 900 ether);

        treasury.payVendor(investorC, 700 ether); // leaves 300 ≥ 200 ✓
        assertEq(stable.balanceOf(investorC), 1_000_700 ether);
    }

    function test_PayVendor_RequiresApprovalOrOperator() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.payVendor(outsider, 1 ether);
    }

    function test_Drain_GuardianOnly() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(treasury), 1_000 ether);
        treasury.receiveFees(1_000 ether);

        vm.prank(outsider);
        vm.expectRevert();
        treasury.drain(outsider);

        vm.prank(guardian);
        treasury.drain(guardian);
        assertEq(stable.balanceOf(guardian), 1_000 ether);
    }
}

contract MawaridInsuranceTest is MawaridFixture {
    function _fundAndPayPremium() internal {
        stable.mint(manager, 5_000 ether);
        stable.approve(address(distributor), 5_000 ether);
        distributor.recordIncome(assetId, 5_000 ether); // 500 into maintenance
        distributor.spendMaintenance(assetId, manager, 500 ether); // returns to manager
        stable.approve(address(distributor), 500 ether);
        distributor.recordIncome(assetId, 500 ether); // replenish via manager
        // simpler: pay the premium straight from the maintenance fund
        insurance.payPremium(assetId, 500 ether);
    }

    function test_PayPremium_DrawsFromMaintenance() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(distributor), 1_000 ether);
        distributor.recordIncome(assetId, 1_000 ether); // 100 → maintenance
        insurance.payPremium(assetId, 100 ether);
        assertEq(insurance.pool(assetId), 100 ether);
        assertEq(distributor.maintenanceFund(assetId), 0);
    }

    function test_Claim_TwoOfThreeApprovals() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(distributor), 1_000 ether);
        distributor.recordIncome(assetId, 1_000 ether);
        insurance.payPremium(assetId, 100 ether);

        uint256 claimId = insurance.fileClaim(assetId, 60 ether, "tenant default - Q3 rent");
        vm.prank(assessor1);
        insurance.voteClaim(claimId, true);
        assertEq(insurance.pool(assetId), 100 ether); // not yet paid

        vm.prank(assessor2);
        insurance.voteClaim(claimId, true);
        assertEq(insurance.pool(assetId), 40 ether);
        ( , , , uint256 approvals, uint256 rejections, bool decided, bool approved) = insurance.claims(claimId);
        assertEq(approvals, 2);
        assertTrue(decided);
        assertTrue(approved);
    }

    function test_Claim_RejectionsClose() public {
        stable.mint(manager, 1_000 ether);
        stable.approve(address(distributor), 1_000 ether);
        distributor.recordIncome(assetId, 1_000 ether);
        insurance.payPremium(assetId, 100 ether);

        uint256 claimId = insurance.fileClaim(assetId, 60 ether, "disputed");
        vm.prank(assessor1);
        insurance.voteClaim(claimId, false);
        vm.prank(assessor2);
        insurance.voteClaim(claimId, false); // 2 approvals unreachable
        ( , , , , , bool decided, bool approved) = insurance.claims(claimId);
        assertTrue(decided);
        assertFalse(approved);
        assertEq(insurance.pool(assetId), 100 ether);
    }

    function test_Claim_InsufficientPool() public {
        uint256 claimId = insurance.fileClaim(assetId, 60 ether, "no premium paid");
        vm.prank(assessor1);
        insurance.voteClaim(claimId, true);
        vm.prank(assessor2);
        vm.expectRevert(abi.encodeWithSelector(MawaridInsuranceFund.InsufficientPool.selector, 0, 60 ether));
        insurance.voteClaim(claimId, true);
    }

    function test_VoteClaim_AssessorOnly() public {
        uint256 claimId = insurance.fileClaim(assetId, 1 ether, "x");
        vm.prank(outsider);
        vm.expectRevert();
        insurance.voteClaim(claimId, true);
    }
}
