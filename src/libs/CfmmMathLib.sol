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
    error InsufficientLiquidPrincipal();
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
    /// @param yPrinWad Current principal y_liq + y_vault (WAD)
    /// @param yLiqWad Current liquid principal (WAD)
    /// @param params CFMM parameters
    ///
    /// @return XNew New shadow reserve (WAD)
    /// @return cashAmountSignedWad Cash change for pool (positive = pool receives, negative = pool pays, WAD)
    function computeSwap(
        uint256 tau,
        int256 bondAmountSigned,
        uint256 X,
        uint256 yPrinWad,
        uint256 yLiqWad,
        CfmmParams memory params
    ) internal pure returns (uint256 XNew, int256 cashAmountSignedWad) {
        require(bondAmountSigned != 0, ZeroAmount());

        int256 alpha;
        uint256 yPrinNewWad;

        // Scope 1: Compute yPrinNewWad
        {
            alpha = _computeAlpha({tau: tau, kappa: params.kappa});

            int256 rStar = NelsonSiegelLib.computeRStar({
                tau: tau, beta0: params.beta0, beta1: params.beta1, beta2: params.beta2, lambda: params.lambda
            });

            int256 rTot = _computeRTot({X: X, yPrinWad: yPrinWad, rStar: rStar, kappa: params.kappa});

            uint256 price = _computePrice({rTot: rTot, tau: tau});

            uint256 x = FixedPointMathLib.divWad({x: X, y: price});

            uint256 K = _computeK({tau: tau, rStar: rStar, alpha: alpha});
            uint256 C = _computeC({K: K, x: x, yPrin: yPrinWad, alpha: alpha});

            // Apply signed bond amount and solve invariant
            // bondAmountSigned > 0: borrow (x increases)
            // bondAmountSigned < 0: lend (x decreases)
            uint256 xNew = uint256(int256(x) + bondAmountSigned);
            yPrinNewWad = _solveInvariantForYPrin({C: C, K: K, xNew: xNew, alpha: alpha});
        }

        // Scope 2: Compute new state (X, psi)
        {
            uint256 psi = FixedPointMathLib.divWad({x: X, y: yPrinWad});
            uint256 psiNew;
            (psiNew, XNew) = _computePsiAndXNew({psi: psi, yPrin: yPrinWad, yPrinNew: yPrinNewWad, alpha: alpha});

            // Guard-rails
            require(psiNew >= params.psiMin && psiNew <= params.psiMax, RateOutOfBounds());
        }

        // Principal payability check (if cash goes out)
        if (yPrinNewWad < yPrinWad) {
            uint256 deltaOutWad = yPrinWad - yPrinNewWad;
            require(yLiqWad >= deltaOutWad, InsufficientLiquidPrincipal());
        }

        // Return cash change from pool perspective (WAD)
        cashAmountSignedWad = int256(yPrinNewWad) - int256(yPrinWad);
    }

    //////////////////////////////////////////////////////////////
    ///                   Private Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute total yield r_tot(τ) = κ ln(X/y_prin) + r*(τ)
    ///
    /// @dev r_tot(τ) = κ ln(X/y_prin) + r*(τ)
    ///
    /// @param X Shadow reserve (WAD)
    /// @param yPrinWad Principal notional (WAD)
    /// @param rStar Anchor rate from Nelson-Siegel (WAD, yield per year)
    /// @param kappa Rate sensitivity parameter (WAD)
    ///
    /// @return rTot Total yield (WAD, per year)
    function _computeRTot(uint256 X, uint256 yPrinWad, int256 rStar, int256 kappa) private pure returns (int256 rTot) {
        int256 ratio = FixedPointMathLib.sDivWad({x: int256(X), y: int256(yPrinWad)});
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

    /// @notice Solve invariant for y_prin_new: K·x_new^α + y_prin_new^α = C
    ///
    /// @dev K(τ)·x_new^α + y_prin_new^α = C
    ///      y_prin_new = (C - K·x_new^α)^(1/α)
    ///      α=1 shortcut: y_prin_new = C - K·x_new (linear)
    ///
    /// @param C Invariant constant (WAD^α)
    /// @param K Coefficient K(τ) (WAD)
    /// @param xNew New virtual inventory (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return yPrinNew New principal (WAD)
    function _solveInvariantForYPrin(uint256 C, uint256 K, uint256 xNew, int256 alpha)
        private
        pure
        returns (uint256 yPrinNew)
    {
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
    /// @param yPrin Principal notional (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return C Invariant constant (WAD^α)
    function _computeC(uint256 K, uint256 x, uint256 yPrin, int256 alpha) private pure returns (uint256 C) {
        // Settlement shortcut (α=1): linear invariant
        if (alpha == 1e18) {
            return FixedPointMathLib.mulWad({x: K, y: x}) + yPrin;
        }

        // General case: power-sum invariant
        uint256 Kx_alpha =
            FixedPointMathLib.mulWad({x: K, y: uint256(FixedPointMathLib.powWad({x: int256(x), y: alpha}))});
        uint256 y_alpha = uint256(FixedPointMathLib.powWad({x: int256(yPrin), y: alpha}));

        return Kx_alpha + y_alpha;
    }

    /// @notice Compute new (ψ, X) via closed-form update
    ///
    /// @dev ψ_new = (y_prin / y_prin_new)^α · (ψ + 1) - 1
    ///      X_new = ψ_new · y_prin_new
    ///
    /// @param psi Current utilization ratio ψ = X/y_prin (WAD)
    /// @param yPrin Current principal (WAD)
    /// @param yPrinNew New principal (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return psiNew New utilization ratio (WAD)
    /// @return XNew New shadow reserve (WAD)
    function _computePsiAndXNew(uint256 psi, uint256 yPrin, uint256 yPrinNew, int256 alpha)
        private
        pure
        returns (uint256 psiNew, uint256 XNew)
    {
        // ratio = y_prin / y_prin_new
        int256 ratio = FixedPointMathLib.sDivWad({x: int256(yPrin), y: int256(yPrinNew)});

        // ratio^alpha
        int256 ratioPowAlpha = FixedPointMathLib.powWad({x: ratio, y: alpha});

        // psi_new = ratio^alpha * (psi + 1) - 1
        int256 psiPlus1 = int256(psi) + 1e18;
        int256 psiNewSigned = FixedPointMathLib.sMulWad({x: ratioPowAlpha, y: psiPlus1}) - 1e18;

        psiNew = uint256(psiNewSigned);
        XNew = FixedPointMathLib.mulWad({x: psiNew, y: yPrinNew});
    }
}
