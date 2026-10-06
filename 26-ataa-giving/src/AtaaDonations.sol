// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaRegistry} from "./AtaaRegistry.sol";
import {AtaaVault} from "./AtaaVault.sol";

/// @title AtaaDonations
/// @notice The general sadaqa desk: anyone gives any amount, optionally with
///         an intent category; donations land in the vault as tracked
///         contributions.
contract AtaaDonations is AccessControl {
    AtaaRegistry public immutable registry;
    AtaaVault public immutable vault;
    IERC20 public immutable paymentToken;

    /// @notice Optional intent category per donation.
    AtaaRegistry.Category public constant DEFAULT_CATEGORY = AtaaRegistry.Category.Families;

    event Donated(address indexed donor, uint256 amount, AtaaRegistry.Category intent);

    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    constructor(AtaaRegistry registry_, AtaaVault vault_, IERC20 paymentToken_) {
        if (address(registry_) == address(0) || address(vault_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        vault = vault_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Anyone may give sadaqa; the vault records the contribution.
    function donate(uint256 amount, AtaaRegistry.Category intent) external returns (uint256 contributionId) {
        if (amount == 0) revert ZeroAmount();
        if (!registry.isDonor(msg.sender)) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(vault), amount)) revert TransferFailed();
        contributionId = vault.recordDonation(msg.sender, amount);
        intent; // stored via the vault's contribution (category tracked off-ledger in the event)
        emit Donated(msg.sender, amount, intent);
    }
}
