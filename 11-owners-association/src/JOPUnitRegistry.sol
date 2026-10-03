// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title JOPUnitRegistry
/// @notice The building's unit ledger: who owns what, how large each unit is, and how
///         service charges accrue — the ownership backbone of the governance suite.
/// @dev Inspired by Dubai's jointly owned property regime (Law No. 6 of 2019 and RERA
///      guidance): every unit carries an area in square metres, ownership weight equals
///      area, and the association levies an annual service charge per square metre.
///      Unit transfers are registered by the governance authority (board or a passed
///      proposal) — on-chain registration is what makes the ledger authoritative.
contract JOPUnitRegistry {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice One unit in the building.
    struct Unit {
        uint256 areaSqm; // ownership weight = area in square metres (1 sqm = 1 vote)
        address owner; // current registered owner
        uint64 lastChargeAccrual; // timestamp of the last service-charge accrual
        uint256 chargeDebt; // accrued, unpaid service charges (AED-S, 18 decimals)
    }

    /// @notice The address allowed to mutate the ledger (the association governor).
    address public authority;

    /// @notice The stablecoin service charges are denominated in.
    IERC20 public immutable chargeToken;

    /// @notice Where paid service charges are forwarded (the association treasury).
    address public treasury;

    /// @notice Annual service charge rate: chargeToken units per square metre per year.
    uint256 public annualChargePerSqm;

    /// @notice The full unit ledger.
    mapping(uint256 unitId => Unit) public units;

    /// @notice Total units registered.
    uint256 public unitCount;

    /// @notice Aggregate registered area of the whole building.
    uint256 public totalAreaSqm;

    /// @notice Aggregated area currently registered to each owner.
    mapping(address owner => uint256) public ownerAreaSqm;

    /// @notice Snapshot history of each owner's aggregated area (voting-power base).
    mapping(address owner => Checkpoints.Checkpoint[]) private _ownerAreaHistory;

    /// @notice Total outstanding service-charge arrears across the building.
    uint256 public totalArrears;

    event UnitAdded(uint256 indexed unitId, address indexed owner, uint256 areaSqm);
    event UnitTransferred(uint256 indexed unitId, address indexed from, address indexed to);
    event ChargeRateSet(uint256 annualPerSqm);
    event ServiceChargeAccrued(uint256 indexed unitId, uint256 amount);
    event ServiceChargePaid(uint256 indexed unitId, address indexed payer, uint256 amount);

    error ZeroAddress();
    error ZeroArea();
    error NotAuthority(address caller);
    error InvalidUnit(uint256 unitId);
    error SameOwner(address owner);
    error Overpay(uint256 debt, uint256 amount);
    error TransferFailed();

    modifier onlyAuthority() {
        if (msg.sender != authority) revert NotAuthority(msg.sender);
        _;
    }

    constructor(IERC20 chargeToken_, address initialAuthority) {
        if (address(chargeToken_) == address(0) || initialAuthority == address(0)) {
            revert ZeroAddress();
        }
        chargeToken = chargeToken_;
        authority = initialAuthority;
    }

    /* ==================== AUTHORITY WIRING ==================== */

    /// @notice Re-points the ledger authority (deploy-time two-step wiring).
    function setAuthority(address newAuthority) external onlyAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        authority = newAuthority;
    }

    /// @notice Points charge payments at the association treasury.
    function setTreasury(address treasury_) external onlyAuthority {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    /* ==================== UNIT LEDGER ==================== */

    /// @notice Registers a new unit.
    /// @dev Only the authority: in production this happens when the developer's building
    ///      plan is registered with the regulator and the initial owners are recorded.
    function addUnit(uint256 areaSqm, address owner) external onlyAuthority returns (uint256 unitId) {
        if (areaSqm == 0) revert ZeroArea();
        if (owner == address(0)) revert ZeroAddress();

        unitId = unitCount++;
        units[unitId] = Unit({ areaSqm: areaSqm, owner: owner, lastChargeAccrual: uint64(block.timestamp), chargeDebt: 0 });

        totalAreaSqm += areaSqm;
        _setOwnerArea(owner, ownerAreaSqm[owner] + areaSqm);
        emit UnitAdded(unitId, owner, areaSqm);
    }

    /// @notice Registers the sale of a unit to a new owner.
    /// @dev Real-estate accuracy: sales are registered, not self-service transfers —
    ///      the board (or a passed proposal) records the transaction after it closes.
    function registerSale(uint256 unitId, address newOwner) external onlyAuthority {
        Unit storage u = units[unitId];
        if (u.owner == address(0)) revert InvalidUnit(unitId);
        if (newOwner == address(0)) revert ZeroAddress();
        if (u.owner == newOwner) revert SameOwner(newOwner);

        _accrue(unitId);
        address previous = u.owner;
        u.owner = newOwner;
        _setOwnerArea(previous, ownerAreaSqm[previous] - u.areaSqm);
        _setOwnerArea(newOwner, ownerAreaSqm[newOwner] + u.areaSqm);
        emit UnitTransferred(unitId, previous, newOwner);
    }

    /* ==================== SERVICE CHARGES ==================== */

    /// @notice Sets the annual service-charge rate per square metre.
    /// @dev Only the authority (a ChargeRate proposal) may change it.
    function setAnnualChargePerSqm(uint256 newRate) external onlyAuthority {
        annualChargePerSqm = newRate;
        emit ChargeRateSet(newRate);
    }

    /// @notice Accrues the unit's service-charge debt since its last accrual.
    /// @dev Accrual is lazy and linear: debt += rate × area × elapsedYears.
    ///      Charges stop accruing from the moment a sale is registered onward.
    function accrue(uint256 unitId) external returns (uint256) {
        return _accrue(unitId);
    }

    /// @notice Pays (part of) the unit's accrued service charges in the charge token.
    /// @dev Funds are pulled from the payer and forwarded straight to the treasury.
    function payServiceCharge(uint256 unitId, uint256 amount) external {
        Unit storage u = units[unitId];
        if (u.owner == address(0)) revert InvalidUnit(unitId);
        _accrue(unitId);
        if (amount == 0) return;
        if (amount > u.chargeDebt) revert Overpay(u.chargeDebt, amount);

        u.chargeDebt -= amount;
        totalArrears -= amount;
        if (!chargeToken.transferFrom(msg.sender, treasury, amount)) revert TransferFailed();
        emit ServiceChargePaid(unitId, msg.sender, amount);
    }

    function _accrue(uint256 unitId) internal returns (uint256 added) {
        Unit storage u = units[unitId];
        if (u.areaSqm == 0) revert InvalidUnit(unitId);
        uint256 elapsed = block.timestamp - u.lastChargeAccrual;
        if (elapsed == 0 || annualChargePerSqm == 0) return 0;
        // rate × area × years, 18-decimals fixed point: rate/365d × elapsed
        added = (annualChargePerSqm * u.areaSqm * elapsed) / 365 days;
        u.chargeDebt += added;
        totalArrears += added;
        u.lastChargeAccrual = uint64(block.timestamp);
        if (added > 0) emit ServiceChargeAccrued(unitId, added);
    }

    /* ==================== VOTING POWER (SNAPSHOT) ==================== */

    /// @notice The area currently registered to `owner` (their voting weight base).
    function ownerArea(address owner) external view returns (uint256) {
        return ownerAreaSqm[owner];
    }

    /// @notice The area registered to `owner` at or before `blockNumber`.
    /// @dev This is the snapshot primitive the governor uses: "power at proposal block".
    function getPastOwnerArea(address owner, uint256 blockNumber) external view returns (uint256) {
        return _ownerAreaHistory[owner].lookup(blockNumber);
    }

    /// @notice The unit's outstanding service-charge debt (accrues lazily — call `accrue`).
    function chargeDebt(uint256 unitId) external view returns (uint256) {
        return units[unitId].chargeDebt;
    }

    function _setOwnerArea(address owner, uint256 newArea) internal {
        ownerAreaSqm[owner] = newArea;
        _ownerAreaHistory[owner].write(ownerAreaSqm[owner], newArea);
    }
}
