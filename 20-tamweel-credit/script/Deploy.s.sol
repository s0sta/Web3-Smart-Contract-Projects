// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {TamweelCompliance} from "../src/TamweelCompliance.sol";
import {TamweelOracle} from "../src/TamweelOracle.sol";
import {TamweelVault} from "../src/TamweelVault.sol";
import {TamweelRateModel} from "../src/TamweelRateModel.sol";
import {TamweelMarkets} from "../src/TamweelMarkets.sol";
import {TamweelLoans} from "../src/TamweelLoans.sol";
import {TamweelCollateral} from "../src/TamweelCollateral.sol";
import {TamweelInsuranceFund} from "../src/TamweelInsuranceFund.sol";
import {TamweelGovernor} from "../src/TamweelGovernor.sol";

/// @title DeployTamweel
/// @notice Deploys the complete digital bank: credit bureau, EMA oracle, the deposit
///         vault (5% liquidity buffer), the two-slope rate model, the collateralized
///         markets (ETH at 70% LTV / 80% threshold / 5% liquidation bonus), the
///         installment loan book (5% flat interest, 5% settlement rebate, 2% late
///         penalty to charity), the Dutch-auction collateral desk, the insurance
///         fund and the vault-share governor (10% quorum).
contract DeployTamweel is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address committee2 = vm.envOr("COMMITTEE_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address committee3 = vm.envOr("COMMITTEE_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);
        address charity = vm.envOr("CHARITY", deployer);

        vm.startBroadcast(deployerKey);

        MockStable stable = new MockStable();

        address[] memory members = new address[](2);
        members[0] = committee2;
        members[1] = committee3;
        TamweelCompliance compliance = new TamweelCompliance(members);

        TamweelOracle oracle = new TamweelOracle(1 hours, 24 hours);
        TamweelVault vault = new TamweelVault(stable, 500);
        TamweelRateModel rateModel = new TamweelRateModel(
            uint256(3e16) / uint256(365 days), // 3% base APR
            uint256(12e16) / uint256(365 days), // 12% slope1
            uint256(60e16) / uint256(365 days), // 60% slope2
            8000, // kink 80%
            1000 // 10% reserve → insurance fund
        );

        TamweelCollateral collateral = new TamweelCollateral(stable);
        TamweelMarkets markets = new TamweelMarkets(vault, oracle, rateModel, compliance, collateral, stable);
        TamweelLoans loans = new TamweelLoans(compliance, vault, stable, charity, 500, 500, 200, 2);
        TamweelInsuranceFund insurance = new TamweelInsuranceFund(vault, stable);
        TamweelGovernor governor = new TamweelGovernor(vault, rateModel, markets, loans, compliance, 1000);

        // ---- wiring ----
        vault.grantRole(vault.MARKETS_ROLE(), address(markets));
        vault.grantRole(vault.MARKETS_ROLE(), address(loans));
        vault.grantRole(vault.INSURANCE_ROLE(), address(insurance));
        markets.grantRole(markets.OPERATOR_ROLE(), address(governor));
        collateral.grantRole(collateral.MARKETS_ROLE(), address(markets));
        loans.grantRole(loans.FINANCIER_ROLE(), address(governor));
        loans.grantRole(loans.DEFAULT_ADMIN_ROLE(), address(governor));
        loans.grantRole(loans.COMMITTEE_ROLE(), committee2);
        loans.grantRole(loans.COMMITTEE_ROLE(), committee3);
        insurance.grantRole(insurance.COMMITTEE_ROLE(), committee2);
        insurance.grantRole(insurance.COMMITTEE_ROLE(), committee3);
        insurance.grantRole(insurance.MARKETS_ROLE(), address(markets));
        insurance.setCommitteeSize(3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        compliance.grantRole(compliance.COMMITTEE_ROLE(), committee2);
        compliance.grantRole(compliance.COMMITTEE_ROLE(), committee3);

        if (guardian == deployer) {
            // the deployer doubles as the guardian and holds roles already
        }
        // KYC the protocol's own contracts so escrow flows work
        compliance.setKyc(address(markets), TamweelCompliance.KycTier.Standard);
        compliance.setKyc(address(collateral), TamweelCompliance.KycTier.Standard);
        compliance.setKyc(deployer, TamweelCompliance.KycTier.Accredited);
        compliance.setCreditScore(deployer, 900);

        markets.listMarket(stable, 7000, 8000, 500);
        oracle.postPrice(address(stable), 2_000 ether); // 1 ETH = 2,000 AED-S
        vm.stopBroadcast();

        console2.log("Stable    :", address(stable));
        console2.log("Compliance:", address(compliance));
        console2.log("Oracle    :", address(oracle));
        console2.log("Vault     :", address(vault));
        console2.log("RateModel :", address(rateModel));
        console2.log("Markets   :", address(markets), "| market 0 (ETH)");
        console2.log("Loans     :", address(loans), "| charity fees:", address(charity));
        console2.log("Collateral:", address(collateral));
        console2.log("Insurance :", address(insurance));
        console2.log("Governor  :", address(governor));
    }
}
