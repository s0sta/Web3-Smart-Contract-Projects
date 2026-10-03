// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title SukukVault
/// @notice A Sharia-compliant sukuk (ijarah structure) on-chain: investors buy
///         certificates in a series backed by a leased income-generating asset.
///
///   · **Issuance** — the issuer registers a series: face value per certificate,
///     total certificates, maturity, the underlying asset and its expected
///     (indicative, non-guaranteed) profit rate.
///   · **Ijara income** — lease income is recorded by the issuer and must be
///     approved by the Shariah board before it can be distributed (income
///     from permissible sources only).
///   · **Profit smoothing** — a share of approved income is withheld into a
///     profit reserve so distributions stay steady across lean periods.
///   · **Distribution epochs** — profits are distributed pro-rata by the
///     certificates held at each epoch's snapshot block; transfers after an
///     epoch cannot capture that epoch's profit.
///   · **Maturity** — the asset manager sells the underlying asset into a
///     redemption pool; holders redeem certificates at face value. Early
///     redemption is not permitted (the certificates run to maturity).
contract SukukVault is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The issuer / asset manager: records income, declares the asset sale.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER");

    /// @notice The Shariah board: approves income sources and distributions.
    bytes32 public constant SHARIAH_ROLE = keccak256("SHARIAH");

    /// @notice The emergency guardian: freeze.
    // (GUARDIAN_ROLE is inherited from AccessControl)

    /// @notice One sukuk series.
    struct Series {
        string name; // e.g. "Green Ijarah Sukuk — Series 1"
        uint256 faceValue; // per certificate, 18 decimals (AED-S)
        uint256 totalCertificates;
        uint256 issuedCertificates;
        uint64 maturity; // redemption opens at this timestamp
        string underlyingAsset; // the leased asset description
        uint256 indicativeProfitBps; // expected annual profit, indicative only
        bool assetSold; // the manager sold the underlying into the redemption pool
        bool frozen;
    }

    Series[] public series;

    /// @notice Certificate balances per series per holder.
    mapping(uint256 seriesId => mapping(address holder => uint256)) public certificates;

    /// @notice Snapshot history per holder per series.
    mapping(uint256 seriesId => mapping(address holder => Checkpoints.Checkpoint[])) private _certHistory;

    /// @notice Unapproved income awaiting the Shariah board.
    mapping(uint256 seriesId => uint256) public pendingApproval;

    /// @notice Approved, undistributed income.
    mapping(uint256 seriesId => uint256) public distributablePool;

    /// @notice Profit-smoothing reserve per series.
    mapping(uint256 seriesId => uint256) public profitReserve;

    /// @notice Redemption pool per series (from the asset sale).
    mapping(uint256 seriesId => uint256) public redemptionPool;

    /// @notice Total income recorded / distributed per series.
    mapping(uint256 seriesId => uint256) public totalIncomeRecorded;
    mapping(uint256 seriesId => uint256) public totalDistributed;

    /// @notice Share of approved income withheld into the profit reserve (bps).
    uint256 public reserveBps;

    /// @notice The payment/profit token (AED-pegged stable).
    IERC20 public immutable paymentToken;

    /// @notice One distribution epoch.
    struct Epoch {
        uint32 snapshotBlock;
        uint256 pool;
        uint256 perCertificate; // pool × 1e18 / totalCertificates
    }

    mapping(uint256 seriesId => Epoch[]) public epochs;
    mapping(uint256 seriesId => mapping(address holder => uint256)) public lastClaimedEpoch;

    /// @notice Redemptions paid per holder per series.
    mapping(uint256 seriesId => mapping(address holder => uint256)) public redeemed;

    event SeriesIssued(uint256 indexed seriesId, string name, uint256 faceValue, uint256 totalCertificates, uint64 maturity);
    event CertificatesPurchased(uint256 indexed seriesId, address indexed investor, uint256 amount);
    event IncomeRecorded(uint256 indexed seriesId, address indexed issuer, uint256 amount);
    event IncomeApproved(uint256 indexed seriesId, uint256 amount);
    event ReserveSet(uint256 bps);
    event Distributed(uint256 indexed seriesId, uint256 epochId, uint256 pool, uint256 perCertificate);
    event Claimed(uint256 indexed seriesId, address indexed holder, uint256 amount);
    event AssetSold(uint256 indexed seriesId, uint256 proceeds);
    event Redeemed(uint256 indexed seriesId, address indexed holder, uint256 certificates, uint256 amount);
    event SeriesFrozen(uint256 indexed seriesId, bool frozen);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownSeries(uint256 seriesId);
    error NotMatured(uint256 seriesId);
    error NotYetMatured(uint256 seriesId);
    error SoldOut();
    error ExceedsSupply(uint256 requested, uint256 remaining);
    error InsufficientCertificates(uint256 balance, uint256 amount);
    error NothingToClaim();
    error NotShariahApproved();
    error FrozenSeries();
    error TransferFailed();
    error RedemptionUnavailable(uint256 seriesId);

    constructor(IERC20 paymentToken_, uint256 reserveBps_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        reserveBps = reserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _grantRole(SHARIAH_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /* ==================== ISSUANCE ==================== */

    function issueSeries(
        string calldata name,
        uint256 faceValue,
        uint256 totalCertificates,
        uint64 maturity,
        string calldata underlyingAsset,
        uint256 indicativeProfitBps
    ) external onlyRole(ISSUER_ROLE) returns (uint256 seriesId) {
        if (faceValue == 0 || totalCertificates == 0) revert ZeroAmount();
        if (maturity <= block.timestamp) revert NotYetMatured(seriesId);
        seriesId = series.length;
        series.push(
            Series({
                name: name,
                faceValue: faceValue,
                totalCertificates: totalCertificates,
                issuedCertificates: 0,
                maturity: maturity,
                underlyingAsset: underlyingAsset,
                indicativeProfitBps: indicativeProfitBps,
                assetSold: false,
                frozen: false
            })
        );
        emit SeriesIssued(seriesId, name, faceValue, totalCertificates, maturity);
    }

    /// @notice Investors purchase certificates at face value.
    function purchase(uint256 seriesId, uint256 amount) external {
        Series storage s = series[seriesId];
        if (s.totalCertificates == 0) revert UnknownSeries(seriesId);
        if (s.frozen) revert FrozenSeries();
        if (block.timestamp >= s.maturity) revert NotYetMatured(seriesId);
        if (amount == 0) revert ZeroAmount();
        if (s.issuedCertificates + amount > s.totalCertificates) {
            revert ExceedsSupply(amount, s.totalCertificates - s.issuedCertificates);
        }
        uint256 cost = amount * s.faceValue;
        if (!paymentToken.transferFrom(msg.sender, address(this), cost)) revert TransferFailed();
        s.issuedCertificates += amount;
        _setCertificates(seriesId, msg.sender, certificates[seriesId][msg.sender] + amount);
        emit CertificatesPurchased(seriesId, msg.sender, amount);
    }

    /* ==================== IJARA INCOME ==================== */

    /// @notice The issuer records lease income; it stays pending until the
    ///         Shariah board approves the source.
    function recordIncome(uint256 seriesId, uint256 amount) external onlyRole(ISSUER_ROLE) {
        Series storage s = series[seriesId];
        if (s.totalCertificates == 0) revert UnknownSeries(seriesId);
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        pendingApproval[seriesId] += amount;
        totalIncomeRecorded[seriesId] += amount;
        emit IncomeRecorded(seriesId, msg.sender, amount);
    }

    /// @notice The Shariah board approves pending income (permissible sources).
    /// @dev The smoothing reserve is withheld before the pool grows.
    function approveIncome(uint256 seriesId) external onlyRole(SHARIAH_ROLE) returns (uint256 approved) {
        approved = pendingApproval[seriesId];
        if (approved == 0) revert ZeroAmount();
        pendingApproval[seriesId] = 0;
        uint256 reserve = (approved * reserveBps) / 10_000;
        profitReserve[seriesId] += reserve;
        distributablePool[seriesId] += approved - reserve;
        emit IncomeApproved(seriesId, approved);
    }

    function setReserveBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    /* ==================== DISTRIBUTION EPOCHS ==================== */

    function distribute(uint256 seriesId) external returns (uint256 epochId) {
        Series storage s = series[seriesId];
        if (s.totalCertificates == 0) revert UnknownSeries(seriesId);
        uint256 pool = distributablePool[seriesId];
        if (pool == 0) revert ZeroAmount();
        distributablePool[seriesId] = 0;
        epochId = epochs[seriesId].length;
        uint256 perCertificate = (pool * 1e18) / s.totalCertificates;
        epochs[seriesId].push(Epoch({ snapshotBlock: uint32(block.number), pool: pool, perCertificate: perCertificate }));
        totalDistributed[seriesId] += pool;
        emit Distributed(seriesId, epochId, pool, perCertificate);
    }

    function claim(uint256 seriesId) external returns (uint256 total) {
        Epoch[] storage history = epochs[seriesId];
        uint256 from = lastClaimedEpoch[seriesId][msg.sender];
        if (from >= history.length) revert NothingToClaim();
        for (uint256 i = from; i < history.length; i++) {
            uint256 certs = _certHistory[seriesId][msg.sender].lookup(history[i].snapshotBlock);
            if (certs > 0) total += (certs * history[i].perCertificate) / 1e18;
        }
        if (total == 0) revert NothingToClaim();
        lastClaimedEpoch[seriesId][msg.sender] = history.length;
        if (!paymentToken.transfer(msg.sender, total)) revert TransferFailed();
        emit Claimed(seriesId, msg.sender, total);
    }

    function claimable(uint256 seriesId, address holder) external view returns (uint256 total) {
        Epoch[] storage history = epochs[seriesId];
        uint256 from = lastClaimedEpoch[seriesId][holder];
        for (uint256 i = from; i < history.length; i++) {
            uint256 certs = _certHistory[seriesId][holder].lookup(history[i].snapshotBlock);
            if (certs > 0) total += (certs * history[i].perCertificate) / 1e18;
        }
    }

    /* ==================== MATURITY & REDEMPTION ==================== */

    /// @notice The manager sells the underlying asset into the redemption pool.
    function sellUnderlying(uint256 seriesId, uint256 proceeds) external onlyRole(ISSUER_ROLE) {
        Series storage s = series[seriesId];
        if (s.totalCertificates == 0) revert UnknownSeries(seriesId);
        if (block.timestamp < s.maturity) revert NotMatured(seriesId);
        if (s.assetSold) revert RedemptionUnavailable(seriesId);
        s.assetSold = true;
        redemptionPool[seriesId] = proceeds;
        emit AssetSold(seriesId, proceeds);
    }

    /// @notice At maturity, holders redeem certificates at face value.
    function redeem(uint256 seriesId, uint256 amount) external returns (uint256 payout) {
        Series storage s = series[seriesId];
        if (s.totalCertificates == 0) revert UnknownSeries(seriesId);
        if (block.timestamp < s.maturity) revert NotMatured(seriesId);
        uint256 bal = certificates[seriesId][msg.sender];
        if (bal < amount) revert InsufficientCertificates(bal, amount);

        payout = amount * s.faceValue;
        uint256 pool = redemptionPool[seriesId] + distributablePool[seriesId];
        if (pool < payout) revert RedemptionUnavailable(seriesId);

        if (redemptionPool[seriesId] >= payout) {
            redemptionPool[seriesId] -= payout;
        } else {
            uint256 fromPool = redemptionPool[seriesId];
            redemptionPool[seriesId] = 0;
            distributablePool[seriesId] -= payout - fromPool;
        }
        _setCertificates(seriesId, msg.sender, bal - amount);
        s.issuedCertificates -= amount;
        redeemed[seriesId][msg.sender] += payout;
        if (!paymentToken.transfer(msg.sender, payout)) revert TransferFailed();
        emit Redeemed(seriesId, msg.sender, amount, payout);
    }

    /* ==================== GUARDIAN ==================== */

    function setSeriesFrozen(uint256 seriesId, bool frozen) external onlyRole(GUARDIAN_ROLE) {
        if (series[seriesId].totalCertificates == 0) revert UnknownSeries(seriesId);
        series[seriesId].frozen = frozen;
        emit SeriesFrozen(seriesId, frozen);
    }

    /* ==================== INTERNALS ==================== */

    function _setCertificates(uint256 seriesId, address holder, uint256 amount) internal {
        certificates[seriesId][holder] = amount;
        _certHistory[seriesId][holder].write(certificates[seriesId][holder], amount);
    }
}
