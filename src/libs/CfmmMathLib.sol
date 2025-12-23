// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {NelsonSiegelLib} from "./NelsonSiegelLib.sol";

/// @title CfmmMathLib - Pure CFMM Math Functions
///
/// @notice Implements the TS-BondMM CFMM invariant and pricing functions.
///
/// @dev This library implements the core math for a term-structure bond AMM.
///
///      **Key Variables:**
///        - X: Shadow reserve (tracks bond exposure, WAD)
///        - y: Cash leg (pool's cash balance, WAD)
///        - x: Virtual inventory = X / price (used in invariant, WAD)
///        - ψ (psi): Utilization ratio = X / y (WAD)
///
///      **Core Invariant:**
///        K(τ)·x^α + y^α = C
///
///        Where:
///        - K(τ) = e^(-τ·r*·α) — coefficient that adjusts for time value
///        - α(τ) = 1/(1 + κτ) — curvature exponent (controls slippage)
///        - r*(τ) — anchor rate from Nelson-Siegel term structure
///        - C — invariant constant (preserved during swaps)
///
///      **Pricing:**
///        - r_tot = κ·ln(X/y) + r*(τ) — total yield (market rate)
///        - price = e^(-r_tot·τ) — bond discount factor
///
///      All functions are pure and work with WAD (18 decimals).
///      Use `computeSwapAtSettlement` for τ=0 (optimized path).
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
    ///
    /// @dev Nelson-Siegel parameters (beta0, beta1, beta2, lambda) define the anchor rate curve r*(τ).
    ///      Kappa (κ) controls rate sensitivity to pool utilization.
    ///      Psi bounds enforce utilization limits to prevent extreme rates.
    ///
    /// @custom:param beta0 Long-term rate level (WAD, e.g., 0.05e18 = 5%)
    /// @custom:param beta1 Short-term deviation (WAD, affects curve slope)
    /// @custom:param beta2 Medium-term hump (WAD, affects curve curvature)
    /// @custom:param lambda Decay factor (WAD, controls where hump peaks)
    /// @custom:param kappa Rate sensitivity κ (WAD, higher = more slippage)
    /// @custom:param psiMin Minimum utilization ratio (WAD, e.g., 0.1e18 = 10%)
    /// @custom:param psiMax Maximum utilization ratio (WAD, e.g., 10e18 = 1000%)
    struct CfmmParams {
        int256 beta0;
        int256 beta1;
        int256 beta2;
        uint256 lambda;
        uint256 kappa;
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
    ///
    ///      **Step-by-step process:**
    ///
    ///      1. **Compute α(τ)** — curvature exponent
    ///         α = 1 / (1 + κτ)
    ///         Controls slippage: α→1 as τ→0, α→0 as τ→∞
    ///
    ///      2. **Compute r*(τ)** — anchor rate from Nelson-Siegel
    ///         r* = β₀ + β₁·f(τ/λ) + β₂·g(τ/λ)
    ///         Defines the "fair" rate for maturity τ
    ///
    ///      3. **Compute r_tot** — total market rate
    ///         r_tot = κ·ln(X/y) + r*(τ)
    ///         Adjusts anchor rate based on pool utilization (X/y)
    ///
    ///      4. **Compute price** — bond discount factor
    ///         price = e^(-r_tot·τ)
    ///         Present value of 1 unit at maturity
    ///
    ///      5. **Compute x** — virtual inventory
    ///         x = X / price
    ///         Converts shadow reserve to invariant space
    ///
    ///      6. **Compute K and C** — invariant parameters
    ///         K = e^(-τ·r*·α)
    ///         C = K·x^α + y^α (invariant constant, preserved)
    ///
    ///      7. **Apply swap to invariant**
    ///         xNew = x + bondAmountSigned
    ///         yNew = (C - K·xNew^α)^(1/α)
    ///
    ///      8. **Update shadow reserve via ψ**
    ///         ψ_new = (y/yNew)^α · (ψ + 1) - 1
    ///         X_new = ψ_new · yNew
    ///
    ///      9. **Validate ψ bounds**
    ///         Ensure psiMin ≤ ψ_new ≤ psiMax
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

        uint256 alpha;

        // Scope 1: Compute yNewWad
        {
            // α = 1 / (1 + κτ)
            alpha = _computeAlpha({tau: tau, kappa: params.kappa});

            // r* = Nelson-Siegel(τ)
            int256 rStar = NelsonSiegelLib.computeRStar({
                tau: tau, beta0: params.beta0, beta1: params.beta1, beta2: params.beta2, lambda: params.lambda
            });

            // r_tot = κ·ln(X/y) + r*
            int256 rTot = _computeRTot({X: X, yWad: yWad, rStar: rStar, kappa: params.kappa});

            // price = e^(-r_tot·τ)
            uint256 price = _computePrice({rTot: rTot, tau: tau});

            // x = X / price
            uint256 x = FixedPointMathLib.divWad({x: X, y: price});

            // K = e^(-τ·r*·α)
            uint256 K = _computeK({tau: tau, rStar: rStar, alpha: alpha});
            // C = K·x^α + y^α
            uint256 C = _computeC({K: K, x: x, y: yWad, alpha: alpha});

            // xNew = x + Δ (borrow: Δ>0, lend: Δ<0)
            int256 xNewSigned = int256(x) + bondAmountSigned;
            require(xNewSigned > 0, InvariantViolated());
            uint256 xNew = uint256(xNewSigned);

            // yNew = (C - K·xNew^α)^(1/α)
            yNewWad = _solveInvariantForY({C: C, K: K, xNew: xNew, alpha: alpha});
        }

        // Scope 2: Compute new state (X, psi)
        {
            // ψ = X / y
            uint256 psi = FixedPointMathLib.divWad({x: X, y: yWad});
            // ψNew, XNew via closed-form update
            uint256 psiNew;
            (psiNew, XNew) = _computePsiAndXNew({psi: psi, y: yWad, yNew: yNewWad, alpha: alpha});

            require(psiNew >= params.psiMin && psiNew <= params.psiMax, RateOutOfBounds());
        }
    }

    /// @notice Compute swap at settlement (τ=0)
    ///
    /// @dev Optimized path for settlement that bypasses all complex CFMM calculations.
    ///
    ///      When τ=0: p(0)=1, α(0)=1, K(0)=1, so the invariant becomes linear.
    ///
    ///      **Derivation for yNew:**
    ///        - x = X / price = X / 1 = X  (virtual inventory equals shadow reserve)
    ///        - Invariant: K·x^α + y^α = C  →  x + y = C  (linear when K=1, α=1)
    ///        - After swap: xNew + yNew = C
    ///        - Therefore: yNew = C - xNew = (x + y) - (x + Δ) = y - Δ
    ///
    ///      **Derivation for XNew:**
    ///        - ψ = X / y
    ///        - ψ_new = (y / yNew)^α · (ψ + 1) - 1  →  (y / yNew) · (ψ + 1) - 1  (when α=1)
    ///        - X_new = ψ_new · yNew
    ///                = [(y / yNew) · (X/y + 1) - 1] · yNew
    ///                = [(X + y) / yNew - 1] · yNew
    ///                = (X + y) - yNew
    ///                = X + y - (y - Δ)
    ///                = X + Δ
    ///
    ///      **Result:** At settlement, swap is 1:1 linear exchange.
    ///        - yNew = y - bondAmountSigned
    ///        - XNew = X + bondAmountSigned
    ///
    /// @param bondAmountSigned Signed bond amount (positive = redeem, negative = repay, WAD)
    /// @param X Current shadow reserve (WAD)
    /// @param yWad Current cash leg (WAD)
    /// @param psiMin Minimum utilization ratio (WAD)
    /// @param psiMax Maximum utilization ratio (WAD)
    ///
    /// @return XNew New shadow reserve (WAD)
    function computeSwapAtSettlement(int256 bondAmountSigned, uint256 X, uint256 yWad, uint256 psiMin, uint256 psiMax)
        internal
        pure
        returns (uint256 XNew)
    {
        require(bondAmountSigned != 0, ZeroAmount());

        // yNew = y - Δ
        int256 yNewSigned = int256(yWad) - bondAmountSigned;
        require(yNewSigned > 0, InvariantViolated());
        uint256 yNewWad = uint256(yNewSigned);

        // XNew = X + Δ
        int256 XNewSigned = int256(X) + bondAmountSigned;
        require(XNewSigned > 0, InvariantViolated());
        XNew = uint256(XNewSigned);

        // ψNew = XNew / yNew
        uint256 psiNew = FixedPointMathLib.divWad({x: XNew, y: yNewWad});
        require(psiNew >= psiMin && psiNew <= psiMax, RateOutOfBounds());
    }

    //////////////////////////////////////////////////////////////
    ///                   Private Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute total yield from pool utilization and anchor rate.
    ///
    /// @dev The total yield combines the anchor rate with a utilization adjustment.
    ///
    ///      **Formula:** r_tot = κ·ln(X/y) + r*(τ)
    ///
    ///      **Mechanism:**
    ///        - When X/y > 1 (more borrows): ln(X/y) > 0 → r_tot > r* → rates go UP
    ///        - When X/y < 1 (more lends): ln(X/y) < 0 → r_tot < r* → rates go DOWN
    ///        - When X/y = 1 (balanced): ln(X/y) = 0 → r_tot = r* → anchor rate
    ///
    ///      This creates a self-balancing mechanism where rates adjust based on
    ///      supply/demand, with κ controlling how sensitive rates are to imbalances.
    ///
    /// @param X Shadow reserve (WAD)
    /// @param yWad Cash leg (WAD)
    /// @param rStar Anchor rate from Nelson-Siegel (WAD, yield per year)
    /// @param kappa Rate sensitivity parameter (WAD)
    ///
    /// @return rTot Total yield (WAD, per year)
    function _computeRTot(uint256 X, uint256 yWad, int256 rStar, uint256 kappa) private pure returns (int256 rTot) {
        // ratio = X / y
        uint256 ratio = FixedPointMathLib.divWad({x: X, y: yWad});
        // lnRatio = ln(X/y) — can be negative when X < y
        int256 lnRatio = FixedPointMathLib.lnWad({x: int256(ratio)});
        // r_tot = κ·ln(X/y) + r*
        return FixedPointMathLib.sMulWad({x: int256(kappa), y: lnRatio}) + rStar;
    }

    /// @notice Compute bond price (present value discount factor).
    ///
    /// @dev The bond price is the present value discount factor.
    ///
    ///      **Formula:** price = e^(-r_tot·τ)
    ///
    ///      **Interpretation:**
    ///        - price < 1: Bond trades at discount (normal case when r_tot > 0)
    ///        - price = 1: Bond trades at par (τ=0 or r_tot=0)
    ///        - price > 1: Bond trades at premium (negative rates)
    ///
    ///      **Example:** r_tot=5%, τ=1 year → price ≈ 0.951
    ///        Meaning: Pay 0.951 today to receive 1.0 at maturity
    ///
    /// @param rTot Total yield (WAD, per year)
    /// @param tau Time to maturity (seconds)
    ///
    /// @return price Bond price (WAD)
    function _computePrice(int256 rTot, uint256 tau) private pure returns (uint256 price) {
        // τ_years = τ / 365 days
        uint256 tauYears = FixedPointMathLib.divWad({x: tau, y: 365 days});
        // price = e^(-r_tot·τ)
        return uint256(FixedPointMathLib.expWad({x: -FixedPointMathLib.sMulWad({x: rTot, y: int256(tauYears)})}));
    }

    /// @notice Compute invariant curvature exponent α(τ).
    ///
    /// @dev Alpha controls the curvature of the invariant and thus slippage.
    ///
    ///      **Formula:** α = 1 / (1 + κτ)
    ///
    ///      **Behavior:**
    ///        - τ → 0: α → 1 (linear invariant, minimal slippage)
    ///        - τ → ∞: α → 0 (high curvature, maximum slippage)
    ///
    ///      **Intuition:**
    ///        Longer maturities have more rate uncertainty, so the AMM charges
    ///        more slippage (via lower α) to compensate for risk.
    ///
    ///      **Role in invariant:** K·x^α + y^α = C
    ///        - α=1: Linear exchange
    ///        - α<1: Curved exchange
    ///
    /// @param tau Time to maturity (seconds)
    /// @param kappa Rate sensitivity (WAD)
    ///
    /// @return alpha Exponent (WAD, always in (0, 1])
    function _computeAlpha(uint256 tau, uint256 kappa) private pure returns (uint256 alpha) {
        // τ_years = τ / 365 days
        uint256 tauYears = FixedPointMathLib.divWad({x: tau, y: 365 days});
        // α = 1 / (1 + κ·τ)
        return FixedPointMathLib.divWad({x: 1e18, y: 1e18 + FixedPointMathLib.mulWad({x: kappa, y: tauYears})});
    }

    /// @notice Compute invariant coefficient K(τ) for bond weighting.
    ///
    /// @dev K adjusts the x-term weight in the invariant based on time value.
    ///
    ///      **Formula:** K = e^(-τ·r*·α)
    ///
    ///      **Role in invariant:** K·x^α + y^α = C
    ///        - K weights the bond side (x) relative to cash side (y)
    ///        - Accounts for time value of money at the anchor rate
    ///
    ///      **Behavior:**
    ///        - τ = 0: K = 1 (bonds and cash equally weighted)
    ///        - τ > 0, r* > 0: K < 1 (bonds discounted vs cash)
    ///        - Higher r* or τ → lower K → bonds worth less
    ///
    ///      **Why use r* instead of r_tot?**
    ///        K uses the anchor rate to maintain path-independence.
    ///        The market rate r_tot affects pricing, not the invariant shape.
    ///
    /// @param tau Time to maturity (seconds)
    /// @param rStar Anchor rate (WAD, per year)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return K Coefficient (WAD)
    function _computeK(uint256 tau, int256 rStar, uint256 alpha) private pure returns (uint256 K) {
        // τ_years = τ / 365 days
        uint256 tauYears = FixedPointMathLib.divWad({x: tau, y: 365 days});
        // exponent = -τ·r*·α (r* can be negative, so use signed math)
        int256 exponent = -FixedPointMathLib.sMulWad({
            x: FixedPointMathLib.sMulWad({x: int256(tauYears), y: rStar}), y: int256(alpha)
        });
        // K = e^(-τ·r*·α)
        return uint256(FixedPointMathLib.expWad({x: exponent}));
    }

    /// @notice Solve invariant for y_new given x_new
    ///
    /// @dev Given the invariant K·x^α + y^α = C and a new x value, solve for y.
    ///
    ///      **Derivation:**
    ///        K·xNew^α + yNew^α = C
    ///        yNew^α = C - K·xNew^α
    ///        yNew = (C - K·xNew^α)^(1/α)
    ///
    ///      **Requirements:**
    ///        - C ≥ K·xNew^α (otherwise no valid y exists → revert)
    ///        - This ensures the swap doesn't exceed available liquidity
    ///
    /// @param C Invariant constant (WAD^α)
    /// @param K Coefficient K(τ) (WAD)
    /// @param xNew New virtual inventory (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return yNew New cash leg (WAD)
    function _solveInvariantForY(uint256 C, uint256 K, uint256 xNew, uint256 alpha)
        private
        pure
        returns (uint256 yNew)
    {
        // Kx_alpha = K·xNew^α — cast to int256 for powWad
        uint256 Kx_alpha =
            FixedPointMathLib.mulWad({x: K, y: uint256(FixedPointMathLib.powWad({x: int256(xNew), y: int256(alpha)}))});

        require(C >= Kx_alpha, InvariantViolated());
        // y_alpha = C - K·xNew^α
        uint256 y_alpha = C - Kx_alpha;

        // invAlpha = 1/α (alpha > 0, so we can use unsigned division)
        uint256 invAlpha = FixedPointMathLib.divWad({x: 1e18, y: alpha});
        // yNew = (C - K·xNew^α)^(1/α)
        return uint256(FixedPointMathLib.powWad({x: int256(y_alpha), y: int256(invAlpha)}));
    }

    /// @notice Compute invariant constant C (preserved during swaps).
    ///
    /// @dev C is the invariant that must be preserved during swaps.
    ///
    ///      **Formula:** C = K·x^α + y^α
    ///
    ///      **Properties:**
    ///        - C is computed BEFORE the swap using current (x, y)
    ///        - C remains constant DURING the swap
    ///        - Given xNew, we solve for yNew such that K·xNew^α + yNew^α = C
    ///
    /// @param K Coefficient K(τ) (WAD)
    /// @param x Virtual inventory (WAD)
    /// @param y Cash leg (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return C Invariant constant (WAD^α)
    function _computeC(uint256 K, uint256 x, uint256 y, uint256 alpha) private pure returns (uint256 C) {
        // Kx_alpha = K·x^α — cast to int256 for powWad
        uint256 Kx_alpha =
            FixedPointMathLib.mulWad({x: K, y: uint256(FixedPointMathLib.powWad({x: int256(x), y: int256(alpha)}))});
        // y_alpha = y^α
        uint256 y_alpha = uint256(FixedPointMathLib.powWad({x: int256(y), y: int256(alpha)}));
        // C = K·x^α + y^α
        return Kx_alpha + y_alpha;
    }

    /// @notice Compute new (ψ, X) via closed-form update.
    ///
    /// @dev Updates the shadow reserve X after a swap, using the ψ ratio.
    ///
    ///      ψ_new = (y / yNew)^α · (ψ + 1) - 1
    ///      X_new = ψ_new · yNew
    ///
    /// @param psi Current utilization ratio ψ = X/y (WAD)
    /// @param y Current cash leg (WAD)
    /// @param yNew New cash leg (WAD)
    /// @param alpha Exponent α(τ) (WAD)
    ///
    /// @return psiNew New utilization ratio (WAD)
    /// @return XNew New shadow reserve (WAD)
    function _computePsiAndXNew(uint256 psi, uint256 y, uint256 yNew, uint256 alpha)
        private
        pure
        returns (uint256 psiNew, uint256 XNew)
    {
        // ratio = y / yNew (both positive)
        uint256 ratio = FixedPointMathLib.divWad({x: y, y: yNew});

        // ratioPowAlpha = (y / yNew)^α — cast to int256 for powWad
        int256 ratioPowAlpha = FixedPointMathLib.powWad({x: int256(ratio), y: int256(alpha)});

        // psiPlusOne = ψ + 1
        uint256 psiPlusOne = psi + 1e18;

        // ψNew = (y/yNew)^α · (ψ + 1) - 1 — use sMulWad for int256 * int256
        psiNew = uint256(FixedPointMathLib.sMulWad({x: ratioPowAlpha, y: int256(psiPlusOne)}) - 1e18);

        // XNew = ψNew · yNew
        XNew = FixedPointMathLib.mulWad({x: psiNew, y: yNew});
    }
}
