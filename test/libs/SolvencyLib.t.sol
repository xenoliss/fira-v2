// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {SolvencyLib} from "../../src/libs/SolvencyLib.sol";

/// @title SolvencyLibTest - Unit tests for solvency primitives
contract SolvencyLibTest is Test {
    //////////////////////////////////////////////////////////////
    ///                       Constants                        ///
    //////////////////////////////////////////////////////////////

    uint256 constant SECONDS_PER_YEAR = 365 days;

    // Default solvency parameters
    uint256 constant LAMBDA_W = SECONDS_PER_YEAR; // 1 year decay
    int256 constant ETA_B = 0.2e18; // 20% borrower haircut
    int256 constant ETA_L = 0.1e18; // 10% lender premium
    int256 constant W_VAULT = 0.5e18; // 50% vault weight

    //////////////////////////////////////////////////////////////
    ///              computeBaseEquity Tests                   ///
    //////////////////////////////////////////////////////////////

    /// @dev E_base = (yLiq + yPnl) + w_vault·y_vault + S_past
    function test_computeBaseEquity_sumsCorrectly() public pure {
        uint256 yLiqWad = 800e18;
        uint256 yPnlWad = 200e18;
        uint256 yVaultWad = 500e18;
        int256 wVault = 0.5e18; // 50%
        int256 sPast = -100e18;

        int256 base = SolvencyLib.computeBaseEquity({
            yLiqWad: yLiqWad, yPnlWad: yPnlWad, yVaultWad: yVaultWad, wVault: wVault, sPast: sPast
        });

        // Expected: (800 + 200) + 0.5 * 500 + (-100) = 1000 + 250 - 100 = 1150
        assertEq(base, 1150e18, "Base equity should sum correctly");
    }

    //////////////////////////////////////////////////////////////
    ///              computeWeightedNet Tests                  ///
    //////////////////////////////////////////////////////////////

    /// @dev At τ=0, φ=0 so weights=1, net equals b - l exactly
    function test_computeWeightedNet_atTauZero_returnsUnweighted() public pure {
        uint256 tau = 0;
        uint256 b = 100e18;
        uint256 l = 50e18;

        int256 net = SolvencyLib.computeWeightedNet({tau: tau, b: b, l: l, lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L});

        // At tau=0, phi=0, so w_b=1, w_l=1
        // net = 1*100 - 1*50 = 50
        assertEq(net, 50e18, "At tau=0, net should be unweighted (b - l)");
    }

    /// @dev At τ→∞, weights converge: w_b = 1-η_b, w_l = 1+η_l
    function test_computeWeightedNet_atLargeTau_convergesToLimits() public pure {
        int256 net = SolvencyLib.computeWeightedNet({
            tau: 100 * SECONDS_PER_YEAR, // φ ≈ 1
            b: 1000e18,
            l: 1000e18,
            lambdaW: LAMBDA_W,
            etaB: ETA_B,
            etaL: ETA_L
        });

        // At φ=1: net = (1-0.2)*1000 - (1+0.1)*1000 = 800 - 1100 = -300
        assertApproxEqRel(net, -300e18, 1e12); // 0.0001% tolerance
    }

    /// @dev At τ=1y, verify pre-computed value from Python (net ≈ 341.97e18)
    function test_computeWeightedNet_knownValue_oneYear() public pure {
        int256 net = SolvencyLib.computeWeightedNet({
            tau: SECONDS_PER_YEAR, b: 1000e18, l: 500e18, lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L
        });

        // Expected: 341.969860292859... e18
        assertApproxEqRel(net, 341969860292860000000, 1e14); // 0.01% tolerance
    }

    //////////////////////////////////////////////////////////////
    ///                 checkFloor Tests                       ///
    //////////////////////////////////////////////////////////////

    /// @dev minERisk >= floor passes without revert
    function test_checkFloor_passes_whenAbove() public pure {
        int256 minERisk = 100e18;
        int256 rho = 1e18; // 1 per LP share
        uint256 nLp = 50e18; // 50 LP shares

        // floor = 1 * 50 = 50, minERisk = 100 >= 50 ✓
        SolvencyLib.checkFloor({minERisk: minERisk, rho: rho, nLp: nLp});
        // Should not revert
    }

    /// @dev minERisk < floor reverts with SolvencyFloorViolated
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_checkFloor_whenBelow() public {
        int256 minERisk = 49e18;
        int256 rho = 1e18;
        uint256 nLp = 50e18;

        // floor = 50, minERisk = 49 < 50 ✗
        vm.expectRevert(SolvencyLib.SolvencyFloorViolated.selector);
        SolvencyLib.checkFloor({minERisk: minERisk, rho: rho, nLp: nLp});
    }

    //////////////////////////////////////////////////////////////
    ///               Integration-style Tests                  ///
    //////////////////////////////////////////////////////////////

    /// @dev End-to-end: base equity + multiple maturities + floor check
    function test_fullSolvencyFlow_passes() public pure {
        // Simulate a full solvency check
        uint256 yLiqWad = 8_000e18;
        uint256 yPnlWad = 2_000e18;
        uint256 yVaultWad = 5_000e18;
        int256 wVault = W_VAULT;
        int256 sPast = -500e18;

        // Base equity
        int256 eRisk = SolvencyLib.computeBaseEquity({
            yLiqWad: yLiqWad, yPnlWad: yPnlWad, yVaultWad: yVaultWad, wVault: wVault, sPast: sPast
        });
        // (8000 + 2000) + 0.5*5000 - 500 = 10000 + 2500 - 500 = 12000
        assertEq(eRisk, 12_000e18, "Base equity check");

        int256 minERisk = eRisk;

        // Add one maturity with b=1000, l=500
        int256 net1 = SolvencyLib.computeWeightedNet({
            tau: SECONDS_PER_YEAR, b: 1000e18, l: 500e18, lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L
        });
        eRisk += net1;
        if (eRisk < minERisk) minERisk = eRisk;

        // Add another maturity with b=200, l=800
        int256 net2 = SolvencyLib.computeWeightedNet({
            tau: 2 * SECONDS_PER_YEAR, b: 200e18, l: 800e18, lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L
        });
        eRisk += net2;
        if (eRisk < minERisk) minERisk = eRisk;

        // Check floor with generous parameters
        SolvencyLib.checkFloor({minERisk: minERisk, rho: 0, nLp: 1000e18});
        // Should pass since rho=0 means floor=0
    }

    //////////////////////////////////////////////////////////////
    ///                     Fuzz Tests                         ///
    //////////////////////////////////////////////////////////////

    /// @dev Property: at τ=0, net = b - l for any b, l
    function testFuzz_computeWeightedNet_tauZero_isUnweighted(uint256 b, uint256 l) public pure {
        b = bound(b, 0, 1e30);
        l = bound(l, 0, 1e30);

        int256 net = SolvencyLib.computeWeightedNet({tau: 0, b: b, l: l, lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L});

        assertEq(net, int256(b) - int256(l), "At tau=0, net should be b - l");
    }

    /// @dev Property: checkFloor reverts iff minERisk < ρ·nLp
    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_checkFloor_consistentWithFormula(int256 minERisk, int256 rho, uint256 nLp) public {
        // Bound to avoid overflow in rho * nLp
        rho = bound(rho, -1e20, 1e20);
        nLp = bound(nLp, 0, 1e30);
        minERisk = bound(minERisk, -1e30, 1e30);

        int256 floor = (rho * int256(nLp)) / 1e18; // sMulWad

        if (minERisk < floor) {
            vm.expectRevert(SolvencyLib.SolvencyFloorViolated.selector);
        }
        SolvencyLib.checkFloor({minERisk: minERisk, rho: rho, nLp: nLp});
    }
}
