// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title NelsonSiegelLib - Term structure curve mathematics
///
/// @notice Implements Nelson-Siegel parametric yield curve: r*(τ) = β₀ + β₁·f₁(τ) + β₂·f₂(τ)
///
/// @dev All values use 18 decimals. τ (tau) is in seconds.
library NelsonSiegelLib {
    //////////////////////////////////////////////////////////////
    ///                   Internal Functions                   ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute r*(τ) = β₀ + β₁·f₁(τ) + β₂·f₂(τ)
    ///
    /// @dev f₁(τ) = (1 - e^(-τ/λ)) / (τ/λ), f₂(τ) = f₁(τ) - e^(-τ/λ)
    ///      τ=0 shortcut: returns beta0 + beta1
    ///
    /// @param tau Time to maturity in seconds
    /// @param beta0 Long-term level (18 decimals)
    /// @param beta1 Short-term slope (18 decimals)
    /// @param beta2 Curvature (18 decimals)
    /// @param lambda Decay parameter in seconds
    ///
    /// @return rStar The anchor rate r*(τ) (18 decimals)
    function computeRStar(uint256 tau, int256 beta0, int256 beta1, int256 beta2, uint256 lambda)
        internal
        pure
        returns (int256)
    {
        int256 sWad = int256(FixedPointMathLib.WAD);

        // f1(0) = 1, f2(0) = 0 → r* = β₀ + β₁
        if (tau == 0) return beta0 + beta1;

        // casting to 'int256' is safe because tau < 100 years and lambda bounded by MAX_LAMBDA
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 tauOverLambda = FixedPointMathLib.sDivWad({x: int256(tau), y: int256(lambda)});
        int256 expNeg = FixedPointMathLib.expWad({x: -tauOverLambda});

        int256 f1 = tauOverLambda < sWad / 100
            ? sWad - tauOverLambda / 2
            : FixedPointMathLib.sDivWad({x: sWad - expNeg, y: tauOverLambda});

        int256 f2 = f1 - expNeg;

        return beta0 + FixedPointMathLib.sMulWad({x: beta1, y: f1}) + FixedPointMathLib.sMulWad({x: beta2, y: f2});
    }
}
