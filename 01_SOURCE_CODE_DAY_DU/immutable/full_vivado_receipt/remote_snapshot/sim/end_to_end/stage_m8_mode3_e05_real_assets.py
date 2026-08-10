#!/usr/bin/env python3
"""Strict CLI for M8 package-v3 continuous real-E05 assets and oracles."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from m7_mode3_real_assets import AssetValidationError
from m8_mode3_e05_real_assets import (
    CHECKPOINT_GOLDENS,
    compare_behavioral_goldens,
    compare_endpoint_arithmetic,
    stage_e05_assets,
    validate_staged_e05,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "stage or validate pinned M8 full-real E05 assets, or gate one "
            "completed RTL run against independent numerical oracles"
        )
    )
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--stage", action="store_true")
    modes.add_argument("--validate", action="store_true")
    modes.add_argument("--compare-endpoint", action="store_true")
    modes.add_argument("--compare-behavioral", action="store_true")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--asset-dir", type=Path)
    parser.add_argument("--checkpoint-dump", action="append", type=Path, default=[])
    parser.add_argument("--embedding-dump", type=Path)
    parser.add_argument("--final-ln-dump", type=Path)
    parser.add_argument("--logits-dump", type=Path)
    parser.add_argument("--probabilities-dump", type=Path)
    parser.add_argument("--class-result-dump", type=Path)
    parser.add_argument("--report", type=Path)
    return parser


def _reject(values: tuple[object, ...], message: str) -> None:
    if any(value is not None and value != [] for value in values):
        raise AssetValidationError(message)


def validate_arguments(args: argparse.Namespace) -> None:
    dumps = (
        args.embedding_dump,
        args.final_ln_dump,
        args.logits_dump,
        args.probabilities_dump,
        args.class_result_dump,
        args.report,
    )
    if args.stage:
        if args.output_dir is None:
            raise AssetValidationError("stage mode requires --output-dir")
        _reject(
            (args.asset_dir, args.checkpoint_dump, *dumps),
            "stage mode rejects validation/comparison arguments",
        )
    elif args.validate:
        if args.asset_dir is None:
            raise AssetValidationError("validate mode requires --asset-dir")
        _reject(
            (args.output_dir, args.checkpoint_dump, *dumps),
            "validate mode rejects stage/comparison arguments",
        )
    elif args.compare_endpoint:
        required = (
            args.asset_dir,
            args.embedding_dump,
            args.final_ln_dump,
            args.logits_dump,
            args.report,
        )
        if any(value is None for value in required):
            raise AssetValidationError(
                "endpoint mode requires --asset-dir, --embedding-dump, "
                "--final-ln-dump, --logits-dump, and --report"
            )
        _reject(
            (
                args.output_dir,
                args.checkpoint_dump,
                args.probabilities_dump,
                args.class_result_dump,
            ),
            "endpoint mode rejects unrelated arguments",
        )
    else:
        required = (
            args.asset_dir,
            args.final_ln_dump,
            args.logits_dump,
            args.probabilities_dump,
            args.class_result_dump,
            args.report,
        )
        if any(value is None for value in required):
            raise AssetValidationError(
                "behavioral mode requires --asset-dir, all final dumps, and --report"
            )
        if len(args.checkpoint_dump) != len(CHECKPOINT_GOLDENS):
            raise AssetValidationError(
                "behavioral mode requires 13 ordered --checkpoint-dump arguments"
            )
        _reject(
            (args.output_dir, args.embedding_dump),
            "behavioral mode rejects unrelated arguments",
        )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        validate_arguments(args)
        if args.stage:
            evidence_path, evidence, evidence_sha256 = stage_e05_assets(
                args.output_dir
            )
            staged = evidence["staged"]
            print(
                "M8_MODE3_E05_ASSET_STAGE_PASS "
                f"files={len(staged)} checkpoints=13 runtime_offsets=200 "
                "model_words=43421440 input_words=150528 scratch_words=1990656 "
                f"evidence={evidence_path} evidence_sha256={evidence_sha256}"
            )
            return 0

        if args.validate:
            evidence = validate_staged_e05(args.asset_dir)
            print(
                "M8_MODE3_E05_ASSET_VALIDATE_PASS "
                f"files={len(evidence['staged'])} checkpoints=13 "
                "runtime_offsets=200 mode=3 geometry=R8C2L16S8"
            )
            return 0

        if args.compare_endpoint:
            report, report_sha256 = compare_endpoint_arithmetic(
                args.asset_dir,
                args.embedding_dump,
                args.final_ln_dump,
                args.logits_dump,
                args.report,
            )
            embedding = report["embedding"]
            classifier = report["classifier"]
            print(
                f"M8_MODE3_E05_ENDPOINT_COMPARE_{report['decision']} "
                f"embedding_words={embedding['words']} "
                f"embedding_exact_mismatch={embedding['exact_mismatches']} "
                f"classifier_words={classifier['words']} "
                f"classifier_exact_mismatch={classifier['exact_mismatches']} "
                f"top1_actual={classifier['actual_top1']} "
                f"top1_oracle={classifier['oracle_top1']} "
                f"report_sha256={report_sha256}"
            )
            return 0 if report["decision"] == "PASS" else 1

        report, report_sha256 = compare_behavioral_goldens(
            args.asset_dir,
            args.checkpoint_dump,
            args.final_ln_dump,
            args.logits_dump,
            args.probabilities_dump,
            args.class_result_dump,
            args.report,
        )
        checkpoint_failures = sum(
            int(row["decision"] != "PASS") for row in report["checkpoints"]
        )
        final_failures = sum(
            int(row["decision"] != "PASS")
            for row in report["final_outputs"].values()
        )
        top1 = report["top1_and_class"]
        print(
            f"M8_MODE3_E05_BEHAVIORAL_COMPARE_{report['decision']} "
            f"checkpoints=13 checkpoint_failures={checkpoint_failures} "
            f"final_vectors=3 final_failures={final_failures} "
            f"top1={top1['class_result']} probability_sum_abs_error="
            f"{top1['probability_sum_abs_error']:.9e} "
            f"report_sha256={report_sha256}"
        )
        return 0 if report["decision"] == "PASS" else 1
    except (AssetValidationError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
