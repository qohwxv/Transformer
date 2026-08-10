#!/usr/bin/env python3
"""Exact scalar-AXI counter model for M4 row reuse.

The formulas mirror the production loop order
``batch -> M tile -> N tile -> K chunk`` with C=2 and L=16.  A and bias
cache behavior is included, while the non-GEMM traffic is anchored to the
M2/M3 measured 249-command schedule.  The CLI defaults to the current R8
child; R2/R4 remain explicit comparison anchors.  This is a schedule oracle,
not a cycle or DDR-latency predictor.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass


ARRAY_COLS = 2
PE_LANES = 16
A_CACHE_DEPTH = 3072
BIAS_CACHE_DEPTH = 3072
NON_GEMM_READS = 65_326_816
NON_GEMM_WRITES = 35_234_824


@dataclass(frozen=True)
class Workload:
    name: str
    count: int
    batch: int
    m: int
    k: int
    n: int
    bias: bool


@dataclass
class Counters:
    array_rows: int = 0
    gemm_commands: int = 0
    gemm_tile_steps: int = 0
    valid_mac_slots: int = 0
    tail_mac_slots: int = 0
    logical_reads: int = 0
    axi_reads: int = 0
    axi_writes: int = 0
    total_word_transactions: int = 0
    a_cache_lookups: int = 0
    a_cache_hits: int = 0
    a_cache_misses: int = 0
    bias_cache_lookups: int = 0
    bias_cache_hits: int = 0
    bias_cache_misses: int = 0
    b_bypass_reads: int = 0
    cache_lookups: int = 0
    cache_hits: int = 0
    cache_misses: int = 0
    gemm_axi_reads: int = 0
    gemm_writes: int = 0
    non_gemm_reads: int = NON_GEMM_READS
    non_gemm_writes: int = NON_GEMM_WRITES
    cache_payload_bytes: int = 0


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def workloads() -> tuple[Workload, ...]:
    return (
        Workload("patch_embed", 1, 1, 196, 768, 768, True),
        Workload("qkv_projection", 36, 1, 197, 768, 768, True),
        Workload("o_projection", 12, 1, 197, 768, 768, True),
        Workload("qk_attention", 12, 12, 197, 64, 197, False),
        Workload("pv_attention", 12, 12, 197, 197, 64, False),
        Workload("fc1", 12, 1, 197, 768, 3072, True),
        Workload("fc2", 12, 1, 197, 3072, 768, True),
        Workload("classifier", 1, 1, 1, 768, 1000, True),
    )


def model(array_rows: int) -> Counters:
    if array_rows <= 0:
        raise ValueError("array_rows must be positive")

    result = Counters(array_rows=array_rows)
    result.cache_payload_bytes = (
        array_rows * A_CACHE_DEPTH * 4 + BIAS_CACHE_DEPTH * 4
    )

    for item in workloads():
        if item.k > A_CACHE_DEPTH:
            raise ValueError(f"{item.name}: K exceeds A-cache depth")
        if item.bias and item.n > BIAS_CACHE_DEPTH:
            raise ValueError(f"{item.name}: N exceeds bias-cache depth")

        scale = item.count * item.batch
        m_tiles = ceil_div(item.m, array_rows)
        n_tiles = ceil_div(item.n, ARRAY_COLS)
        k_chunks = ceil_div(item.k, PE_LANES)

        tile_steps = scale * m_tiles * n_tiles * k_chunks
        valid_macs = scale * item.m * item.k * item.n
        physical_slots = (
            tile_steps * array_rows * ARRAY_COLS * PE_LANES
        )

        a_lookups = scale * item.m * item.k * n_tiles
        a_misses = scale * item.m * item.k
        b_reads = scale * m_tiles * item.k * item.n
        bias_lookups = (
            scale * m_tiles * item.n if item.bias else 0
        )
        # Bias is filled once per command, including commands with batch > 1.
        bias_misses = item.count * item.n if item.bias else 0
        gemm_writes = scale * item.m * item.n

        result.gemm_commands += item.count
        result.gemm_tile_steps += tile_steps
        result.valid_mac_slots += valid_macs
        result.tail_mac_slots += physical_slots - valid_macs
        result.a_cache_lookups += a_lookups
        result.a_cache_misses += a_misses
        result.bias_cache_lookups += bias_lookups
        result.bias_cache_misses += bias_misses
        result.b_bypass_reads += b_reads
        result.gemm_writes += gemm_writes

    result.a_cache_hits = result.a_cache_lookups - result.a_cache_misses
    result.bias_cache_hits = (
        result.bias_cache_lookups - result.bias_cache_misses
    )
    result.cache_lookups = (
        result.a_cache_lookups + result.bias_cache_lookups
    )
    result.cache_hits = result.a_cache_hits + result.bias_cache_hits
    result.cache_misses = (
        result.a_cache_misses + result.bias_cache_misses
    )
    result.gemm_axi_reads = (
        result.a_cache_misses
        + result.b_bypass_reads
        + result.bias_cache_misses
    )
    result.logical_reads = (
        result.a_cache_lookups
        + result.b_bypass_reads
        + result.bias_cache_lookups
        + NON_GEMM_READS
    )
    result.axi_reads = result.gemm_axi_reads + NON_GEMM_READS
    result.axi_writes = result.gemm_writes + NON_GEMM_WRITES
    result.total_word_transactions = result.axi_reads + result.axi_writes
    return result


KNOWN = {
    2: {
        "logical_reads": 17_683_017_416,
        "axi_reads": 8_915_887_832,
        "axi_writes": 59_130_368,
        "b_bypass_reads": 8_826_580_992,
        "gemm_tile_steps": 276_172_800,
        "valid_mac_slots": 17_563_828_224,
        "tail_mac_slots": 111_230_976,
    },
    4: {
        "logical_reads": 13_310_291_912,
        "axi_reads": 4_547_264_216,
        "axi_writes": 59_130_368,
        "b_bypass_reads": 4_457_957_376,
        "gemm_tile_steps": 139_483_968,
        "valid_mac_slots": 17_563_828_224,
        "tail_mac_slots": 290_119_680,
    },
    8: {
        "logical_reads": 11_079_900_104,
        "axi_reads": 2_318_964_440,
        "axi_writes": 59_130_368,
        "b_bypass_reads": 2_229_657_600,
        "gemm_tile_steps": 69_763_200,
        "valid_mac_slots": 17_563_828_224,
        "tail_mac_slots": 295_550_976,
    },
}


def self_check() -> None:
    checks = 0
    for rows, expected in KNOWN.items():
        actual = asdict(model(rows))
        for key, value in expected.items():
            if actual[key] != value:
                raise AssertionError(
                    f"R={rows} {key}: expected {value}, got {actual[key]}"
                )
            checks += 1
        if actual["cache_lookups"] != (
            actual["cache_hits"] + actual["cache_misses"]
        ):
            raise AssertionError(f"R={rows}: cache invariant failed")
        checks += 1
    print(f"M4_REUSE_MODEL_SELF_CHECK_PASS checks={checks}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--array-rows",
        type=int,
        default=8,
        help="row-reuse geometry (default: 8 for the current M4-R8 child)",
    )
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return
    counters = asdict(model(args.array_rows))
    if args.json:
        print(json.dumps(counters, indent=2, sort_keys=True))
    else:
        for key, value in counters.items():
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
