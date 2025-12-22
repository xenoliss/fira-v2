#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["nelson-siegel-svensson>=0.5.0"]
# ///
"""
Generate test values for NelsonSiegelLib.computeRStar.

Formula: r*(τ) = β₀ + β₁·f₁(τ) + β₂·f₂(τ)
where:
  f₁(τ) = (1 - e^(-τ/λ)) / (τ/λ)
  f₂(τ) = f₁(τ) - e^(-τ/λ)

Special cases:
  - τ=0: r* = β₀ + β₁ (instant rate)
  - τ/λ < 0.01: Taylor approximation f₁ ≈ 1 - (τ/λ)/2
"""
from nelson_siegel_svensson import NelsonSiegelCurve


def compute_rstar(tau: float, beta0: float, beta1: float, beta2: float, lambda_: float) -> float:
    """Compute r*(τ) using Nelson-Siegel curve."""
    if tau == 0:
        return beta0 + beta1
    curve = NelsonSiegelCurve(beta0, beta1, beta2, lambda_)
    return curve(tau)


def print_case(tau: float, beta0: float, beta1: float, beta2: float, lambda_: float) -> None:
    """Print a single test case."""
    expected = compute_rstar(tau, beta0, beta1, beta2, lambda_)
    print(f"  tau={tau}, beta0={beta0}, beta1={beta1}, beta2={beta2}, lambda={lambda_} => {expected}")


def main() -> None:
    # Standard maturities (in years) - matches Solidity day counts
    STANDARD_TAUS = [1/365, 7/365, 30/365, 91/365, 182/365, 1, 2, 5, 10, 30]

    # ═══════════════════════════════════════════════════════════════════════
    # τ=0 (Instant Rate)
    # At τ=0, f₁→1, f₂→0, so r* = β₀ + β₁
    # ═══════════════════════════════════════════════════════════════════════
    print("=== Category 1: tau=0 (r* = beta0 + beta1) ===")
    for beta0, beta1, beta2, lambda_ in [
        (0.05, -0.02, 0.01, 2),
        (0.10, 0, 0, 1),
        (0.03, 0.02, -0.01, 1),
        (0.08, -0.05, 0.03, 3),
        (0.02, 0.01, 0, 1),
    ]:
        print_case(0, beta0, beta1, beta2, lambda_)

    # ═══════════════════════════════════════════════════════════════════════
    # Flat Curve (β₁=β₂=0)
    # r*(τ) = β₀ for all maturities
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 2: Flat curve (beta1=beta2=0) ===")
    for tau in STANDARD_TAUS:
        print_case(tau, 0.05, 0, 0, 2)

    # ═══════════════════════════════════════════════════════════════════════
    # Normal Curve (β₁ < 0)
    # Upward sloping: short rates < long rates
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 3: Normal curve (beta1 < 0) ===")
    for beta0 in [0.03, 0.05, 0.08]:
        for tau in STANDARD_TAUS:
            print_case(tau, beta0, -0.02, 0.01, 2)

    # ═══════════════════════════════════════════════════════════════════════
    # Inverted Curve (β₁ > 0)
    # Downward sloping: short rates > long rates
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 4: Inverted curve (beta1 > 0) ===")
    for beta1 in [0.01, 0.02]:
        for tau in STANDARD_TAUS:
            print_case(tau, 0.05, beta1, -0.01, 1)

    # ═══════════════════════════════════════════════════════════════════════
    # Curvature Effects (β₂ ≠ 0)
    # Medium-term hump (β₂ > 0) or trough (β₂ < 0)
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 5: Curvature effects ===")
    for beta2 in [0.02, 0.03]:
        for tau in STANDARD_TAUS:
            print_case(tau, 0.05, 0, beta2, 2)

    # ═══════════════════════════════════════════════════════════════════════
    # Lambda Variations
    # Controls decay speed of β₁ and β₂ influence
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 6: Lambda variations ===")
    for lambda_ in [0.5, 1, 2, 3, 5]:
        for tau in [1, 2, 5]:
            print_case(tau, 0.05, -0.02, 0.01, lambda_)

    # ═══════════════════════════════════════════════════════════════════════
    # Large τ (Asymptotic Behavior)
    # As τ→∞, f₁→0, f₂→0, so r*→β₀
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 7: Edge cases (large tau) ===")
    for tau in [20, 30, 50, 100]:
        print_case(tau, 0.05, -0.02, 0.01, 2)

    # ═══════════════════════════════════════════════════════════════════════
    # Small τ/λ Ratio (Taylor Branch)
    # When τ/λ < 0.01, code uses approximation f₁ ≈ 1 - (τ/λ)/2
    # With λ=2yr, τ<7.3 days enters this branch
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 8: Small tau/lambda ratio (Taylor approximation) ===")
    for tau_days, lambda_years in [(1, 2), (3, 2), (7, 2), (1, 5), (3, 5)]:
        tau = tau_days / 365
        print_case(tau, 0.05, -0.02, 0.01, lambda_years)

    # ═══════════════════════════════════════════════════════════════════════
    # Negative Rates
    # Tests: (a) β₀ < 0 (negative long rate), (b) β₀ + β₁ < 0 (negative instant)
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 9: Negative rates ===")
    # β₀ < 0 (negative long rate)
    print("  # beta0 < 0 (negative long rate)")
    for tau in [0, 1, 5]:
        print_case(tau, -0.01, 0.02, 0, 2)

    # β₀ + β₁ < 0 (negative instant rate)
    print("  # beta0 + beta1 < 0 (negative instant rate)")
    for tau in [0, 1, 5]:
        print_case(tau, 0.01, -0.03, 0, 2)


if __name__ == "__main__":
    main()
