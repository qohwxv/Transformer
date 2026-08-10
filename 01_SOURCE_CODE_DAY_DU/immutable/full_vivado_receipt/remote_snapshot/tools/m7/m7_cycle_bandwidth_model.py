#!/usr/bin/env python3
"""Exact M7 schedule counts and explicitly idealized lower bounds.

The default configuration is the current S8 child: one physical R8/C1 pass
per selected output column, with column 0/1 executed in order and no B cache.
The superseded S16 R8/C2 single-pass schedule remains available explicitly for
comparison.  Counts are derived from the production ViT-Base command shapes.

Cycle and beat lower bounds exclude arbitration, latency, stalls and control
bubbles.  All values emitted by this model are DERIVED planning evidence, not
simulation, Vivado or physical-board measurements.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass


ARRAY_ROWS = 8
LOGICAL_ARRAY_COLS = 2
PE_LANES = 16
S8_STREAMS = 8
S16_STREAMS = 16
NOMINAL_CLOCK_HZ = 50_000_000

NON_GEMM_READ_U32 = 65_326_816
NON_GEMM_WRITE_U32 = 35_234_824
A_CACHE_MISS_FP32 = 23_895_312
BIAS_CACHE_MISS_FP32 = 84_712
GEMM_WRITE_U32 = 23_895_544
M5_JOB_CYCLES = 70_351_474_706
M5_GEMM_CYCLES = 66_917_621_368
M5_OTHER_CYCLES = 3_433_853_338
M5_R_BEATS = 714_804_440
M5_AR_TRANSACTIONS = 313_764_440
M5_EXTERNAL_READ_U32 = 2_318_964_440


@dataclass(frozen=True)
class Workload:
    name: str
    count: int
    batch: int
    m: int
    k: int
    n: int
    persistent_b: bool
    bias: bool


@dataclass(frozen=True)
class ScheduleConfig:
    name: str
    fp16_streams: int
    physical_array_cols: int
    two_pass_columns: bool
    b_cache: bool


S8_CONFIG = ScheduleConfig(
    name="s8_r8c1_two_pass_no_b_cache",
    fp16_streams=S8_STREAMS,
    physical_array_cols=1,
    two_pass_columns=True,
    b_cache=False,
)

S16_CONFIG = ScheduleConfig(
    name="s16_r8c2_single_pass_baseline",
    fp16_streams=S16_STREAMS,
    physical_array_cols=2,
    two_pass_columns=False,
    b_cache=False,
)

CONFIG_BY_STREAMS = {
    S8_CONFIG.fp16_streams: S8_CONFIG,
    S16_CONFIG.fp16_streams: S16_CONFIG,
}


@dataclass(frozen=True)
class M7Model:
    evidence_class: str
    configuration: str
    fp16_streams: int
    physical_array_rows: int
    physical_array_cols: int
    logical_array_cols: int
    two_pass_columns: bool
    b_cache: bool
    gemm_commands: int
    logical_result_tiles: int
    physical_result_passes: int
    biased_logical_result_tiles: int
    logical_k16_tile_steps: int
    physical_k16_passes: int
    physical_mac_slots: int
    valid_mac_terms: int
    tail_mac_terms: int
    persistent_b_source_fp16_elements: int
    packed_b_external_read_u32: int
    dynamic_b_external_read_u32: int
    other_a_bias_external_read_u32: int
    external_read_u32: int
    full_width_r_beats: int
    narrow_r_beats: int
    total_r_beats: int
    full_width_ar_transactions: int
    total_ar_transactions: int
    external_write_u32: int
    ideal_compute_feed_cycles: int
    valid_term_lower_bound_cycles: int
    sequential_bias_upper_bound_cycles: int
    ideal_compute_feed_seconds_50mhz: float
    ideal_read_beat_seconds_50mhz: float
    m5_other_seconds_50mhz: float
    external_read_u32_delta_vs_m5: int
    r_beat_delta_vs_m5: int
    ar_delta_vs_m5: int
    external_read_u32_reduction_vs_m5_percent: float
    r_beat_reduction_vs_m5_percent: float
    ar_reduction_vs_m5_percent: float


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def workloads() -> tuple[Workload, ...]:
    return (
        Workload("patch_embed", 1, 1, 196, 768, 768, True, True),
        Workload("qkv_projection", 36, 1, 197, 768, 768, True, True),
        Workload("o_projection", 12, 1, 197, 768, 768, True, True),
        Workload("qk_attention", 12, 12, 197, 64, 197, False, False),
        Workload("pv_attention", 12, 12, 197, 197, 64, False, False),
        Workload("fc1", 12, 1, 197, 768, 3072, True, True),
        Workload("fc2", 12, 1, 197, 3072, 768, True, True),
        Workload("classifier", 1, 1, 1, 768, 1000, True, True),
    )


def config_for_streams(fp16_streams: int) -> ScheduleConfig:
    try:
        return CONFIG_BY_STREAMS[fp16_streams]
    except KeyError as error:
        supported = ", ".join(str(value) for value in sorted(CONFIG_BY_STREAMS))
        raise ValueError(
            f"unsupported FP16 stream count {fp16_streams}; choose {supported}"
        ) from error


def model(fp16_streams: int = S8_STREAMS) -> M7Model:
    config = config_for_streams(fp16_streams)
    commands = 0
    logical_result_tiles = 0
    physical_result_passes = 0
    biased_tiles = 0
    logical_steps = 0
    physical_passes = 0
    physical_slots = 0
    valid_terms = 0
    persistent_b_source = 0
    packed_b_reads = 0
    dynamic_b_reads = 0

    for item in workloads():
        scale = item.count * item.batch
        m_tiles = ceil_div(item.m, ARRAY_ROWS)
        n_tiles = ceil_div(item.n, LOGICAL_ARRAY_COLS)
        k_chunks = ceil_div(item.k, PE_LANES)
        item_logical_tiles = scale * m_tiles * n_tiles
        item_logical_steps = item_logical_tiles * k_chunks
        item_b_values = scale * m_tiles * item.k * item.n

        if config.two_pass_columns:
            # S8 selects one valid output column per physical pass.  An odd
            # final column therefore runs once, not as a padded second pass.
            item_physical_result_passes = scale * m_tiles * item.n
            item_physical_k16_passes = item_physical_result_passes * k_chunks
        else:
            item_physical_result_passes = item_logical_tiles
            item_physical_k16_passes = item_logical_steps

        commands += item.count
        logical_result_tiles += item_logical_tiles
        physical_result_passes += item_physical_result_passes
        if item.bias:
            biased_tiles += item_logical_tiles
        logical_steps += item_logical_steps
        physical_passes += item_physical_k16_passes
        physical_slots += (
            item_physical_k16_passes
            * ARRAY_ROWS
            * config.physical_array_cols
            * PE_LANES
        )
        valid_terms += scale * item.m * item.k * item.n

        if item.persistent_b:
            persistent_b_source += item_b_values
            if config.two_pass_columns:
                # One packed u32 contains the two legacy C2 half values.  S8
                # rereads that word when it rewinds K for the second column.
                packed_b_reads += item_b_values
            else:
                if item_b_values & 1:
                    raise AssertionError("persistent B must pack by pairs")
                packed_b_reads += item_b_values // 2
        elif config.two_pass_columns:
            # Dynamic B remains row-major FP32 and the legacy frontend fetches
            # the complete C2 pair on each selected-column pass.  Each full
            # pair is thus fetched twice.  An odd last column is fetched once.
            pair_width_reads_per_k = (
                4 * (item.n // LOGICAL_ARRAY_COLS)
                + (item.n % LOGICAL_ARRAY_COLS)
            )
            dynamic_b_reads += (
                scale * m_tiles * item.k * pair_width_reads_per_k
            )
        else:
            dynamic_b_reads += item_b_values

    other_a_bias_reads = (
        A_CACHE_MISS_FP32 + BIAS_CACHE_MISS_FP32 + NON_GEMM_READ_U32
    )
    narrow_reads = dynamic_b_reads + other_a_bias_reads

    # Each persistent K16/C2 block occupies 16 packed u32 values: four native
    # 128-bit beats in one maximum-length M5-compatible burst.  S8 performs
    # that burst once per selected physical column because it has no B cache.
    if packed_b_reads % 16:
        raise AssertionError("packed-B traffic must contain whole K16 blocks")
    full_beats = packed_b_reads // 4
    full_ars = packed_b_reads // 16
    total_reads = packed_b_reads + narrow_reads
    total_beats = full_beats + narrow_reads
    total_ars = full_ars + narrow_reads
    ideal_cycles = ceil_div(physical_slots, config.fp16_streams)

    return M7Model(
        evidence_class="DERIVED",
        configuration=config.name,
        fp16_streams=config.fp16_streams,
        physical_array_rows=ARRAY_ROWS,
        physical_array_cols=config.physical_array_cols,
        logical_array_cols=LOGICAL_ARRAY_COLS,
        two_pass_columns=config.two_pass_columns,
        b_cache=config.b_cache,
        gemm_commands=commands,
        logical_result_tiles=logical_result_tiles,
        physical_result_passes=physical_result_passes,
        biased_logical_result_tiles=biased_tiles,
        logical_k16_tile_steps=logical_steps,
        physical_k16_passes=physical_passes,
        physical_mac_slots=physical_slots,
        valid_mac_terms=valid_terms,
        tail_mac_terms=physical_slots - valid_terms,
        persistent_b_source_fp16_elements=persistent_b_source,
        packed_b_external_read_u32=packed_b_reads,
        dynamic_b_external_read_u32=dynamic_b_reads,
        other_a_bias_external_read_u32=other_a_bias_reads,
        external_read_u32=total_reads,
        full_width_r_beats=full_beats,
        narrow_r_beats=narrow_reads,
        total_r_beats=total_beats,
        full_width_ar_transactions=full_ars,
        total_ar_transactions=total_ars,
        external_write_u32=NON_GEMM_WRITE_U32 + GEMM_WRITE_U32,
        ideal_compute_feed_cycles=ideal_cycles,
        valid_term_lower_bound_cycles=ceil_div(
            valid_terms, config.fp16_streams
        ),
        sequential_bias_upper_bound_cycles=(
            biased_tiles * ARRAY_ROWS * LOGICAL_ARRAY_COLS
        ),
        ideal_compute_feed_seconds_50mhz=ideal_cycles / NOMINAL_CLOCK_HZ,
        ideal_read_beat_seconds_50mhz=total_beats / NOMINAL_CLOCK_HZ,
        m5_other_seconds_50mhz=M5_OTHER_CYCLES / NOMINAL_CLOCK_HZ,
        external_read_u32_delta_vs_m5=total_reads - M5_EXTERNAL_READ_U32,
        r_beat_delta_vs_m5=total_beats - M5_R_BEATS,
        ar_delta_vs_m5=total_ars - M5_AR_TRANSACTIONS,
        external_read_u32_reduction_vs_m5_percent=(
            1.0 - total_reads / M5_EXTERNAL_READ_U32
        ) * 100.0,
        r_beat_reduction_vs_m5_percent=(
            1.0 - total_beats / M5_R_BEATS
        ) * 100.0,
        ar_reduction_vs_m5_percent=(
            1.0 - total_ars / M5_AR_TRANSACTIONS
        ) * 100.0,
    )


EXPECTED_S8 = {
    "gemm_commands": 98,
    "logical_result_tiles": 1_518_500,
    "physical_result_passes": 3_033_400,
    "biased_logical_result_tiles": 1_046_900,
    "logical_k16_tile_steps": 69_763_200,
    "physical_k16_passes": 139_512_000,
    "physical_mac_slots": 17_857_536_000,
    "valid_mac_terms": 17_563_828_224,
    "tail_mac_terms": 293_707_776,
    "persistent_b_source_fp16_elements": 2_138_880_000,
    "packed_b_external_read_u32": 2_138_880_000,
    "dynamic_b_external_read_u32": 181_324_800,
    "other_a_bias_external_read_u32": 89_306_840,
    "external_read_u32": 2_409_511_640,
    "full_width_r_beats": 534_720_000,
    "narrow_r_beats": 270_631_640,
    "total_r_beats": 805_351_640,
    "full_width_ar_transactions": 133_680_000,
    "total_ar_transactions": 404_311_640,
    "external_write_u32": 59_130_368,
    "ideal_compute_feed_cycles": 2_232_192_000,
    "valid_term_lower_bound_cycles": 2_195_478_528,
    "sequential_bias_upper_bound_cycles": 16_750_400,
    "external_read_u32_delta_vs_m5": 90_547_200,
    "r_beat_delta_vs_m5": 90_547_200,
    "ar_delta_vs_m5": 90_547_200,
}


EXPECTED_S16 = {
    "gemm_commands": 98,
    "logical_result_tiles": 1_518_500,
    "physical_result_passes": 1_518_500,
    "biased_logical_result_tiles": 1_046_900,
    "logical_k16_tile_steps": 69_763_200,
    "physical_k16_passes": 69_763_200,
    "physical_mac_slots": 17_859_379_200,
    "valid_mac_terms": 17_563_828_224,
    "tail_mac_terms": 295_550_976,
    "persistent_b_source_fp16_elements": 2_138_880_000,
    "packed_b_external_read_u32": 1_069_440_000,
    "dynamic_b_external_read_u32": 90_777_600,
    "other_a_bias_external_read_u32": 89_306_840,
    "external_read_u32": 1_249_524_440,
    "full_width_r_beats": 267_360_000,
    "narrow_r_beats": 180_084_440,
    "total_r_beats": 447_444_440,
    "full_width_ar_transactions": 66_840_000,
    "total_ar_transactions": 246_924_440,
    "external_write_u32": 59_130_368,
    "ideal_compute_feed_cycles": 1_116_211_200,
    "valid_term_lower_bound_cycles": 1_097_739_264,
    "sequential_bias_upper_bound_cycles": 16_750_400,
    "external_read_u32_delta_vs_m5": -1_069_440_000,
    "r_beat_delta_vs_m5": -267_360_000,
    "ar_delta_vs_m5": -66_840_000,
}

# Backward-compatible name now follows the current/default S8 child.
EXPECTED = EXPECTED_S8


def check_expected(fp16_streams: int, expected: dict[str, int]) -> int:
    actual = asdict(model(fp16_streams))
    for key, value in expected.items():
        if actual[key] != value:
            raise AssertionError(
                f"S{fp16_streams} {key}: expected {value}, got {actual[key]}"
            )
    if actual["physical_mac_slots"] != (
        actual["valid_mac_terms"] + actual["tail_mac_terms"]
    ):
        raise AssertionError(f"S{fp16_streams} MAC-slot identity failed")
    if actual["full_width_r_beats"] * 4 != actual[
        "packed_b_external_read_u32"
    ]:
        raise AssertionError(f"S{fp16_streams} packed-B beat identity failed")
    if actual["total_r_beats"] != (
        actual["full_width_r_beats"] + actual["narrow_r_beats"]
    ):
        raise AssertionError(f"S{fp16_streams} R-beat split identity failed")
    if actual["total_ar_transactions"] != (
        actual["full_width_ar_transactions"] + actual["narrow_r_beats"]
    ):
        raise AssertionError(f"S{fp16_streams} AR split identity failed")
    return len(expected) + 4


def self_check() -> None:
    checks = 0
    checks += check_expected(S8_STREAMS, EXPECTED_S8)
    checks += check_expected(S16_STREAMS, EXPECTED_S16)
    if M5_JOB_CYCLES - M5_GEMM_CYCLES != M5_OTHER_CYCLES:
        raise AssertionError("M5 measured cycle split is inconsistent")
    checks += 1
    print(
        "M7_CYCLE_BANDWIDTH_MODEL_PASS "
        f"configs=S8,S16 evidence=DERIVED checks={checks}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--fp16-streams",
        type=int,
        choices=sorted(CONFIG_BY_STREAMS),
        default=S8_STREAMS,
        help="schedule configuration; default is current S8 two-pass child",
    )
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return
    values = asdict(model(args.fp16_streams))
    if args.json:
        print(json.dumps(values, indent=2, sort_keys=True))
    else:
        for key, value in values.items():
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
