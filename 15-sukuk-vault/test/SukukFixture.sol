// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {SukukVault} from "../src/SukukVault.sol";

/// @notice Shared fixture: "Green Ijarah Sukuk — Series 1" — 1,000 certificates
///         at 100 AED-S face value, 365-day maturity, 8% indicative profit,
///         a 10% profit-smoothing reserve, three investors.
abstract contract SukukFixture is Test {
    MockStable internal stable;
    SukukVault internal vault;

    address internal issuer = address(this);
    address internal shariah = address(0xC);
    address internal guardian = address(0x6);
    address internal investorA = address(0xA);
    address internal investorB = address(0xB);
    address internal investorC = address(0xD);
    address internal outsider = address(0x9);

    uint256 internal seriesId;
    uint256 internal maturity;

    function setUp() public virtual {
        stable = new MockStable();
        vault = new SukukVault(stable, 1000); // 10% smoothing reserve
        vault.grantRole(vault.SHARIAH_ROLE(), shariah);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        maturity = block.timestamp + 365 days;
        seriesId = vault.issueSeries(
            "Green Ijarah Sukuk - Series 1",
            100 ether, // face value
            1000, // certificates
            uint64(maturity),
            "Solar rooftop array, Al Quoz",
            800 // 8% indicative
        );

        for (uint256 i = 1; i < 6; i++) {
            address a = address(uint160(i));
            stable.mint(a, 1_000_000 ether);
            vm.prank(a);
            stable.approve(address(vault), 1_000_000 ether);
        }
        stable.mint(investorA, 100_000 ether);
        stable.mint(investorB, 100_000 ether);
        stable.mint(investorC, 100_000 ether);
        vm.prank(investorA);
        stable.approve(address(vault), 100_000 ether);
        vm.prank(investorB);
        stable.approve(address(vault), 100_000 ether);
        vm.prank(investorC);
        stable.approve(address(vault), 100_000 ether);

        vm.prank(investorA);
        vault.purchase(seriesId, 400);
        vm.prank(investorB);
        vault.purchase(seriesId, 300);
        vm.prank(investorC);
        vault.purchase(seriesId, 300);
    }

    function _recordIncome(uint256 amount) internal {
        stable.mint(issuer, amount);
        stable.approve(address(vault), amount);
        vault.recordIncome(seriesId, amount);
    }
}
