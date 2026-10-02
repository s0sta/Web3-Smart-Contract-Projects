// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

/// @notice Minimal ERC-20 used to prove the multisig can move tokens via generic calldata.
contract MockToken {
    string public name = "MockToken";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A destination that rejects ETH until told otherwise — used to test the
///         "execution failure → retry" flow.
contract RevertingReceiver {
    bool public fail = true;

    function setFail(bool fail_) external {
        fail = fail_;
    }

    receive() external payable {
        if (fail) revert("no thanks");
    }
}

contract MultiSigWalletTest is Test {
    MultiSigWallet wallet;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");
    address recipient = makeAddr("recipient");

    event Deposit(address indexed sender, uint256 value);
    event Submission(uint256 indexed txId);
    event Confirmation(address indexed sender, uint256 indexed txId);
    event Revocation(address indexed sender, uint256 indexed txId);
    event Execution(uint256 indexed txId);
    event ExecutionFailure(uint256 indexed txId);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;
        wallet = new MultiSigWallet(owners, 2);
        vm.deal(address(wallet), 10 ether);
    }

    /// Alice submits a plain ETH transfer of `amount` to `recipient`.
    function _submitEthTransfer(uint256 amount) internal returns (uint256 txId) {
        vm.prank(alice);
        txId = wallet.submitTransaction(recipient, amount, "");
    }

    /* ==================== CONSTRUCTION ==================== */

    function test_Constructor_RejectsEmptyOwnerSet() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(MultiSigWallet.NoOwners.selector);
        new MultiSigWallet(owners, 1);
    }

    function test_Constructor_RejectsZeroThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 0, 1));
        new MultiSigWallet(owners, 0);
    }

    function test_Constructor_RejectsThresholdAboveOwnerCount() public {
        address[] memory owners = new address[](1);
        owners[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 2, 1));
        new MultiSigWallet(owners, 2);
    }

    function test_Constructor_RejectsDuplicateOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = alice;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidOwner.selector, alice));
        new MultiSigWallet(owners, 1);
    }

    function test_Constructor_RejectsZeroAddressOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = alice;
        owners[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidOwner.selector, address(0)));
        new MultiSigWallet(owners, 1);
    }

    /* ==================== DEPOSITS ==================== */

    function test_Receive_AcceptsEthAndEmitsDeposit() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, true, true);
        emit Deposit(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 11 ether);
    }

    /* ==================== SUBMIT ==================== */

    function test_Submit_RecordsTransaction() public {
        vm.prank(alice);
        uint256 txId = wallet.submitTransaction(recipient, 3 ether, "");
        assertEq(txId, 0);
        (address dest, uint256 value, bytes memory data, bool executed) = wallet.transactions(0);
        assertEq(dest, recipient);
        assertEq(value, 3 ether);
        assertEq(data.length, 0);
        assertFalse(executed);
        assertEq(wallet.transactionCount(), 1);
    }

    function test_Submit_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Submission(0);
        vm.prank(alice);
        wallet.submitTransaction(recipient, 1 ether, "");
    }

    function test_Submit_NonOwnerReverts() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector, mallory));
        wallet.submitTransaction(recipient, 1 ether, "");
    }

    /* ==================== CONFIRM ==================== */

    function test_Confirm_IncrementsCount() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.expectEmit(true, true, false, true);
        emit Confirmation(alice, txId);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        assertEq(wallet.getConfirmationCount(txId), 1);
        assertTrue(wallet.isConfirmed(txId, alice));
    }

    function test_Confirm_DoubleConfirmReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.AlreadyConfirmed.selector, txId, alice));
        wallet.confirmTransaction(txId);
    }

    function test_Confirm_NonExistentTxReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxDoesNotExist.selector, 7));
        wallet.confirmTransaction(7);
    }

    function test_Confirm_NonOwnerReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector, mallory));
        wallet.confirmTransaction(txId);
    }

    /* ==================== REVOKE ==================== */

    function test_Revoke_LowersCountAndBlocksExecution() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);

        vm.expectEmit(true, true, false, true);
        emit Revocation(bob, txId);
        vm.prank(bob);
        wallet.revokeConfirmation(txId);

        assertEq(wallet.getConfirmationCount(txId), 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, txId, 1, 2)
        );
        wallet.executeTransaction(txId);
    }

    function test_Revoke_WithoutConfirmationReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotConfirmed.selector, txId, alice));
        wallet.revokeConfirmation(txId);
    }

    function test_Revoke_AfterExecutionReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.AlreadyExecuted.selector, txId));
        wallet.revokeConfirmation(txId);
    }

    /* ==================== EXECUTE ==================== */

    function test_Execute_SendsEthWhenThresholdMet() public {
        uint256 txId = _submitEthTransfer(3 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);

        vm.expectEmit(true, false, false, true);
        emit Execution(txId);
        vm.prank(carol); // any owner may trigger execution
        wallet.executeTransaction(txId);

        assertEq(recipient.balance, 3 ether);
        assertEq(address(wallet).balance, 7 ether);
        (,,, bool executed) = wallet.transactions(txId);
        assertTrue(executed);
    }

    function test_Execute_BelowThresholdReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, txId, 1, 2)
        );
        wallet.executeTransaction(txId);
    }

    function test_Execute_DoubleExecutionReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.AlreadyExecuted.selector, txId));
        wallet.executeTransaction(txId);
    }

    function test_Execute_NonOwnerReverts() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector, mallory));
        wallet.executeTransaction(txId);
    }

    function test_Execute_FailedCallRollsBackAndCanRetry() public {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.prank(alice);
        uint256 txId = wallet.submitTransaction(address(receiver), 1 ether, "");
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);

        // Target rejects ETH → event emitted, flag rolled back, no revert of the whole tx.
        vm.expectEmit(true, false, false, true);
        emit ExecutionFailure(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        (,,, bool executed) = wallet.transactions(txId);
        assertFalse(executed);
        assertEq(wallet.getConfirmationCount(txId), 2); // confirmations persist

        // Fix the target and retry — same confirmations still valid.
        receiver.setFail(false);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        assertEq(address(receiver).balance, 1 ether);
        (,,, executed) = wallet.transactions(txId);
        assertTrue(executed);
    }

    /* ==================== THRESHOLD CHANGES ==================== */

    function test_ChangeThreshold_TakesEffect() public {
        vm.prank(alice);
        wallet.changeThreshold(3);
        assertEq(wallet.threshold(), 3);

        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, txId, 2, 3)
        );
        wallet.executeTransaction(txId);

        vm.prank(carol);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        assertEq(recipient.balance, 1 ether);
    }

    function test_ChangeThreshold_InvalidValuesRevert() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 0, 3));
        wallet.changeThreshold(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 4, 3));
        wallet.changeThreshold(4);
    }

    function test_ChangeThreshold_NonOwnerReverts() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector, mallory));
        wallet.changeThreshold(3);
    }

    /* ==================== TOKENS VIA GENERIC CALL ==================== */

    function test_Execute_TransfersErc20ThroughGenericCall() public {
        MockToken token = new MockToken();
        token.mint(address(wallet), 1000 ether);

        bytes memory data = abi.encodeWithSelector(MockToken.transfer.selector, recipient, 100 ether);
        vm.prank(alice);
        uint256 txId = wallet.submitTransaction(address(token), 0, data);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);

        assertEq(token.balanceOf(address(wallet)), 900 ether);
        assertEq(token.balanceOf(recipient), 100 ether);
    }

    /* ==================== VIEWS ==================== */

    function test_GetConfirmations_ListsInOwnerOrder() public {
        uint256 txId = _submitEthTransfer(1 ether);
        vm.prank(carol);
        wallet.confirmTransaction(txId);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        address[] memory confirmed = wallet.getConfirmations(txId);
        assertEq(confirmed.length, 2);
        assertEq(confirmed[0], alice); // owner order, not confirmation order
        assertEq(confirmed[1], carol);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_ExecuteSendsExactEth(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        uint256 txId = _submitEthTransfer(amount);
        vm.prank(alice);
        wallet.confirmTransaction(txId);
        vm.prank(bob);
        wallet.confirmTransaction(txId);
        vm.prank(carol);
        wallet.executeTransaction(txId);
        assertEq(recipient.balance, amount);
        assertEq(address(wallet).balance, 10 ether - amount);
    }
}
