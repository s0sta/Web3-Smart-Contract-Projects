// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaRegistry} from "./AtaaRegistry.sol";
import {AtaaOracle} from "./AtaaOracle.sol";
import {AtaaVault} from "./AtaaVault.sol";

/// @title AtaaZakat
/// @notice The zakat intelligence core. A payer declares wealth per asset
///         class; the module tracks nisab and hawl per class, computes the
///         due amount with the class-specific rate, and collects it into the
///         vault — with full edge-case handling:
///           · wealth below nisab      → due 0, no hawl clock
///           · wealth crosses nisab    → hawl clock starts
///           · wealth drops below      → hawl clock resets
///           · re-declaration          → recomputed instantly
///           · hawl complete           → due = wealth × rate
///           · partial payment         → remainder tracked, hawl unchanged
///           · full payment            → hawl restarts (no double payment)
///           · produce (harvest)       → no hawl, 10% rain-fed / 5% irrigated
///           · rikaz (found treasure)  → 20%, no hawl, no nisab
///           · livestock               → head-count schedule lookups
contract AtaaZakat is AccessControl {
    /// @notice The committee adjusts prices and pauses.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice Asset classes.
    enum AssetClass { None, Cash, Gold, Silver, Crypto, Produce, Livestock, Rikaz }

    /// @notice One declared wealth position.
    struct Position {
        uint256 declaredWealth;
        uint64 hawlStart;
        uint256 paidThisHawl;
        uint64 lastDeclaredAt;
    }

    mapping(address payer => mapping(AssetClass ac => Position)) public positions;

    /// @notice Class rates (bps).
    mapping(AssetClass ac => uint256) public rateBps;

    /// @notice Whether the class uses a hawl clock (monetary classes do;
    ///         produce/rikaz do not).
    mapping(AssetClass ac => bool) public requiresHawl;

    /// @notice The hawl duration (lunar year ≈ 354 days).
    uint256 public constant HAWL = 354 days;

    /// @notice Nisab thresholds, set by the committee (in the payment token).
    uint256 public cashNisab;
    uint256 public goldNisabGrams;
    uint256 public silverNisabGrams;
    uint256 public produceNisabKg;

    /// @notice Produce irrigation modes.
    enum Irrigation { RainFed, Irrigated }

    AtaaRegistry public immutable registry;
    AtaaOracle public immutable oracle;
    AtaaVault public immutable vault;
    IERC20 public immutable paymentToken;

    bool public paused;

    event WealthDeclared(address indexed payer, AssetClass indexed ac, uint256 amount);
    event ZakatPaid(address indexed payer, AssetClass indexed ac, uint256 amount);
    event HawlRestarted(address indexed payer, AssetClass indexed ac);
    event NisabSet(string which, uint256 value);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidClass();
    error BelowNisab(uint256 wealth, uint256 nisab);
    error HawlNotComplete(uint64 hawlStart, uint64 now);
    error NothingDue(address payer, AssetClass ac);
    error ExceedsDue(uint256 due, uint256 amount);
    error ProtocolPaused();

    constructor(
        AtaaRegistry registry_,
        AtaaOracle oracle_,
        AtaaVault vault_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(oracle_) == address(0) || address(vault_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        oracle = oracle_;
        vault = vault_;
        paymentToken = paymentToken_;

        // Shariah-fixed rates
        rateBps[AssetClass.Cash] = 250; // 2.5%
        rateBps[AssetClass.Gold] = 250;
        rateBps[AssetClass.Silver] = 250;
        rateBps[AssetClass.Crypto] = 250;
        rateBps[AssetClass.Produce] = 0; // set per irrigation mode
        rateBps[AssetClass.Livestock] = 0; // schedule-based
        rateBps[AssetClass.Rikaz] = 2000; // 20%

        requiresHawl[AssetClass.Cash] = true;
        requiresHawl[AssetClass.Gold] = true;
        requiresHawl[AssetClass.Silver] = true;
        requiresHawl[AssetClass.Crypto] = true;
        requiresHawl[AssetClass.Produce] = false;
        requiresHawl[AssetClass.Livestock] = true;
        requiresHawl[AssetClass.Rikaz] = false;

        goldNisabGrams = 85;
        silverNisabGrams = 595;
        produceNisabKg = 653; // 5 wasaq ≈ 653 kg
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== DECLARATION ==================== */

    function declareWealth(AssetClass ac, uint256 amount) external whenNotPaused {
        if (ac == AssetClass.None || ac == AssetClass.Livestock || ac == AssetClass.Rikaz) revert InvalidClass();
        if (amount == 0) revert ZeroAmount();
        if (!registry.isDonor(msg.sender)) revert ZeroAmount();

        Position storage p = positions[msg.sender][ac];
        p.declaredWealth = amount;
        p.lastDeclaredAt = uint64(block.timestamp);

        if (requiresHawl[ac]) {
            uint256 nisab = _nisabOf(ac, amount);
            if (amount >= nisab) {
                if (p.hawlStart == 0) p.hawlStart = uint64(block.timestamp);
            } else {
                p.hawlStart = 0; // fell below the nisab — the clock resets
            }
        }
        emit WealthDeclared(msg.sender, ac, amount);
    }

    /// @dev The nisab for monetary classes; gold/silver convert grams via the
    ///      oracle prices; cash uses the committee's direct threshold.
    function _nisabOf(AssetClass ac, uint256) internal view returns (uint256) {
        if (ac == AssetClass.Gold) return (oracle.price(oracle.goldToken()) * goldNisabGrams);
        if (ac == AssetClass.Silver) return (oracle.price(oracle.silverToken()) * silverNisabGrams);
        return cashNisab; // Cash / Crypto use the cash nisab
    }

    /* ==================== DUE COMPUTATION ==================== */

    /// @notice The zakat currently due for a monetary class.
    function due(address payer, AssetClass ac) public view returns (uint256) {
        if (ac == AssetClass.None) return 0;
        if (ac == AssetClass.Produce || ac == AssetClass.Rikaz || ac == AssetClass.Livestock) return 0;
        Position storage p = positions[payer][ac];
        if (p.declaredWealth < _nisabOf(ac, p.declaredWealth)) return 0;
        if (p.hawlStart == 0 || block.timestamp < uint256(p.hawlStart) + HAWL) return 0;
        uint256 total = (p.declaredWealth * rateBps[ac]) / 10_000;
        uint256 remaining = total > p.paidThisHawl ? total - p.paidThisHawl : 0;
        return remaining;
    }

    /// @notice The due zakat for produce (no hawl): 10% rain-fed, 5% irrigated.
    function produceDue(uint256 produceKg, Irrigation mode) public pure returns (uint256) {
        uint256 rate = mode == Irrigation.RainFed ? 1000 : 500;
        return (produceKg * rate) / 10_000;
    }

    /// @notice Livestock schedule lookups (head count → due heads).
    function sheepDue(uint256 heads) public pure returns (uint256) {
        if (heads < 40) return 0;
        if (heads <= 120) return 1;
        if (heads <= 200) return 2;
        return 2 + (heads - 200) / 100;
    }

    function camelDue(uint256 heads) public pure returns (uint256) {
        if (heads < 5) return 0;
        if (heads <= 9) return 1; // one sheep per camel in this band
        if (heads <= 14) return 2;
        if (heads <= 19) return 3;
        if (heads <= 24) return 4;
        if (heads <= 35) return heads - 25 + 5; // 25–35 → one 1yr she-camel
        if (heads <= 45) return 1; // 36–45 → one 2yr she-camel (simplified heads)
        if (heads <= 60) return 1; // 46–60 → one 3yr she-camel
        if (heads <= 75) return 1; // 61–75 → one 4yr she-camel
        if (heads <= 90) return 2; // 76–90 → two 2yr she-camels
        return 2 + (heads - 90) / 50;
    }

    function cowDue(uint256 heads) public pure returns (uint256) {
        if (heads < 30) return 0;
        if (heads <= 39) return 1; // one 1yr calf
        if (heads <= 59) return 1; // one 2yr calf
        return 1 + (heads - 60) / 30;
    }

    /* ==================== PAYMENT ==================== */

    /// @notice Pays the full or partial due for a monetary class.
    function payZakat(AssetClass ac, uint256 amount) external whenNotPaused {
        if (ac == AssetClass.None || ac == AssetClass.Produce || ac == AssetClass.Rikaz || ac == AssetClass.Livestock) revert InvalidClass();
        if (amount == 0) revert ZeroAmount();
        uint256 owed = due(msg.sender, ac);
        if (owed == 0) revert NothingDue(msg.sender, ac);
        if (amount > owed) revert ExceedsDue(owed, amount);

        Position storage p = positions[msg.sender][ac];
        p.paidThisHawl += amount;

        if (!paymentToken.transferFrom(msg.sender, address(vault), amount)) revert ExceedsDue(owed, amount);
        vault.recordZakat(msg.sender, ac, amount);

        if (p.paidThisHawl >= (p.declaredWealth * rateBps[ac]) / 10_000) {
            p.paidThisHawl = 0;
            p.hawlStart = uint64(block.timestamp); // the next hawl begins now
            emit HawlRestarted(msg.sender, ac);
        }
        emit ZakatPaid(msg.sender, ac, amount);
    }

    /// @notice Pays produce zakat (no hawl) — value-denominated.
    function payProduceZakat(uint256 produceKg, Irrigation mode, uint256 pricePerKg) external whenNotPaused {
        if (produceKg == 0 || pricePerKg == 0) revert ZeroAmount();
        if (produceKg < produceNisabKg) revert BelowNisab(produceKg, produceNisabKg);
        uint256 value = produceKg * pricePerKg;
        uint256 owed = (value * (mode == Irrigation.RainFed ? 1000 : 500)) / 10_000;
        if (!paymentToken.transferFrom(msg.sender, address(vault), owed)) revert ExceedsDue(owed, 0);
        vault.recordZakat(msg.sender, AssetClass.Produce, owed);
        emit ZakatPaid(msg.sender, AssetClass.Produce, owed);
    }

    /// @notice Pays rikaz (found treasure): 20%, no nisab, no hawl.
    function payRikaz(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 owed = (amount * rateBps[AssetClass.Rikaz]) / 10_000;
        if (!paymentToken.transferFrom(msg.sender, address(vault), owed)) revert ExceedsDue(owed, 0);
        vault.recordZakat(msg.sender, AssetClass.Rikaz, owed);
        emit ZakatPaid(msg.sender, AssetClass.Rikaz, owed);
    }

    /* ==================== ADMIN ==================== */

    function setCashNisab(uint256 nisab) external onlyRole(COMMITTEE_ROLE) {
        if (nisab == 0) revert ZeroAmount();
        cashNisab = nisab;
        emit NisabSet("cash", nisab);
    }

    function setNisabGrams(uint256 goldGrams, uint256 silverGrams, uint256 produceKg_) external onlyRole(COMMITTEE_ROLE) {
        if (goldGrams == 0 || silverGrams == 0 || produceKg_ == 0) revert ZeroAmount();
        goldNisabGrams = goldGrams;
        silverNisabGrams = silverGrams;
        produceNisabKg = produceKg_;
        emit NisabSet("grams", goldGrams);
    }

    function pause() external onlyRole(COMMITTEE_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(COMMITTEE_ROLE) {
        paused = false;
        emit Paused(false);
    }
}
