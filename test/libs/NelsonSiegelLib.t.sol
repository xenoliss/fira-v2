// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {NelsonSiegelLib} from "../../src/libs/NelsonSiegelLib.sol";

import {Test} from "forge-std/Test.sol";

contract NelsonSiegelLibTest is Test {
    uint256 constant YEAR = 365 days;

    //////////////////////////////////////////////////////////////
    ///                    tau=0 (Instant Rate)                ///
    //////////////////////////////////////////////////////////////

    /// @dev When τ=0, the rate should equal β₀ + β₁ (instant rate).
    ///      At this limit, f₁→1 and f₂→0, so only β₀ and β₁ contribute.
    function test_computeRStar_tauZero_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeRStar({tau: 0, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.030000000000000002e18});
        _assertComputeRStar({tau: 0, b0: 0.10e18, b1: 0, b2: 0, lam: YEAR, expected: 0.10e18});
        _assertComputeRStar({tau: 0, b0: 0.03e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 0, b0: 0.08e18, b1: -0.05e18, b2: 0.03e18, lam: 3 * YEAR, expected: 0.03e18});
        _assertComputeRStar({tau: 0, b0: 0.02e18, b1: 0.01e18, b2: 0, lam: YEAR, expected: 0.03e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                Flat Curve (β₁=β₂=0)                    ///
    //////////////////////////////////////////////////////////////

    /// @dev When β₁=β₂=0, the rate should be flat at β₀ for all maturities.
    ///      Only the level parameter β₀ remains, independent of τ.
    function test_computeRStar_flatCurve_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: 0, b2: 0, lam: 2 * YEAR, expected: 0.05e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///              Normal Curve (β₁ < 0)                     ///
    //////////////////////////////////////////////////////////////

    /// @dev When β₁ < 0, the curve should be upward-sloping (short rates < long rates).
    ///      The rate starts at β₀+β₁ and rises toward β₀ as τ increases.
    function test_computeRStar_normalCurve_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // beta0 = 3%
        _assertComputeRStar({tau: 1 days, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.010020535440394928e18});
        _assertComputeRStar({tau: 7 days, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.010143224451052816e18});
        _assertComputeRStar({tau: 30 days, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.010605322388505369e18});
        _assertComputeRStar({tau: 91 days, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.011770184129429366e18});
        _assertComputeRStar({tau: 182 days, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.013355782761582533e18});
        _assertComputeRStar({tau: YEAR, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.016065306597126332e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.02e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.025507490008256608e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.027946096424007316e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.03e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.029333330478245007e18});
        // beta0 = 5%
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.030020535440394933e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03014322445105282e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03060532238850537e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03177018412942937e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.033355782761582534e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03606530659712633e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04550749000825661e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04794609642400732e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04933333047824501e18});
        // beta0 = 8%
        _assertComputeRStar({tau: 1 days, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.06002053544039493e18});
        _assertComputeRStar({tau: 7 days, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.060143224451052815e18});
        _assertComputeRStar({tau: 30 days, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.06060532238850538e18});
        _assertComputeRStar({tau: 91 days, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.061770184129429376e18});
        _assertComputeRStar({tau: 182 days, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.06335578276158253e18});
        _assertComputeRStar({tau: YEAR, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.06606530659712634e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.07e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.07550749000825661e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.07794609642400732e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.08e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.079333330478245e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///              Inverted Curve (β₁ > 0)                   ///
    //////////////////////////////////////////////////////////////

    /// @dev When β₁ > 0, the curve should be downward-sloping (short rates > long rates).
    ///      The rate starts at β₀+β₁ and falls toward β₀ as τ increases.
    function test_computeRStar_invertedCurve_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // beta1 = 1%
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05997264023596859e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.059810046472287264e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05921095293343955e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05779334390986866e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.056073620929748685e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05367879441171443e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05135335283236613e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.050067379469990854e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05000045399929763e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: 0.01e18, b2: -0.01e18, lam: YEAR, expected: 0.05000000000000094e18});
        // beta1 = 2%
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.0699589541074322e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.06971476613159455e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.06881102557659172e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.06664421723841747e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.06394795258162633e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.060000000000000005e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.05567667641618307e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.05205390357599268e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.051000408599367865e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: 0.02e18, b2: -0.01e18, lam: YEAR, expected: 0.05033333333333424e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                  Curvature (β₂ ≠ 0)                    ///
    //////////////////////////////////////////////////////////////

    /// @dev When β₂ ≠ 0, the curve should exhibit a hump or trough at medium maturities.
    ///      Positive β₂ creates a hump, negative β₂ creates a trough.
    function test_computeRStar_curvature_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // beta2 = 2%
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05001368612639591e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05009527961154654e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.050399871384959764e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05114766456882156e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.052115058837360326e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.053608160417242e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05528482235314231e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05570162003853084e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.05383828927202195e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: 0, b2: 0.02e18, lam: 2 * YEAR, expected: 0.051333326807417166e18});
        // beta2 = 3%
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05002052918959386e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05014291941731981e18});
        _assertComputeRStar({tau: 30 days, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05059980707743965e18});
        _assertComputeRStar({tau: 91 days, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.051721496853232345e18});
        _assertComputeRStar({tau: 182 days, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05317258825604049e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.055412240625862995e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05792723352971346e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.058552430057796256e18});
        _assertComputeRStar({tau: 10 * YEAR, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.05575743390803292e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: 0, b2: 0.03e18, lam: 2 * YEAR, expected: 0.051999990211125745e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                   Lambda Variations                    ///
    //////////////////////////////////////////////////////////////

    /// @dev The rate should converge to β₀ faster when λ is small.
    ///      Large λ extends the influence of β₁ and β₂ to longer maturities.
    function test_computeRStar_lambdaVariations_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR / 2, expected: 0.04432332358381694e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR / 2, expected: 0.0473626327083345e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR / 2, expected: 0.04899959140063214e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR, expected: 0.04e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR, expected: 0.04432332358381694e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: YEAR, expected: 0.04794609642400732e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03606530659712633e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04550749000825661e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 3 * YEAR, expected: 0.03433062621147579e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 3 * YEAR, expected: 0.03756708559516296e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 3 * YEAR, expected: 0.043244497588649754e18});
        _assertComputeRStar({tau: YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 5 * YEAR, expected: 0.032749230123119276e18});
        _assertComputeRStar({tau: 2 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 5 * YEAR, expected: 0.03505480069053459e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 5 * YEAR, expected: 0.04e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///               Large τ (Asymptotic Behavior)            ///
    //////////////////////////////////////////////////////////////

    /// @dev When τ is very large, the rate should converge toward β₀.
    ///      As τ→∞, f₁→0 and f₂→0, leaving only the long-rate parameter.
    function test_computeRStar_largeTau_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeRStar({tau: 20 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04899959140063214e18});
        _assertComputeRStar({tau: 30 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.04933333047824501e18});
        _assertComputeRStar({tau: 50 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.049599999999866674e18});
        _assertComputeRStar({tau: 100 * YEAR, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.049800000000000004e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///         Small τ/λ Ratio (Taylor Approximation)        ///
    //////////////////////////////////////////////////////////////

    /// @dev Tests the Taylor approximation branch when τ/λ < 0.01.
    ///      When τ/λ is small, f₁ ≈ 1 - (τ/λ)/2 instead of full exp.
    function test_computeRStar_smallTauLambdaRatio_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // λ=2yr: τ < 7.3 days triggers Taylor branch
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.030020535440394933e18});
        _assertComputeRStar({tau: 3 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03006153138858853e18});
        _assertComputeRStar({tau: 7 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 2 * YEAR, expected: 0.03014322445105282e18});
        // λ=5yr: τ < 18.25 days triggers Taylor branch
        _assertComputeRStar({tau: 1 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 5 * YEAR, expected: 0.0300082171767977e18});
        _assertComputeRStar({tau: 3 days, b0: 0.05e18, b1: -0.02e18, b2: 0.01e18, lam: 5 * YEAR, expected: 0.03002463952886016e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                     Negative Rates                     ///
    //////////////////////////////////////////////////////////////

    /// @dev Tests negative rate scenarios (β₀ < 0 or β₀ + β₁ < 0).
    ///      The library should handle negative betas correctly.
    function test_computeRStar_negativeRates_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // β₀ < 0 (negative long rate)
        _assertComputeRStar({tau: 0, b0: -0.01e18, b1: 0.02e18, b2: 0, lam: 2 * YEAR, expected: 0.01e18});
        _assertComputeRStar({tau: YEAR, b0: -0.01e18, b1: 0.02e18, b2: 0, lam: 2 * YEAR, expected: 0.005738773611494665e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: -0.01e18, b1: 0.02e18, b2: 0, lam: 2 * YEAR, expected: -0.002656679988991191e18});
        // β₀ + β₁ < 0 (negative instant rate)
        _assertComputeRStar({tau: 0, b0: 0.01e18, b1: -0.03e18, b2: 0, lam: 2 * YEAR, expected: -0.019999999999999997e18});
        _assertComputeRStar({tau: YEAR, b0: 0.01e18, b1: -0.03e18, b2: 0, lam: 2 * YEAR, expected: -0.013608160417241994e18});
        _assertComputeRStar({tau: 5 * YEAR, b0: 0.01e18, b1: -0.03e18, b2: 0, lam: 2 * YEAR, expected: -0.001014980016513213e18});
        // forgefmt: disable-end
    }

    //////////////////////////////////////////////////////////////
    ///                       Helper                           ///
    //////////////////////////////////////////////////////////////

    function _assertComputeRStar(uint256 tau, int256 b0, int256 b1, int256 b2, uint256 lam, int256 expected)
        internal
        pure
    {
        int256 result = NelsonSiegelLib.computeRStar({tau: tau, beta0: b0, beta1: b1, beta2: b2, lambda: lam});
        // 0.01% tolerance
        assertApproxEqRel(result, expected, 0.0001e18);
    }
}
