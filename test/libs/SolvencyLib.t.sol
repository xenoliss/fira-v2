// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {SolvencyLib} from "../../src/libs/SolvencyLib.sol";

contract SolvencyLibTest is Test {
    uint256 constant YEAR = 365 days;

    //////////////////////////////////////////////////////////////
    ///               computeWeightedNet Tests                 ///
    //////////////////////////////////////////////////////////////

    /// @dev When τ=0, the net should equal b - l (no haircuts applied).
    ///      At τ=0, φ=0 so both weights w_b and w_l are exactly 1.
    function test_computeWeightedNet_tauZero_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: 0, b: 100e18, l: 50e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 50e18});
        _assertComputeWeightedNet({tau: 0, b: 50e18, l: 100e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -50e18});
        _assertComputeWeightedNet({tau: 0, b: 100e18, l: 100e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 0});
        _assertComputeWeightedNet({tau: 0, b: 1000e18, l: 0, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 1000e18});
        _assertComputeWeightedNet({tau: 0, b: 0, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -1000e18});
        _assertComputeWeightedNet({tau: 0, b: 500e18, l: 200e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 300e18});
        _assertComputeWeightedNet({tau: 0, b: 200e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -300e18});
        _assertComputeWeightedNet({tau: 0, b: 1e18, l: 1e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 0});
        // forgefmt: disable-end
    }

    /// @dev When τ=λ, haircuts and buffers should be at ~63% of their maximum.
    ///      At τ=λ, φ ≈ 0.632 so w_b ≈ 1 - 0.63·η_b and w_l ≈ 1 + 0.63·η_l.
    function test_computeWeightedNet_tauEqLambda_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 341.9698602928605e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.1e18, etaL: 0.1e18, expected: 405.1819161757164e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.3e18, etaL: 0.2e18, expected: 247.15177646857705e18});
        _assertComputeWeightedNet({tau: YEAR, b: 500e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -626.4241117657116e18});
        _assertComputeWeightedNet({tau: YEAR, b: 500e18, l: 1000e18, lambdaW: YEAR, etaB: 0.1e18, etaL: 0.1e18, expected: -594.8180838242836e18});
        _assertComputeWeightedNet({tau: YEAR, b: 500e18, l: 1000e18, lambdaW: YEAR, etaB: 0.3e18, etaL: 0.2e18, expected: -721.2421955899949e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -189.63616764856738e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.1e18, etaL: 0.1e18, expected: -126.42411176571147e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.3e18, etaL: 0.2e18, expected: -316.0602794142786e18});
        _assertComputeWeightedNet({tau: YEAR, b: 2000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 683.939720585721e18});
        _assertComputeWeightedNet({tau: YEAR, b: 2000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.1e18, etaL: 0.1e18, expected: 810.3638323514328e18});
        _assertComputeWeightedNet({tau: YEAR, b: 2000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.3e18, etaL: 0.2e18, expected: 494.3035529371541e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 2000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -1252.8482235314232e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 2000e18, lambdaW: YEAR, etaB: 0.1e18, etaL: 0.1e18, expected: -1189.6361676485672e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 2000e18, lambdaW: YEAR, etaB: 0.3e18, etaL: 0.2e18, expected: -1442.4843911799899e18});
        // forgefmt: disable-end
    }

    /// @dev When τ is very large, the weights should reach their extremes.
    ///      As τ→∞, φ→1 so w_b = 1 - η_b (max haircut) and w_l = 1 + η_l (max buffer).
    function test_computeWeightedNet_largeTau_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: 10 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 250.0113499824406e18});
        _assertComputeWeightedNet({tau: 10 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -299.98638002107134e18});
        _assertComputeWeightedNet({tau: 20 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 250.00000051528832e18});
        _assertComputeWeightedNet({tau: 20 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -299.9999993816541e18});
        _assertComputeWeightedNet({tau: 50 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 250e18});
        _assertComputeWeightedNet({tau: 50 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -300e18});
        _assertComputeWeightedNet({tau: 100 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 250e18});
        _assertComputeWeightedNet({tau: 100 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -300e18});
        // forgefmt: disable-end
    }

    /// @dev When b=l, the weighted net should always be negative (for τ > 0).
    ///      Since w_b = 1 - η_b·φ ≤ 1 and w_l = 1 + η_l·φ ≥ 1, net = b·(w_b - w_l) < 0.
    function test_computeWeightedNet_balanced_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: 1 days, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -0.8207929209422673e18});
        _assertComputeWeightedNet({tau: 7 days, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -5.698605831382224e18});
        _assertComputeWeightedNet({tau: 30 days, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -23.67141199681339e18});
        _assertComputeWeightedNet({tau: 91 days, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -66.19968270394054e18});
        _assertComputeWeightedNet({tau: 182 days, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -117.79137210753959e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -189.63616764856738e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -259.3994150290164e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -297.97861590027435e18});
        _assertComputeWeightedNet({tau: 10 * YEAR, b: 1000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -299.98638002107134e18});
        // forgefmt: disable-end
    }

    /// @dev When b >> l, the net should be positive but decrease with τ.
    ///      As τ increases, φ increases, so w_b = 1 - η_b·φ decreases.
    function test_computeWeightedNet_bDominates_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: 1 days, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 8994.254449553404e18});
        _assertComputeWeightedNet({tau: 7 days, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 8960.109759180325e18});
        _assertComputeWeightedNet({tau: 30 days, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 8834.300116022305e18});
        _assertComputeWeightedNet({tau: 91 days, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 8536.602221072417e18});
        _assertComputeWeightedNet({tau: 182 days, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 8175.460395247224e18});
        _assertComputeWeightedNet({tau: YEAR, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 7672.5468264600295e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 7184.204094796886e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 6914.149688698079e18});
        _assertComputeWeightedNet({tau: 10 * YEAR, b: 10000e18, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 6900.095339852501e18});
        // forgefmt: disable-end
    }

    /// @dev When b << l, the net should be negative and worsen with τ.
    ///      As τ increases, φ increases, so w_l = 1 + η_l·φ increases.
    function test_computeWeightedNet_lDominates_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: 1 days, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9003.283171683768e18});
        _assertComputeWeightedNet({tau: 7 days, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9022.794423325528e18});
        _assertComputeWeightedNet({tau: 30 days, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9094.685647987255e18});
        _assertComputeWeightedNet({tau: 91 days, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9264.79873081576e18});
        _assertComputeWeightedNet({tau: 182 days, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9471.165488430159e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -9758.544670594269e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -10037.597660116066e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -10191.914463601097e18});
        _assertComputeWeightedNet({tau: 10 * YEAR, b: 1000e18, l: 10000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -10199.945520084288e18});
        // forgefmt: disable-end
    }

    /// @dev The weights should reach their extremes faster when λ is small.
    ///      λ controls decay speed: smaller λ means φ grows faster toward 1.
    function test_computeWeightedNet_lambdaVariations_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR / 2, etaB: 0.2e18, etaL: 0.1e18, expected: 283.83382080915305e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR / 2, etaB: 0.2e18, etaL: 0.1e18, expected: 254.57890972218354e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR / 2, etaB: 0.2e18, etaL: 0.1e18, expected: 250.0113499824406e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 341.9698602928605e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 283.83382080915305e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 251.6844867497714e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: 2 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 401.6326649281583e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 500e18, lambdaW: 2 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 341.9698602928605e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: 2 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 270.52124965597466e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: 3 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 429.1328276434473e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 500e18, lambdaW: 3 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 378.3542797581481e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: 3 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 297.21890070939037e18});
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 500e18, lambdaW: 5 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 454.68268826949543e18});
        _assertComputeWeightedNet({tau: 2 * YEAR, b: 1000e18, l: 500e18, lambdaW: 5 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 417.5800115089097e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: 5 * YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 341.9698602928605e18});
        // forgefmt: disable-end
    }

    /// @dev Tests edge cases where one side is zero.
    ///      b=0: net = -w_l·l (only liability)
    ///      l=0: net = w_b·b (only bonds)
    function test_computeWeightedNet_zeroNotionals_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        // b=0: net = -w_l * l = -(1 + η_l·φ) * l
        _assertComputeWeightedNet({tau: YEAR, b: 0, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -1063.2120558828558e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 0, l: 1000e18, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: -1099.3262053000915e18});
        // l=0: net = w_b * b = (1 - η_b·φ) * b
        _assertComputeWeightedNet({tau: YEAR, b: 1000e18, l: 0, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 873.5758882342884e18});
        _assertComputeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 0, lambdaW: YEAR, etaB: 0.2e18, etaL: 0.1e18, expected: 801.3475893998171e18});
        // forgefmt: disable-end
    }

    /// @dev When ηb=ηl=0, weights are always 1 so net = b - l (trivial).
    function test_computeWeightedNet_zeroEtas_equalsUnweightedNet() public pure {
        int256 result =
            SolvencyLib.computeWeightedNet({tau: 5 * YEAR, b: 1000e18, l: 500e18, lambdaW: YEAR, etaB: 0, etaL: 0});
        assertEq(result, 500e18);
    }

    //////////////////////////////////////////////////////////////
    ///               computeBaseEquity Tests                  ///
    //////////////////////////////////////////////////////////////

    /// @dev When w_vault=1, the vault should count at full value (no haircut).
    ///      E_base = yLiq + yPnl + yVault + sPast.
    function test_computeBaseEquity_vaultAtPar_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeBaseEquity({yLiq: 800e18, yPnl: 200e18, yVault: 500e18, wV: 1e18, sP: -100e18, expected: 1400e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 0, yVault: 500e18, wV: 1e18, sP: 0, expected: 1500e18});
        _assertComputeBaseEquity({yLiq: 0, yPnl: 500e18, yVault: 1000e18, wV: 1e18, sP: -200e18, expected: 1300e18});
        _assertComputeBaseEquity({yLiq: 5000e18, yPnl: 1000e18, yVault: 2000e18, wV: 1e18, sP: 500e18, expected: 8500e18});
        _assertComputeBaseEquity({yLiq: 100e18, yPnl: 50e18, yVault: 200e18, wV: 1e18, sP: -50e18, expected: 300e18});
        // forgefmt: disable-end
    }

    /// @dev When w_vault=0.5, the vault should receive a 50% haircut.
    ///      E_base = yLiq + yPnl + 0.5·yVault + sPast.
    function test_computeBaseEquity_vaultHaircut_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeBaseEquity({yLiq: 800e18, yPnl: 200e18, yVault: 500e18, wV: 0.5e18, sP: -100e18, expected: 1150e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 0, yVault: 1000e18, wV: 0.5e18, sP: 0, expected: 1500e18});
        _assertComputeBaseEquity({yLiq: 0, yPnl: 500e18, yVault: 2000e18, wV: 0.5e18, sP: -200e18, expected: 1300e18});
        _assertComputeBaseEquity({yLiq: 5000e18, yPnl: 1000e18, yVault: 4000e18, wV: 0.5e18, sP: 500e18, expected: 8500e18});
        _assertComputeBaseEquity({yLiq: 100e18, yPnl: 50e18, yVault: 400e18, wV: 0.5e18, sP: -50e18, expected: 300e18});
        // forgefmt: disable-end
    }

    /// @dev The base equity should increase or decrease linearly with s_past.
    ///      Negative s_past reduces equity (past losses), positive increases it.
    function test_computeBaseEquity_sPastVariations_matchesPythonOutput() public pure {
        // forgefmt: disable-start
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: -1000e18, expected: 900e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: -500e18, expected: 1400e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: -100e18, expected: 1800e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: 0, expected: 1900e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: 100e18, expected: 2000e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: 500e18, expected: 2400e18});
        _assertComputeBaseEquity({yLiq: 1000e18, yPnl: 500e18, yVault: 500e18, wV: 0.8e18, sP: 1000e18, expected: 2900e18});
        // forgefmt: disable-end
    }

    /// @dev When wVault=0, vault doesn't contribute so E_base = yLiq + yPnl + sPast (trivial).
    function test_computeBaseEquity_wVaultZero_excludesVault() public pure {
        int256 result =
            SolvencyLib.computeBaseEquity({yLiqWad: 1000e18, yPnlWad: 500e18, yVaultWad: 1000e18, wVault: 0, sPast: 0});
        assertEq(result, 1500e18);
    }

    //////////////////////////////////////////////////////////////
    ///                   checkFloor Tests                     ///
    //////////////////////////////////////////////////////////////

    /// @dev Passing case: minERisk > floor.
    function test_checkFloor_passesAboveFloor() public pure {
        // floor = 0.1e18 * 1000e18 / 1e18 = 100e18
        // minERisk = 150e18 > 100e18 → passes
        SolvencyLib.checkFloor({minERisk: 150e18, rho: 0.1e18, nLp: 1000e18});
    }

    /// @dev Passing case: minERisk == floor (equality).
    function test_checkFloor_passesAtFloor() public pure {
        // floor = 1e18 * 500e18 / 1e18 = 500e18
        // minERisk = 500e18 == 500e18 → passes
        SolvencyLib.checkFloor({minERisk: 500e18, rho: 1e18, nLp: 500e18});
    }

    /// @dev Reverting case: minERisk < floor.
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_checkFloor_belowFloor() public {
        // floor = 0.5e18 * 1000e18 / 1e18 = 500e18
        // minERisk = 499e18 < 500e18 → reverts
        vm.expectRevert(SolvencyLib.SolvencyFloorViolated.selector);
        SolvencyLib.checkFloor({minERisk: 499e18, rho: 0.5e18, nLp: 1000e18});
    }

    /// @dev Reverting case: negative minERisk.
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_checkFloor_negativeMinERisk() public {
        // floor = 0.1e18 * 1000e18 / 1e18 = 100e18
        // minERisk = -50e18 < 100e18 → reverts
        vm.expectRevert(SolvencyLib.SolvencyFloorViolated.selector);
        SolvencyLib.checkFloor({minERisk: -50e18, rho: 0.1e18, nLp: 1000e18});
    }

    /// @dev Passing case: rho = 0 means floor = 0, any positive minERisk passes.
    function test_checkFloor_zeroRho_alwaysPasses() public pure {
        // floor = 0 * 1000e18 / 1e18 = 0
        // minERisk = 1 >= 0 → passes
        SolvencyLib.checkFloor({minERisk: 1, rho: 0, nLp: 1000e18});
    }

    //////////////////////////////////////////////////////////////
    ///                        Helpers                         ///
    //////////////////////////////////////////////////////////////

    function _assertComputeWeightedNet(
        uint256 tau,
        uint256 b,
        uint256 l,
        uint256 lambdaW,
        int256 etaB,
        int256 etaL,
        int256 expected
    ) internal pure {
        int256 result = SolvencyLib.computeWeightedNet({tau: tau, b: b, l: l, lambdaW: lambdaW, etaB: etaB, etaL: etaL});
        if (expected == 0) {
            assertEq(result, 0);
        } else {
            // 0.01% tolerance
            assertApproxEqRel(result, expected, 0.0001e18);
        }
    }

    function _assertComputeBaseEquity(uint256 yLiq, uint256 yPnl, uint256 yVault, int256 wV, int256 sP, int256 expected)
        internal
        pure
    {
        int256 result =
            SolvencyLib.computeBaseEquity({yLiqWad: yLiq, yPnlWad: yPnl, yVaultWad: yVault, wVault: wV, sPast: sP});
        assertEq(result, expected);
    }
}
