// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1155} from "solady/tokens/ERC1155.sol";

/// @title MockBondToken - Mock ERC1155 for testing
///
/// @dev No access control - anyone can mint/burn for testing purposes.
contract MockBondToken is ERC1155 {
    mapping(uint256 maturity => uint256 supply) private _totalSupply;

    function mint(address to, uint256 maturity, uint256 amount) external {
        _mint({to: to, id: maturity, amount: amount, data: ""});
        _totalSupply[maturity] += amount;
    }

    function burn(address from, uint256 maturity, uint256 amount) external {
        _burn({from: from, id: maturity, amount: amount});
        _totalSupply[maturity] -= amount;
    }

    function totalSupply(uint256 maturity) external view returns (uint256) {
        return _totalSupply[maturity];
    }

    function uri(uint256) public pure override returns (string memory) {
        return "";
    }
}
