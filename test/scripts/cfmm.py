#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["nelson-siegel-svensson>=0.5.0", "eth-abi>=5.0.0"]
# ///
"""CFMM Python - Batched differential testing for CfmmMathLib.

Input format (hex-encoded JSON via argv[1]):
    [{"tau": ..., "bondAmountSigned": ..., "X": ..., "yPrin": ..., "yLiq": ..., "psiMin": ..., "psiMax": ...}, ...]

Output format (ABI-encoded):
    Array of (uint256 XNew, int256 cashAmountSigned) tuples

Error signaling:
    When XNew == type(uint256).max, cashAmountSigned contains the error code:
    - 1: InvariantViolated (x_new <= 0 or y_alpha_new <= 0)
    - 2: RateOutOfBounds (psiNew outside [psiMin, psiMax])
    - 3: InsufficientLiquidPrincipal (yLiq < deltaOut)
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

# Error codes (returned in cashAmountSigned when XNew == MAX_UINT256)
ERROR_INVARIANT_VIOLATED = 1       # x_new <= 0 or y_alpha_new <= 0
ERROR_RATE_OUT_OF_BOUNDS = 2       # psiNew outside [psiMin, psiMax]
ERROR_INSUFFICIENT_LIQUIDITY = 3   # yLiq < deltaOut

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


def compute_rtot(X: float, y_prin: float, tau_seconds: int) -> float:
    """Total rate r_tot = kappa * ln(X/y_prin) + r*(tau)."""
    psi = X / y_prin
    rstar = compute_rstar(tau_seconds)
    return KAPPA * math.log(psi) + rstar


def compute_price(tau_seconds: int, X: float, y_prin: float) -> float:
    """Price p(tau) = exp(-r_tot * tau_years)."""
    if tau_seconds == 0:
        return 1.0
    rtot = compute_rtot(X, y_prin, tau_seconds)
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
    y_prin: int,
    y_liq: int,
    psi_min: int,
    psi_max: int,
) -> tuple[int, int]:
    """Compute CFMM swap. Returns (XNew, cashAmountSigned) in WAD.

    On error, returns (MAX_UINT256, error_code).
    """
    X_f = X / WAD
    y_prin_f = y_prin / WAD
    y_liq_f = y_liq / WAD
    psi_min_f = psi_min / WAD
    psi_max_f = psi_max / WAD
    bond_f = bond_amount_signed / WAD

    # tau=0 shortcut
    if tau_seconds == 0:
        cash_f = -bond_f
        x = X_f
        x_new = x + bond_f
        y_prin_new = y_prin_f - bond_f

        psi = X_f / y_prin_f
        ratio = y_prin_f / y_prin_new
        alpha = 1.0
        psi_new = (ratio**alpha) * (psi + 1) - 1
        X_new_f = psi_new * y_prin_new

        # Check psi bounds
        if psi_new < psi_min_f or psi_new > psi_max_f:
            return (MAX_UINT256, ERROR_RATE_OUT_OF_BOUNDS)

        # Check liquidity (if cash goes out, i.e., borrow)
        if y_prin_new < y_prin_f:
            delta_out_f = y_prin_f - y_prin_new
            if y_liq_f < delta_out_f:
                return (MAX_UINT256, ERROR_INSUFFICIENT_LIQUIDITY)

        return (int(X_new_f * WAD), int(cash_f * WAD))

    # Normal case: tau > 0
    price = compute_price(tau_seconds, X_f, y_prin_f)
    x = X_f / price

    alpha = compute_alpha(tau_seconds)
    K = compute_K(tau_seconds)

    C = K * (x**alpha) + (y_prin_f**alpha)

    x_new = x + bond_f
    if x_new <= 0:
        return (MAX_UINT256, ERROR_INVARIANT_VIOLATED)

    x_new_alpha = math.pow(x_new, alpha)
    y_alpha_new = C - K * x_new_alpha
    if y_alpha_new <= 0:
        return (MAX_UINT256, ERROR_INVARIANT_VIOLATED)

    y_prin_new = math.pow(y_alpha_new, 1 / alpha)

    psi = X_f / y_prin_f
    ratio = y_prin_f / y_prin_new
    psi_new = (ratio**alpha) * (psi + 1) - 1
    X_new_f = psi_new * y_prin_new

    # Check psi bounds
    if psi_new < psi_min_f or psi_new > psi_max_f:
        return (MAX_UINT256, ERROR_RATE_OUT_OF_BOUNDS)

    # Check liquidity (if cash goes out, i.e., borrow)
    if y_prin_new < y_prin_f:
        delta_out_f = y_prin_f - y_prin_new
        if y_liq_f < delta_out_f:
            return (MAX_UINT256, ERROR_INSUFFICIENT_LIQUIDITY)

    cash_f = y_prin_new - y_prin_f

    return (int(X_new_f * WAD), int(cash_f * WAD))


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
        y_prin = int(case["yPrin"])
        y_liq = int(case["yLiq"])
        psi_min = int(case["psiMin"])
        psi_max = int(case["psiMax"])

        x_new, cash = compute_swap(tau, bond, X, y_prin, y_liq, psi_min, psi_max)
        results.append((x_new, cash))

    encoded = encode(["(uint256,int256)[]"], [results])
    print("0x" + encoded.hex(), end="")


if __name__ == "__main__":
    main()
