// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

import {CfmmMathLib} from "./libs/CfmmMathLib.sol";
import {LpLib} from "./libs/LpLib.sol";
import {SolvencyLib} from "./libs/SolvencyLib.sol";
import {BondToken} from "./tokens/BondToken.sol";
import {LpToken} from "./tokens/LpToken.sol";

/// @title Fira - TS-BondMM v2.2.1
///
/// @notice CFMM for zero-coupon bonds with Nelson-Siegel term structure.
contract Fira {
    //////////////////////////////////////////////////////////////
    ///                       Errors                           ///
    //////////////////////////////////////////////////////////////

    error MaturityTooSoon();
    error MaturityTooFar();
    error MaturityNotActive();
    error MaturityActive();
    error InvalidHint();
    error MaturityNotReached();
    error InsufficientYLiq();
    error ZeroDeposit();

    //////////////////////////////////////////////////////////////
    ///                       Events                           ///
    //////////////////////////////////////////////////////////////

    event Borrowed(address indexed user, uint256 indexed maturity, uint256 bondAmount, uint256 cashNet);

    event Lent(address indexed user, uint256 indexed maturity, uint256 bondAmount, uint256 cashNet);

    event Repaid(address indexed user, uint256 indexed maturity, uint256 bondAmount);

    event Redeemed(address indexed user, uint256 indexed maturity, uint256 bondAmount);

    event MaturityExpiredEvent(uint256 indexed maturity, int256 netPosition);

    event Deposited(address indexed user, uint256 amount, uint256 shares);

    //////////////////////////////////////////////////////////////
    ///                       Immutables                       ///
    //////////////////////////////////////////////////////////////

    ERC20 public immutable CASH_TOKEN;
    BondToken public immutable BOND_TOKEN;
    LpToken public immutable LP_TOKEN;
    uint8 public immutable CASH_DECIMALS;
    uint256 public immutable DECIMAL_SCALE; // 10^(18 - CASH_DECIMALS)

    //////////////////////////////////////////////////////////////
    ///                    CFMM State                         ///
    //////////////////////////////////////////////////////////////

    /// @notice Shadow reserve (WAD)
    uint256 public X;

    /// @notice Liquid principal in pool (native decimals)
    uint256 public yLiq;

    /// @notice Realized P&L (native decimals)
    uint256 public yPnl;

    /// @notice Principal in vault (native decimals, =0 for M1-M4)
    uint256 public yVault;

    //////////////////////////////////////////////////////////////
    ///                  Nelson-Siegel Parameters             ///
    //////////////////////////////////////////////////////////////

    int256 public beta0; // WAD
    int256 public beta1; // WAD
    int256 public beta2; // WAD
    uint256 public lambda; // seconds

    //////////////////////////////////////////////////////////////
    ///                  Pricing Parameters                   ///
    //////////////////////////////////////////////////////////////

    uint256 public kappa; // WAD - rate sensitivity (κ > 0)

    uint256 public tauMin; // seconds
    uint256 public tauMax; // seconds

    uint256 public psiMin; // WAD - yield band
    uint256 public psiMax; // WAD

    //////////////////////////////////////////////////////////////
    ///                  Maturity Buckets                     ///
    //////////////////////////////////////////////////////////////

    /// @notice Node in the maturity singly-linked list
    struct MaturityNode {
        uint256 next; // Next maturity timestamp (0 if tail)
        uint256 b; // Borrower notional (WAD)
        uint256 l; // Lender notional (WAD)
    }

    /// @notice Earliest active maturity (head of linked list)
    uint256 public head;

    /// @notice Latest active maturity (tail of linked list)
    uint256 public tail;

    /// @notice Mapping from maturity timestamp to its node
    mapping(uint256 maturity => MaturityNode) public maturities;

    //////////////////////////////////////////////////////////////
    ///                     Solvency Storage                   ///
    //////////////////////////////////////////////////////////////

    /// @notice Past-due aggregate (WAD)
    int256 public sPast;

    /// @notice Weight decay timescale (seconds)
    uint256 public lambdaW;

    /// @notice Borrower weight haircut (WAD, 0 to 1)
    int256 public etaB;

    /// @notice Lender weight premium (WAD, >= 0)
    int256 public etaL;

    /// @notice Vault weight for solvency (WAD, 0 to 1)
    int256 public wVault;

    /// @notice Solvency floor per LP share (WAD)
    int256 public rho;

    //////////////////////////////////////////////////////////////
    ///                      Constructor                       ///
    //////////////////////////////////////////////////////////////

    /// @notice Nelson-Siegel term structure parameters
    struct NSParams {
        int256 beta0; // Long-term rate (WAD)
        int256 beta1; // Slope (WAD)
        int256 beta2; // Curvature (WAD)
        uint256 lambda; // Decay timescale (seconds)
    }

    /// @notice CFMM pricing parameters
    struct CfmmParams {
        uint256 kappa; // Rate sensitivity (WAD)
        uint256 tauMin; // Minimum time to maturity (seconds)
        uint256 tauMax; // Maximum time to maturity (seconds)
        uint256 psiMin; // Minimum utilization ratio (WAD)
        uint256 psiMax; // Maximum utilization ratio (WAD)
    }

    /// @notice Solvency check parameters
    struct SolvencyParams {
        uint256 lambdaW; // Weight decay timescale (seconds)
        int256 etaB; // Borrower haircut (WAD)
        int256 etaL; // Lender premium (WAD)
        int256 wVault; // Vault weight (WAD)
        int256 rho; // Floor per LP share (WAD)
    }

    /// @notice Constructor parameters grouped by concern
    struct ConstructorParams {
        address cashToken;
        address bondToken;
        address lpToken;
        NSParams ns;
        CfmmParams cfmm;
        SolvencyParams solvency;
    }

    constructor(ConstructorParams memory p) {
        CASH_TOKEN = ERC20(p.cashToken);
        BOND_TOKEN = BondToken(p.bondToken);
        LP_TOKEN = LpToken(p.lpToken);
        CASH_DECIMALS = ERC20(p.cashToken).decimals();
        DECIMAL_SCALE = 10 ** (18 - CASH_DECIMALS);

        beta0 = p.ns.beta0;
        beta1 = p.ns.beta1;
        beta2 = p.ns.beta2;
        lambda = p.ns.lambda;

        kappa = p.cfmm.kappa;
        tauMin = p.cfmm.tauMin;
        tauMax = p.cfmm.tauMax;
        psiMin = p.cfmm.psiMin;
        psiMax = p.cfmm.psiMax;

        lambdaW = p.solvency.lambdaW;
        etaB = p.solvency.etaB;
        etaL = p.solvency.etaL;
        wVault = p.solvency.wVault;
        rho = p.solvency.rho;
    }

    //////////////////////////////////////////////////////////////
    ///                   Core Trade Functions                 ///
    //////////////////////////////////////////////////////////////

    /// @notice Execute a borrow trade (user sells bonds to pool)
    ///
    /// @dev Pattern: swapExactBondForCash
    ///      - Input: exact bondAmount (user specifies how many bonds to sell)
    ///      - Output: variable cashOut (amount of cash received depends on current price)
    ///
    /// @param maturity Maturity timestamp
    /// @param bondAmount Face value of bonds to sell (WAD)
    function borrow(uint256 maturity, uint256 bondAmount) external {
        // Validate maturity
        uint256 tau = _checkedTau({maturity: maturity});

        // Execute pure CFMM swap
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;

        (uint256 XNew, uint256 yPrinNewWad) = CfmmMathLib.computeSwap({
            tau: tau, bondAmountSigned: int256(bondAmount), X: X, yWad: yPrinWad, params: _getCfmmParams()
        });

        // Liquidity check (borrow = cash goes out)
        uint256 cashOutWad = yPrinWad - yPrinNewWad;
        uint256 cashOut = cashOutWad / DECIMAL_SCALE; // Round DOWN to protect protocol
        require(yLiq >= cashOut, InsufficientYLiq());

        // State updates
        X = XNew;
        yLiq -= cashOut;
        maturities[maturity].b += bondAmount;

        // Solvency check
        _checkSolvency();

        // Token transfers
        BOND_TOKEN.burn({from: msg.sender, maturity: maturity, amount: bondAmount});
        CASH_TOKEN.transfer({to: msg.sender, amount: cashOut});

        emit Borrowed({user: msg.sender, maturity: maturity, bondAmount: bondAmount, cashNet: cashOut});
    }

    /// @notice Execute a lend trade (user buys bonds from pool)
    ///
    /// @dev Pattern: swapCashForExactBond
    ///      - Input: exact bondAmount (user specifies how many bonds to buy)
    ///      - Output: variable cashIn (amount of cash required depends on current price)
    ///
    /// @param maturity Maturity timestamp
    /// @param bondAmount Face value of bonds to buy (WAD)
    function lend(uint256 maturity, uint256 bondAmount) external {
        // Validate maturity
        uint256 tau = _checkedTau({maturity: maturity});

        // Execute pure CFMM swap
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;

        (uint256 XNew, uint256 yPrinNewWad) = CfmmMathLib.computeSwap({
            tau: tau, bondAmountSigned: -int256(bondAmount), X: X, yWad: yPrinWad, params: _getCfmmParams()
        });

        uint256 cashInWad = yPrinNewWad - yPrinWad;
        uint256 cashIn = (cashInWad + DECIMAL_SCALE - 1) / DECIMAL_SCALE; // Round UP to protect protocol

        // State updates (lend = cash comes in, no liquidity check needed)
        X = XNew;
        yLiq += cashIn;
        maturities[maturity].l += bondAmount;

        // Solvency check
        _checkSolvency();

        // Token transfers
        CASH_TOKEN.transferFrom({from: msg.sender, to: address(this), amount: cashIn});
        BOND_TOKEN.mint({to: msg.sender, maturity: maturity, amount: bondAmount});

        emit Lent({user: msg.sender, maturity: maturity, bondAmount: bondAmount, cashNet: cashIn});
    }

    //////////////////////////////////////////////////////////////
    ///                 Settlement Functions                   ///
    //////////////////////////////////////////////////////////////

    // FIXME: There is a vuln here where anyone can call repay which decreases maturities[maturity].b
    //        and prevents legitimate borrowers from repaying their bonds (because maturities[maturity].b will
    //        underflow).
    //
    //        This might be fixable by only allowing users with actual position in the external Collateral System to
    //        repay. Either Fira queries the Collateral System for the user's position, or we make it so that only the
    //        Collateral System can call repay on Fira's contract.

    /// @notice Repay borrowed bonds at/after maturity.
    ///
    /// @dev Settlement at τ=0 (p(0)=1). Updates b and sPast incrementally (O(1)).
    ///      Requires maturity to be expired first via expireMaturity().
    ///
    /// @param maturity Maturity timestamp (seconds).
    /// @param bondAmount Face value of bonds to repay (WAD).
    function repay(uint256 maturity, uint256 bondAmount) external {
        require(!_isActive({maturity: maturity}), MaturityActive());

        // At settlement (τ=0), price = 1
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;

        uint256 XNew = CfmmMathLib.computeSwapAtSettlement({
            bondAmountSigned: -int256(bondAmount), X: X, yWad: yPrinWad, psiMin: psiMin, psiMax: psiMax
        });

        uint256 cashIn = (bondAmount + DECIMAL_SCALE - 1) / DECIMAL_SCALE; // Round UP to protect protocol

        // State updates (repay = cash comes in, no liquidity check needed)
        X = XNew;
        yLiq += cashIn;
        maturities[maturity].b -= bondAmount; // Reverts if maturity does not exist
        sPast -= int256(bondAmount);

        // Solvency check
        _checkSolvency();

        // Token transfers
        CASH_TOKEN.transferFrom({from: msg.sender, to: address(this), amount: cashIn});
        BOND_TOKEN.mint({to: msg.sender, maturity: maturity, amount: bondAmount});

        emit Repaid({user: msg.sender, maturity: maturity, bondAmount: bondAmount});
    }

    /// @notice Redeem lent bonds at/after maturity.
    ///
    /// @dev Settlement at τ=0 (p(0)=1). Updates l and sPast incrementally (O(1)).
    ///      Requires maturity to be expired first via expireMaturity().
    ///
    /// @param maturity Maturity timestamp (seconds).
    /// @param bondAmount Face value of bonds to redeem (WAD).
    function redeem(uint256 maturity, uint256 bondAmount) external {
        require(!_isActive({maturity: maturity}), MaturityActive());

        // At settlement (τ=0), price = 1
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;

        uint256 XNew = CfmmMathLib.computeSwapAtSettlement({
            bondAmountSigned: int256(bondAmount), X: X, yWad: yPrinWad, psiMin: psiMin, psiMax: psiMax
        });

        // Liquidity check (redeem = cash goes out)
        uint256 cashOut = bondAmount / DECIMAL_SCALE; // Round DOWN to protect protocol
        require(yLiq >= cashOut, InsufficientYLiq());

        // State updates
        X = XNew;
        yLiq -= cashOut;
        maturities[maturity].l -= bondAmount; // Reverts if maturity does not exist
        sPast += int256(bondAmount);

        // Solvency check
        _checkSolvency();

        // Token transfers
        BOND_TOKEN.burn({from: msg.sender, maturity: maturity, amount: bondAmount});
        CASH_TOKEN.transfer({to: msg.sender, amount: cashOut});

        emit Redeemed({user: msg.sender, maturity: maturity, bondAmount: bondAmount});
    }

    //////////////////////////////////////////////////////////////
    ///                    LP Functions                        ///
    //////////////////////////////////////////////////////////////

    /// @notice Deposit cash to receive LP tokens.
    ///
    /// @dev Off-curve operation: scales (X, yPrin) to preserve psi (utilization ratio ψ = X / yPrin).
    ///      Bootstrap (LP_TOKEN.totalSupply() = 0): mints 1:1 shares, sets X = yPrin (psi = 1).
    ///      Mints LpToken ERC20 to the depositor.
    ///
    /// @param amount Amount of cash to deposit (native decimals).
    function deposit(uint256 amount) external {
        require(amount > 0, ZeroDeposit());

        // Compute sum of (b - l) over active maturities
        int256 sumBucketNet;
        {
            uint256 current = head;
            while (current != 0) {
                sumBucketNet += int256(maturities[current].b) - int256(maturities[current].l);
                current = maturities[current].next;
            }
        }

        // Compute deposit
        uint256 yPrinOldWad = (yLiq + yVault) * DECIMAL_SCALE;
        (uint256 sharesToMint, uint256 XNew) = LpLib.computeDeposit({
            enom: LpLib.EnomParams({
                yLiqWad: yLiq * DECIMAL_SCALE,
                yPnlWad: yPnl * DECIMAL_SCALE,
                yVaultWad: yVault * DECIMAL_SCALE,
                sPast: sPast,
                sumBucketNet: sumBucketNet
            }),
            X: X,
            nLp: LP_TOKEN.totalSupply(),
            depositWad: amount * DECIMAL_SCALE,
            yPrinOldWad: yPrinOldWad
        });

        // State updates
        yLiq += amount;
        X = XNew;

        // Interactions
        CASH_TOKEN.transferFrom({from: msg.sender, to: address(this), amount: amount});
        LP_TOKEN.mint({to: msg.sender, amount: sharesToMint});

        emit Deposited({user: msg.sender, amount: amount, shares: sharesToMint});
    }

    //////////////////////////////////////////////////////////////
    ///            Maturity Linked-List Management             ///
    //////////////////////////////////////////////////////////////

    /// @notice Add a new maturity to the active list
    ///
    /// @dev Permissionless for now. TODO: Add onlyOwner modifier for production.
    ///      Maturities must be added before trading can occur at that maturity.
    ///
    /// @param maturity Maturity timestamp to add
    /// @param hint Hint for insertion position (0 for auto-find or head insertion)
    function addMaturity(uint256 maturity, uint256 hint) external {
        require(!_isActive({maturity: maturity}), MaturityActive());

        // Empty list
        if (head == 0) {
            require(hint == 0, InvalidHint());
            head = maturity;
            tail = maturity;
            return;
        }

        // Insert at head (hint = 0)
        if (hint == 0) {
            require(maturity < head, InvalidHint());
            maturities[maturity].next = head;
            head = maturity;
            return;
        }

        // Verify hint and insert after
        require(hint < maturity, InvalidHint());
        require(_isActive({maturity: hint}), InvalidHint());

        uint256 nextNode = maturities[hint].next;
        require(nextNode == 0 || nextNode > maturity, InvalidHint());

        maturities[maturity].next = nextNode;
        maturities[hint].next = maturity;

        if (nextNode == 0) {
            tail = maturity;
        }
    }

    /// @notice Expire a maturity by removing it from the active list
    ///
    /// @dev Moves (b_k - l_k) into S_past aggregate (O(1))
    ///      Removes from linked list but keeps b and l in mapping for settlement
    ///
    /// @param maturity Maturity timestamp to expire
    /// @param hint Previous node in the list (0 if maturity is head)
    function expireMaturity(uint256 maturity, uint256 hint) external {
        require(block.timestamp >= maturity, MaturityNotReached());
        require(_isActive({maturity: maturity}), MaturityNotActive());

        // Remove from linked list
        if (head == maturity) {
            head = maturities[maturity].next;
            if (head == 0) tail = 0;
        } else {
            require(maturities[hint].next == maturity, InvalidHint());
            maturities[hint].next = maturities[maturity].next;
            if (tail == maturity) tail = hint;
        }

        // Update state
        maturities[maturity].next = 0;

        // Roll net position into S_past (b - l)
        int256 net = int256(maturities[maturity].b) - int256(maturities[maturity].l);
        sPast += net;

        emit MaturityExpiredEvent({maturity: maturity, netPosition: net});
    }

    //////////////////////////////////////////////////////////////
    ///                 Internal Helpers                       ///
    //////////////////////////////////////////////////////////////

    /// @notice Get CFMM parameters for pure computation
    ///
    /// @return params CFMM parameters struct
    function _getCfmmParams() internal view returns (CfmmMathLib.CfmmParams memory params) {
        params = CfmmMathLib.CfmmParams({
            beta0: beta0, beta1: beta1, beta2: beta2, lambda: lambda, kappa: kappa, psiMin: psiMin, psiMax: psiMax
        });
    }

    /// @notice Compute and validate tau for trading
    ///
    /// @dev Computes tau and validates bounds and active status.
    ///      Reverts if maturity is in past (underflow on subtraction).
    ///
    /// @param maturity Maturity timestamp
    ///
    /// @return tau Time to maturity (seconds), validated
    function _checkedTau(uint256 maturity) internal view returns (uint256 tau) {
        tau = maturity - block.timestamp;
        require(tau >= tauMin, MaturityTooSoon());
        require(tau <= tauMax, MaturityTooFar());
        require(_isActive({maturity: maturity}), MaturityNotActive());
    }

    /// @notice Check solvency floor after state changes.
    ///
    /// @dev Iterates directly over maturity linked list.
    ///      E_risk = y_liq + y_pnl + w_vault·y_vault + S_past + Σ(w_b(τ)·b - w_l(τ)·l)
    function _checkSolvency() internal view {
        // 1. Compute base equity
        int256 eRisk = SolvencyLib.computeBaseEquity({
            yLiqWad: yLiq * DECIMAL_SCALE,
            yPnlWad: yPnl * DECIMAL_SCALE,
            yVaultWad: yVault * DECIMAL_SCALE,
            wVault: wVault,
            sPast: sPast
        });
        int256 minErisk = eRisk;

        // 2. Iterate over maturities (sorted by tau ascending)
        uint256 current = head;
        while (current != 0) {
            MaturityNode storage node = maturities[current];

            int256 net = SolvencyLib.computeWeightedNet({
                tau: current - block.timestamp, b: node.b, l: node.l, lambdaW: lambdaW, etaB: etaB, etaL: etaL
            });

            eRisk += net;
            if (eRisk < minErisk) minErisk = eRisk;

            current = node.next;
        }

        // 3. Check floor
        SolvencyLib.checkFloor({minErisk: minErisk, rho: rho, nLp: LP_TOKEN.totalSupply()});
    }

    /// @notice Check if a maturity is in the active linked list.
    ///
    /// @dev Derived from linked list structure: active if has successor or is tail.
    ///
    /// @param maturity Maturity timestamp (seconds).
    ///
    /// @return True if maturity is in the active list.
    function _isActive(uint256 maturity) internal view returns (bool) {
        return maturities[maturity].next != 0 || maturity == tail;
    }
}
