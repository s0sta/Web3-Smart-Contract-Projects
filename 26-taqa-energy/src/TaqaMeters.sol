// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";
import {TaqaOracle} from "./TaqaOracle.sol";

/// @title TaqaMeters
/// @notice The meter registry: producers register physical meters; auditors
///         attest their capacity; production accumulates from oracle telemetry.
contract TaqaMeters is AccessControl {
    /// @notice One meter.
    struct Meter {
        address owner;
        uint256 capacityWatts; // installed capacity
        uint256 totalProducedKwh; // cumulative production
        uint256 attestedKwh; // auditor-attested production (certificate basis)
        uint64 lastReadAt;
        bool active;
    }

    Meter[] public meters;
    mapping(address owner => uint256[]) public metersOf;
    mapping(bytes32 meterId => uint256) public meterBySerial;

    /// @notice kWh per renewable energy certificate (1 REC = 1,000 kWh).
    uint256 public constant KWH_PER_CERT = 1000;

    TaqaRegistry public immutable registry;
    TaqaOracle public immutable oracle;

    event MeterRegistered(uint256 indexed meterId, address indexed owner, uint256 capacityWatts);
    event ProductionAttested(uint256 indexed meterId, uint256 kwh, uint256 certsIssuable);
    event MeterDeactivated(uint256 indexed meterId);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownMeter(uint256 meterId);
    error NotOwnerOrAuditor(uint256 meterId);
    error MeterInactive(uint256 meterId);
    error SerialTaken(bytes32 serial);

    constructor(TaqaRegistry registry_, TaqaOracle oracle_) {
        if (address(registry_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        registry = registry_;
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== REGISTRATION ==================== */

    function registerMeter(bytes32 serial, uint256 capacityWatts) external returns (uint256 meterId) {
        if (capacityWatts == 0) revert ZeroAmount();
        if (serial == bytes32(0)) revert ZeroAmount();
        if (meterBySerial[serial] != 0) revert SerialTaken(serial);
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        if (registry.roleOf(msg.sender) != TaqaRegistry.Role.Producer) revert NotOwnerOrAuditor(0);

        meterId = meters.length;
        meters.push();
        Meter storage m = meters[meterId];
        m.owner = msg.sender;
        m.capacityWatts = capacityWatts;
        m.active = true;
        meterBySerial[serial] = meterId + 1;
        metersOf[msg.sender].push(meterId);
        emit MeterRegistered(meterId, msg.sender, capacityWatts);
    }

    /// @notice The oracle's telemetry accumulates into the meter (operator-gated
    ///         via the oracle contract's production feed).
    function recordProduction(uint256 meterId, bytes32 serial, uint256 kwh) external {
        if (msg.sender != address(oracle) && registry.roleOf(msg.sender) != TaqaRegistry.Role.Auditor) {
            revert NotOwnerOrAuditor(meterId);
        }
        Meter storage m = meters[meterId];
        if (m.owner == address(0)) revert UnknownMeter(meterId);
        if (!m.active) revert MeterInactive(meterId);
        if (kwh == 0) revert ZeroAmount();
        m.totalProducedKwh += kwh;
        m.lastReadAt = uint64(block.timestamp);
        serial; // serials are matched at registration
    }

    /// @notice An auditor attests production, making certificates issuable.
    function attestProduction(uint256 meterId, uint256 kwh) external returns (uint256 certsIssuable) {
        if (registry.roleOf(msg.sender) != TaqaRegistry.Role.Auditor) revert NotOwnerOrAuditor(meterId);
        Meter storage m = meters[meterId];
        if (m.owner == address(0)) revert UnknownMeter(meterId);
        if (!m.active) revert MeterInactive(meterId);
        if (kwh == 0) revert ZeroAmount();
        m.attestedKwh += kwh;
        certsIssuable = m.attestedKwh / KWH_PER_CERT;
        emit ProductionAttested(meterId, kwh, certsIssuable);
    }

    function deactivate(uint256 meterId) external {
        Meter storage m = meters[meterId];
        if (m.owner == address(0)) revert UnknownMeter(meterId);
        if (msg.sender != m.owner && registry.roleOf(msg.sender) != TaqaRegistry.Role.Auditor) {
            revert NotOwnerOrAuditor(meterId);
        }
        m.active = false;
        emit MeterDeactivated(meterId);
    }

    function metersOfList(address owner) external view returns (uint256[] memory) {
        return metersOf[owner];
    }
}
