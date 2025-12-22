// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fira} from "../../src/Fira.sol";

/// @title FiraHarness - Test harness for Fira
///
/// @dev Exposes setters to initialize pool state for testing.
///      Only use in tests - not for production.
contract FiraHarness is Fira {
    constructor(ConstructorParams memory p) Fira(p) {}

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
