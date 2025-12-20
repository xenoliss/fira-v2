// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {NelsonSiegelLib} from "../../src/libs/NelsonSiegelLib.sol";
import {LibString} from "solady/utils/LibString.sol";

import {Test, stdMath} from "forge-std/Test.sol";

/// @title NelsonSiegelLibTest - Unit tests for Nelson-Siegel curve library
contract NelsonSiegelLibTest is Test {
    //////////////////////////////////////////////////////////////
    ///                       Constants                        ///
    //////////////////////////////////////////////////////////////

    uint256 constant SECONDS_PER_YEAR = 365 days;
    int256 constant WAD = 1e18;

    // Default Nelson-Siegel parameters
    int256 constant BETA0 = 0.05e18; // 5% long-term rate
    int256 constant BETA1 = -0.02e18; // -2% short-term slope (normal curve)
    int256 constant BETA2 = 0.01e18; // 1% curvature
    uint256 constant LAMBDA = 2 * SECONDS_PER_YEAR; // 2 year decay

    //////////////////////////////////////////////////////////////
    ///                   tau = 0 Tests                        ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_tau0_returnsBeta0PlusBeta1() public pure {
        // When tau = 0: f1(0) = 1, f2(0) = 0 -> r* = beta0 + beta1
        int256 result = NelsonSiegelLib.computeRStar({tau: 0, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA});

        assertEq(result, BETA0 + BETA1, "tau=0 should return beta0 + beta1");
        assertEq(result, 0.03e18, "Expected 5% - 2% = 3%");
    }

    //////////////////////////////////////////////////////////////
    ///                   Flat Curve Tests                     ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_flatCurve_returnsBeta0() public pure {
        // Flat curve: beta1 = beta2 = 0 -> r* = beta0 for all maturities
        int256 beta0 = 0.03e18; // 3%

        int256 result1y =
            NelsonSiegelLib.computeRStar({tau: SECONDS_PER_YEAR, beta0: beta0, beta1: 0, beta2: 0, lambda: LAMBDA});

        int256 result5y =
            NelsonSiegelLib.computeRStar({tau: 5 * SECONDS_PER_YEAR, beta0: beta0, beta1: 0, beta2: 0, lambda: LAMBDA});

        assertEq(result1y, beta0, "1y flat curve should return beta0");
        assertEq(result5y, beta0, "5y flat curve should return beta0");
    }

    //////////////////////////////////////////////////////////////
    ///                Normal Curve Tests                      ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_normalCurve_increasesWithTau() public pure {
        // Normal upward-sloping curve: beta1 < 0
        // Short rates lower than long rates

        int256 result6m = NelsonSiegelLib.computeRStar({
            tau: SECONDS_PER_YEAR / 2, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA
        });

        int256 result1y = NelsonSiegelLib.computeRStar({
            tau: SECONDS_PER_YEAR, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA
        });

        int256 result5y = NelsonSiegelLib.computeRStar({
            tau: 5 * SECONDS_PER_YEAR, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA
        });

        // With negative beta1, rates should increase with maturity
        assertLt(result6m, result1y, "6m rate should be less than 1y rate");
        assertLt(result1y, result5y, "1y rate should be less than 5y rate");
    }

    //////////////////////////////////////////////////////////////
    ///               Inverted Curve Tests                     ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_invertedCurve_decreasesWithTau() public pure {
        // Inverted curve: beta1 > 0
        // Short rates higher than long rates
        int256 beta1Positive = 0.02e18;

        int256 result6m = NelsonSiegelLib.computeRStar({
            tau: SECONDS_PER_YEAR / 2,
            beta0: BETA0,
            beta1: beta1Positive,
            beta2: -0.01e18,
            lambda: SECONDS_PER_YEAR // 1 year decay
        });

        int256 result5y = NelsonSiegelLib.computeRStar({
            tau: 5 * SECONDS_PER_YEAR, beta0: BETA0, beta1: beta1Positive, beta2: -0.01e18, lambda: SECONDS_PER_YEAR
        });

        // With positive beta1, short rates should be higher
        assertGt(result6m, result5y, "6m rate should be greater than 5y rate (inverted)");
    }

    //////////////////////////////////////////////////////////////
    ///                Convergence Tests                       ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_largeTau_approachesBeta0() public pure {
        // As tau -> infinity: f1(tau) -> 0, f2(tau) -> 0 -> r* -> beta0

        int256 result10y = NelsonSiegelLib.computeRStar({
            tau: 10 * SECONDS_PER_YEAR, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA
        });

        int256 result30y = NelsonSiegelLib.computeRStar({
            tau: 30 * SECONDS_PER_YEAR, beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA
        });

        // 30y should be closer to beta0 than 10y
        uint256 diff10y = stdMath.abs(result10y - BETA0);
        uint256 diff30y = stdMath.abs(result30y - BETA0);

        assertLt(diff30y, diff10y, "30y should be closer to beta0 than 10y");

        // 30y should be very close to beta0 (within 2%)
        assertApproxEqRel(result30y, BETA0, 0.02e18, "30y should be ~beta0");
    }

    //////////////////////////////////////////////////////////////
    ///                    Curvature Tests                     ///
    //////////////////////////////////////////////////////////////

    function test_computeRStar_positiveBeta2_createsHump() public pure {
        // Positive beta2 creates a hump in the middle of the curve
        int256 beta2Positive = 0.03e18;

        int256 resultShort = NelsonSiegelLib.computeRStar({
            tau: SECONDS_PER_YEAR / 4, // 3 months
            beta0: BETA0,
            beta1: 0, // no slope
            beta2: beta2Positive,
            lambda: LAMBDA
        });

        int256 resultMid = NelsonSiegelLib.computeRStar({
            tau: 2 * SECONDS_PER_YEAR, // 2 years (near lambda)
            beta0: BETA0,
            beta1: 0,
            beta2: beta2Positive,
            lambda: LAMBDA
        });

        int256 resultLong = NelsonSiegelLib.computeRStar({
            tau: 10 * SECONDS_PER_YEAR, // 10 years
            beta0: BETA0,
            beta1: 0,
            beta2: beta2Positive,
            lambda: LAMBDA
        });

        // Middle maturity should have highest rate (hump)
        assertGt(resultMid, resultShort, "Mid should be higher than short");
        assertGt(resultMid, resultLong, "Mid should be higher than long");
    }

    //////////////////////////////////////////////////////////////
    ///        Differential Fuzz Test (vs Python)              ///
    //////////////////////////////////////////////////////////////

    uint256 constant BATCH_SIZE = 50;

    struct NsTestCase {
        uint256 tau; // seconds
        int256 beta0;
        int256 beta1;
        int256 beta2;
        uint256 lambda; // seconds
    }

    /// @notice Batched differential fuzz test against Python
    function testFuzz_computeRStar_matchesPython(uint256 seed) public {
        NsTestCase[] memory cases = _generateTestCases(seed);
        int256[] memory pythonResults = _callPython(cases);

        // Compare each case against Solidity implementation
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            NsTestCase memory tc = cases[i];

            int256 solidityResult = NelsonSiegelLib.computeRStar({
                tau: tc.tau, beta0: tc.beta0, beta1: tc.beta1, beta2: tc.beta2, lambda: tc.lambda
            });

            // Allow 0.01% relative error
            assertApproxEqRel(
                solidityResult, pythonResults[i], 1e14, string.concat("r* mismatch at case ", vm.toString(i))
            );
        }
    }

    /// @notice Generate test cases from seed
    function _generateTestCases(uint256 seed) internal pure returns (NsTestCase[] memory cases) {
        cases = new NsTestCase[](BATCH_SIZE);

        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));

            // tau: 0 to 30 years (in seconds)
            uint256 tau = bound(uint256(keccak256(abi.encode(r, "tau"))), 0, 30 * SECONDS_PER_YEAR);

            // beta0: 1% to 10% (WAD)
            int256 beta0 = int256(bound(uint256(keccak256(abi.encode(r, "b0"))), 0.01e18, 0.1e18));

            // beta1: -5% to +5% (WAD)
            int256 beta1 = int256(bound(uint256(keccak256(abi.encode(r, "b1"))), 0, 0.1e18)) - 0.05e18;

            // beta2: -3% to +3% (WAD)
            int256 beta2 = int256(bound(uint256(keccak256(abi.encode(r, "b2"))), 0, 0.06e18)) - 0.03e18;

            // lambda: 0.5 to 5 years (in seconds)
            uint256 lambda = bound(uint256(keccak256(abi.encode(r, "lam"))), SECONDS_PER_YEAR / 2, 5 * SECONDS_PER_YEAR);

            cases[i] = NsTestCase({tau: tau, beta0: beta0, beta1: beta1, beta2: beta2, lambda: lambda});
        }
    }

    /// @notice Call Python with batched test cases
    function _callPython(NsTestCase[] memory cases) internal returns (int256[] memory) {
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
                '"beta0":',
                vm.toString(cases[i].beta0),
                ",",
                '"beta1":',
                vm.toString(cases[i].beta1),
                ",",
                '"beta2":',
                vm.toString(cases[i].beta2),
                ",",
                '"lambda":',
                vm.toString(cases[i].lambda),
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
        inputs[2] = "test/scripts/nelson_siegel.py";
        inputs[3] = hexJson;

        bytes memory result = vm.ffi(inputs);

        // Decode ABI-encoded results
        int256[] memory results = abi.decode(result, (int256[]));
        return results;
    }
}
