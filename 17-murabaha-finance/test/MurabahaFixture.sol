// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {MurabahaFinancing} from "../src/MurabahaFinancing.sol";

/// @notice Shared fixture: "Gulf Trade Finance" — AED-S token, 5% settlement
///         rebate, 2 missed installments tolerated, 2% late penalty to charity.
abstract contract MurabahaFixture is Test {
    MockStable internal stable;
    MurabahaFinancing internal murabaha;

    address internal financier = address(this);
    address internal shariah = address(0xC);
    address internal guardian = address(0x6);
    address internal charity = address(0x7);
    address internal buyer = address(0xA);
    address internal supplier = address(0xB);
    address internal guarantor = address(0xD);
    address internal outsider = address(0x99);

    uint256 internal tradeId;

    function setUp() public virtual {
        stable = new MockStable();
        murabaha = new MurabahaFinancing(stable, charity, 500, 2, 200); // 5% rebate, 2 misses, 2% penalty
        murabaha.grantRole(murabaha.SHARIAH_ROLE(), shariah);
        murabaha.grantRole(murabaha.GUARDIAN_ROLE(), guardian);

        stable.setMinter(address(this));
        for (uint256 i = 1; i < 14; i++) {
            stable.mint(address(uint160(i)), 1_000_000 ether);
            vm.prank(address(uint160(i)));
            stable.approve(address(murabaha), 1_000_000 ether);
        }
        stable.mint(buyer, 1_000_000 ether);
        vm.prank(buyer);
        stable.approve(address(murabaha), 1_000_000 ether);

        // financier holds funds to pay the supplier
        stable.mint(financier, 1_000_000 ether);
        stable.approve(address(murabaha), 1_000_000 ether);

        vm.prank(buyer);
        tradeId = murabaha.requestTrade(supplier, guarantor, 10_000 ether, 1_000 ether, 10, 30 days, bytes32("invoice-42"), "Solar panels, 40 kW");
    }

    function _approveAndPurchase() internal {
        vm.prank(shariah);
        murabaha.approveTrade(tradeId);
        murabaha.purchaseAsset(tradeId);
        vm.prank(buyer);
        murabaha.confirmDelivery(tradeId);
    }

    function _payInstallments(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(buyer);
            murabaha.payInstallment(tradeId);
        }
    }
}
