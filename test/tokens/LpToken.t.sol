// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {LpToken} from "../../src/tokens/LpToken.sol";

/// @title LpTokenTest - Unit tests for LpToken
contract LpTokenTest is Test {
    LpToken lp;
    address minter = makeAddr("minter");
    address user = makeAddr("user");
    address otherUser = makeAddr("otherUser");

    function setUp() public {
        lp = new LpToken({minter: minter});
    }

    //////////////////////////////////////////////////////////////
    ///                   Metadata Tests                       ///
    //////////////////////////////////////////////////////////////

    /// @dev name() returns "Fira LP Token".
    function test_name() public view {
        assertEq(lp.name(), "Fira LP Token");
    }

    /// @dev symbol() returns "fLP".
    function test_symbol() public view {
        assertEq(lp.symbol(), "fLP");
    }

    /// @dev decimals() returns 18.
    function test_decimals() public view {
        assertEq(lp.decimals(), 18);
    }

    /// @dev MINTER is set correctly.
    function test_minter() public view {
        assertEq(lp.MINTER(), minter);
    }

    //////////////////////////////////////////////////////////////
    ///                    Mint Tests                          ///
    //////////////////////////////////////////////////////////////

    /// @dev Minter can mint tokens.
    function test_mint_asMinter() public {
        uint256 amount = 1000e18;

        vm.prank(minter);
        lp.mint({to: user, amount: amount});

        assertEq(lp.balanceOf(user), amount);
        assertEq(lp.totalSupply(), amount);
    }

    /// @dev Non-minter mint reverts with Unauthorized.
    function test_mint_asNonMinter_reverts() public {
        vm.prank(user);
        vm.expectRevert(LpToken.Unauthorized.selector);
        lp.mint({to: user, amount: 1000e18});
    }

    /// @dev Multiple mints increase balances correctly.
    function testFuzz_mint_multipleUsers(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, 1e36);
        amount2 = bound(amount2, 1, 1e36);

        vm.startPrank(minter);
        lp.mint({to: user, amount: amount1});
        lp.mint({to: otherUser, amount: amount2});
        vm.stopPrank();

        assertEq(lp.balanceOf(user), amount1);
        assertEq(lp.balanceOf(otherUser), amount2);
        assertEq(lp.totalSupply(), amount1 + amount2);
    }

    //////////////////////////////////////////////////////////////
    ///                    Burn Tests                          ///
    //////////////////////////////////////////////////////////////

    /// @dev Minter can burn tokens.
    function test_burn_asMinter() public {
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 400e18;

        vm.startPrank(minter);
        lp.mint({to: user, amount: mintAmount});
        lp.burn({from: user, amount: burnAmount});
        vm.stopPrank();

        assertEq(lp.balanceOf(user), mintAmount - burnAmount);
        assertEq(lp.totalSupply(), mintAmount - burnAmount);
    }

    /// @dev Non-minter burn reverts with Unauthorized.
    function test_burn_asNonMinter_reverts() public {
        vm.prank(minter);
        lp.mint({to: user, amount: 1000e18});

        vm.prank(user);
        vm.expectRevert(LpToken.Unauthorized.selector);
        lp.burn({from: user, amount: 500e18});
    }

    /// @dev Burning more than balance reverts.
    function test_burn_moreThanBalance_reverts() public {
        uint256 mintAmount = 1000e18;

        vm.startPrank(minter);
        lp.mint({to: user, amount: mintAmount});

        vm.expectRevert(); // Underflow
        lp.burn({from: user, amount: mintAmount + 1});
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////
    ///                  Constructor Tests                     ///
    //////////////////////////////////////////////////////////////

    /// @dev Zero address minter reverts.
    function test_constructor_zeroMinter_reverts() public {
        vm.expectRevert(LpToken.ZeroAddress.selector);
        new LpToken({minter: address(0)});
    }

    //////////////////////////////////////////////////////////////
    ///                  Transfer Tests                        ///
    //////////////////////////////////////////////////////////////

    /// @dev LP tokens are transferable (ERC20).
    function test_transfer() public {
        uint256 amount = 1000e18;
        uint256 transferAmount = 300e18;

        vm.prank(minter);
        lp.mint({to: user, amount: amount});

        vm.prank(user);
        lp.transfer({to: otherUser, amount: transferAmount});

        assertEq(lp.balanceOf(user), amount - transferAmount);
        assertEq(lp.balanceOf(otherUser), transferAmount);
    }

    /// @dev LP tokens support approve/transferFrom.
    function test_approve_transferFrom() public {
        uint256 amount = 1000e18;
        uint256 transferAmount = 300e18;

        vm.prank(minter);
        lp.mint({to: user, amount: amount});

        vm.prank(user);
        lp.approve({spender: otherUser, amount: transferAmount});

        vm.prank(otherUser);
        lp.transferFrom({from: user, to: otherUser, amount: transferAmount});

        assertEq(lp.balanceOf(user), amount - transferAmount);
        assertEq(lp.balanceOf(otherUser), transferAmount);
    }
}
