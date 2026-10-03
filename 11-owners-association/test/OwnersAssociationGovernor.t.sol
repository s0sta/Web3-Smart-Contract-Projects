// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OwnersAssociationGovernor} from "../src/OwnersAssociationGovernor.sol";
import {AssociationFixture} from "./AssociationFixture.sol";

contract OwnersAssociationGovernorTest is AssociationFixture {
    address internal candidate = address(0xC0FFEE);

    function _fundTreasury(uint256 amount) internal {
        stable.setMinter(address(this));
        stable.mint(address(this), amount);
        stable.approve(address(treasury), amount);
        treasury.receiveStable(amount);
    }

    function test_Propose_ThresholdEnforced() public {
        address[] memory t = new address[](1);
        t[0] = address(treasury);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(treasury.setReserveBps, (500));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnersAssociationGovernor.BelowProposalThreshold.selector, 0, 50));
        governor.propose(0, t, v, c, "too small");

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnersAssociationGovernor.BelowProposalThreshold.selector, 0, 50));
        governor.propose(0, t, v, c, "still small");
    }

    function test_Propose_BoardBypassesThreshold() public {
        address[] memory t = new address[](1);
        t[0] = address(treasury);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(treasury.setReserveBps, (600));

        vm.prank(owner4);
        uint256 id = governor.propose(0, t, v, c, "board proposal");
        assertEq(governor.state(id), 0);
    }

    function test_Propose_RejectsArbitraryTarget() public {
        address[] memory t = new address[](1);
        t[0] = address(0xDEAD);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = hex"12345678";
        vm.expectRevert(OwnersAssociationGovernor.InvalidTargets.selector);
        _propose(admin, 0, t, v, c, "escape attempt");
    }

    function test_Propose_PaymentMustTargetTreasury() public {
        address[] memory t = new address[](1);
        t[0] = address(registry);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = hex"";
        vm.expectRevert(OwnersAssociationGovernor.InvalidPaymentTarget.selector);
        _propose(admin, 5, t, v, c, "bad payment");
    }

    function test_Propose_ChargeRateMustCallRegistrySetter() public {
        address[] memory t = new address[](1);
        t[0] = address(registry);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(registry.setAnnualChargePerSqm, (70 ether));
        _propose(admin, 1, t, v, c, "raise charge to 70");

        c[0] = abi.encodeCall(registry.setTreasury, (address(0x7)));
        vm.expectRevert(OwnersAssociationGovernor.InvalidTargets.selector);
        _propose(admin, 1, t, v, c, "wrong selector");
    }

    function test_Propose_ElectionMustElectSeat() public {
        address[] memory t = new address[](1);
        t[0] = address(governor);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(governor.setBoardMember, (candidate, 4));
        _propose(admin, 4, t, v, c, "elect seat 4");

        c[0] = abi.encodeCall(governor.setQuorum, (0, 100));
        vm.expectRevert(OwnersAssociationGovernor.InvalidElectionCalldata.selector);
        _propose(admin, 4, t, v, c, "not an election");
    }

    function test_Propose_EmergencyBoardOnly() public {
        address[] memory t = new address[](1);
        t[0] = address(treasury);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = hex"";

        vm.prank(admin);
        vm.expectRevert(OwnersAssociationGovernor.InvalidProposalType.selector);
        governor.propose(6, t, v, c, "non-board emergency");

        vm.prank(owner2);
        uint256 id = governor.propose(6, t, v, c, "civil defence item");
        (OwnersAssociationGovernor.ProposalType pt, , , , , , , , , , , , , ) = governor.proposals(id);
        assertEq(uint256(pt), 6);
    }

    function test_Review_VetoByCompliance() public {
        uint256 id = _proposeSingle(admin, 0, "boring");
        vm.prank(owner5);
        governor.veto(id, "non-compliant with service charge law");
        assertEq(governor.state(id), 7);
        (, , , , , , , , , , , bool vetoed, string memory note, ) = governor.proposals(id);
        assertTrue(vetoed);
        assertEq(note, "non-compliant with service charge law");
    }

    function test_Review_VetoOnlyCompliance() public {
        uint256 id = _proposeSingle(admin, 0, "boring");
        vm.prank(owner2);
        vm.expectRevert();
        governor.veto(id, "nope");
    }

    function test_Review_BoardFastTracks() public {
        uint256 id = _proposeSingle(admin, 0, "fast one");
        assertEq(governor.state(id), 0);
        vm.prank(owner3);
        governor.fastTrack(id);
        assertEq(governor.state(id), 1);
    }

    function test_Review_NonBoardCannotFastTrack() public {
        uint256 id = _proposeSingle(admin, 0, "slow one");
        vm.prank(admin);
        vm.expectRevert();
        governor.fastTrack(id);
    }

    function test_Vote_WeightEqualsArea() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(admin, 0, "weight test");
        vm.warp(block.timestamp + 3 days);

        _vote(admin, id, true);
        (, , , , , , , uint256 forV, , , , , , ) = governor.proposals(id);
        assertEq(forV, 180);
    }

    function test_Vote_CannotVoteDuringReview() public {
        uint256 id = _proposeSingle(admin, 0, "early vote");
        vm.expectRevert();
        _vote(admin, id, true);
    }

    function test_Vote_CannotVoteTwice() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(admin, 0, "double vote");
        vm.warp(block.timestamp + 3 days);
        _vote(admin, id, true);
        vm.expectRevert(abi.encodeWithSelector(OwnersAssociationGovernor.AlreadyVoted.selector, id, admin));
        _vote(admin, id, true);
    }

    function test_Vote_CannotVoteAfterEnd() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(admin, 0, "late vote");
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert();
        _vote(admin, id, true);
    }

    function test_Delegate_TransfersProxyPower() public {
        vm.roll(block.number + 1);
        vm.prank(owner2);
        governor.delegate(admin, block.timestamp + 30 days);
        assertEq(governor.delegatee(owner2), admin);
        assertEq(governor.votingPower(admin), 180 + 160);
        assertEq(governor.votingPowerAt(admin, block.number), 340);
        assertEq(governor.votingPowerAt(admin, block.number - 1), 180);
    }

    function test_Delegate_ExpiryLapses() public {
        uint256 t0 = block.timestamp;
        vm.prank(owner2);
        governor.delegate(admin, t0 + 10 days);
        vm.warp(block.timestamp + 11 days);
        assertFalse(governor.delegationActive(owner2));
    }

    function test_Delegate_RevokeReturnsPower() public {
        vm.prank(owner2);
        governor.delegate(admin, block.timestamp + 30 days);
        vm.prank(owner2);
        governor.revokeDelegation();
        assertEq(governor.votingPower(admin), 180);
        assertEq(governor.delegatee(owner2), address(0));
    }

    function test_Delegate_SaleAdjustsDelegatedPower() public {
        vm.prank(owner2);
        governor.delegate(admin, block.timestamp + 30 days);
        assertEq(governor.votingPower(admin), 340);

        vm.prank(owner4);
        governor.registerUnitSale(1, owner5);
        assertEq(governor.votingPower(admin), 180 + 40);
        assertEq(governor.votingPower(owner5), 60 + 120);
    }

    function test_FullLifecycle_PaymentProposal() public {
        uint256 t0 = block.timestamp;
        _fundTreasury(100_000 ether);
        address vendor = address(0xBEEF);

        address[] memory t = new address[](1);
        t[0] = address(treasury);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(treasury.payVendor, (vendor, 10_000 ether));

        uint256 id = _propose(admin, 5, t, v, c, "pay cleaning contractor Q3");
        vm.warp(block.timestamp + 3 days);
        assertEq(governor.state(id), 1);

        _vote(admin, id, true);
        _vote(owner2, id, true);
        assertEq(governor.state(id), 1);

        vm.warp(block.timestamp + 5 days);
        (,,,,,,uint256 execAfter,,,,,,,) = governor.proposals(id);
        vm.expectRevert(abi.encodeWithSelector(OwnersAssociationGovernor.Timelocked.selector, id, execAfter));
        governor.execute(id);

        vm.warp(block.timestamp + 8 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(stable.balanceOf(vendor), 10_000 ether);
    }

    function test_Lifecycle_DefeatedWhenUnderQuorum() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(admin, 0, "lonely");
        vm.warp(block.timestamp + 3 days);
        _vote(owner4, id, true);
        vm.warp(block.timestamp + 5 days);
        assertEq(governor.state(id), 5);
        vm.expectRevert(abi.encodeWithSelector(OwnersAssociationGovernor.NotSucceeded.selector, id));
        governor.execute(id);
    }

    function test_Lifecycle_EmergencySkipsTimelock() public {
        uint256 t0 = block.timestamp;
        _fundTreasury(100_000 ether);
        address vendor = address(0xBEEF);
        address[] memory t = new address[](1);
        t[0] = address(treasury);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(treasury.payVendor, (vendor, 5_000 ether));

        vm.prank(owner2);
        uint256 id = governor.propose(6, t, v, c, "fire-safety rectification");
        vm.warp(block.timestamp + 3 days);
        _vote(admin, id, true);
        _vote(owner2, id, true);
        vm.warp(block.timestamp + 5 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(stable.balanceOf(vendor), 5_000 ether);
    }

    function test_Election_ReplacesBoardSeat() public {
        uint256 t0 = block.timestamp;
        address[] memory t = new address[](1);
        t[0] = address(governor);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(governor.setBoardMember, (candidate, 0));

        uint256 id = _propose(admin, 4, t, v, c, "elect candidate to seat 0");
        vm.warp(block.timestamp + 3 days);
        _vote(admin, id, true);
        _vote(owner2, id, true);
        vm.warp(block.timestamp + 8 days);
        governor.execute(id);

        assertEq(governor.boardSeats(0), candidate);
        assertFalse(governor.hasRole(governor.BOARD_MEMBER_ROLE(), owner2));
        assertTrue(governor.hasRole(governor.BOARD_MEMBER_ROLE(), candidate));
    }

    function test_RulesProposal_ChangesQuorum() public {
        uint256 t0 = block.timestamp;
        address[] memory t = new address[](1);
        t[0] = address(governor);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(governor.setQuorum, (0, 1500));

        uint256 id = _propose(admin, 3, t, v, c, "lower budget quorum to 15%");
        vm.warp(block.timestamp + 3 days);
        _vote(admin, id, true);
        _vote(owner2, id, true);
        vm.warp(block.timestamp + 8 days);
        governor.execute(id);
        assertEq(governor.quorumBps(OwnersAssociationGovernor.ProposalType(0)), 1500);
    }

    function test_ChargeRateProposal_UpdatesRegistry() public {
        uint256 t0 = block.timestamp;
        address[] memory t = new address[](1);
        t[0] = address(registry);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(registry.setAnnualChargePerSqm, (70 ether));

        uint256 id = _propose(admin, 1, t, v, c, "raise service charge to 70");
        vm.warp(block.timestamp + 3 days);
        _vote(admin, id, true);
        _vote(owner2, id, true);
        vm.warp(block.timestamp + 8 days);
        governor.execute(id);
        assertEq(registry.annualChargePerSqm(), 70 ether);
    }

    function test_RegisterUnitSale_BoardOrGovernance() public {
        vm.prank(owner2);
        governor.registerUnitSale(0, outsider);
        (, address own0, , ) = registry.units(0);
        assertEq(own0, outsider);

        vm.prank(admin);
        vm.expectRevert(OwnersAssociationGovernor.NotProposerOrBoard.selector);
        governor.registerUnitSale(1, outsider);
    }

    function test_Pause_BlocksProposeAndVote() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(owner2, 0, "pre-pause proposal");

        vm.prank(guardian);
        governor.pause();
        assertTrue(governor.paused());

        vm.prank(admin);
        vm.expectRevert(OwnersAssociationGovernor.ProtocolPaused.selector);
        governor.propose(0, new address[](1), new uint256[](1), new bytes[](1), "paused");

        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        vm.expectRevert(OwnersAssociationGovernor.ProtocolPaused.selector);
        governor.vote(id, true);

        vm.prank(guardian);
        governor.unpause();
        assertFalse(governor.paused());
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(admin);
        vm.expectRevert();
        governor.pause();
    }

    function test_State_Transitions() public {
        uint256 t0 = block.timestamp;
        uint256 id = _proposeSingle(admin, 0, "state walk");
        assertEq(governor.state(id), 0);
        vm.warp(block.timestamp + 3 days);
        assertEq(governor.state(id), 1);
        _vote(admin, id, true);
        vm.warp(block.timestamp + 5 days);
        vm.warp(block.timestamp + 8 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
    }

    function _singleTreasuryCall() internal view returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = address(treasury);
        c[0] = abi.encodeCall(treasury.setReserveBps, (500));
        return (t, v, c);
    }

    function _proposeSingle(address proposer, uint8 pType, string memory desc) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _singleTreasuryCall();
        return _propose(proposer, pType, t, v, c, desc);
    }
}
