// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {MawaridShares} from "./MawaridShares.sol";
import {MawaridAssetRegistry} from "./MawaridAssetRegistry.sol";

/// @title MawaridRentalDistributor
/// @notice Multi-asset rental income: the manager records lease income per asset,
///         a maintenance reserve is withheld, and the remainder is distributed in
///         epochs — pro-rata by the shares held at each epoch's snapshot block.
contract MawaridRentalDistributor is AccessControl {
    /// @notice The platform manager records income and spends maintenance.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice One distribution epoch.
    struct Epoch {
        uint32 snapshotBlock;
        uint256 pool;
        uint256 perShare; // pool × 1e18 / totalShares
    }

    mapping(uint256 assetId => Epoch[]) public epochs;

    mapping(uint256 assetId => uint256) public totalIncomeRecorded;
    mapping(uint256 assetId => uint256) public totalDistributed;
    mapping(uint256 assetId => uint256) public maintenanceFund;
    mapping(uint256 assetId => uint256) public distributablePool;

    /// @notice Share of income withheld into the maintenance fund (bps).
    uint256 public maintenanceReserveBps;

    mapping(uint256 assetId => mapping(address holder => uint256)) public lastClaimedEpoch;

    MawaridShares public immutable shares;
    MawaridAssetRegistry public immutable registry;
    IERC20 public immutable paymentToken;

    event IncomeRecorded(uint256 indexed assetId, address indexed manager, uint256 amount);
    event Distributed(uint256 indexed assetId, uint256 epochId, uint256 pool, uint256 perShare);
    event Claimed(uint256 indexed assetId, address indexed holder, uint256 amount);
    event MaintenanceSpent(uint256 indexed assetId, address indexed to, uint256 amount);
    event ReserveSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownAsset(uint256 assetId);
    error NothingToClaim();
    error InsufficientMaintenance(uint256 available, uint256 requested);
    error TransferFailed();

    constructor(
        MawaridShares shares_,
        MawaridAssetRegistry registry_,
        IERC20 paymentToken_,
        uint256 maintenanceReserveBps_
    ) {
        if (address(shares_) == address(0) || address(registry_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        shares = shares_;
        registry = registry_;
        paymentToken = paymentToken_;
        maintenanceReserveBps = maintenanceReserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function _totalShares(uint256 assetId) internal view returns (uint256) {
        ( , , , uint256 totalShares, , , , ) = registry.assets(assetId);
        return totalShares;
    }

    /* ==================== INCOME ==================== */

    function recordIncome(uint256 assetId, uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (_totalShares(assetId) == 0) revert UnknownAsset(assetId);
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 reserve = (amount * maintenanceReserveBps) / 10_000;
        maintenanceFund[assetId] += reserve;
        distributablePool[assetId] += amount - reserve;
        totalIncomeRecorded[assetId] += amount;
        emit IncomeRecorded(assetId, msg.sender, amount);
    }

    function setMaintenanceReserveBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        maintenanceReserveBps = bps;
        emit ReserveSet(bps);
    }

    /* ==================== DISTRIBUTION EPOCHS ==================== */

    function distribute(uint256 assetId) external returns (uint256 epochId) {
        uint256 totalShares = _totalShares(assetId);
        if (totalShares == 0) revert UnknownAsset(assetId);
        uint256 pool = distributablePool[assetId];
        if (pool == 0) revert ZeroAmount();

        distributablePool[assetId] = 0;
        epochId = epochs[assetId].length;
        uint256 perShare = (pool * 1e18) / totalShares;
        epochs[assetId].push(Epoch({ snapshotBlock: uint32(block.number), pool: pool, perShare: perShare }));
        totalDistributed[assetId] += pool;
        emit Distributed(assetId, epochId, pool, perShare);
    }

    function claim(uint256 assetId) external returns (uint256 total) {
        Epoch[] storage history = epochs[assetId];
        uint256 from = lastClaimedEpoch[assetId][msg.sender];
        if (from >= history.length) revert NothingToClaim();

        for (uint256 i = from; i < history.length; i++) {
            uint256 held = shares.getPastBalance(msg.sender, history[i].snapshotBlock);
            if (held > 0) total += (held * history[i].perShare) / 1e18;
        }
        if (total == 0) revert NothingToClaim();
        lastClaimedEpoch[assetId][msg.sender] = history.length;
        if (!paymentToken.transfer(msg.sender, total)) revert TransferFailed();
        emit Claimed(assetId, msg.sender, total);
    }

    function claimable(uint256 assetId, address holder) external view returns (uint256 total) {
        Epoch[] storage history = epochs[assetId];
        uint256 from = lastClaimedEpoch[assetId][holder];
        for (uint256 i = from; i < history.length; i++) {
            uint256 held = shares.getPastBalance(holder, history[i].snapshotBlock);
            if (held > 0) total += (held * history[i].perShare) / 1e18;
        }
    }

    /* ==================== MAINTENANCE ==================== */

    function spendMaintenance(uint256 assetId, address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (maintenanceFund[assetId] < amount) revert InsufficientMaintenance(maintenanceFund[assetId], amount);
        maintenanceFund[assetId] -= amount;
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit MaintenanceSpent(assetId, to, amount);
    }
}
