#!/usr/bin/env python3
"""Classify complete M8 real-E05 raw output before numerical comparison.

Only two states are eligible to reach the expensive external comparators:

* a clean simulator exit with the exact structural-PASS marker; or
* a non-timeout simulator failure explicitly caused by the late structural
  gate, after all ordered checkpoint/final dumps were completed and validated.

Timeouts, partial output, unrelated crashes, missing files and malformed files
always fail closed and are never called a full numerical run.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


HEX_WORD_RE = re.compile(r"[0-9a-fA-F]{8}")
STRUCTURAL_PASS_RE = re.compile(
    r"VIT_PHASE_E_AXI_E05_MODE3_REAL_RTL_STRUCTURAL_PASS "
    r"mode=3 rows=8 cols=2 checks=[1-9][0-9]* "
    r"cycles=([1-9][0-9]*) job_cycles=([1-9][0-9]*) "
    r"commands=249 checkpoints_dumped=13 blocked_gemm=74 packed_gemm=74 "
    r"fp16_gemm=98 row_major_gemm=24 packed_tiles=133680000 "
    r"nonpacked_tiles=5832000 reads=([1-9][0-9]*) writes=59130368 "
    r"axi_stalls=[0-9]+ model_reads=[1-9][0-9]* input_reads=[1-9][0-9]* "
    r"scratch_reads=[1-9][0-9]* cmd_active=[1-9][0-9]* "
    r"logical_reads=[1-9][0-9]* cache_hits=[0-9]+ valid_mac=17563828224 "
    r"tail_mac=293707776 class=879 logit=([0-9a-fA-F]{8}) "
    r"numerical_status=PENDING_EXTERNAL_ARITHMETIC_AND_FP32_ORACLES"
)
STRUCTURAL_FAIL_TOKEN = (
    "VIT_PHASE_E_AXI_E05_MODE3_REAL_RTL_STRUCTURAL_FAIL"
)
SEVERE_RE = re.compile(
    r"(%Error|%Fatal|STRUCTURAL_FAIL|CHECK FAILED|watchdog timeout)"
)


@dataclass(frozen=True)
class OutputContract:
    checkpoint_words_each: int = 151_296
    final_ln_words: int = 151_296
    logits_words: int = 1_000
    probabilities_words: int = 1_000
    class_result_words: int = 2


@dataclass(frozen=True)
class RunEvidenceReceipt:
    decision: str
    simulator_status: int
    cycles: int | None
    job_cycles: int | None
    reads: int | None
    class_logit: str | None


class RunEvidenceError(RuntimeError):
    """Raw run evidence is incomplete, malformed, or ineligible for salvage."""


def _absolute_normalized(path: Path, description: str) -> Path:
    if not path.is_absolute() or Path(os.path.abspath(os.fspath(path))) != path:
        raise RunEvidenceError(f"{description} must be absolute and normalized")
    return path


def _regular_without_symlinks(path: Path, description: str) -> Path:
    path = _absolute_normalized(path, description)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise RunEvidenceError(f"{description} contains a symlink: {current}")
    if not path.is_file():
        raise RunEvidenceError(f"{description} is missing/nonregular: {path}")
    return path


def _output_files(
    output_dir: Path, contract: OutputContract
) -> tuple[tuple[Path, int], ...]:
    rows: list[tuple[Path, int]] = [
        (
            output_dir / "checkpoint_00_embedding_rtl_f32.hex",
            contract.checkpoint_words_each,
        )
    ]
    rows.extend(
        (
            output_dir
            / f"checkpoint_{layer + 1:02d}_encoder_layer_{layer:02d}_step_20_rtl_f32.hex",
            contract.checkpoint_words_each,
        )
        for layer in range(12)
    )
    rows.extend(
        (
            (output_dir / "final_layernorm_rtl_f32.hex", contract.final_ln_words),
            (output_dir / "logits_rtl_f32.hex", contract.logits_words),
            (
                output_dir / "probabilities_rtl_f32.hex",
                contract.probabilities_words,
            ),
            (output_dir / "class_result_rtl_u32.hex", contract.class_result_words),
        )
    )
    return tuple(rows)


def _validate_output_files(output_dir: Path, contract: OutputContract) -> None:
    for path, expected_words in _output_files(output_dir, contract):
        _regular_without_symlinks(path, f"E05 dump {path.name}")
        try:
            words = [
                line.strip()
                for line in path.read_text(encoding="ascii").splitlines()
                if line.strip() and not line.lstrip().startswith("//")
            ]
        except (OSError, UnicodeError) as exc:
            raise RunEvidenceError(f"cannot read E05 dump {path}: {exc}") from exc
        if len(words) != expected_words or any(
            not HEX_WORD_RE.fullmatch(word) for word in words
        ):
            raise RunEvidenceError(
                f"malformed E05 dump: {path} expected_words={expected_words} "
                f"actual_words={len(words)}"
            )


def _unique_fullmatch(
    lines: Sequence[str], pattern: re.Pattern[str], description: str
) -> tuple[int, re.Match[str]]:
    hits = [
        (index, match)
        for index, line in enumerate(lines)
        if (match := pattern.fullmatch(line))
    ]
    if len(hits) != 1:
        raise RunEvidenceError(f"{description} marker count={len(hits)}")
    return hits[0]


def _validate_checkpoint_markers(
    lines: Sequence[str], output_dir: Path, output_dump_index: int
) -> None:
    expected: list[tuple[re.Pattern[str], Path]] = [
        (
            re.compile(
                r"M8_MODE3_E05_CHECKPOINT_DUMP index=0 section=EMBEDDING "
                r"layer=15 step=3 words=151296 path=(.+)"
            ),
            output_dir / "checkpoint_00_embedding_rtl_f32.hex",
        )
    ]
    expected.extend(
        (
            re.compile(
                rf"M8_MODE3_E05_CHECKPOINT_DUMP index={layer + 1} "
                rf"section=ENCODER layer={layer} step=19 words=151296 path=(.+)"
            ),
            output_dir
            / f"checkpoint_{layer + 1:02d}_encoder_layer_{layer:02d}_step_20_rtl_f32.hex",
        )
        for layer in range(12)
    )
    marker_lines = [
        (index, line)
        for index, line in enumerate(lines)
        if line.startswith("M8_MODE3_E05_CHECKPOINT_DUMP ")
    ]
    if len(marker_lines) != 13:
        raise RunEvidenceError(
            f"checkpoint-dump marker count={len(marker_lines)}, expected 13"
        )
    last_index = -1
    for ordinal, ((index, line), (pattern, path)) in enumerate(
        zip(marker_lines, expected, strict=True)
    ):
        match = pattern.fullmatch(line)
        if match is None:
            raise RunEvidenceError(
                f"checkpoint marker {ordinal} is out of order or malformed"
            )
        if Path(match.group(1)) != path:
            raise RunEvidenceError(
                f"checkpoint marker {ordinal} path mismatch: {match.group(1)}"
            )
        if index <= last_index or index >= output_dump_index:
            raise RunEvidenceError("checkpoint markers do not precede final dump marker")
        last_index = index


def classify_run_evidence(
    log_path: Path,
    output_dir: Path,
    *,
    simulator_status: int,
    tee_status: int,
    contract: OutputContract = OutputContract(),
) -> RunEvidenceReceipt:
    """Return PASS/salvage eligibility or raise without making an accuracy claim."""

    if simulator_status == 124:
        raise RunEvidenceError("timeout status 124 is incomplete and never salvageable")
    if not 0 <= simulator_status <= 255 or not 0 <= tee_status <= 255:
        raise RunEvidenceError("pipeline status is outside 0..255")
    if tee_status != 0:
        raise RunEvidenceError("tee/log pipeline failed; evidence is not trustworthy")

    log_path = _regular_without_symlinks(log_path, "E05 run log")
    output_dir = _absolute_normalized(output_dir, "E05 output directory")
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise RunEvidenceError("E05 output directory is missing/non-directory/symlinked")
    try:
        lines = log_path.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()
    except OSError as exc:
        raise RunEvidenceError(f"cannot read E05 run log: {exc}") from exc

    dump_pattern = re.compile(
        r"M8_MODE3_E05_OUTPUT_DUMPS checkpoints=13 "
        rf"checkpoint_words_each={contract.checkpoint_words_each} "
        rf"final_ln_words={contract.final_ln_words} "
        rf"logits_words={contract.logits_words} "
        rf"probabilities_words={contract.probabilities_words} "
        rf"class_result_words={contract.class_result_words} "
        rf"output_dir={re.escape(str(output_dir))} "
        r"numerical_status=PENDING_EXTERNAL_ARITHMETIC_AND_FP32_ORACLES"
    )
    dump_index, _ = _unique_fullmatch(lines, dump_pattern, "output-dump")
    _validate_checkpoint_markers(lines, output_dir, dump_index)
    _validate_output_files(output_dir, contract)

    traffic_pattern = re.compile(
        r"M8_MODE3_E05_TRAFFIC_DIAGNOSTIC .+ "
        r"first_run_gate=ALGEBRA_PROTOCOL_ONLY"
    )
    traffic_index, _ = _unique_fullmatch(
        lines, traffic_pattern, "observation-first traffic"
    )
    if traffic_index <= dump_index:
        raise RunEvidenceError("traffic marker does not follow the final dump marker")

    structural_hits = [
        (index, match)
        for index, line in enumerate(lines)
        if (match := STRUCTURAL_PASS_RE.fullmatch(line))
    ]
    fail_indices = [
        index for index, line in enumerate(lines) if STRUCTURAL_FAIL_TOKEN in line
    ]

    if simulator_status == 0:
        if any(SEVERE_RE.search(line) for line in lines):
            raise RunEvidenceError("clean-exit log contains a severity marker")
        if len(structural_hits) != 1 or fail_indices:
            raise RunEvidenceError("clean exit lacks one unique structural PASS")
        structural_index, structural = structural_hits[0]
        if structural_index <= traffic_index:
            raise RunEvidenceError("structural PASS marker order is invalid")
        return RunEvidenceReceipt(
            decision="STRUCTURAL_PASS",
            simulator_status=simulator_status,
            cycles=int(structural.group(1)),
            job_cycles=int(structural.group(2)),
            reads=int(structural.group(3)),
            class_logit=structural.group(4).lower(),
        )

    if structural_hits:
        raise RunEvidenceError("nonzero simulator exit also contains structural PASS")
    if len(fail_indices) != 1 or fail_indices[0] <= traffic_index:
        raise RunEvidenceError(
            "nonzero exit is not one late post-dump structural failure"
        )
    if any("watchdog timeout" in line for line in lines):
        raise RunEvidenceError("watchdog timeout is incomplete and never salvageable")
    return RunEvidenceReceipt(
        decision="SALVAGE_NUMERICAL_ONLY",
        simulator_status=simulator_status,
        cycles=None,
        job_cycles=None,
        reads=None,
        class_logit=None,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-log", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--simulator-status", required=True, type=int)
    parser.add_argument("--tee-status", required=True, type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        receipt = classify_run_evidence(
            args.run_log,
            args.output_dir,
            simulator_status=args.simulator_status,
            tee_status=args.tee_status,
        )
    except (RunEvidenceError, OSError, ValueError) as exc:
        print(f"ERROR: M8 E05 raw evidence rejected: {exc}", file=sys.stderr)
        return 2
    if receipt.decision == "STRUCTURAL_PASS":
        print(
            "M8_MODE3_E05_RAW_OUTPUT_GATE_PASS checkpoints=13 "
            "checkpoint_words_each=151296 final_ln_words=151296 "
            "logits_words=1000 probabilities_words=1000 class_result_words=2 "
            "commands=249 "
            f"cycles={receipt.cycles} job_cycles={receipt.job_cycles} "
            f"reads={receipt.reads} writes=59130368 class=879 "
            f"logit={receipt.class_logit} traffic_gate=OBSERVATION_FIRST"
        )
    else:
        print(
            "M8_MODE3_E05_SALVAGE_RAW_OUTPUT_GATE_PASS checkpoints=13 "
            "final_dumps=4 simulator_status="
            f"{receipt.simulator_status} structural_status=FAIL "
            "numerical_status=PENDING_EXTERNAL_ORACLES overall_status=FAIL"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

