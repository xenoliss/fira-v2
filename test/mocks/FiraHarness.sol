// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fira} from "../../src/Fira.sol";

/// @title FiraHarness - Test harness for Fira
///
/// @dev Exposes setters to initialize pool state for testing.
///      Only use in tests - not for production.
contract FiraHarness is Fira {
    constructor(
        address cash,
        address bond,
        int256 beta0_,
        int256 beta1_,
        int256 beta2_,
        uint256 lambda_,
        int256 kappa_,
        uint256 tauMin_,
        uint256 tauMax_,
        uint256 psiMin_,
        uint256 psiMax_
    ) Fira(cash, bond, beta0_, beta1_, beta2_, lambda_, kappa_, tauMin_, tauMax_, psiMin_, psiMax_) {}

    /// @notice Set shadow reserve X (for testing)
    function setX(uint256 x) external {
        X = x;
    }

    /// @notice Set liquid principal yLiq (for testing)
    function setYLiq(uint256 y) external {
        yLiq = y;
    }

    /// @notice Set vault principal yVault (for testing)
    function setYVault(uint256 y) external {
        yVault = y;
    }

    /// @notice Set sPast (for testing)
    function setSPast(int256 s) external {
        sPast = s;
    }
}
