// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {RahalaStable} from "../src/RahalaStable.sol";
import {RahalaCompliance} from "../src/RahalaCompliance.sol";
import {RahalaOracle} from "../src/RahalaOracle.sol";
import {RahalaAccounts} from "../src/RahalaAccounts.sol";
import {RahalaTreasury} from "../src/RahalaTreasury.sol";
import {RahalaFX} from "../src/RahalaFX.sol";
import {RahalaEscrow} from "../src/RahalaEscrow.sol";
import {RahalaInvoices} from "../src/RahalaInvoices.sol";
import {RahalaSettlement} from "../src/RahalaSettlement.sol";
import {RahalaDisputes} from "../src/RahalaDisputes.sol";
import {RahalaGovernor} from "../src/RahalaGovernor.sol";

/// @title DeployRahala
/// @notice Deploys the complete payments network: AED-S settlement currency,
///         compliance (UAE + US regions allowed), the EMA FX oracle (USD at
///         3.67), the participant ledger, the treasury (20% reserve), the FX
///         desk (0.5%/0.2%), the escrow rail (0.25% fee), invoice factoring
///         (3% minimum discount), batch netting, a 3-arbiter dispute desk and
///         the governor (10% quorum).
contract DeployRahala is Script {
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
        address arbiter2 = vm.envOr("ARBITER_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address arbiter3 = vm.envOr("ARBITER_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        RahalaStable aeds = new RahalaStable("Rahala AED Stable", "AED-S");
        MockStable usdToken = new MockStable();

        address[] memory officers = new address[](1);
        officers[0] = officer;
        RahalaCompliance compliance = new RahalaCompliance(officers);

        RahalaOracle oracle = new RahalaOracle(1 hours, 24 hours);
        RahalaAccounts accounts = new RahalaAccounts(aeds);
        RahalaTreasury treasury = new RahalaTreasury(aeds, 2000);
        RahalaFX fx = new RahalaFX(aeds, oracle, compliance, treasury);
        RahalaEscrow escrow = new RahalaEscrow(aeds, compliance, treasury);
        RahalaInvoices invoices = new RahalaInvoices(aeds, compliance);
        RahalaSettlement netting = new RahalaSettlement(aeds);
        RahalaDisputes disputes = new RahalaDisputes();
        RahalaGovernor governor = new RahalaGovernor(accounts, fx, escrow, invoices, netting, treasury, compliance, oracle, 1000);

        // ---- wiring ----
        escrow.grantRole(escrow.DISPUTES_ROLE(), address(disputes));
        disputes.grantRole(disputes.ARBITER_ROLE(), arbiter2);
        disputes.grantRole(disputes.ARBITER_ROLE(), arbiter3);
        disputes.grantRole(disputes.ARBITER_ROLE(), officer);
        disputes.setArbiterCount(3);
        fx.grantRole(fx.OPERATOR_ROLE(), address(governor));
        escrow.grantRole(escrow.DEFAULT_ADMIN_ROLE(), address(governor));
        invoices.grantRole(invoices.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        aeds.grantRole(aeds.ISSUER_ROLE(), address(accounts));

        if (officer == deployer) {
            compliance.setRegionAllowed(784, true); // UAE
            compliance.setRegionAllowed(840, true); // US
            compliance.setKyc(deployer, RahalaCompliance.KycTier.Verified);
            compliance.setHomeRegion(deployer, 784);
        }

        fx.listCurrency(address(usdToken), "USD", 840);
        oracle.postRate(address(usdToken), 3_670_000_000_000_000_000); // 3.67
        vm.stopBroadcast();

        console2.log("AED-S     :", address(aeds));
        console2.log("USD token :", address(usdToken));
        console2.log("Compliance:", address(compliance));
        console2.log("Oracle    :", address(oracle));
        console2.log("Accounts  :", address(accounts));
        console2.log("Treasury  :", address(treasury));
        console2.log("FX        :", address(fx));
        console2.log("Escrow    :", address(escrow));
        console2.log("Invoices  :", address(invoices));
        console2.log("Settlement:", address(netting));
        console2.log("Disputes  :", address(disputes));
        console2.log("Governor  :", address(governor));
    }
}
