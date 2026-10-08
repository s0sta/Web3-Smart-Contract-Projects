// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {TaqaRegistry} from "../src/TaqaRegistry.sol";
import {TaqaOracle} from "../src/TaqaOracle.sol";
import {TaqaMeters} from "../src/TaqaMeters.sol";
import {TaqaCertificates} from "../src/TaqaCertificates.sol";
import {TaqaCarbon} from "../src/TaqaCarbon.sol";
import {TaqaTreasury} from "../src/TaqaTreasury.sol";
import {TaqaMarket} from "../src/TaqaMarket.sol";
import {TaqaP2P} from "../src/TaqaP2P.sol";
import {TaqaRetirement} from "../src/TaqaRetirement.sol";
import {TaqaCompliance} from "../src/TaqaCompliance.sol";
import {TaqaGovernor} from "../src/TaqaGovernor.sol";

/// @title DeployTaqa
/// @notice Deploys the complete energy market: the registry, the EMA oracle
///         (energy tariff 0.5 AED/kWh), the meter registry (1 REC = 1,000 kWh),
///         certificates, carbon credits, the certificate market (0.5% fee),
///         P2P energy trading (0.3% fee), the retirement desk, zone
///         compliance, the treasury (20% reserve) and the governor.
contract DeployTaqa is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address officer = vm.envOr("COMPLIANCE_OFFICER", deployer);
        address auditor = vm.envOr("AUDITOR", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        MockStable aeds = new MockStable();
        TaqaRegistry registry = new TaqaRegistry();
        TaqaOracle oracle = new TaqaOracle(1 hours, 24 hours);
        TaqaMeters meters = new TaqaMeters(registry, oracle);
        TaqaCertificates certificates = new TaqaCertificates(registry, meters);
        TaqaCarbon carbon = new TaqaCarbon(registry);
        TaqaTreasury treasury = new TaqaTreasury(aeds, 2000);
        TaqaMarket market = new TaqaMarket(registry, certificates, carbon, treasury, aeds);
        TaqaP2P p2p = new TaqaP2P(registry, oracle, treasury, aeds);
        TaqaRetirement retirement = new TaqaRetirement(registry, certificates, carbon);
        TaqaCompliance compliance = new TaqaCompliance(registry);
        TaqaGovernor governor = new TaqaGovernor(registry, compliance, meters, certificates, carbon, market, p2p, retirement, treasury, oracle, 100);

        // ---- wiring ----
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        certificates.grantRole(certificates.AUDITOR_ROLE(), auditor);
        certificates.grantRole(certificates.MARKET_ROLE(), address(market));
        certificates.grantRole(certificates.RETIREMENT_ROLE(), address(retirement));
        carbon.grantRole(carbon.AUDITOR_ROLE(), auditor);
        carbon.grantRole(carbon.MARKET_ROLE(), address(market));
        carbon.grantRole(carbon.RETIREMENT_ROLE(), address(retirement));
        market.grantRole(market.OPERATOR_ROLE(), address(governor));
        p2p.grantRole(p2p.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        if (officer == deployer) {
            compliance.setZoneAllowed(784, true); // UAE
            registry.register(TaqaRegistry.Role.Producer, 784);
        }
        oracle.postPrice(address(aeds), 500_000_000_000_000_000); // 0.5 AED/kWh
        vm.stopBroadcast();

        console2.log("AED-S     :", address(aeds));
        console2.log("Registry  :", address(registry));
        console2.log("Oracle    :", address(oracle));
        console2.log("Meters    :", address(meters));
        console2.log("Certificates:", address(certificates));
        console2.log("Carbon    :", address(carbon));
        console2.log("Treasury  :", address(treasury));
        console2.log("Market    :", address(market));
        console2.log("P2P       :", address(p2p));
        console2.log("Retirement:", address(retirement));
        console2.log("Compliance:", address(compliance));
        console2.log("Governor  :", address(governor));
    }
}
