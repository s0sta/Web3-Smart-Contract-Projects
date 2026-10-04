// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {SahmCompliance} from "../src/SahmCompliance.sol";
import {SahmOracle} from "../src/SahmOracle.sol";
import {SahmCollateral} from "../src/SahmCollateral.sol";
import {SahmTreasury} from "../src/SahmTreasury.sol";
import {SahmRisk} from "../src/SahmRisk.sol";
import {SahmOrderBook} from "../src/SahmOrderBook.sol";
import {SahmAMM} from "../src/SahmAMM.sol";
import {SahmMargin} from "../src/SahmMargin.sol";
import {SahmInsuranceFund} from "../src/SahmInsuranceFund.sol";
import {SahmGovernor} from "../src/SahmGovernor.sol";

/// @title DeploySahm
/// @notice Deploys the complete exchange: compliance, EMA oracle, collateral
///         desk, treasury (20% reserve), risk engine (ETH market: 1M position
///         cap / 5M daily volume / 10% move breaker), the order book (0.1% /
///         0.2% fees), one AMM pool (0.3% fee, 20% protocol share), the margin
///         desk (5x), the insurance fund and the LP-share governor (10% quorum).
contract DeploySahm is Script {
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
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        MockStable stable = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        SahmCompliance compliance = new SahmCompliance(officers);

        SahmOracle oracle = new SahmOracle(1 hours, 24 hours);
        SahmCollateral collateral = new SahmCollateral(stable);
        SahmTreasury treasury = new SahmTreasury(stable, 2000);
        SahmRisk risk = new SahmRisk(oracle);
        SahmOrderBook book = new SahmOrderBook(collateral, compliance, risk, treasury, stable);
        SahmAMM amm = new SahmAMM(compliance, risk, treasury, stable);
        SahmMargin margin = new SahmMargin(collateral, oracle, compliance, risk);
        SahmInsuranceFund insurance = new SahmInsuranceFund(stable);
        SahmGovernor governor = new SahmGovernor(amm, margin, book, risk, treasury, 1000);

        // ---- wiring ----
        collateral.grantRole(collateral.ORDERBOOK_ROLE(), address(book));
        collateral.grantRole(collateral.MARGIN_ROLE(), address(margin));
        risk.grantRole(risk.VENUE_ROLE(), address(book));
        risk.grantRole(risk.VENUE_ROLE(), address(amm));
        risk.grantRole(risk.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        book.grantRole(book.OPERATOR_ROLE(), address(governor));
        amm.grantRole(amm.OPERATOR_ROLE(), address(governor));
        margin.grantRole(margin.OPERATOR_ROLE(), address(governor));
        insurance.grantRole(insurance.COMMITTEE_ROLE(), officer);
        insurance.grantRole(insurance.VENUE_ROLE(), address(amm));
        insurance.setCommitteeSize(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        if (officer == deployer) {
            compliance.setKyc(deployer, SahmCompliance.KycTier.Professional);
        }

        risk.setMarket(address(stable), 1_000_000 ether, 5_000_000 ether, 1000);
        oracle.postPrice(address(stable), 2_000 ether); // 1 ETH = 2,000 AED-S
        vm.stopBroadcast();

        console2.log("Stable    :", address(stable));
        console2.log("Compliance:", address(compliance));
        console2.log("Oracle    :", address(oracle));
        console2.log("Collateral:", address(collateral));
        console2.log("Treasury  :", address(treasury));
        console2.log("Risk      :", address(risk));
        console2.log("OrderBook :", address(book));
        console2.log("AMM       :", address(amm));
        console2.log("Margin    :", address(margin));
        console2.log("Insurance :", address(insurance));
        console2.log("Governor  :", address(governor));
    }
}
