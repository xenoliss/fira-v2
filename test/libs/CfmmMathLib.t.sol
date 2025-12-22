// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CfmmMathLib} from "../../src/libs/CfmmMathLib.sol";

import {Test} from "forge-std/Test.sol";

contract CfmmMathLibTest is Test {
    //////////////////////////////////////////////////////////////
    ///                       Constants                        ///
    //////////////////////////////////////////////////////////////

    uint256 constant SECONDS_PER_YEAR = 365 days;
    int256 constant WAD = 1e18;

    // Default parameters
    int256 constant BETA0 = 0.05e18; // 5%
    int256 constant BETA1 = -0.02e18; // -2%
    int256 constant BETA2 = 0.01e18; // 1%
    uint256 constant LAMBDA = 2 * SECONDS_PER_YEAR;
    int256 constant KAPPA = 0.5e18; // rate sensitivity
    uint256 constant PSI_MIN = 0.5e18; // 50%
    uint256 constant PSI_MAX = 2e18; // 200%

    // Initial state
    uint256 constant INITIAL_X = 1000e18; // 1000 WAD
    uint256 constant INITIAL_Y = 1000e18; // 1000 WAD

    //////////////////////////////////////////////////////////////
    ///                tau = 0 Shortcut Tests                  ///
    //////////////////////////////////////////////////////////////

    /// @dev At settlement (τ=0), price = 1 so cash = bondAmount
    function test_computeSwap_tauZero_priceIsOne() public pure {
        // At tau=0 (settlement), price should be exactly 1
        // This means cash exchanged = bond amount
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0,
            beta1: BETA1,
            beta2: BETA2,
            lambda: LAMBDA,
            kappa: KAPPA,
            psiMin: 0, // no bounds for this test
            psiMax: type(uint256).max
        });

        int256 bondAmount = 100e18;

        (uint256 XNew, uint256 yNewWad) = CfmmMathLib.computeSwap({
            tau: 0,
            bondAmountSigned: -bondAmount, // lend direction (pool receives cash)
            X: INITIAL_X,
            yWad: INITIAL_Y,
            params: params
        });

        // At tau=0: alpha=1, K=1, price=1
        // Linear invariant: x + y = C
        // Pool receives cash = bondAmount (since price = 1)
        // yNew - y = cash received
        int256 cashReceived = int256(yNewWad) - int256(INITIAL_Y);
        // 0.01% tolerance
        assertApproxEqRel(cashReceived, bondAmount, 0.0001e18, "Cash should equal bond amount at tau=0");
        assertTrue(XNew > 0, "XNew should be positive");
    }

    //////////////////////////////////////////////////////////////
    ///                Borrow/Lend Direction Tests             ///
    //////////////////////////////////////////////////////////////

    /// @dev Borrow increases X (shadow reserve) and decreases y (cash out)
    function test_computeSwap_borrow_XIncreases() public pure {
        CfmmMathLib.CfmmParams memory params = _getDefaultParams();
        uint256 tau = SECONDS_PER_YEAR; // 1 year

        int256 bondAmount = 100e18;

        (uint256 XNew, uint256 yNewWad) = CfmmMathLib.computeSwap({
            tau: tau,
            bondAmountSigned: bondAmount, // positive = borrow
            X: INITIAL_X,
            yWad: INITIAL_Y,
            params: params
        });

        assertGt(XNew, INITIAL_X, "X should increase on borrow");
        assertLt(yNewWad, INITIAL_Y, "y should decrease on borrow (cash out)");
    }

    /// @dev Lend decreases X (shadow reserve) and increases y (cash in)
    function test_computeSwap_lend_XDecreases() public pure {
        CfmmMathLib.CfmmParams memory params = _getDefaultParams();
        uint256 tau = SECONDS_PER_YEAR;

        int256 bondAmount = 100e18;

        (uint256 XNew, uint256 yNewWad) = CfmmMathLib.computeSwap({
            tau: tau,
            bondAmountSigned: -bondAmount, // negative = lend
            X: INITIAL_X,
            yWad: INITIAL_Y,
            params: params
        });

        assertLt(XNew, INITIAL_X, "X should decrease on lend");
        assertGt(yNewWad, INITIAL_Y, "y should increase on lend (cash in)");
    }

    //////////////////////////////////////////////////////////////
    ///                   Price Discount Test                  ///
    //////////////////////////////////////////////////////////////

    /// @dev Longer maturity = higher discount = less cash for same bond amount
    function test_computeSwap_longerMaturity_lowerPrice() public pure {
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: 0, psiMax: type(uint256).max
        });

        int256 bondAmount = 100e18;

        // Lend at 1 year
        (, uint256 yNew1y) = CfmmMathLib.computeSwap({
            tau: SECONDS_PER_YEAR, bondAmountSigned: -bondAmount, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });

        // Lend at 5 years
        (, uint256 yNew5y) = CfmmMathLib.computeSwap({
            tau: 5 * SECONDS_PER_YEAR, bondAmountSigned: -bondAmount, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });

        // Longer maturity = more discount = less cash for same bond amount
        // cash = yNew - y, so smaller yNew means less cash
        assertLt(yNew5y, yNew1y, "5y lend should receive less cash than 1y lend");
    }

    //////////////////////////////////////////////////////////////
    ///                  τ=0 (Settlement)                      ///
    //////////////////////////////////////////////////////////////

    /// @dev When τ=0 (settlement), the invariant should become linear (α=1, K=1, price=1).
    ///      Cash exchanged equals bond amount exactly since price = 1.
    function test_computeSwap_tauZero_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeSwap({tau: 0, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1100e18, expectedY: 900e18});
        _assertComputeSwap({tau: 0, bond: 200e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1200e18, expectedY: 800e18});
        _assertComputeSwap({tau: 0, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 899.9999999999999e18, expectedY: 1100e18});
        _assertComputeSwap({tau: 0, bond: -200e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 800.0000000000001e18, expectedY: 1200e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                   Borrow (∆x > 0)                      ///
    //////////////////////////////////////////////////////////////

    /// @dev When borrowing (bondAmount > 0), X should increase and y should decrease.
    ///      The borrower sells bonds to the pool and receives cash.
    function test_computeSwap_borrow_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeSwap({tau: 1 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1049.8521564535633e18, expectedY: 950.0075328319917e18});
        _assertComputeSwap({tau: 1 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1099.68990028024e18, expectedY: 900.0219230632409e18});
        _assertComputeSwap({tau: 30 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1045.7495210556042e18, expectedY: 950.2236514227959e18});
        _assertComputeSwap({tau: 30 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1091.112434534394e18, expectedY: 900.6430583197739e18});
        _assertComputeSwap({tau: 91 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1038.1501373114986e18, expectedY: 950.6658219626787e18});
        _assertComputeSwap({tau: 91 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1075.364633917001e18, expectedY: 901.8695265384072e18});
        _assertComputeSwap({tau: 182 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1028.8707956005442e18, expectedY: 951.3027595497379e18});
        _assertComputeSwap({tau: 182 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1056.3793316092308e18, expectedY: 903.5447517664321e18});
        _assertComputeSwap({tau: 365 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1015.3075784275518e18, expectedY: 952.5343680980479e18});
        _assertComputeSwap({tau: 365 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1029.1020184465444e18, expectedY: 906.5494585438335e18});
        _assertComputeSwap({tau: 730 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 999.4793577002337e18, expectedY: 954.8854672802007e18});
        _assertComputeSwap({tau: 730 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 997.9626388849459e18, expectedY: 911.7630875914437e18});
        _assertComputeSwap({tau: 1825 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 983.0931957719121e18, expectedY: 961.2769447688811e18});
        _assertComputeSwap({tau: 1825 days, bond: 100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 966.5042575076678e18, expectedY: 924.6389918425044e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                    Lend (∆x < 0)                       ///
    //////////////////////////////////////////////////////////////

    /// @dev When lending (bondAmount < 0), X should decrease and y should increase.
    ///      The lender buys bonds from the pool and pays cash.
    function test_computeSwap_lend_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeSwap({tau: 1 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 950.1341826407794e18, expectedY: 1049.9993088343065e18});
        _assertComputeSwap({tau: 1 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 900.2553193011065e18, expectedY: 1100.0054778918895e18});
        _assertComputeSwap({tau: 30 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 953.8807138468524e18, expectedY: 1049.9728040204502e18});
        _assertComputeSwap({tau: 30 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 907.4053146105331e18, expectedY: 1100.143696915925e18});
        _assertComputeSwap({tau: 91 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 960.9397699927628e18, expectedY: 1049.8798745474649e18});
        _assertComputeSwap({tau: 91 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 920.989012141357e18, expectedY: 1100.3157236367474e18});
        _assertComputeSwap({tau: 182 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 969.7761466044573e18, expectedY: 1049.6627756084063e18});
        _assertComputeSwap({tau: 182 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 938.2016734083735e18, expectedY: 1100.321889925112e18});
        _assertComputeSwap({tau: 365 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 983.141137563054e18, expectedY: 1049.0170497085714e18});
        _assertComputeSwap({tau: 365 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 964.6855966029467e18, expectedY: 1099.6650771828238e18});
        _assertComputeSwap({tau: 730 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 999.4547526394413e18, expectedY: 1047.2463120404493e18});
        _assertComputeSwap({tau: 730 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 997.7652450541325e18, expectedY: 1096.7811445303978e18});
        _assertComputeSwap({tau: 1825 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1017.2304306284312e18, expectedY: 1040.9907165288726e18});
        _assertComputeSwap({tau: 1825 days, bond: -100e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1034.789673060005e18, expectedY: 1084.4550957407591e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                   ψ Variations                         ///
    //////////////////////////////////////////////////////////////

    /// @dev When the initial ψ (X/y ratio) varies, the trade outcome should differ accordingly.
    ///      Higher ψ means higher implied rates, affecting discount and slippage.
    function test_computeSwap_psiVariations_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeSwap({tau: 365 days, bond: 50e18, X: 500e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 532.2434608179561e18, expectedY: 934.0056388716611e18});
        _assertComputeSwap({tau: 365 days, bond: -50e18, X: 500e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 463.8659207455416e18, expectedY: 1070.6660179649916e18});
        _assertComputeSwap({tau: 365 days, bond: 50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1015.3075784275518e18, expectedY: 952.5343680980479e18});
        _assertComputeSwap({tau: 365 days, bond: -50e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 983.141137563054e18, expectedY: 1049.0170497085714e18});
        _assertComputeSwap({tau: 365 days, bond: 50e18, X: 2000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1999.6115623980004e18, expectedY: 966.186710872931e18});
        _assertComputeSwap({tau: 365 days, bond: -50e18, X: 2000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1999.613031745858e18, expectedY: 1034.3948294253798e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                  Large Trades (Slippage)               ///
    //////////////////////////////////////////////////////////////

    /// @dev When trades exceed 20% of pool size, significant slippage should occur.
    ///      The CFMM curvature protects against large trades depleting liquidity.
    function test_computeSwap_largeTrades_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeSwap({tau: 365 days, bond: 300e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1069.697349770659e18, expectedY: 736.2503063495396e18});
        _assertComputeSwap({tau: 365 days, bond: -300e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 873.6705075306556e18, expectedY: 1320.5652030320837e18});
        _assertComputeSwap({tau: 365 days, bond: 500e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 1087.660150792781e18, expectedY: 585.6175537989936e18});
        _assertComputeSwap({tau: 365 days, bond: -500e18, X: 1000e18, y: 1000e18, psiMin: 0.1e18, psiMax: 10e18, expectedX: 750.5876157913261e18, expectedY: 1577.7159262149453e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                      Error Cases                       ///
    //////////////////////////////////////////////////////////////

    /// @dev When a trade pushes ψ outside bounds, the function should revert with RateOutOfBounds.
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeSwap_rateOutOfBounds() public {
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: 0.9e18, psiMax: 1.1e18
        });

        // Borrow pushes psi above max
        vm.expectRevert(CfmmMathLib.RateOutOfBounds.selector);
        CfmmMathLib.computeSwap({tau: 365 days, bondAmountSigned: 400e18, X: 1000e18, yWad: 1000e18, params: params});

        // Lend pushes psi below min
        vm.expectRevert(CfmmMathLib.RateOutOfBounds.selector);
        CfmmMathLib.computeSwap({tau: 365 days, bondAmountSigned: -400e18, X: 1000e18, yWad: 1000e18, params: params});
    }

    /// @dev When bondAmount is zero, the function should revert with ZeroAmount.
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeSwap_zeroAmount() public {
        CfmmMathLib.CfmmParams memory params = _getDefaultParams();

        vm.expectRevert(CfmmMathLib.ZeroAmount.selector);
        CfmmMathLib.computeSwap({
            tau: SECONDS_PER_YEAR, bondAmountSigned: 0, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });
    }

    //////////////////////////////////////////////////////////////
    ///                       Helpers                          ///
    //////////////////////////////////////////////////////////////

    function _getDefaultParams() internal pure returns (CfmmMathLib.CfmmParams memory) {
        return CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: PSI_MIN, psiMax: PSI_MAX
        });
    }

    function _assertComputeSwap(
        uint256 tau,
        int256 bond,
        uint256 X,
        uint256 y,
        uint256 psiMin,
        uint256 psiMax,
        uint256 expectedX,
        uint256 expectedY
    ) internal pure {
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: psiMin, psiMax: psiMax
        });
        (uint256 XNew, uint256 yNew) =
            CfmmMathLib.computeSwap({tau: tau, bondAmountSigned: bond, X: X, yWad: y, params: params});
        // 0.01% tolerance
        assertApproxEqRel(XNew, expectedX, 0.0001e18);
        assertApproxEqRel(yNew, expectedY, 0.0001e18);
    }
}
