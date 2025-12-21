// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {NelsonSiegelLib} from "./NelsonSiegelLib.sol";

/// @title CfmmMathLib - Pure CFMM Math Functions
///
/// @notice Implements the TS-BondMM CFMM invariant and pricing functions.
///
/// @dev All functions are pure and work with WAD (18 decimals).
///      Special τ=0 shortcuts are implemented for gas efficiency and precision.
library CfmmMathLib {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    error InvariantViolated();
    error RateOutOfBounds();
    error ZeroAmount();

    //////////////////////////////////////////////////////////////
    ///                       Structs                          ///
    //////////////////////////////////////////////////////////////

    /// @notice CFMM parameters for pure swap computation
    struct CfmmParams {
        int256 beta0;
        int256 beta1;
        int256 beta2;
        uint256 lambda;
        int256 kappa;
        uint256 psiMin;
        uint256 psiMax;
    }

    //////////////////////////////////////////////////////////////
    ///                   Internal Functions                   ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute CFMM swap
    ///
    /// @dev Pure CFMM logic: computes pricing via invariant, returns new state.
    ///      Does NOT update any state - completely pure calculation.
    ///      All amounts in WAD (18 decimals).
    ///
    /// @param tau Time to maturity (seconds)
    /// @param bondAmountSigned Signed bond amount (positive = borrow, negative = lend, WAD)
    /// @param X Current shadow reserve (WAD)
    /// @param yWad Current cash leg (WAD)
    /// @param params CFMM parameters
    ///
    /// @return XNew New shadow reserve (WAD)
    /// @return yNewWad New cash leg (WAD)
    function computeSwap(uint256 tau, int256 bondAmountSigned, uint256 X, uint256 yWad, CfmmParams memory params)
        internal
        pure
        returns (uint256 XNew, uint256 yNewWad)
    {
        require(bondAmountSigned != 0, ZeroAmount());

        int256 alpha;

        // Scope 1: Compute yNewWad
        {
            alpha = _computeAlpha({tau: tau, kappa: params.kappa});

            int256 rStar = NelsonSiegelLib.computeRStar({
                tau: tau, beta0: params.beta0, beta1: params.beta1, beta2: params.beta2, lambda: params.lambda
            });

            int256 rTot = _computeRTot({X: X, yWad: yWad, rStar: rStar, kappa: params.kappa});

            uint256 price = _computePrice({rTot: rTot, tau: tau});

            uint256 x = FixedPointMathLib.divWad({x: X, y: price});

            uint256 K = _computeK({tau: tau, rStar: rStar, alpha: alpha});
            uint256 C = _computeC({K: K, x: x, y: yWad, alpha: alpha});

            // Apply signed bond amount and solve invariant
            // bondAmountSigned > 0: borrow (x increases)
            // bondAmountSigned < 0: lend (x decreases)
            int256 xNewSigned = int256(x) + bondAmountSigned;
            require(xNewSigned > 0, InvariantViolated());
            uint256 xNew = uint256(xNewSigned);

            yNewWad = _solveInvariantForY({C: C, K: K, xNew: xNew, alpha: alpha});
        }

        // Scope 2: Compute new state (X, psi)
        {
            uint256 psi = FixedPointMathLib.divWad({x: X, y: yWad});
            uint256 psiNew;
            (psiNew, XNew) = _computePsiAndXNew({psi: psi, y: yWad, yNew: yNewWad, alpha: alpha});

            // Guard-rails
            require(psiNew >= params.psiMin && psiNew <= params.psiMax, RateOutOfBounds());
        }
    }

    //////////////////////////////////////////////////////////////
    ///                   Private Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute total yield r_tot(τ) = κ ln(X/y) + r*(τ)
    ///
    /// @dev r_tot(τ) = κ ln(X/y) + r*(τ)
    ///
    /// @param X Shadow reserve (WAD)
    /// @param yWad Cash leg (WAD)
    /// @param rStar Anchor rate from Nelson-Siegel (WAD, yield per year)
    /// @param kappa Rate sensitivity parameter (WAD)
    ///
    /// @return rTot Total yield (WAD, per year)
    function _computeRTot(uint256 X, uint256 yWad, int256 rStar, int256 kappa) private pure returns (int256 rTot) {
        int256 ratio = FixedPointMathLib.sDivWad({x: int256(X), y: int256(yWad)});
        int256 lnRatio = FixedPointMathLib.lnWad({x: ratio});
        return FixedPointMathLib.sMulWad({x: kappa, y: lnRatio}) + rStar;
    }

    /// @notice Compute bond price p(τ) = e^(-r_tot·τ)
    ///
    /// @dev p(τ) = e^(-r_tot·τ)
    ///      τ=0 shortcut: returns 1 (WAD)
    ///
    /// @param rTot Total yield (WAD, per year)
    /// @param tau Time to maturity (seconds)
    ///
    /// @return price Bond price (WAD)
    function _computePrice(int256 rTot, uint256 tau) private pure returns (uint256 price) {
        if (tau == 0) return 1e18;

        int256 tauYears = FixedPointMathLib.sDivWad({x: int256(tau), y: int256(365 days)});
        return uint256(FixedPointMathLib.expWad({x: -FixedPointMathLib.sMulWad({x: rTot, y: tauYears})}));
    }

    /// @notice Compute invariant exponent α(τ) = 1/(1 + κτ)
    ///
    /// @dev α(τ) = 1/(1 + κτ)
    ///      τ=0 shortcut: returns 1 (WAD)
    ///
    /// @param tau Time to maturity (seconds)
    /// @param kappa Rate sensitivity (WAD)
    ///
    /// @return alpha Exponent (WAD)
    function _computeAlpha(uint256 tau, int256 kappa) private pure returns (int256 alpha) {
        if (tau == 0) return 1e18;

        int256 tauYears = FixedPointMathLib.sDivWad({x: int256(tau), y: int256(365 days)});
        return FixedPointMathLib.sDivWad({x: 1e18, y: 1e18 + FixedPointMathLib.sMulWad({x: kappa, y: tauYears})});
    }

    /// @notice Compute invariant coefficient K(τ) = exp(-τ·r*·α)
    ///
    /// @dev K(τ) = e^(-τ·r*·α)
    ///      τ=0 shortcut: returns 1 (WAD)
    ///
    /// @param tau Time to maturity (seconds)
    /// @param rStar Anchor rate (WAD, per year)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return K Coefficient (WAD)
    function _computeK(uint256 tau, int256 rStar, int256 alpha) private pure returns (uint256 K) {
        if (tau == 0) return 1e18;

        int256 tauYears = FixedPointMathLib.sDivWad({x: int256(tau), y: int256(365 days)});
        int256 exponent = -FixedPointMathLib.sMulWad({x: FixedPointMathLib.sMulWad({x: tauYears, y: rStar}), y: alpha});
        return uint256(FixedPointMathLib.expWad({x: exponent}));
    }

    /// @notice Solve invariant for y_new: K·x_new^α + y_new^α = C
    ///
    /// @dev K(τ)·x_new^α + y_new^α = C
    ///      y_new = (C - K·x_new^α)^(1/α)
    ///      α=1 shortcut: y_new = C - K·x_new (linear)
    ///
    /// @param C Invariant constant (WAD^α)
    /// @param K Coefficient K(τ) (WAD)
    /// @param xNew New virtual inventory (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return yNew New cash leg (WAD)
    function _solveInvariantForY(uint256 C, uint256 K, uint256 xNew, int256 alpha) private pure returns (uint256 yNew) {
        // Settlement shortcut (α=1): linear solve
        if (alpha == 1e18) {
            uint256 KxNew = FixedPointMathLib.mulWad({x: K, y: xNew});
            require(C >= KxNew, InvariantViolated());
            return C - KxNew;
        }

        // General case: y_new = (C - K·x_new^α)^(1/α)
        uint256 Kx_alpha =
            FixedPointMathLib.mulWad({x: K, y: uint256(FixedPointMathLib.powWad({x: int256(xNew), y: alpha}))});

        require(C >= Kx_alpha, InvariantViolated());
        uint256 y_alpha = C - Kx_alpha;

        int256 invAlpha = FixedPointMathLib.sDivWad({x: 1e18, y: alpha});
        return uint256(FixedPointMathLib.powWad({x: int256(y_alpha), y: invAlpha}));
    }

    /// @notice Compute invariant constant C = K·x^α + y^α
    ///
    /// @dev C = K·x^α + y^α
    ///      α=1 shortcut: C = K·x + y (linear invariant)
    ///
    /// @param K Coefficient K(τ) (WAD)
    /// @param x Virtual inventory (WAD)
    /// @param y Cash leg (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return C Invariant constant (WAD^α)
    function _computeC(uint256 K, uint256 x, uint256 y, int256 alpha) private pure returns (uint256 C) {
        // Settlement shortcut (α=1): linear invariant
        if (alpha == 1e18) {
            return FixedPointMathLib.mulWad({x: K, y: x}) + y;
        }

        // General case: power-sum invariant
        uint256 Kx_alpha =
            FixedPointMathLib.mulWad({x: K, y: uint256(FixedPointMathLib.powWad({x: int256(x), y: alpha}))});
        uint256 y_alpha = uint256(FixedPointMathLib.powWad({x: int256(y), y: alpha}));

        return Kx_alpha + y_alpha;
    }

    /// @notice Compute new (ψ, X) via closed-form update
    ///
    /// @dev ψ_new = (y / y_new)^α · (ψ + 1) - 1
    ///      X_new = ψ_new · y_new
    ///
    /// @param psi Current utilization ratio ψ = X/y (WAD)
    /// @param y Current cash leg (WAD)
    /// @param yNew New cash leg (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return psiNew New utilization ratio (WAD)
    /// @return XNew New shadow reserve (WAD)
    function _computePsiAndXNew(uint256 psi, uint256 y, uint256 yNew, int256 alpha)
        private
        pure
        returns (uint256 psiNew, uint256 XNew)
    {
        // ratio = y / y_new
        int256 ratio = FixedPointMathLib.sDivWad({x: int256(y), y: int256(yNew)});

        // ratio^alpha
        int256 ratioPowAlpha = FixedPointMathLib.powWad({x: ratio, y: alpha});

        // psi_new = ratio^alpha * (psi + 1) - 1
        int256 psiPlus1 = int256(psi) + 1e18;
        int256 psiNewSigned = FixedPointMathLib.sMulWad({x: ratioPowAlpha, y: psiPlus1}) - 1e18;

        psiNew = uint256(psiNewSigned);
        XNew = FixedPointMathLib.mulWad({x: psiNew, y: yNew});
    }
}
