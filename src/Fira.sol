// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

import {CfmmMathLib} from "./libs/CfmmMathLib.sol";
import {SolvencyLib} from "./libs/SolvencyLib.sol";
import {BondToken} from "./tokens/BondToken.sol";

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

    //////////////////////////////////////////////////////////////
    ///                       Events                           ///
    //////////////////////////////////////////////////////////////

    event Borrowed(address indexed user, uint256 indexed maturity, uint256 bondAmount, uint256 cashNet);

    event Lent(address indexed user, uint256 indexed maturity, uint256 bondAmount, uint256 cashNet);

    event Repaid(address indexed user, uint256 indexed maturity, uint256 amount);

    event Redeemed(address indexed user, uint256 indexed maturity, uint256 amount);

    event MaturityExpiredEvent(uint256 indexed maturity, int256 netPosition);

    //////////////////////////////////////////////////////////////
    ///                       Immutables                       ///
    //////////////////////////////////////////////////////////////

    ERC20 public immutable CASH;
    BondToken public immutable BOND;
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

    int256 public kappa; // WAD - rate sensitivity

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
    ///                  Solvency Storage (M2)                ///
    //////////////////////////////////////////////////////////////

    /// @notice Past-due aggregate (WAD)
    int256 public sPast;

    /// @notice Total LP shares (WAD). Zero until M3.
    uint256 public nLp;

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
    ///                     Constructor                       ///
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
        int256 kappa; // Rate sensitivity (WAD)
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
        address cash;
        address bond;
        NSParams ns;
        CfmmParams cfmm;
        SolvencyParams solvency;
    }

    constructor(ConstructorParams memory p) {
        CASH = ERC20(p.cash);
        BOND = BondToken(p.bond);
        CASH_DECIMALS = ERC20(p.cash).decimals();
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
    ///                   Core Trade Functions                ///
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
        uint256 yLiqWad = yLiq * DECIMAL_SCALE;

        (uint256 XNew, uint256 yPrinNewWad) = CfmmMathLib.computeSwap({
            tau: tau, bondAmountSigned: int256(bondAmount), X: X, yWad: yPrinWad, params: _getCfmmParams()
        });

        // Liquidity check (borrow = cash goes out)
        uint256 cashOutWad = yPrinWad - yPrinNewWad;
        require(yLiqWad >= cashOutWad, InsufficientYLiq());

        // State updates
        X = XNew;
        uint256 cashOut = cashOutWad / DECIMAL_SCALE;
        yLiq -= cashOut;
        maturities[maturity].b += bondAmount;

        // Solvency check
        _checkSolvency();

        // Token transfers
        BOND.burn({from: msg.sender, maturity: maturity, amount: bondAmount});
        CASH.transfer({to: msg.sender, amount: cashOut});

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

        // State updates (lend = cash comes in, no liquidity check needed)
        X = XNew;
        uint256 cashInWad = yPrinNewWad - yPrinWad;
        uint256 cashIn = cashInWad / DECIMAL_SCALE;
        yLiq += cashIn;
        maturities[maturity].l += bondAmount;

        // Solvency check
        _checkSolvency();

        // Token transfers
        CASH.transferFrom({from: msg.sender, to: address(this), amount: cashIn});
        BOND.mint({to: msg.sender, maturity: maturity, amount: bondAmount});

        emit Lent({user: msg.sender, maturity: maturity, bondAmount: bondAmount, cashNet: cashIn});
    }

    //////////////////////////////////////////////////////////////
    ///                 Settlement Functions                  ///
    //////////////////////////////////////////////////////////////

    /// @notice Repay borrowed bonds at/after maturity.
    ///
    /// @dev Settlement at τ=0 (p(0)=1). Updates b and sPast incrementally (O(1)).
    ///      Requires maturity to be expired first via expireMaturity().
    ///      Underflows if amount > position (Solidity 0.8+ automatic check).
    ///
    /// @param maturity Maturity timestamp (seconds).
    /// @param amount Amount to repay (native decimals).
    function repay(uint256 maturity, uint256 amount) external {
        require(!_isActive({maturity: maturity}), MaturityActive());

        uint256 amountWad = amount * DECIMAL_SCALE;

        // Execute pure CFMM swap (settlement at tau=0)
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;

        (uint256 XNew, uint256 yPrinNewWad) = CfmmMathLib.computeSwap({
            tau: 0, bondAmountSigned: -int256(amountWad), X: X, yWad: yPrinWad, params: _getCfmmParams()
        });

        // State updates (repay = cash comes in, no liquidity check needed)
        X = XNew;
        uint256 cashInWad = yPrinNewWad - yPrinWad;
        uint256 cashIn = cashInWad / DECIMAL_SCALE;
        yLiq += cashIn;
        maturities[maturity].b -= amountWad; // Reverts if maturity does not exist
        sPast -= int256(amountWad);

        // Solvency check
        _checkSolvency();

        // Token transfers
        CASH.transferFrom({from: msg.sender, to: address(this), amount: cashIn});
        BOND.mint({to: msg.sender, maturity: maturity, amount: amountWad});

        emit Repaid({user: msg.sender, maturity: maturity, amount: amount});
    }

    /// @notice Redeem lent bonds at/after maturity.
    ///
    /// @dev Settlement at τ=0 (p(0)=1). Updates l and sPast incrementally (O(1)).
    ///      Requires maturity to be expired first via expireMaturity().
    ///      Underflows if amount > position (Solidity 0.8+ automatic check).
    ///
    /// @param maturity Maturity timestamp (seconds).
    /// @param amount Amount to redeem (native decimals).
    function redeem(uint256 maturity, uint256 amount) external {
        require(!_isActive({maturity: maturity}), MaturityActive());

        uint256 amountWad = amount * DECIMAL_SCALE;

        // Execute pure CFMM swap (settlement at tau=0)
        uint256 yPrinWad = (yLiq + yVault) * DECIMAL_SCALE;
        uint256 yLiqWad = yLiq * DECIMAL_SCALE;

        (uint256 XNew, uint256 yPrinNewWad) = CfmmMathLib.computeSwap({
            tau: 0, bondAmountSigned: int256(amountWad), X: X, yWad: yPrinWad, params: _getCfmmParams()
        });

        // Liquidity check (redeem = cash goes out)
        uint256 cashOutWad = yPrinWad - yPrinNewWad;
        require(yLiqWad >= cashOutWad, InsufficientYLiq());

        // State updates
        X = XNew;
        uint256 cashOut = cashOutWad / DECIMAL_SCALE;
        yLiq -= cashOut;
        maturities[maturity].l -= amountWad; // Reverts if maturity does not exist
        sPast += int256(amountWad);

        // Solvency check
        _checkSolvency();

        // Token transfers
        BOND.burn({from: msg.sender, maturity: maturity, amount: amountWad});
        CASH.transfer({to: msg.sender, amount: cashOut});

        emit Redeemed({user: msg.sender, maturity: maturity, amount: amount});
    }

    //////////////////////////////////////////////////////////////
    ///            Maturity Linked-List Management            ///
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
    ///                 Internal Helpers                      ///
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
        int256 minERisk = eRisk;

        // 2. Iterate over maturities (sorted by tau ascending)
        uint256 current = head;
        while (current != 0) {
            MaturityNode storage node = maturities[current];

            int256 net = SolvencyLib.computeWeightedNet({
                tau: current - block.timestamp, b: node.b, l: node.l, lambdaW: lambdaW, etaB: etaB, etaL: etaL
            });

            eRisk += net;
            if (eRisk < minERisk) minERisk = eRisk;

            current = node.next;
        }

        // 3. Check floor
        SolvencyLib.checkFloor({minERisk: minERisk, rho: rho, nLp: nLp});
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
