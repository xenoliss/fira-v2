// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {Fira} from "../src/Fira.sol";
import {FiraHarness} from "./mocks/FiraHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBondToken} from "./mocks/MockBondToken.sol";

/// @title FiraTest - Integration tests for Fira protocol
contract FiraTest is Test {
    //////////////////////////////////////////////////////////////
    ///                       Constants                        ///
    //////////////////////////////////////////////////////////////

    uint256 constant SECONDS_PER_YEAR = 365 days;

    // Nelson-Siegel parameters
    int256 constant BETA0 = 0.05e18; // 5% long-term rate
    int256 constant BETA1 = -0.02e18; // -2% slope
    int256 constant BETA2 = 0.01e18; // 1% curvature
    uint256 constant LAMBDA = 2 * SECONDS_PER_YEAR; // 2 year decay

    // CFMM parameters
    int256 constant KAPPA = 0.5e18;
    uint256 constant TAU_MIN = 7 days;
    uint256 constant TAU_MAX = 5 * SECONDS_PER_YEAR;
    uint256 constant PSI_MIN = 0.5e18; // 50%
    uint256 constant PSI_MAX = 2e18; // 200%

    // Solvency parameters (M2)
    uint256 constant LAMBDA_W = SECONDS_PER_YEAR; // 1 year decay
    int256 constant ETA_B = 0.2e18; // 20% borrower haircut
    int256 constant ETA_L = 0.1e18; // 10% lender premium
    int256 constant W_VAULT = 0.5e18; // 50% vault weight
    int256 constant RHO = 0; // Zero floor (no LPs yet)

    // Initial pool state
    uint256 constant INITIAL_Y_LIQ = 10_000e6; // 10,000 USDC (6 decimals)
    uint256 constant INITIAL_X = 10_000e18; // 10,000 WAD (psi = 1)

    // Test amounts
    uint256 constant BOND_AMOUNT = 1000e18; // 1000 FV in WAD
    uint256 constant CASH_AMOUNT = 1000e6; // 1000 USDC

    //////////////////////////////////////////////////////////////
    ///                       State                            ///
    //////////////////////////////////////////////////////////////

    MockERC20 cash;
    MockBondToken bondToken;
    FiraHarness fira;

    address borrower = makeAddr("borrower");
    address lender = makeAddr("lender");

    uint256 maturity;

    //////////////////////////////////////////////////////////////
    ///                       Setup                            ///
    //////////////////////////////////////////////////////////////

    function setUp() public {
        // 1. Deploy mocks
        cash = new MockERC20({name: "USD Coin", symbol: "USDC", decimals: 6});
        bondToken = new MockBondToken();

        // 2. Deploy Fira with test parameters
        fira = new FiraHarness(
            Fira.ConstructorParams({
                cash: address(cash),
                bond: address(bondToken),
                ns: Fira.NSParams({beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA}),
                cfmm: Fira.CfmmParams({
                    kappa: KAPPA, tauMin: TAU_MIN, tauMax: TAU_MAX, psiMin: PSI_MIN, psiMax: PSI_MAX
                }),
                solvency: Fira.SolvencyParams({lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L, wVault: W_VAULT, rho: RHO})
            })
        );

        // 3. Set maturity to 1 year from now
        maturity = block.timestamp + SECONDS_PER_YEAR;

        // 4. Initialize pool state
        cash.mint({to: address(fira), amount: INITIAL_Y_LIQ});
        fira.setX({x: INITIAL_X});
        fira.setYLiq({y: INITIAL_Y_LIQ});

        // 5. Add maturity to active list
        fira.addMaturity({maturity: maturity, hint: 0});

        // 6. Give users some tokens
        // Borrower gets bonds (simulating collateral system)
        bondToken.mint({to: borrower, maturity: maturity, amount: BOND_AMOUNT});

        // Lender gets cash
        cash.mint({to: lender, amount: CASH_AMOUNT});
    }

    //////////////////////////////////////////////////////////////
    ///                   Borrow Tests                         ///
    //////////////////////////////////////////////////////////////

    /// @dev Borrow decreases pool liquidity (yLiq)
    function test_borrow_reducesYLiq() public {
        uint256 yLiqBefore = fira.yLiq();
        uint256 bondAmount = 100e18;

        // Approve bond burn (not needed for MockBondToken but good practice)
        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});

        fira.borrow({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        uint256 yLiqAfter = fira.yLiq();
        assertLt(yLiqAfter, yLiqBefore, "yLiq should decrease after borrow");
    }

    /// @dev Borrow burns user's bond tokens
    function test_borrow_burnsBonds() public {
        uint256 bondsBefore = bondToken.balanceOf({owner: borrower, id: maturity});
        uint256 bondAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.borrow({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        uint256 bondsAfter = bondToken.balanceOf({owner: borrower, id: maturity});
        assertEq(bondsAfter, bondsBefore - bondAmount, "Bonds should be burned");
    }

    /// @dev Borrow increases maturity bucket b (borrower notional)
    function test_borrow_increasesBucketB() public {
        (, uint256 bBefore,) = fira.maturities(maturity);
        uint256 bondAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.borrow({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        (, uint256 bAfter,) = fira.maturities(maturity);
        assertEq(bAfter, bBefore + bondAmount, "Bucket b should increase");
    }

    /// @dev Borrow transfers cash to user
    function test_borrow_userReceivesCash() public {
        uint256 cashBefore = cash.balanceOf(borrower);
        uint256 bondAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.borrow({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        uint256 cashAfter = cash.balanceOf(borrower);
        assertGt(cashAfter, cashBefore, "Borrower should receive cash");
    }

    /// @dev Borrow emits Borrowed event with correct params
    function test_borrow_emitsBorrowedEvent() public {
        uint256 bondAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});

        vm.expectEmit(true, true, false, false);
        emit Fira.Borrowed({user: borrower, maturity: maturity, bondAmount: bondAmount, cashNet: 0});

        fira.borrow({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////
    ///                    Lend Tests                          ///
    //////////////////////////////////////////////////////////////

    /// @dev Lend increases pool liquidity (yLiq)
    function test_lend_increasesYLiq() public {
        uint256 yLiqBefore = fira.yLiq();
        uint256 bondAmount = 100e18;

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.lend({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        uint256 yLiqAfter = fira.yLiq();
        assertGt(yLiqAfter, yLiqBefore, "yLiq should increase after lend");
    }

    /// @dev Lend mints bond tokens to user
    function test_lend_mintsBonds() public {
        uint256 bondsBefore = bondToken.balanceOf({owner: lender, id: maturity});
        uint256 bondAmount = 100e18;

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.lend({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        uint256 bondsAfter = bondToken.balanceOf({owner: lender, id: maturity});
        assertEq(bondsAfter, bondsBefore + bondAmount, "Lender should receive bonds");
    }

    /// @dev Lend increases maturity bucket l (lender notional)
    function test_lend_increasesBucketL() public {
        (,, uint256 lBefore) = fira.maturities(maturity);
        uint256 bondAmount = 100e18;

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.lend({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();

        (,, uint256 lAfter) = fira.maturities(maturity);
        assertEq(lAfter, lBefore + bondAmount, "Bucket l should increase");
    }

    /// @dev Lend emits Lent event with correct params
    function test_lend_emitsLentEvent() public {
        uint256 bondAmount = 100e18;

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});

        vm.expectEmit(true, true, false, false);
        emit Fira.Lent({user: lender, maturity: maturity, bondAmount: bondAmount, cashNet: 0});

        fira.lend({maturity: maturity, bondAmount: bondAmount});
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////
    ///                   Settlement Tests                     ///
    //////////////////////////////////////////////////////////////

    /// @dev At maturity (τ=0), repay is 1:1 (cash = bondAmount)
    function test_repay_atMaturity_isOneToOne() public {
        // Setup: borrower has a position (b > 0)
        uint256 borrowAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.borrow({maturity: maturity, bondAmount: borrowAmount});
        vm.stopPrank();

        // Expire the maturity (hint=0 since it's head)
        vm.warp(maturity);
        fira.expireMaturity({maturity: maturity, hint: 0});

        // Get borrower's position (in WAD)
        (, uint256 bPosition,) = fira.maturities(maturity);
        assertEq(bPosition, borrowAmount, "b should equal borrowed amount");

        // Borrower needs cash to repay
        // At tau=0, repay amount in native decimals = bPosition / DECIMAL_SCALE
        uint256 repayAmountNative = borrowAmount / 1e12; // Convert WAD to 6 decimals
        cash.mint({to: borrower, amount: repayAmountNative});

        uint256 cashBefore = cash.balanceOf(borrower);

        vm.startPrank(borrower);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.repay({maturity: maturity, amount: repayAmountNative});
        vm.stopPrank();

        uint256 cashAfter = cash.balanceOf(borrower);

        // At settlement (tau=0), should be 1:1
        // Cash paid should be approximately repayAmountNative (some precision loss possible)
        assertApproxEqAbs(
            cashBefore - cashAfter,
            repayAmountNative,
            1, // 1 wei tolerance
            "Settlement should be 1:1"
        );
    }

    /// @dev At maturity (τ=0), redeem is 1:1 (cash = bondAmount)
    function test_redeem_atMaturity_isOneToOne() public {
        // Setup: lender has bonds
        uint256 lendAmount = 100e18;

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.lend({maturity: maturity, bondAmount: lendAmount});
        vm.stopPrank();

        // Expire the maturity (hint=0 since it's head)
        vm.warp(maturity);
        fira.expireMaturity({maturity: maturity, hint: 0});

        // Get lender's bond balance
        uint256 bondBalance = bondToken.balanceOf({owner: lender, id: maturity});
        assertEq(bondBalance, lendAmount, "Lender should have bonds");

        uint256 redeemAmountNative = lendAmount / 1e12; // Convert WAD to 6 decimals
        uint256 cashBefore = cash.balanceOf(lender);

        vm.startPrank(lender);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.redeem({maturity: maturity, amount: redeemAmountNative});
        vm.stopPrank();

        uint256 cashAfter = cash.balanceOf(lender);

        // At settlement (tau=0), should be 1:1
        assertApproxEqAbs(cashAfter - cashBefore, redeemAmountNative, 1, "Settlement should be 1:1");
    }

    //////////////////////////////////////////////////////////////
    ///              Maturity Management Tests                 ///
    //////////////////////////////////////////////////////////////

    /// @dev Adding first maturity sets both head and tail
    function test_addMaturity_toEmptyList() public {
        // Create a fresh Fira with no maturities
        FiraHarness freshFira = new FiraHarness(
            Fira.ConstructorParams({
                cash: address(cash),
                bond: address(bondToken),
                ns: Fira.NSParams({beta0: BETA0, beta1: BETA1, beta2: BETA2, lambda: LAMBDA}),
                cfmm: Fira.CfmmParams({
                    kappa: KAPPA, tauMin: TAU_MIN, tauMax: TAU_MAX, psiMin: PSI_MIN, psiMax: PSI_MAX
                }),
                solvency: Fira.SolvencyParams({lambdaW: LAMBDA_W, etaB: ETA_B, etaL: ETA_L, wVault: W_VAULT, rho: RHO})
            })
        );

        uint256 newMaturity = block.timestamp + SECONDS_PER_YEAR;

        freshFira.addMaturity({maturity: newMaturity, hint: 0});

        assertEq(freshFira.head(), newMaturity, "Head should be the new maturity");
        assertEq(freshFira.tail(), newMaturity, "Tail should be the new maturity");
    }

    /// @dev expireMaturity adds (b-l) to sPast for solvency tracking
    function test_expireMaturity_updatesSpast() public {
        // Setup: create positions
        uint256 borrowAmount = 200e18;
        uint256 lendAmount = 100e18;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});
        fira.borrow({maturity: maturity, bondAmount: borrowAmount});
        vm.stopPrank();

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});
        fira.lend({maturity: maturity, bondAmount: lendAmount});
        vm.stopPrank();

        // Get bucket values
        (, uint256 b, uint256 l) = fira.maturities(maturity);
        int256 expectedNet = int256(b) - int256(l); // b - l

        int256 sPastBefore = fira.sPast();

        // Warp and expire (hint=0 since it's head)
        vm.warp(maturity);
        fira.expireMaturity({maturity: maturity, hint: 0});

        int256 sPastAfter = fira.sPast();

        // sPast should increase by (b - l)
        assertEq(sPastAfter, sPastBefore + expectedNet, "sPast should update with net position");
    }

    //////////////////////////////////////////////////////////////
    ///                  Revert Tests                          ///
    //////////////////////////////////////////////////////////////

    /// @dev Borrow on non-existent maturity reverts
    function test_borrow_revertIfMaturityNotActive() public {
        uint256 inactiveMaturity = block.timestamp + 2 * SECONDS_PER_YEAR;

        vm.startPrank(borrower);
        bondToken.setApprovalForAll({operator: address(fira), isApproved: true});

        vm.expectRevert(Fira.MaturityNotActive.selector);
        fira.borrow({maturity: inactiveMaturity, bondAmount: 100e18});
        vm.stopPrank();
    }

    /// @dev Lend with τ < τ_min reverts
    function test_lend_revertIfMaturityTooSoon() public {
        uint256 soonMaturity = block.timestamp + 1 days; // Less than TAU_MIN

        fira.addMaturity({maturity: soonMaturity, hint: 0});

        vm.startPrank(lender);
        cash.approve({spender: address(fira), amount: type(uint256).max});

        vm.expectRevert(Fira.MaturityTooSoon.selector);
        fira.lend({maturity: soonMaturity, bondAmount: 100e18});
        vm.stopPrank();
    }

    /// @dev Repay before maturity expires reverts
    function test_repay_revertIfMaturityStillActive() public {
        // Try to repay before maturity is expired
        vm.startPrank(borrower);
        cash.approve({spender: address(fira), amount: type(uint256).max});

        vm.expectRevert(Fira.MaturityActive.selector);
        fira.repay({maturity: maturity, amount: 100e6});
        vm.stopPrank();
    }
}
