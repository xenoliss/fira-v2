// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title MockLpToken - Mock ERC20 for testing
///
/// @dev No access control - anyone can mint/burn for testing purposes.
contract MockLpToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock Fira LP Token";
    }

    function symbol() public pure override returns (string memory) {
        return "mfLP";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
