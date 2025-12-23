// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title LpToken - Fira LP shares
///
/// @notice ERC20 token representing LP positions in the Fira pool.
///
/// @dev tokenId = maturity timestamp. Only the minter (AMM) can mint/burn.
contract LpToken is ERC20 {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    /// @notice Thrown when caller is not the authorized minter.
    error Unauthorized();

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    //////////////////////////////////////////////////////////////
    ///                       Immutables                       ///
    //////////////////////////////////////////////////////////////

    /// @notice The address authorized to mint and burn tokens (the AMM).
    address public immutable MINTER;

    //////////////////////////////////////////////////////////////
    ///                       Constructor                      ///
    //////////////////////////////////////////////////////////////

    /// @notice Creates a new LpToken with a designated minter.
    ///
    /// @param minter The address authorized to mint/burn (typically the AMM).
    constructor(address minter) {
        require(minter != address(0), ZeroAddress());
        MINTER = minter;
    }

    //////////////////////////////////////////////////////////////
    ///                    Public Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Mints LP tokens to an address.
    ///
    /// @param to The recipient address.
    /// @param amount The amount to mint (WAD).
    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, Unauthorized());
        _mint(to, amount);
    }

    /// @notice Burns LP tokens from an address.
    ///
    /// @param from The address to burn from.
    /// @param amount The amount to burn (WAD).
    function burn(address from, uint256 amount) external {
        require(msg.sender == MINTER, Unauthorized());
        _burn(from, amount);
    }

    /// @notice Returns the token name.
    function name() public pure override returns (string memory) {
        return "Fira LP Token";
    }

    /// @notice Returns the token symbol.
    function symbol() public pure override returns (string memory) {
        return "fLP";
    }

    /// @notice Returns the number of decimals (18 for WAD compatibility).
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
