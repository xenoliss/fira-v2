#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["nelson-siegel-svensson>=0.5.0", "eth-abi>=5.0.0"]
# ///
"""CFMM Python - Batched differential testing for CfmmMathLib.

Input format (hex-encoded JSON via argv[1]):
    [{"tau": ..., "bondAmountSigned": ..., "X": ..., "y": ..., "psiMin": ..., "psiMax": ...}, ...]

Output format (ABI-encoded):
    Array of (uint256 XNew, uint256 yNewWad) tuples

Error signaling:
    When XNew == type(uint256).max, yNewWad contains the error code:
    - 1: InvariantViolated (x_new <= 0 or y_alpha_new <= 0)
    - 2: RateOutOfBounds (psiNew outside [psiMin, psiMax])
"""
import json
import math
import sys

from eth_abi import encode
from nelson_siegel_svensson import NelsonSiegelCurve

# Constants
SECONDS_PER_YEAR = 365 * 24 * 3600
WAD = 1e18
MAX_UINT256 = 2**256 - 1

# Error codes (returned in yPrinNew when XNew == MAX_UINT256)
ERROR_INVARIANT_VIOLATED = 1       # x_new <= 0 or y_alpha_new <= 0
ERROR_RATE_OUT_OF_BOUNDS = 2       # psiNew outside [psiMin, psiMax]

# Default Nelson-Siegel parameters (matching Solidity tests)
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
    bond_amount_signed: int,
    X: int,
    y: int,
    psi_min: int,
    psi_max: int,
) -> tuple[int, int]:
    """Compute CFMM swap. Returns (XNew, yNewWad) in WAD.

    On error, returns (MAX_UINT256, error_code).
    """
    X_f = X / WAD
    y_f = y / WAD
    psi_min_f = psi_min / WAD
    psi_max_f = psi_max / WAD
    bond_f = bond_amount_signed / WAD

    # tau=0 shortcut
    if tau_seconds == 0:
        x = X_f
        x_new = x + bond_f
        y_new = y_f - bond_f

        psi = X_f / y_f
        ratio = y_f / y_new
        alpha = 1.0
        psi_new = (ratio**alpha) * (psi + 1) - 1
        X_new_f = psi_new * y_new

        # Check psi bounds
        if psi_new < psi_min_f or psi_new > psi_max_f:
            return (MAX_UINT256, ERROR_RATE_OUT_OF_BOUNDS)

        return (int(X_new_f * WAD), int(y_new * WAD))

    # Normal case: tau > 0
    price = compute_price(tau_seconds, X_f, y_f)
    x = X_f / price

    alpha = compute_alpha(tau_seconds)
    K = compute_K(tau_seconds)

    C = K * (x**alpha) + (y_f**alpha)

    x_new = x + bond_f
    if x_new <= 0:
        return (MAX_UINT256, ERROR_INVARIANT_VIOLATED)

    x_new_alpha = math.pow(x_new, alpha)
    y_alpha_new = C - K * x_new_alpha
    if y_alpha_new <= 0:
        return (MAX_UINT256, ERROR_INVARIANT_VIOLATED)

    y_new = math.pow(y_alpha_new, 1 / alpha)

    psi = X_f / y_f
    ratio = y_f / y_new
    psi_new = (ratio**alpha) * (psi + 1) - 1
    X_new_f = psi_new * y_new

    # Check psi bounds
    if psi_new < psi_min_f or psi_new > psi_max_f:
        return (MAX_UINT256, ERROR_RATE_OUT_OF_BOUNDS)

    return (int(X_new_f * WAD), int(y_new * WAD))


def main():
    hex_input = sys.argv[1]
    if hex_input.startswith("0x"):
        hex_input = hex_input[2:]

    json_str = bytes.fromhex(hex_input).decode("utf-8")
    cases = json.loads(json_str)

    results = []
    for case in cases:
        tau = int(case["tau"])
        bond = int(case["bondAmountSigned"])
        X = int(case["X"])
        y = int(case["y"])
        psi_min = int(case["psiMin"])
        psi_max = int(case["psiMax"])

        x_new, y_new = compute_swap(tau, bond, X, y, psi_min, psi_max)
        results.append((x_new, y_new))

    encoded = encode(["(uint256,uint256)[]"], [results])
    print("0x" + encoded.hex(), end="")


if __name__ == "__main__":
    main()
