// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LpLib - LP deposit computation
///
/// @notice Pure math for LP deposits.
///
/// @dev All functions are pure and work with WAD (18 decimals).
library LpLib {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    error NegativeEquity();

    //////////////////////////////////////////////////////////////
    ///                       Structs                          ///
    //////////////////////////////////////////////////////////////

    /// @notice Parameters for computing nominal equity (eNom).
    struct EnomParams {
        uint256 yLiqWad;
        uint256 yPnlWad;
        uint256 yVaultWad;
        int256 sPast;
        int256 sumBucketNet;
    }

    //////////////////////////////////////////////////////////////
    ///                   Internal Functions                   ///
    //////////////////////////////////////////////////////////////

    /// @notice Compute deposit outputs.
    ///
    /// @dev Computes shares to mint and new X value.
    ///      Bootstrap case (nLp = 0): mints 1:1 shares, sets X = yPrinNew (ψ = 1).
    ///      Normal case: shares = deposit * nLp / eNom, X scaled to preserve ψ.
    ///      eNom = yLiq + yPnl + yVault + sPast + sumBucketNet
    ///
    /// @param enom Parameters for nominal equity computation.
    /// @param X Current shadow reserve (WAD).
    /// @param nLp Current LP shares (WAD).
    /// @param depositWad Deposit amount (WAD).
    /// @param yPrinOldWad Principal before deposit (WAD).
    ///
    /// @return sharesToMint Shares to mint (WAD).
    /// @return XNew New shadow reserve (WAD).
    function computeDeposit(EnomParams memory enom, uint256 X, uint256 nLp, uint256 depositWad, uint256 yPrinOldWad)
        internal
        pure
        returns (uint256 sharesToMint, uint256 XNew)
    {
        uint256 yPrinNewWad = yPrinOldWad + depositWad;

        // Compute shares
        if (nLp == 0) {
            sharesToMint = depositWad;
        } else {
            int256 eNom = int256(enom.yLiqWad + enom.yPnlWad + enom.yVaultWad) + enom.sPast + enom.sumBucketNet;
            require(eNom > 0, NegativeEquity());
            sharesToMint = FixedPointMathLib.mulDiv({x: depositWad, y: nLp, d: uint256(eNom)});
        }

        // Scale X to preserve psi (utilization ratio ψ = X / yPrin).
        if (yPrinOldWad == 0) {
            // Bootstrap sets ψ = 1 (balanced pool), which should always be within bounds.
            XNew = yPrinNewWad;
        } else {
            // Deposits should not change the interest rate, so we keep ψ constant:
            //   ψ_new = ψ_old  →  X_new / yPrin_new = X_old / yPrin_old
            //   X_new = X_old * yPrin_new / yPrin_old
            XNew = FixedPointMathLib.mulDiv({x: X, y: yPrinNewWad, d: yPrinOldWad});
        }
    }
}
