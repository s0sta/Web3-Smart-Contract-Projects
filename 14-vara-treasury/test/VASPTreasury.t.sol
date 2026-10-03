// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TreasuryFixture} from "./TreasuryFixture.sol";
import {VASPTreasury} from "../src/VASPTreasury.sol";

contract VASPTreasuryTest is TreasuryFixture {
    /* ---------- deposits ---------- */

    function test_ClientDeposit_TracksLedger() public {
        _clientDeposit(clientA, 5_000 ether);
        assertEq(treasury.clientBalances(address(stable), clientA), 5_000 ether);
        assertEq(treasury.clientTotals(address(stable)), 5_000 ether);
        assertEq(treasury.houseBalances(address(stable)), 30_000 ether); // untouched
    }

    function test_ClientDeposit_SanctionedBlocked() public {
        _fundStable(sanctioned, 100 ether);
        vm.prank(sanctioned);
        vm.expectRevert();
        treasury.deposit(address(stable), 100 ether);
    }

    function test_ClientDeposit_UnlistedAssetReverts() public {
        _fundStable(clientA, 100 ether);
        vm.prank(clientA);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.AssetNotListed.selector, address(0x1234)));
        treasury.deposit(address(0x1234), 100 ether);
    }

    function test_EthDeposit_TracksLedger() public {
        vm.deal(clientA, 5 ether);
        vm.prank(clientA);
        treasury.depositEth{ value: 2 ether }();
        assertEq(treasury.ethClientBalances(clientA), 2 ether);
        assertEq(treasury.ethClientTotal(), 2 ether);
    }

    /* ---------- withdrawals: segregation ---------- */

    function test_Withdraw_ClientFundsOnly() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(clientA);
        treasury.withdraw(address(stable), clientA, 400 ether);
        assertEq(treasury.clientBalances(address(stable), clientA), 600 ether);
        assertEq(stable.balanceOf(clientA), 400 ether);
    }

    function test_Withdraw_CannotTouchHouseFunds() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(clientA);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.InsufficientClientBalance.selector, 1_000 ether, 2_000 ether));
        treasury.withdraw(address(stable), clientA, 2_000 ether);
        assertEq(treasury.houseBalances(address(stable)), 30_000 ether);
    }

    function test_Withdraw_ToCounterpartyOnly() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(clientA);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.NotApprovedCounterparty.selector, outsider));
        treasury.withdraw(address(stable), outsider, 100 ether);

        vm.prank(clientA);
        treasury.withdraw(address(stable), bank, 100 ether);
        assertEq(stable.balanceOf(bank), 100 ether);
    }

    /* ---------- risk limits ---------- */

    function test_Withdraw_SingleTxLimit() public {
        _clientDeposit(clientA, 1_000 ether); // Enhanced: 100k single limit → fine

        _clientDeposit(clientB, 50_000 ether); // Standard: 10k single limit
        vm.prank(clientB);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.WithdrawalLimit.selector, 10_000 ether, 20_000 ether));
        treasury.withdraw(address(stable), clientB, 20_000 ether);
    }

    function test_Withdraw_DailyLimitWindow() public {
        _clientDeposit(clientB, 60_000 ether); // Standard: 10k/tx, 50k/day
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether);
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether);
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether);
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether);
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether); // 50k used
        vm.prank(clientB);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.WithdrawalLimit.selector, 50_000 ether, 60_000 ether));
        treasury.withdraw(address(stable), clientB, 10_000 ether); // would reach 60k

        // next day: the window resets
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(clientB);
        treasury.withdraw(address(stable), clientB, 10_000 ether);
        assertEq(stable.balanceOf(clientB), 60_000 ether);
    }

    /* ---------- capital reserve ---------- */

    function test_Withdraw_ReserveEnforced() public {
        // 20% reserve with 30k house: client liabilities up to 150k are covered
        _clientDeposit(clientA, 140_000 ether);
        vm.prank(clientA);
        treasury.withdraw(address(stable), clientA, 1_000 ether); // 139k → 27.8k ✓ passes

        // grow the liability past the house capacity: 159k → 31.8k > 30k house
        _clientDeposit(clientB, 20_000 ether);
        vm.prank(clientA);
        vm.expectRevert(abi.encodeWithSelector(VASPTreasury.ReserveBreach.selector, 30_000 ether, (158_999 ether * 2000) / 10_000));
        treasury.withdraw(address(stable), clientA, 1 ether);
    }

    function test_OperatorWithdraw_KeepsReserve() public {
        _clientDeposit(clientA, 40_000 ether); // required house = 8k
        treasury.operatorWithdraw(address(stable), operator, 1_000 ether); // 29k ≥ 8k ✓
        assertEq(treasury.houseBalances(address(stable)), 29_000 ether);
        vm.expectRevert();
        treasury.operatorWithdraw(address(stable), operator, 22_001 ether); // 6,999 < 8,000
    }

    function test_OperatorWithdraw_OperatorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.operatorWithdraw(address(stable), outsider, 1 ether);
    }

    /* ---------- compliance powers ---------- */

    function test_FreezeAccount_BlocksFlows() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(complianceOfficer);
        treasury.freezeAccount(clientA);

        vm.prank(clientA);
        vm.expectRevert();
        treasury.withdraw(address(stable), clientA, 1 ether);
    }

    function test_ForcedTransfer_ToRecovery() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(complianceOfficer);
        treasury.freezeAccount(clientA);

        vm.prank(complianceOfficer);
        treasury.forcedTransfer(clientA, address(stable), 400 ether);
        assertEq(treasury.clientBalances(address(stable), clientA), 600 ether);
        assertEq(treasury.clientBalances(address(stable), guardian), 400 ether); // recovery = guardian
    }

    function test_ForcedTransfer_OnlyWhenFrozen() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(complianceOfficer);
        vm.expectRevert();
        treasury.forcedTransfer(clientA, address(stable), 1 ether);
    }

    /* ---------- guardian powers ---------- */

    function test_Pause_GuardianOnly_BlocksAll() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.pause();

        vm.prank(guardian);
        treasury.pause();
        _fundStable(clientA, 100 ether);
        vm.prank(clientA);
        vm.expectRevert(VASPTreasury.ProtocolPaused.selector);
        treasury.deposit(address(stable), 100 ether);
    }

    function test_EmergencyDrain_MovesEverything() public {
        _clientDeposit(clientA, 1_000 ether);
        vm.prank(guardian);
        treasury.pause();
        address[] memory tokens = new address[](1);
        tokens[0] = address(stable);
        vm.prank(guardian);
        treasury.emergencyDrainAssets(tokens);
        assertEq(stable.balanceOf(guardian), 31_000 ether); // client + house
        assertEq(treasury.clientTotals(address(stable)), 0);
        assertEq(treasury.houseBalances(address(stable)), 0);
    }

    function test_EmergencyDrain_RequiresPause() public {
        vm.prank(guardian);
        vm.expectRevert(VASPTreasury.ProtocolPaused.selector);
        treasury.emergencyDrain();
    }

    /* ---------- audit snapshots ---------- */

    function test_ClientTotalSnapshot_Historical() public {
        _clientDeposit(clientA, 5_000 ether);
        vm.roll(block.number + 1);
        _clientDeposit(clientB, 2_000 ether);
        assertEq(treasury.getPastClientTotal(address(stable), block.number), 7_000 ether);
        assertEq(treasury.getPastClientTotal(address(stable), block.number - 1), 5_000 ether);
    }

    /* ---------- admin ---------- */

    function test_ReserveBps_OperatorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.setReserveBps(1000);
        treasury.setReserveBps(1000);
        assertEq(treasury.reserveBps(), 1000);
        vm.expectRevert();
        treasury.setReserveBps(10_001);
    }

    function test_RecoveryAddress_AdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.setRecoveryAddress(outsider);
    }
}
