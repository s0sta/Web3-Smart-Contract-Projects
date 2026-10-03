// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {RERAPropertyRegistry} from "./RERAPropertyRegistry.sol";

/// @title RentalDistributor
/// @notice Collects rental income for tokenized properties and distributes it to
///         fractional owners pro-rata, with a maintenance reserve withheld from every
///         rent payment — the DLD tokenization model: rent → reserve fund → distributions.
///
/// @dev Distribution epochs: each `distribute` call snapshots the pool at a block and
///      records a per-share rate. Holders claim by summing (shares at each epoch's
///      snapshot block × that epoch's per-share rate) — share transfers after an epoch
///      cannot redirect that epoch's income (the snapshot is authoritative).
contract RentalDistributor is AccessControl {
    /// @notice The property manager: may spend the maintenance fund.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice The property ledger (share balances and snapshots).
    RERAPropertyRegistry public immutable registry;

    /// @notice The rent token (AED-pegged stable).
    IERC20 public immutable rentToken;

    /// @notice Share of every rent payment withheld into the maintenance fund (bps).
    uint256 public maintenanceReserveBps;

    /// @notice One distribution epoch: the pool recorded at a snapshot block.
    struct Epoch {
        uint32 snapshotBlock;
        uint256 pool; // rent added to the pool in this epoch (18 decimals)
        uint256 perShare; // pool × 1e18 / totalShares
    }

    /// @notice Per-property epoch history.
    mapping(uint256 propertyId => Epoch[]) public epochs;

    /// @notice Per-property: rent received, distributed, maintenance fund, pending pool.
    mapping(uint256 propertyId => uint256) public totalRentReceived;
    mapping(uint256 propertyId => uint256) public totalDistributed;
    mapping(uint256 propertyId => uint256) public maintenanceFund;
    mapping(uint256 propertyId => uint256) public pendingPool;

    /// @notice Per-property pause (compliance).
    mapping(uint256 propertyId => bool) public paused;

    /// @notice The last epoch each holder has claimed per property.
    mapping(uint256 propertyId => mapping(address holder => uint256)) public lastClaimedEpoch;

    event RentPaid(uint256 indexed propertyId, address indexed payer, uint256 amount);
    event Distributed(uint256 indexed propertyId, uint256 epochId, uint256 pool, uint256 perShare);
    event Claimed(uint256 indexed propertyId, address indexed holder, uint256 amount);
    event MaintenanceSpent(uint256 indexed propertyId, address indexed to, uint256 amount);
    event ReserveSet(uint256 bps);
    event PauseSet(uint256 indexed propertyId, bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownProperty(uint256 propertyId);
    error PropertyPaused(uint256 propertyId);
    error NothingToClaim();
    error InsufficientMaintenance(uint256 available, uint256 requested);
    error NoEpochsYet();
    error TransferFailed();

    constructor(RERAPropertyRegistry registry_, IERC20 rentToken_, uint256 maintenanceReserveBps_) {
        if (address(registry_) == address(0) || address(rentToken_) == address(0)) revert ZeroAddress();
        if (maintenanceReserveBps_ > 10_000) revert ZeroAmount();
        registry = registry_;
        rentToken = rentToken_;
        maintenanceReserveBps = maintenanceReserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    /* ==================== RENT ==================== */

    /// @notice The tenant (or anyone) pays rent for a property.
    /// @dev The maintenance reserve is withheld first; the remainder enters the pending pool.
    function payRent(uint256 propertyId, uint256 amount) external {
        if (_totalShares(propertyId) == 0) revert UnknownProperty(propertyId);
        if (paused[propertyId]) revert PropertyPaused(propertyId);
        if (amount == 0) revert ZeroAmount();
        if (!rentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        uint256 reserve = (amount * maintenanceReserveBps) / 10_000;
        maintenanceFund[propertyId] += reserve;
        pendingPool[propertyId] += amount - reserve;
        totalRentReceived[propertyId] += amount;
        emit RentPaid(propertyId, msg.sender, amount);
    }

    /// @notice Anyone may distribute the pending pool into a new epoch.
    /// @dev Snapshot block = now; the registry's getPastBalance is the authoritative
    ///      entitlement for this epoch.
    function distribute(uint256 propertyId) external returns (uint256 epochId) {
        uint256 pool = pendingPool[propertyId];
        if (pool == 0) revert ZeroAmount();
        uint256 totalShares = _totalShares(propertyId);
        if (totalShares == 0) revert UnknownProperty(propertyId);

        pendingPool[propertyId] = 0;
        epochId = epochs[propertyId].length;
        uint256 perShare = (pool * 1e18) / totalShares;
        epochs[propertyId].push(Epoch({ snapshotBlock: uint32(block.number), pool: pool, perShare: perShare }));
        totalDistributed[propertyId] += pool;
        emit Distributed(propertyId, epochId, pool, perShare);
    }

    /* ==================== CLAIMS ==================== */

    /// @notice Claims the holder's share of every epoch since their last claim.
    function claim(uint256 propertyId) external returns (uint256 total) {
        Epoch[] storage history = epochs[propertyId];
        uint256 from = lastClaimedEpoch[propertyId][msg.sender];
        if (from >= history.length) revert NothingToClaim();

        for (uint256 i = from; i < history.length; i++) {
            uint256 shares = registry.getPastBalance(propertyId, msg.sender, history[i].snapshotBlock);
            if (shares > 0) total += (shares * history[i].perShare) / 1e18;
        }
        if (total == 0) revert NothingToClaim();

        lastClaimedEpoch[propertyId][msg.sender] = history.length;
        if (!rentToken.transfer(msg.sender, total)) revert TransferFailed();
        emit Claimed(propertyId, msg.sender, total);
    }

    /// @notice The holder's currently claimable amount (view).
    function claimable(uint256 propertyId, address holder) external view returns (uint256 total) {
        Epoch[] storage history = epochs[propertyId];
        uint256 from = lastClaimedEpoch[propertyId][holder];
        for (uint256 i = from; i < history.length; i++) {
            uint256 shares = registry.getPastBalance(propertyId, holder, history[i].snapshotBlock);
            if (shares > 0) total += (shares * history[i].perShare) / 1e18;
        }
    }

    /* ==================== MAINTENANCE & GOVERNANCE ==================== */

    /// @notice The manager spends the maintenance fund (repairs, service providers).
    function spendMaintenance(uint256 propertyId, address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (maintenanceFund[propertyId] < amount) revert InsufficientMaintenance(maintenanceFund[propertyId], amount);
        maintenanceFund[propertyId] -= amount;
        if (!rentToken.transfer(to, amount)) revert TransferFailed();
        emit MaintenanceSpent(propertyId, to, amount);
    }

    /// @notice The manager adjusts the maintenance reserve ratio.
    function setMaintenanceReserveBps(uint256 bps) external onlyRole(MANAGER_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        maintenanceReserveBps = bps;
        emit ReserveSet(bps);
    }

    /// @notice Compliance pauses rent acceptance for a property.
    function setPaused(uint256 propertyId, bool paused_) external onlyRole(COMPLIANCE_ROLE) {
        if (_totalShares(propertyId) == 0) revert UnknownProperty(propertyId);
        paused[propertyId] = paused_;
        emit PauseSet(propertyId, paused_);
    }

    /// @dev The registry's auto-generated struct getter returns a flat tuple; keep a
    ///      small helper so the rest of the contract only cares about the share count.
    function _totalShares(uint256 propertyId) internal view returns (uint256) {
        (, uint256 totalShares, , , , , ) = registry.properties(propertyId);
        return totalShares;
    }
}
