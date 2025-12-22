#!/usr/bin/env python3
"""
Generate test values for SolvencyLib functions.

Functions tested:
  1. computeBaseEquity: E_base = yLiq + yPnl + w_vault·yVault + sPast
  2. computeWeightedNet: net = w_b(τ)·b - w_l(τ)·l

Weight formulas:
  φ(τ) = 1 - e^(-τ/λ)
  w_b(τ) = 1 - η_b·φ(τ)   (discount on bonds)
  w_l(τ) = 1 + η_l·φ(τ)   (premium on liabilities)

Special cases:
  - τ=0: φ=0, so w_b=1, w_l=1, net = b - l
  - τ→∞: φ→1, so w_b→(1-η_b), w_l→(1+η_l)
"""
import math


def compute_phi(tau: float, lambda_: float) -> float:
    """Compute φ(τ) = 1 - e^(-τ/λ)."""
    if tau == 0:
        return 0.0
    return 1 - math.exp(-tau / lambda_)


def compute_weighted_net(tau: float, b: float, l: float, lambda_: float, eta_b: float, eta_l: float) -> float:
    """Compute weighted net = w_b·b - w_l·l."""
    if tau == 0:
        return b - l
    phi = compute_phi(tau, lambda_)
    w_b = 1 - eta_b * phi
    w_l = 1 + eta_l * phi
    return w_b * b - w_l * l


def compute_base_equity(y_liq: float, y_pnl: float, y_vault: float, w_vault: float, s_past: float) -> float:
    """Compute base equity = yLiq + yPnl + w_vault·yVault + sPast."""
    return y_liq + y_pnl + w_vault * y_vault + s_past


def print_weighted_net(tau: float, b: float, l: float, lambda_: float, eta_b: float, eta_l: float) -> None:
    """Print a computeWeightedNet test case."""
    expected = compute_weighted_net(tau, b, l, lambda_, eta_b, eta_l)
    print(f"  tau={tau}, b={b}, l={l}, lambda={lambda_}, etaB={eta_b}, etaL={eta_l} => {expected}")


def print_base_equity(y_liq: float, y_pnl: float, y_vault: float, w_vault: float, s_past: float) -> None:
    """Print a computeBaseEquity test case."""
    expected = compute_base_equity(y_liq, y_pnl, y_vault, w_vault, s_past)
    print(f"  yLiq={y_liq}, yPnl={y_pnl}, yVault={y_vault}, wVault={w_vault}, sPast={s_past} => {expected}")


def main() -> None:
    # Standard maturities (in years) - matches Solidity day counts
    STANDARD_TAUS = [1/365, 7/365, 30/365, 91/365, 182/365, 1, 2, 5, 10]

    print("=" * 70)
    print("computeWeightedNet TEST CASES")
    print("=" * 70)

    # ═══════════════════════════════════════════════════════════════════════
    # τ=0 (Instant Maturity)
    # At τ=0, φ=0, so w_b=1, w_l=1, net = b - l
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 1: tau=0 (phi=0, net = b - l) ===")
    for b, l in [(100, 50), (50, 100), (100, 100), (1000, 0), (0, 1000), (500, 200), (200, 500), (1, 1)]:
        print_weighted_net(0, b, l, 1, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # τ=λ (Characteristic Time)
    # At τ=λ, φ = 1 - e^(-1) ≈ 0.632
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 2: tau=lambda (phi ~ 0.632) ===")
    for b, l in [(1000, 500), (500, 1000), (1000, 1000), (2000, 1000), (1000, 2000)]:
        for eta_b, eta_l in [(0.2, 0.1), (0.1, 0.1), (0.3, 0.2)]:
            print_weighted_net(1, b, l, 1, eta_b, eta_l)

    # ═══════════════════════════════════════════════════════════════════════
    # τ >> λ (Asymptotic Behavior)
    # As τ→∞, φ→1, so w_b→(1-η_b), w_l→(1+η_l)
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 3: tau >> lambda (phi -> 1) ===")
    for tau in [10, 20, 50, 100]:
        for b, l in [(1000, 500), (1000, 1000)]:
            print_weighted_net(tau, b, l, 1, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # Balanced b=l
    # Tests net behavior when bond and liability notionals are equal
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 4: Balanced b=l ===")
    for tau in STANDARD_TAUS:
        print_weighted_net(tau, 1000, 1000, 1, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # b >> l (Net Long Position)
    # Tests behavior when heavily long bonds
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 5: b >> l ===")
    for tau in STANDARD_TAUS:
        print_weighted_net(tau, 10000, 1000, 1, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # b << l (Net Short Position)
    # Tests behavior when heavily short bonds
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 6: b << l ===")
    for tau in STANDARD_TAUS:
        print_weighted_net(tau, 1000, 10000, 1, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # Lambda Variations
    # Controls decay speed of weight adjustments
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 7: Lambda variations ===")
    for lambda_ in [0.5, 1, 2, 3, 5]:
        for tau in [1, 2, 5]:
            print_weighted_net(tau, 1000, 500, lambda_, 0.2, 0.1)

    # ═══════════════════════════════════════════════════════════════════════
    # Zero Notionals (Edge Cases)
    # Tests edge cases where one side is zero (requires exp calculation)
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 8: Zero notionals (edge cases) ===")
    # b=0: net = -w_l * l (only liability, negative)
    # l=0: net = w_b * b (only bonds, positive)
    for tau in [1, 5]:
        print_weighted_net(tau, 0, 1000, 1, 0.2, 0.1)
        print_weighted_net(tau, 1000, 0, 1, 0.2, 0.1)

    print("\n")
    print("=" * 70)
    print("computeBaseEquity TEST CASES")
    print("=" * 70)

    # ═══════════════════════════════════════════════════════════════════════
    # wVault = 1 (Full Vault Weight)
    # E_base = yLiq + yPnl + yVault + sPast
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 1: wVault = 1 ===")
    for y_liq, y_pnl, y_vault, w_vault, s_past in [
        (800, 200, 500, 1.0, -100),
        (1000, 0, 500, 1.0, 0),
        (0, 500, 1000, 1.0, -200),
        (5000, 1000, 2000, 1.0, 500),
        (100, 50, 200, 1.0, -50),
    ]:
        print_base_equity(y_liq, y_pnl, y_vault, w_vault, s_past)

    # ═══════════════════════════════════════════════════════════════════════
    # wVault = 0.5 (Partial Vault Weight)
    # E_base = yLiq + yPnl + 0.5·yVault + sPast
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 2: wVault = 0.5 ===")
    for y_liq, y_pnl, y_vault, w_vault, s_past in [
        (800, 200, 500, 0.5, -100),
        (1000, 0, 1000, 0.5, 0),
        (0, 500, 2000, 0.5, -200),
        (5000, 1000, 4000, 0.5, 500),
        (100, 50, 400, 0.5, -50),
    ]:
        print_base_equity(y_liq, y_pnl, y_vault, w_vault, s_past)

    # ═══════════════════════════════════════════════════════════════════════
    # sPast Variations
    # Tests accumulated past income/loss component
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 3: sPast variations ===")
    for s_past in [-1000, -500, -100, 0, 100, 500, 1000]:
        print_base_equity(1000, 500, 500, 0.8, s_past)


if __name__ == "__main__":
    main()
