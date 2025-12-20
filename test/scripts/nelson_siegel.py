#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["nelson-siegel-svensson>=0.5.0", "eth-abi>=5.0.0"]
# ///
"""Nelson-Siegel FFI wrapper - batched differential testing.

Input format (hex-encoded JSON via argv[1]):
    [{"tau": 31536000, "beta0": 0.05e18, "beta1": -0.02e18, "beta2": 0.01e18, "lambda": 63072000}, ...]

Output format (ABI-encoded):
    Array of int256 r* values
"""
import json
import sys

from eth_abi import encode
from nelson_siegel_svensson import NelsonSiegelCurve

SECONDS_PER_YEAR = 365 * 24 * 3600
WAD = 1e18


def from_wad(wad_val) -> float:
    """Convert WAD value to float."""
    return int(wad_val) / WAD


def compute_rstar(tau_seconds: int, beta0: float, beta1: float, beta2: float, lambda_seconds: int) -> float:
    """Compute Nelson-Siegel rate r*(tau)."""
    tau_years = tau_seconds / SECONDS_PER_YEAR
    lambda_years = lambda_seconds / SECONDS_PER_YEAR

    if tau_years == 0:
        return beta0 + beta1
    curve = NelsonSiegelCurve(beta0, beta1, beta2, lambda_years)
    return curve(tau_years)


def main():
    hex_input = sys.argv[1]
    if hex_input.startswith("0x"):
        hex_input = hex_input[2:]

    json_str = bytes.fromhex(hex_input).decode("utf-8")
    cases = json.loads(json_str)

    results = []
    for case in cases:
        tau = int(case["tau"])
        beta0 = from_wad(case["beta0"])
        beta1 = from_wad(case["beta1"])
        beta2 = from_wad(case["beta2"])
        lambda_ = int(case["lambda"])

        rstar = compute_rstar(tau, beta0, beta1, beta2, lambda_)
        results.append(int(rstar * WAD))

    encoded = encode(["int256[]"], [results])
    print("0x" + encoded.hex(), end="")


if __name__ == "__main__":
    main()
