// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GovToken} from "../src/GovToken.sol";
import {Governor} from "../src/Governor.sol";

/// @notice A target contract the DAO can control through proposals.
contract MockTarget {
    uint256 public value;
    event Called(uint256 value);

    function setValue(uint256 v) external {
        value = v;
        emit Called(v);
    }

    receive() external payable {}
}

contract GovernorTest is Test {
    GovToken token;
    Governor governor;
    MockTarget target;

    address deployer = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");
    address recipient = makeAddr("recipient");

    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant THRESHOLD = 10_000 ether;
    uint256 constant QUORUM_BPS = 400; // 4%
    uint256 constant QUORUM = (SUPPLY * QUORUM_BPS) / 10_000; // 40,000 GOV

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, uint256 deadline);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);

    function setUp() public {
        token = new GovToken("Governance", "GOV", SUPPLY, deployer);
        governor = new Governor(token, 3 days, THRESHOLD, QUORUM_BPS);
        target = new MockTarget();

        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 60_000 ether);
        token.transfer(carol, 20_000 ether);
        token.transfer(mallory, 1000 ether);
        vm.roll(block.number + 1); // so the distributions land in a *past* block
    }

    /// Alice proposes "target.setValue(42)".
    function _proposeSetValue(uint256 v) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(MockTarget.setValue.selector, v);

        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, "Set value");
    }

    /* ==================== SNAPSHOT TOKEN ==================== */

    function test_GovToken_HistoricalBalances() public {
        uint256 before = block.number;
        vm.roll(block.number + 1);
        token.transfer(bob, 5 ether); // checkpoint lands in the next block
        vm.roll(block.number + 1);

        assertEq(token.getPastVotes(bob, before), 60_000 ether); // before the transfer
        assertEq(token.getPastVotes(bob, before + 1), 60_005 ether); // after
        assertEq(token.getPastTotalSupply(before + 1), SUPPLY);
    }

    function test_GovToken_FutureBlockReverts() public {
        vm.expectRevert(abi.encodeWithSelector(GovToken.FutureBlock.selector, block.number + 1, block.number));
        token.getPastVotes(alice, block.number + 1);
    }

    /* ==================== PROPOSE ==================== */

    function test_Propose_BelowThresholdReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        vm.prank(mallory); // only 1,000 GOV
        vm.expectRevert(
            abi.encodeWithSelector(Governor.BelowProposalThreshold.selector, 1000 ether, THRESHOLD)
        );
        governor.propose(targets, values, calldatas, "nope");
    }

    function test_Propose_CreatesActiveProposal() public {
        vm.expectEmit(true, true, false, true);
        emit ProposalCreated(0, alice, block.timestamp + 3 days);
        uint256 id = _proposeSetValue(42);

        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Active));
        (address proposer, uint256 snapshot, uint256 deadline,,,,,) = governor.proposals(id);
        assertEq(proposer, alice);
        assertEq(snapshot, block.number);
        assertEq(deadline, block.timestamp + 3 days);
        assertEq(governor.quorum(id), QUORUM);
    }

    function test_Propose_Validation() public {
        address[] memory empty = new address[](0);
        uint256[] memory emptyVals = new uint256[](0);
        bytes[] memory emptyData = new bytes[](0);
        vm.prank(alice);
        vm.expectRevert(Governor.EmptyProposal.selector);
        governor.propose(empty, emptyVals, emptyData, "empty");

        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        vm.prank(alice);
        vm.expectRevert(Governor.LengthMismatch.selector);
        governor.propose(targets, values, calldatas, "mismatch");

        address[] memory zeroTargets = new address[](1);
        zeroTargets[0] = address(0);
        vm.prank(alice);
        vm.expectRevert(Governor.ZeroTarget.selector);
        governor.propose(zeroTargets, values, calldatas, "zero");
    }

    /* ==================== VOTE ==================== */

    function test_Vote_WeightsAndDoubleVote() public {
        uint256 id = _proposeSetValue(42);

        vm.expectEmit(true, true, false, true);
        emit VoteCast(id, alice, true, 100_000 ether);
        vm.prank(alice);
        governor.vote(id, true);
        vm.prank(carol);
        governor.vote(id, false);
        vm.prank(mallory);
        governor.vote(id, true);

        (, , , uint256 forVotes, uint256 againstVotes,,,) = governor.proposals(id);
        assertEq(forVotes, 100_000 ether + 1000 ether);
        assertEq(againstVotes, 20_000 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Governor.AlreadyVoted.selector, id, alice));
        governor.vote(id, true);
    }

    function test_Vote_AfterDeadlineReverts() public {
        uint256 id = _proposeSetValue(42);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Governor.VotingEnded.selector, id));
        governor.vote(id, true);
    }

    function test_Vote_SnapshotPreventsFlashVoteBuying() public {
        uint256 id = _proposeSetValue(42); // snapshot = current block

        // After the proposal exists, alice sells 90k tokens to mallory.
        vm.roll(block.number + 1); // move to a new block so checkpoints advance
        vm.prank(alice);
        token.transfer(mallory, 90_000 ether);
        vm.roll(block.number + 1);

        // Mallory now holds 91k tokens — but had only 1k AT SNAPSHOT time.
        vm.prank(mallory);
        governor.vote(id, false);
        (, , , , uint256 againstVotes,,,) = governor.proposals(id);
        assertEq(againstVotes, 1000 ether); // snapshot weight, not current balance

        // Alice votes with her full snapshot weight even though she sold.
        vm.prank(alice);
        governor.vote(id, true);
        (, , , uint256 forVotes,,,,) = governor.proposals(id);
        assertEq(forVotes, 100_000 ether);
    }

    /* ==================== EXECUTION ==================== */

    function test_Execute_PassingProposalRunsCalls() public {
        uint256 id = _proposeSetValue(42);
        vm.prank(alice);
        governor.vote(id, true); // 100k for
        vm.prank(bob);
        governor.vote(id, true); // 60k for
        vm.warp(block.timestamp + 3 days + 1);

        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Succeeded));
        vm.expectEmit(true, false, false, true);
        emit ProposalExecuted(id);
        governor.execute(id);

        assertEq(target.value(), 42); // the DAO actually changed on-chain state
        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Executed));
        vm.expectRevert(abi.encodeWithSelector(Governor.ProposalNotSucceeded.selector, id));
        governor.execute(id); // cannot run twice
    }

    function test_Execute_BeforeDeadlineReverts() public {
        uint256 id = _proposeSetValue(42);
        vm.prank(alice);
        governor.vote(id, true);
        vm.expectRevert(abi.encodeWithSelector(Governor.ProposalNotSucceeded.selector, id));
        governor.execute(id);
    }

    function test_Execute_BelowQuorumFails() public {
        // Reshape balances BEFORE the proposal so the snapshot sees alice below quorum.
        vm.roll(block.number + 1);
        vm.prank(alice);
        token.transfer(bob, 70_000 ether); // alice keeps 30k — under the 40k quorum
        vm.roll(block.number + 1);

        uint256 id = _proposeSetValue(42);
        vm.prank(alice);
        governor.vote(id, true); // 30k for
        vm.warp(block.timestamp + 3 days + 1);

        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Defeated));
        vm.expectRevert(abi.encodeWithSelector(Governor.ProposalNotSucceeded.selector, id));
        governor.execute(id);
    }

    function test_Execute_MajorityAgainstFails() public {
        // Give carol enough tokens BEFORE the proposal for the opposition to win.
        vm.roll(block.number + 1);
        vm.prank(alice);
        token.transfer(carol, 40_000 ether); // alice 60k, carol 60k at snapshot
        vm.roll(block.number + 1);

        uint256 id = _proposeSetValue(42);
        vm.prank(alice);
        governor.vote(id, true); // 60k for
        vm.prank(bob);
        governor.vote(id, false); // 60k against
        vm.prank(carol);
        governor.vote(id, false); // 60k against
        vm.warp(block.timestamp + 3 days + 1);

        // 60k for vs 120k against — quorum reached but the majority said no.
        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Defeated));
        vm.expectRevert(abi.encodeWithSelector(Governor.ProposalNotSucceeded.selector, id));
        governor.execute(id);
    }

    function test_Execute_EthTransferProposal() public {
        vm.deal(address(governor), 2 ether);
        address[] memory targets = new address[](1);
        targets[0] = recipient;
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        bytes[] memory calldatas = new bytes[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "Pay contributor");
        vm.prank(alice);
        governor.vote(id, true);
        vm.warp(block.timestamp + 3 days + 1);

        governor.execute(id);
        assertEq(recipient.balance, 1 ether);
        assertEq(address(governor).balance, 1 ether);
    }

    /* ==================== CANCEL ==================== */

    function test_Cancel_ProposerOnlyWhileActive() public {
        uint256 id = _proposeSetValue(42);

        vm.prank(bob);
        vm.expectRevert(Governor.NotProposer.selector);
        governor.cancel(id);

        vm.prank(alice);
        governor.cancel(id);
        assertEq(uint256(governor.state(id)), uint256(Governor.ProposalState.Canceled));

        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(abi.encodeWithSelector(Governor.ProposalNotSucceeded.selector, id));
        governor.execute(id);
    }

    function test_Cancel_AfterDeadlineReverts() public {
        uint256 id = _proposeSetValue(42);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Governor.VotingEnded.selector, id));
        governor.cancel(id);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_StateMachineMatchesVotes(uint256 aliceWeight, uint256 bobWeight) public {
        aliceWeight = bound(aliceWeight, THRESHOLD, 200_000 ether);
        bobWeight = bound(bobWeight, 0, 200_000 ether);

        // Reshape balances BEFORE the proposal so the snapshot sees exactly these weights.
        vm.roll(block.number + 1);
        uint256 aliceBal = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(deployer, aliceBal);
        uint256 bobBal = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(deployer, bobBal);
        vm.roll(block.number + 1);
        token.transfer(alice, aliceWeight);
        token.transfer(bob, bobWeight);
        vm.roll(block.number + 1);

        uint256 id = _proposeSetValue(7);
        vm.prank(alice);
        governor.vote(id, true);
        vm.prank(bob);
        governor.vote(id, false);
        vm.warp(block.timestamp + 3 days + 1);

        bool shouldPass = aliceWeight > bobWeight && aliceWeight >= QUORUM;
        Governor.ProposalState expected =
            shouldPass ? Governor.ProposalState.Succeeded : Governor.ProposalState.Defeated;
        assertEq(uint256(governor.state(id)), uint256(expected));
        if (shouldPass) {
            governor.execute(id);
            assertEq(target.value(), 7);
        }
    }
}
