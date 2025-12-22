#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["nelson-siegel-svensson>=0.5.0"]
# ///
"""
Generate test values for CfmmMathLib.computeSwap.

Formula: Uses power-sum CFMM invariant K(τ)·x^α + y^α = C

Key functions:
  - r*(τ): Nelson-Siegel anchor rate
  - r_tot(τ) = κ·ln(X/y) + r*(τ): Total yield
  - p(τ) = exp(-r_tot·τ): Bond price
  - α(τ) = 1/(1 + κ·τ): Invariant exponent
  - K(τ) = exp(-τ·r*·α): Coefficient

Special cases:
  - τ=0: α=1, K=1, price=1 (settlement)
"""
import math

from nelson_siegel_svensson import NelsonSiegelCurve

# Constants (matching Solidity tests)
SECONDS_PER_YEAR = 365 * 24 * 3600

# Default Nelson-Siegel parameters
BETA0 = 0.05  # 5%
BETA1 = -0.02  # -2%
BETA2 = 0.01  # 1%
LAMBDA_YEARS = 2.0  # 2 years
KAPPA = 0.5


# Nelson-Siegel curve instance
NS_CURVE = NelsonSiegelCurve(BETA0, BETA1, BETA2, LAMBDA_YEARS)


def compute_rstar(tau_seconds: int) -> float:
    """Nelson-Siegel anchor rate r*(tau)."""
    if tau_seconds == 0:
        return BETA0 + BETA1
    tau_years = tau_seconds / SECONDS_PER_YEAR
    return NS_CURVE(tau_years)


def compute_rtot(X: float, y: float, tau_seconds: int) -> float:
    """Total rate r_tot = kappa * ln(X/y) + r*(tau)."""
    psi = X / y
    rstar = compute_rstar(tau_seconds)
    return KAPPA * math.log(psi) + rstar


def compute_price(tau_seconds: int, X: float, y: float) -> float:
    """Price p(tau) = exp(-r_tot * tau_years)."""
    if tau_seconds == 0:
        return 1.0
    rtot = compute_rtot(X, y, tau_seconds)
    tau_years = tau_seconds / SECONDS_PER_YEAR
    return math.exp(-rtot * tau_years)


def compute_alpha(tau_seconds: int) -> float:
    """alpha(tau) = 1 / (1 + kappa * tau_years)."""
    if tau_seconds == 0:
        return 1.0
    tau_years = tau_seconds / SECONDS_PER_YEAR
    return 1 / (1 + KAPPA * tau_years)


def compute_K(tau_seconds: int) -> float:
    """K(tau) = exp(-tau_years * r* * alpha)."""
    if tau_seconds == 0:
        return 1.0
    rstar = compute_rstar(tau_seconds)
    alpha = compute_alpha(tau_seconds)
    tau_years = tau_seconds / SECONDS_PER_YEAR
    return math.exp(-tau_years * rstar * alpha)


def compute_swap(
    tau_seconds: int,
    bond_amount_signed: float,
    X: float,
    y: float,
    psi_min: float,
    psi_max: float,
) -> tuple[float, float] | tuple[str, str]:
    """Compute CFMM swap. Returns (XNew, yNew) or error tuple."""
    # tau=0 shortcut
    if tau_seconds == 0:
        x = X
        x_new = x + bond_amount_signed
        y_new = y - bond_amount_signed

        psi = X / y
        ratio = y / y_new
        alpha = 1.0
        psi_new = (ratio**alpha) * (psi + 1) - 1
        X_new = psi_new * y_new

        # Check psi bounds
        if psi_new < psi_min or psi_new > psi_max:
            return ("ERROR", "RateOutOfBounds")

        return (X_new, y_new)

    # Normal case: tau > 0
    price = compute_price(tau_seconds, X, y)
    x = X / price

    alpha = compute_alpha(tau_seconds)
    K = compute_K(tau_seconds)

    C = K * (x**alpha) + (y**alpha)

    x_new = x + bond_amount_signed
    if x_new <= 0:
        return ("ERROR", "InvariantViolated")

    x_new_alpha = math.pow(x_new, alpha)
    y_alpha_new = C - K * x_new_alpha
    if y_alpha_new <= 0:
        return ("ERROR", "InvariantViolated")

    y_new = math.pow(y_alpha_new, 1 / alpha)

    psi = X / y
    ratio = y / y_new
    psi_new = (ratio**alpha) * (psi + 1) - 1
    X_new = psi_new * y_new

    # Check psi bounds
    if psi_new < psi_min or psi_new > psi_max:
        return ("ERROR", "RateOutOfBounds")

    return (X_new, y_new)


def print_case(tau: int, bond: float, X: float, y: float, psi_min: float, psi_max: float) -> None:
    """Print a single test case with float values."""
    result = compute_swap(tau, bond, X, y, psi_min, psi_max)
    if result[0] == "ERROR":
        print(f"  tau={tau}, bond={bond}, X={X}, y={y}, psiMin={psi_min}, psiMax={psi_max} => {result[1]}")
    else:
        X_new, y_new = result
        print(f"  tau={tau}, bond={bond}, X={X}, y={y}, psiMin={psi_min}, psiMax={psi_max} => XNew={X_new}, yNew={y_new}")


def main() -> None:
    # Standard maturities (in seconds)
    DAY = 86400
    YEAR = SECONDS_PER_YEAR
    STANDARD_TAUS = [DAY, 30 * DAY, 91 * DAY, 182 * DAY, YEAR, 2 * YEAR, 5 * YEAR]

    # Default pool: X = y = 1000 (balanced)
    X_DEFAULT = 1000.0
    Y_DEFAULT = 1000.0

    # Wide psi bounds (allow most trades)
    PSI_MIN = 0.1
    PSI_MAX = 10.0

    print("=" * 70)
    print("CfmmMathLib.computeSwap TEST CASES")
    print("=" * 70)

    # ═══════════════════════════════════════════════════════════════════════
    # τ=0 (Settlement)
    # At τ=0, α=1, K=1, price=1 → linear invariant, cash = bondAmount
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 1: tau=0 (settlement, price=1) ===")
    for bond in [100, 200, -100, -200]:
        print_case(0, bond, X_DEFAULT, Y_DEFAULT, PSI_MIN, PSI_MAX)

    # ═══════════════════════════════════════════════════════════════════════
    # Borrow (bondAmount > 0)
    # X increases, y decreases
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 2: Borrow (bondAmount > 0) ===")
    for tau in STANDARD_TAUS:
        for bond in [50, 100]:
            print_case(tau, bond, X_DEFAULT, Y_DEFAULT, PSI_MIN, PSI_MAX)

    # ═══════════════════════════════════════════════════════════════════════
    # Lend (bondAmount < 0)
    # X decreases, y increases
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 3: Lend (bondAmount < 0) ===")
    for tau in STANDARD_TAUS:
        for bond in [-50, -100]:
            print_case(tau, bond, X_DEFAULT, Y_DEFAULT, PSI_MIN, PSI_MAX)

    # ═══════════════════════════════════════════════════════════════════════
    # Psi Variations
    # Same trade with different initial X/y ratios
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 4: Psi variations ===")
    for X, y in [(500, 1000), (1000, 1000), (2000, 1000)]:  # psi = 0.5, 1.0, 2.0
        for bond in [50, -50]:
            print_case(YEAR, bond, X, y, PSI_MIN, PSI_MAX)

    # ═══════════════════════════════════════════════════════════════════════
    # Large Trades (slippage)
    # Trades > 20% of pool
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 5: Large trades (slippage) ===")
    for bond in [300, -300]:  # 30% of pool
        print_case(YEAR, bond, X_DEFAULT, Y_DEFAULT, PSI_MIN, PSI_MAX)
    for bond in [500, -500]:  # 50% of pool
        print_case(YEAR, bond, X_DEFAULT, Y_DEFAULT, PSI_MIN, PSI_MAX)

    # ═══════════════════════════════════════════════════════════════════════
    # Error Cases (RateOutOfBounds)
    # Trades that push psi outside bounds
    # ═══════════════════════════════════════════════════════════════════════
    print("\n=== Category 6: Error cases (RateOutOfBounds) ===")
    # Tight bounds to trigger error
    TIGHT_PSI_MIN = 0.9
    TIGHT_PSI_MAX = 1.1
    for bond in [400, -400]:  # Large trades with tight bounds
        print_case(YEAR, bond, X_DEFAULT, Y_DEFAULT, TIGHT_PSI_MIN, TIGHT_PSI_MAX)


if __name__ == "__main__":
    main()
