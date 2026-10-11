// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ShifaScopes
/// @notice The consent scope bits, shared by every Shifa contract so the same
///         numbers are never written twice. Scopes combine: a provider may hold
///         records + prescriptions but not insurance.
library ShifaScopes {
    uint8 internal constant RECORDS = 1;
    uint8 internal constant PRESCRIPTIONS = 2;
    uint8 internal constant INSURANCE = 4;
    uint8 internal constant EMERGENCY = 8;
    uint8 internal constant ALL = 15;
}
