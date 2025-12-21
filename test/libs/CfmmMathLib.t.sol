// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CfmmMathLib} from "../../src/libs/CfmmMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";

import {Test} from "forge-std/Test.sol";

/// @title CfmmMathLibTest - Unit tests for CFMM math library
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
    ///                       Helpers                          ///
    //////////////////////////////////////////////////////////////

    function _getDefaultParams() internal pure returns (CfmmMathLib.CfmmParams memory) {
        return CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: PSI_MIN, psiMax: PSI_MAX
        });
    }

    //////////////////////////////////////////////////////////////
    ///                tau = 0 Shortcut Tests                  ///
    //////////////////////////////////////////////////////////////

    function test_computeSwap_tau0_priceIsOne() public pure {
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
        assertApproxEqRel(cashReceived, bondAmount, 1e14, "Cash should equal bond amount at tau=0");
        assertTrue(XNew > 0, "XNew should be positive");
    }

    //////////////////////////////////////////////////////////////
    ///                Borrow/Lend Direction Tests             ///
    //////////////////////////////////////////////////////////////

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
    ///                   Psi Bounds Tests                     ///
    //////////////////////////////////////////////////////////////

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeSwap_psiBelowMin() public {
        // Create params with tight psi bounds
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0,
            beta1: BETA1,
            beta2: BETA2,
            lambda: LAMBDA,
            kappa: KAPPA,
            psiMin: 0.9e18, // 90% - tight lower bound
            psiMax: 1.1e18 // 110% - tight upper bound
        });

        // Try a large lend that would push psi below min
        int256 largeLend = -900e18;

        vm.expectRevert(CfmmMathLib.RateOutOfBounds.selector);
        CfmmMathLib.computeSwap({
            tau: SECONDS_PER_YEAR, bondAmountSigned: largeLend, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeSwap_psiAboveMax() public {
        // Create params with tight psi bounds
        CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
            beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA, kappa: KAPPA, psiMin: 0.9e18, psiMax: 1.1e18
        });

        // Try a large borrow that would push psi above max
        int256 largeBorrow = 900e18;

        vm.expectRevert(CfmmMathLib.RateOutOfBounds.selector);
        CfmmMathLib.computeSwap({
            tau: SECONDS_PER_YEAR, bondAmountSigned: largeBorrow, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });
    }

    //////////////////////////////////////////////////////////////
    ///                  Zero Amount Test                      ///
    //////////////////////////////////////////////////////////////

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_computeSwap_zeroAmount() public {
        CfmmMathLib.CfmmParams memory params = _getDefaultParams();

        vm.expectRevert(CfmmMathLib.ZeroAmount.selector);
        CfmmMathLib.computeSwap({
            tau: SECONDS_PER_YEAR, bondAmountSigned: 0, X: INITIAL_X, yWad: INITIAL_Y, params: params
        });
    }

    //////////////////////////////////////////////////////////////
    ///                   Price Discount Test                  ///
    //////////////////////////////////////////////////////////////

    function test_computeSwap_priceDecreasesWithTau() public pure {
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
    ///        Differential Fuzz Tests (vs Python)              ///
    //////////////////////////////////////////////////////////////

    uint256 constant BATCH_SIZE = 50;

    // Python error codes (returned in yNewWad when XNew == type(uint256).max)
    uint256 constant ERROR_INVARIANT_VIOLATED = 1;
    uint256 constant ERROR_RATE_OUT_OF_BOUNDS = 2;

    struct SwapTestCase {
        uint256 tau;
        int256 bondAmountSigned;
        uint256 X;
        uint256 y;
        uint256 psiMin;
        uint256 psiMax;
    }

    struct SwapResult {
        uint256 XNew;
        uint256 yNewWad;
    }

    /// @notice Batched differential fuzz test against Python
    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_computeSwap_matchesPython(uint256 seed) public {
        SwapTestCase[] memory cases = _generateTestCases(seed);
        SwapResult[] memory pythonResults = _callPython(cases);

        // Compare each case against Solidity implementation
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            SwapTestCase memory tc = cases[i];
            SwapResult memory expected = pythonResults[i];

            // Build params with test case bounds
            CfmmMathLib.CfmmParams memory params = CfmmMathLib.CfmmParams({
                beta0: BETA0,
                beta1: BETA1,
                beta2: BETA2,
                lambda: LAMBDA,
                kappa: KAPPA,
                psiMin: tc.psiMin,
                psiMax: tc.psiMax
            });

            // Python encountered an error - verify Solidity also reverts with same error
            if (expected.XNew == type(uint256).max) {
                if (expected.yNewWad == ERROR_INVARIANT_VIOLATED) {
                    vm.expectRevert(CfmmMathLib.InvariantViolated.selector);
                } else if (expected.yNewWad == ERROR_RATE_OUT_OF_BOUNDS) {
                    vm.expectRevert(CfmmMathLib.RateOutOfBounds.selector);
                } else {
                    revert(string.concat("Unknown Python error code: ", vm.toString(expected.yNewWad)));
                }

                CfmmMathLib.computeSwap({
                    tau: tc.tau, bondAmountSigned: tc.bondAmountSigned, X: tc.X, yWad: tc.y, params: params
                });
                continue;
            }

            // Python succeeded - compare results
            (uint256 solidityXNew, uint256 solidityYNew) = CfmmMathLib.computeSwap({
                tau: tc.tau, bondAmountSigned: tc.bondAmountSigned, X: tc.X, yWad: tc.y, params: params
            });

            // Allow 0.1% relative error for floating-point vs fixed-point differences
            assertApproxEqRel(
                solidityXNew,
                expected.XNew,
                1e15, // 0.1%
                string.concat("XNew mismatch at case ", vm.toString(i))
            );
            assertApproxEqRel(
                solidityYNew,
                expected.yNewWad,
                1e15, // 0.1%
                string.concat("yNew mismatch at case ", vm.toString(i))
            );
        }
    }

    /// @notice Generate test cases from seed
    function _generateTestCases(uint256 seed) internal pure returns (SwapTestCase[] memory cases) {
        cases = new SwapTestCase[](BATCH_SIZE);

        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));

            // tau: 1 day to 10 years
            uint256 tau = bound(uint256(keccak256(abi.encode(r, "tau"))), 1 days, 10 * SECONDS_PER_YEAR);

            // y: 1k to 1B WAD
            uint256 y = bound(uint256(keccak256(abi.encode(r, "y"))), 1_000e18, 1_000_000_000e18);

            // X: 10% to 1000% of y (psi from 0.1 to 10)
            uint256 X = bound(uint256(keccak256(abi.encode(r, "X"))), y / 10, y * 10);

            // bond amount: -50% to +50% of y
            int256 maxBond = int256(y / 2);
            int256 bondAmountSigned =
                int256(bound(uint256(keccak256(abi.encode(r, "bond"))), 0, uint256(maxBond * 2))) - maxBond;

            // Skip zero amounts
            if (bondAmountSigned == 0) bondAmountSigned = 1e18;

            // psiMin/psiMax: generate bounds that sometimes constrain the result
            // 50% of cases: wide bounds (0.1 to 10) - unlikely to trigger error
            // 50% of cases: tight bounds around current psi - may trigger error
            uint256 psiMin;
            uint256 psiMax;
            uint256 boundChoice = uint256(keccak256(abi.encode(r, "boundChoice"))) % 2;
            if (boundChoice == 0) {
                // Wide bounds
                psiMin = 0.1e18;
                psiMax = 10e18;
            } else {
                // Tight bounds around current psi (±20%)
                uint256 currentPsi = (X * 1e18) / y;
                psiMin = (currentPsi * 80) / 100;
                psiMax = (currentPsi * 120) / 100;
                // Ensure valid bounds
                if (psiMin == 0) psiMin = 0.01e18;
            }

            cases[i] = SwapTestCase({
                tau: tau, bondAmountSigned: bondAmountSigned, X: X, y: y, psiMin: psiMin, psiMax: psiMax
            });
        }
    }

    /// @notice Call Python with batched test cases
    function _callPython(SwapTestCase[] memory cases) internal returns (SwapResult[] memory) {
        // Build JSON array
        string memory json = "[";
        for (uint256 i = 0; i < cases.length; i++) {
            if (i > 0) json = string.concat(json, ",");
            json = string.concat(
                json,
                "{",
                '"tau":',
                vm.toString(cases[i].tau),
                ",",
                '"bondAmountSigned":',
                vm.toString(cases[i].bondAmountSigned),
                ",",
                '"X":',
                vm.toString(cases[i].X),
                ",",
                '"y":',
                vm.toString(cases[i].y),
                ",",
                '"psiMin":',
                vm.toString(cases[i].psiMin),
                ",",
                '"psiMax":',
                vm.toString(cases[i].psiMax),
                "}"
            );
        }
        json = string.concat(json, "]");

        // Hex-encode JSON
        bytes memory jsonBytes = bytes(json);
        string memory hexJson = LibString.toHexString(jsonBytes);

        // Call Python script
        string[] memory inputs = new string[](4);
        inputs[0] = "uv";
        inputs[1] = "run";
        inputs[2] = "test/scripts/cfmm.py";
        inputs[3] = hexJson;

        bytes memory result = vm.ffi(inputs);

        // Decode ABI-encoded results
        SwapResult[] memory results = abi.decode(result, (SwapResult[]));
        return results;
    }
}
