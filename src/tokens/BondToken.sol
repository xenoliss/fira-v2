// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1155} from "solady/tokens/ERC1155.sol";

/// @title BondToken - Multi-Maturity Bond Token
///
/// @notice ERC1155 token representing bonds with different maturities.
/// @dev tokenId = maturity timestamp. Only the minter (AMM) can mint/burn.
contract BondToken is ERC1155 {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    /// @notice Thrown when caller is not the authorized minter.
    error Unauthorized();

    /// @notice Thrown when a zero address is provided.
    error ZeroAddress();

    //////////////////////////////////////////////////////////////
    ///                       Events                           ///
    //////////////////////////////////////////////////////////////

    /// @notice Emitted when tokens are minted.
    ///
    /// @param to The address receiving the tokens.
    /// @param maturity The maturity timestamp (tokenId).
    /// @param amount The amount minted.
    event Minted(address indexed to, uint256 indexed maturity, uint256 amount);

    /// @notice Emitted when tokens are burned.
    ///
    /// @param from The address whose tokens are burned.
    /// @param maturity The maturity timestamp (tokenId).
    /// @param amount The amount burned.
    event Burned(address indexed from, uint256 indexed maturity, uint256 amount);

    //////////////////////////////////////////////////////////////
    ///                       Storage                          ///
    //////////////////////////////////////////////////////////////

    /// @notice Total supply per maturity.
    mapping(uint256 maturity => uint256 supply) private _totalSupply;

    //////////////////////////////////////////////////////////////
    ///                       Immutables                       ///
    //////////////////////////////////////////////////////////////

    /// @notice The address authorized to mint and burn tokens (the AMM).
    address public immutable MINTER;

    //////////////////////////////////////////////////////////////
    ///                       Constructor                      ///
    //////////////////////////////////////////////////////////////

    /// @notice Creates a new BondToken with a designated minter.
    ///
    /// @param minter The address authorized to mint/burn (typically the AMM).
    constructor(address minter) {
        if (minter == address(0)) revert ZeroAddress();
        MINTER = minter;
    }

    //////////////////////////////////////////////////////////////
    ///                       Modifiers                        ///
    //////////////////////////////////////////////////////////////

    /// @dev Restricts function access to the minter only.
    modifier onlyMinter() {
        _checkMinter();
        _;
    }

    /// @dev Internal function to check minter authorization.
    function _checkMinter() internal view {
        if (msg.sender != MINTER) revert Unauthorized();
    }

    //////////////////////////////////////////////////////////////
    ///                    Public Functions                    ///
    //////////////////////////////////////////////////////////////

    /// @notice Mints bond tokens to an address.
    ///
    /// @param to The recipient address.
    /// @param maturity The maturity timestamp (tokenId).
    /// @param amount The amount to mint.
    function mint(address to, uint256 maturity, uint256 amount) external onlyMinter {
        _mint({to: to, id: maturity, amount: amount, data: ""});
        _totalSupply[maturity] += amount;

        emit Minted({to: to, maturity: maturity, amount: amount});
    }

    /// @notice Burns bond tokens from an address.
    ///
    /// @param from The address to burn from.
    /// @param maturity The maturity timestamp (tokenId).
    /// @param amount The amount to burn.
    function burn(address from, uint256 maturity, uint256 amount) external onlyMinter {
        _burn({from: from, id: maturity, amount: amount});
        _totalSupply[maturity] -= amount;

        emit Burned({from: from, maturity: maturity, amount: amount});
    }

    /// @notice Returns the total supply for a given maturity.
    ///
    /// @param maturity The maturity timestamp.
    ///
    /// @return The total supply of tokens for this maturity.
    function totalSupply(uint256 maturity) external view returns (uint256) {
        return _totalSupply[maturity];
    }

    /// @notice Checks if a bond maturity has expired.
    ///
    /// @param maturity The maturity timestamp.
    ///
    /// @return True if the current time is >= maturity.
    function isExpired(uint256 maturity) external view returns (bool) {
        return block.timestamp >= maturity;
    }

    /// @notice Returns the URI for a given token ID.
    ///
    /// @param id The token ID (maturity).
    ///
    /// @return Empty string (no metadata for now).
    function uri(uint256 id) public pure override returns (string memory) {
        id; // Silence unused variable warning
        return "";
    }
}
