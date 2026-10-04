// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title HuwiyyaSchema
/// @notice The schema registry: versioned definitions of the claim fields a
///         credential may carry, with a value type per field. Issuers reference
///         schemas so verifiers know how to interpret disclosed claims.
contract HuwiyyaSchema is AccessControl {
    /// @notice The operator publishes schemas.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Claim value types.
    enum FieldType { String, Number, Date, Boolean }

    /// @notice One field definition.
    struct Field {
        string name;
        FieldType fType;
    }

    /// @notice One schema version.
    struct SchemaVersion {
        string name;
        uint64 version;
        bool active;
    }

    SchemaVersion[] public schemas;
    mapping(uint256 schemaId => Field[]) private _fields;
    mapping(uint256 schemaId => uint256) public fieldCount;

    event SchemaPublished(uint256 indexed schemaId, string name, uint64 version);
    event SchemaDeactivated(uint256 indexed schemaId);

    error ZeroAddress();
    error InvalidSchema();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function publishSchema(
        string calldata name,
        uint64 version,
        string[] calldata fieldNames,
        FieldType[] calldata fieldTypes
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 schemaId) {
        if (fieldNames.length == 0 || fieldNames.length != fieldTypes.length) revert InvalidSchema();
        schemaId = schemas.length;
        schemas.push(SchemaVersion({ name: name, version: version, active: true }));
        for (uint256 i = 0; i < fieldNames.length; i++) {
            _fields[schemaId].push(Field({ name: fieldNames[i], fType: fieldTypes[i] }));
        }
        fieldCount[schemaId] = fieldNames.length;
        emit SchemaPublished(schemaId, name, version);
    }

    function setActive(uint256 schemaId, bool active) external onlyRole(OPERATOR_ROLE) {
        if (schemas[schemaId].version == 0) revert InvalidSchema();
        schemas[schemaId].active = active;
        if (!active) emit SchemaDeactivated(schemaId);
    }

    function field(uint256 schemaId, uint256 index) external view returns (Field memory) {
        if (index >= fieldCount[schemaId]) revert InvalidSchema();
        return _fields[schemaId][index];
    }

    function isActive(uint256 schemaId) external view returns (bool) {
        return schemas[schemaId].active;
    }
}
