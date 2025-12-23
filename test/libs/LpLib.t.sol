// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {LpLib} from "../../src/libs/LpLib.sol";

contract LpLibTest is Test {
    //////////////////////////////////////////////////////////////
    ///               computeDeposit Tests                     ///
    //////////////////////////////////////////////////////////////

    /// @dev When nLp=0, shares should equal deposit (1:1 bootstrap).
    function testFuzz_computeDeposit_bootstrap(uint256 depositWad) public pure {
        // Bound: 1 wei to 1e36 WAD (1e18 tokens, 1000x more than all USD worldwide)
        depositWad = bound(depositWad, 1, 1e36);

        (uint256 sharesToMint, uint256 XNew) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: 0, yPnlWad: 0, yVaultWad: 0, sPast: 0, sumBucketNet: 0}),
            X: 0,
            nLp: 0,
            depositWad: depositWad,
            yPrinOldWad: 0
        });

        assertEq(sharesToMint, depositWad);
        assertEq(XNew, depositWad);
    }

    /// @dev Shares should be proportional to eNom when pool has existing LPs.
    function test_computeDeposit_normalCase() public pure {
        // eNom = 2000, nLp = 1000, deposit = 500
        // shares = 500 * 1000 / 2000 = 250
        (uint256 sharesToMint, uint256 XNew) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: 2000e18, yPnlWad: 0, yVaultWad: 0, sPast: 0, sumBucketNet: 0}),
            X: 1000e18,
            nLp: 1000e18,
            depositWad: 500e18,
            yPrinOldWad: 1000e18
        });

        assertEq(sharesToMint, 250e18);
        assertEq(XNew, 1500e18);
    }

    /// @dev X should scale to preserve psi after deposit.
    function testFuzz_computeDeposit_preservesPsi(uint256 X, uint256 yPrinOldWad, uint256 depositWad) public pure {
        // Bound: 1e18 WAD (1 token) to 1e36 WAD (1e18 tokens)
        // Min 1e18 to avoid precision loss with tiny values
        X = bound(X, 1e18, 1e36);
        yPrinOldWad = bound(yPrinOldWad, 1e18, 1e36);
        depositWad = bound(depositWad, 1e18, 1e36);

        // Ensure psi is within realistic bounds (0.01% to 1000%)
        // Extreme ratios cause large relative errors with tiny absolute values
        uint256 psiOld = X * 1e18 / yPrinOldWad;
        vm.assume(psiOld >= 0.0001e18 && psiOld <= 10e18);

        (, uint256 XNew) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: yPrinOldWad, yPnlWad: 0, yVaultWad: 0, sPast: 0, sumBucketNet: 0}),
            X: X,
            nLp: 1000e18,
            depositWad: depositWad,
            yPrinOldWad: yPrinOldWad
        });

        uint256 yPrinNewWad = yPrinOldWad + depositWad;
        uint256 psiNew = XNew * 1e18 / yPrinNewWad;

        // 0.0001% tolerance for integer rounding errors
        assertApproxEqRel(psiNew, psiOld, 0.000001e18, "psi should be preserved after deposit");
    }

    /// @dev eNom should include all components (yLiq, yPnl, yVault, sPast, sumBucketNet).
    function test_computeDeposit_fullEnomFormula() public pure {
        // eNom = 1000 + 50 + 200 + (-100) + 150 = 1300
        // shares = 1300 * 1000 / 1300 = 1000
        (uint256 sharesToMint,) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({
                yLiqWad: 1000e18, yPnlWad: 50e18, yVaultWad: 200e18, sPast: -100e18, sumBucketNet: 150e18
            }),
            X: 1000e18,
            nLp: 1000e18,
            depositWad: 1300e18,
            yPrinOldWad: 1000e18
        });

        assertEq(sharesToMint, 1000e18);
    }

    /// @dev Large deposits should dilute existing shareholders proportionally.
    function test_computeDeposit_largeDilution() public pure {
        // eNom = 1000, nLp = 1000, deposit = 9000
        // shares = 9000 * 1000 / 1000 = 9000
        // Total shares = 10000, original holders have 10%
        (uint256 sharesToMint, uint256 XNew) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: 1000e18, yPnlWad: 0, yVaultWad: 0, sPast: 0, sumBucketNet: 0}),
            X: 1000e18,
            nLp: 1000e18,
            depositWad: 9000e18,
            yPrinOldWad: 1000e18
        });

        assertEq(sharesToMint, 9000e18);
        assertEq(XNew, 10000e18);
    }

    /// @dev Small deposits to large pools should mint proportionally fewer shares.
    function test_computeDeposit_smallDeposit() public pure {
        // eNom = 1_000_000, nLp = 500_000 (NAV = 2)
        // shares = 100 * 500_000 / 1_000_000 = 50
        (uint256 sharesToMint,) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: 1_000_000e18, yPnlWad: 0, yVaultWad: 0, sPast: 0, sumBucketNet: 0}),
            X: 500_000e18,
            nLp: 500_000e18,
            depositWad: 100e18,
            yPrinOldWad: 500_000e18
        });

        assertEq(sharesToMint, 50e18);
    }

    /// @dev Reverting case: negative eNom should revert.
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeDeposit_negativeEquity() public {
        // eNom = 100 + 0 + 0 + (-500) + (-200) = -600 < 0
        vm.expectRevert(LpLib.NegativeEquity.selector);
        LpLib.computeDeposit({
            enom: LpLib.EnomParams({yLiqWad: 100e18, yPnlWad: 0, yVaultWad: 0, sPast: -500e18, sumBucketNet: -200e18}),
            X: 1000e18,
            nLp: 1000e18,
            depositWad: 500e18,
            yPrinOldWad: 1000e18
        });
    }
}
