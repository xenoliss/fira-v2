// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";

import {CfmmMathLib} from "./libs/CfmmMathLib.sol";
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

    /// @notice Node in the maturity doubly-linked list
    struct MaturityNode {
        uint256 prev; // Previous maturity timestamp (0 if head)
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

    //////////////////////////////////////////////////////////////
    ///                     Constructor                       ///
    //////////////////////////////////////////////////////////////

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
    ) {
        CASH = ERC20(cash);
        BOND = BondToken(bond);
        CASH_DECIMALS = ERC20(cash).decimals();
        DECIMAL_SCALE = 10 ** (18 - CASH_DECIMALS);

        beta0 = beta0_;
        beta1 = beta1_;
        beta2 = beta2_;
        lambda = lambda_;
        kappa = kappa_;

        tauMin = tauMin_;
        tauMax = tauMax_;
        psiMin = psiMin_;
        psiMax = psiMax_;
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

        (uint256 XNew, int256 cashAmountSignedWad) = CfmmMathLib.computeSwap({
            tau: tau,
            bondAmountSigned: int256(bondAmount),
            X: X,
            yPrinWad: yPrinWad,
            yLiqWad: yLiqWad,
            params: _getCfmmParams()
        });

        // State updates
        X = XNew;
        uint256 cashOutWad = uint256(-cashAmountSignedWad);
        uint256 cashOut = cashOutWad / DECIMAL_SCALE;
        yLiq -= cashOut;
        maturities[maturity].b += bondAmount;

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
        uint256 yLiqWad = yLiq * DECIMAL_SCALE;

        (uint256 XNew, int256 cashAmountSignedWad) = CfmmMathLib.computeSwap({
            tau: tau,
            bondAmountSigned: -int256(bondAmount),
            X: X,
            yPrinWad: yPrinWad,
            yLiqWad: yLiqWad,
            params: _getCfmmParams()
        });

        // State updates
        X = XNew;
        uint256 cashInWad = uint256(cashAmountSignedWad);
        uint256 cashIn = cashInWad / DECIMAL_SCALE;
        yLiq += cashIn;
        maturities[maturity].l += bondAmount;

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
        uint256 yLiqWad = yLiq * DECIMAL_SCALE;

        (uint256 XNew, int256 cashAmountSignedWad) = CfmmMathLib.computeSwap({
            tau: 0,
            bondAmountSigned: -int256(amountWad),
            X: X,
            yPrinWad: yPrinWad,
            yLiqWad: yLiqWad,
            params: _getCfmmParams()
        });

        // State updates
        X = XNew;
        uint256 cashInWad = uint256(cashAmountSignedWad);
        uint256 cashIn = cashInWad / DECIMAL_SCALE;
        yLiq += cashIn;
        maturities[maturity].b -= amountWad; // Reverts if maturity does not exist
        sPast -= int256(amountWad);

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

        (uint256 XNew, int256 cashAmountSignedWad) = CfmmMathLib.computeSwap({
            tau: 0,
            bondAmountSigned: int256(amountWad),
            X: X,
            yPrinWad: yPrinWad,
            yLiqWad: yLiqWad,
            params: _getCfmmParams()
        });

        // State updates
        X = XNew;
        uint256 cashOutWad = uint256(-cashAmountSignedWad);
        uint256 cashOut = cashOutWad / DECIMAL_SCALE;
        yLiq -= cashOut;
        maturities[maturity].l -= amountWad; // Reverts if maturity does not exist
        sPast += int256(amountWad);

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
            maturities[head].prev = maturity;
            maturities[maturity].next = head;
            head = maturity;
            return;
        }

        // Verify hint
        require(hint < maturity, InvalidHint());
        require(_isActive({maturity: hint}), InvalidHint());

        uint256 nextNode = maturities[hint].next;
        require(nextNode == 0 || nextNode > maturity, InvalidHint());

        // Insert after hint
        maturities[maturity].prev = hint;
        maturities[maturity].next = nextNode;
        maturities[hint].next = maturity;

        if (nextNode != 0) {
            maturities[nextNode].prev = maturity;
        } else {
            tail = maturity;
        }
    }

    /// @notice Expire a maturity by removing it from the active list
    ///
    /// @dev Moves (l_k - b_k) into S_past aggregate (O(1))
    ///      Removes from linked list but keeps b and l in mapping for settlement
    ///
    /// @param maturity Maturity timestamp to expire
    function expireMaturity(uint256 maturity) external {
        require(block.timestamp >= maturity, MaturityNotReached());
        require(_isActive({maturity: maturity}), MaturityNotActive());

        MaturityNode storage node = maturities[maturity];

        // 1. Roll net position into S_past (b - l)
        int256 net = int256(node.b) - int256(node.l);
        sPast += net;

        // 2. Remove from linked list (O(1))
        if (head == maturity) {
            // Expiring the head node
            head = node.next;
            if (node.next != 0) {
                maturities[node.next].prev = 0;
            } else {
                // List is now empty
                tail = 0;
            }
        } else {
            // Not the head, update prev node's next pointer
            maturities[node.prev].next = node.next;
            if (node.next != 0) {
                maturities[node.next].prev = node.prev;
            } else {
                // Expiring the tail node
                tail = node.prev;
            }
        }

        // Clear prev/next pointers (but keep b and l for settlement)
        node.prev = 0;
        node.next = 0;

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

    /// @notice Check if a maturity is in the active linked list.
    ///
    /// @dev Returns true if maturity is tracked in the list. Note that a maturity
    ///      can be "active" (in the list) even if block.timestamp >= maturity.
    ///      Use expireMaturity() to remove past-due maturities from the list.
    ///
    /// @param maturity Maturity timestamp (seconds).
    ///
    /// @return True if maturity is in the active list.
    function _isActive(uint256 maturity) internal view returns (bool) {
        if (head == maturity || tail == maturity) return true;

        MaturityNode storage node = maturities[maturity];
        return node.prev != 0 || node.next != 0;
    }
}
