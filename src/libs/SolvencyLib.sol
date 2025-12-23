// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title SolvencyLib - Risk-weighted equity computations
///
/// @notice Pure math primitives for solvency checks. Fira handles iteration.
library SolvencyLib {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    error SolvencyFloorViolated();

    //////////////////////////////////////////////////////////////
    ///                   Internal Functions                   ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute base equity before maturity adjustments.
    ///
    /// @dev E_base = (yLiq + yPnl) + w_vault·y_vault + S_past
    ///
    /// @param yLiqWad Liquid principal (WAD)
    /// @param yPnlWad Realized P&L (WAD)
    /// @param yVaultWad Vault principal (WAD)
    /// @param wVault Vault weight (WAD)
    /// @param sPast Past-due aggregate (WAD)
    ///
    /// @return base Base equity (WAD)
    function computeBaseEquity(uint256 yLiqWad, uint256 yPnlWad, uint256 yVaultWad, int256 wVault, int256 sPast)
        internal
        pure
        returns (int256 base)
    {
        // weightedVault = w_vault · y_vault
        int256 weightedVault = FixedPointMathLib.sMulWad({x: wVault, y: int256(yVaultWad)});
        // base = y_liq + y_pnl + weightedVault + sPast
        return int256(yLiqWad + yPnlWad) + weightedVault + sPast;
    }

    /// @notice Compute weighted net for one maturity bucket.
    ///
    /// @dev net = w_b(τ)·b - w_l(τ)·l
    ///      w_b(τ) = 1 - η_b·φ(τ)
    ///      w_l(τ) = 1 + η_l·φ(τ)
    ///
    /// @param tau Time to maturity (seconds)
    /// @param b Borrower notional (WAD)
    /// @param l Lender notional (WAD)
    /// @param lambdaW Weight decay timescale (seconds)
    /// @param etaB Borrower haircut (WAD)
    /// @param etaL Lender premium (WAD)
    ///
    /// @return net Weighted net position (WAD)
    function computeWeightedNet(uint256 tau, uint256 b, uint256 l, uint256 lambdaW, int256 etaB, int256 etaL)
        internal
        pure
        returns (int256 net)
    {
        int256 phi = _computePhi({tau: tau, lambdaW: lambdaW});

        // w_b = 1 - η_b·φ (haircut: w_b ≤ 1)
        int256 wB = 1e18 - FixedPointMathLib.sMulWad({x: etaB, y: phi});

        // w_l = 1 + η_l·φ (premium: w_l ≥ 1)
        int256 wL = 1e18 + FixedPointMathLib.sMulWad({x: etaL, y: phi});

        // net = w_b·b - w_l·l
        int256 weightedB = FixedPointMathLib.sMulWad({x: wB, y: int256(b)});
        int256 weightedL = FixedPointMathLib.sMulWad({x: wL, y: int256(l)});
        return weightedB - weightedL;
    }

    /// @notice Check solvency floor and revert if violated.
    ///
    /// @dev Floor check: minErisk >= ρ · N_LP
    ///
    /// @param minErisk Minimum risk-weighted equity across horizons (WAD)
    /// @param rho Floor per LP share (WAD)
    /// @param nLp Total LP shares (WAD)
    function checkFloor(int256 minErisk, int256 rho, uint256 nLp) internal pure {
        // floor = ρ · N_LP
        int256 floor = FixedPointMathLib.sMulWad({x: rho, y: int256(nLp)});
        require(minErisk >= floor, SolvencyFloorViolated());
    }

    //////////////////////////////////////////////////////////////
    ///                   Private Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute time-weight factor for maturity adjustments.
    ///
    /// @dev φ(τ) = 1 - e^(-τ/λ_w)
    ///      φ → 0 as τ → 0 (near-term: weights close to 1)
    ///      φ → 1 as τ → ∞ (far-term: full haircut/premium applied)
    ///
    /// @param tau Time to maturity (seconds)
    /// @param lambdaW Weight decay timescale (seconds)
    ///
    /// @return phi Time-weight factor (WAD, 0 to 1)
    function _computePhi(uint256 tau, uint256 lambdaW) private pure returns (int256 phi) {
        if (tau == 0) return 0;

        // ratio = τ / λ_w
        int256 ratio = FixedPointMathLib.sDivWad({x: int256(tau), y: int256(lambdaW)});
        // expNeg = e^(-τ/λ_w)
        int256 expNeg = FixedPointMathLib.expWad({x: -ratio});
        // φ = 1 - expNeg
        return 1e18 - expNeg;
    }
}
