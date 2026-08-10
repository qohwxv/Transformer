#!/usr/bin/env python3
"""CLI for exact M7 mode-3 real assets and post-simulation E04 compare."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

from m7_mode3_real_assets import (
    AssetValidationError,
    compare_e01_behavioral_golden_dump,
    compare_e01_m6_current_adder_oracle_dump,
    compare_e04_behavioral_golden_dumps,
    compare_e04_m6_classifier_oracle_dumps,
    stage_phase_assets,
)


def finite_nonnegative(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a floating-point value") from exc
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be finite and non-negative")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "stage hash-pinned package-v3 readmemh assets, or compare E04 "
            "RTL dumps against the M6/current-adder oracle"
        )
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--compare-e01-m6-current-adder-oracle",
        action="store_true",
        help="select the exact full-E01 M6/current-adder comparison",
    )
    modes.add_argument(
        "--compare-e01-behavioral-golden",
        action="store_true",
        help="select the independent full-E01 FP32 quality comparison",
    )
    modes.add_argument(
        "--compare-e04-m6-classifier-oracle",
        "--compare-e04-dumps",
        dest="compare_e04_m6_classifier_oracle",
        action="store_true",
        help="select the exact M6 classifier-arithmetic comparison",
    )
    modes.add_argument(
        "--compare-e04-behavioral-golden",
        action="store_true",
        help="select independent final-LN/logit/probability/class comparison",
    )
    parser.add_argument("--phase", choices=("e01", "e04"))
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--asset-dir", type=Path)
    parser.add_argument("--final-ln-dump", type=Path)
    parser.add_argument("--logits-dump", type=Path)
    parser.add_argument("--probabilities-dump", type=Path)
    parser.add_argument("--class-result-dump", type=Path)
    parser.add_argument("--embedding-dump", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--abs-tolerance",
        type=finite_nonnegative,
        default=0.0,
        help="absolute logit tolerance (default: exact, 0)",
    )
    parser.add_argument(
        "--rel-tolerance",
        type=finite_nonnegative,
        default=0.0,
        help="relative logit tolerance (default: exact, 0)",
    )
    return parser


def require_exact_mode_arguments(args: argparse.Namespace) -> None:
    stage_values = (args.phase, args.output_dir)
    common_compare_values = (
        args.asset_dir,
        args.final_ln_dump,
        args.logits_dump,
        args.report,
    )
    e04_dump_values = (
        args.final_ln_dump,
        args.logits_dump,
        args.probabilities_dump,
        args.class_result_dump,
    )
    if args.compare_e01_m6_current_adder_oracle:
        if any(value is not None for value in stage_values):
            raise AssetValidationError(
                "E01 M6 compare mode rejects --phase and --output-dir"
            )
        if any(value is None for value in (args.asset_dir, args.embedding_dump, args.report)):
            raise AssetValidationError(
                "E01 M6 compare mode requires --asset-dir, --embedding-dump, and --report"
            )
        if any(value is not None for value in e04_dump_values):
            raise AssetValidationError("E01 M6 compare mode rejects E04 dump arguments")
        if args.abs_tolerance != 0.0 or args.rel_tolerance != 0.0:
            raise AssetValidationError("E01 M6 compare is exact and rejects tolerances")
    elif args.compare_e01_behavioral_golden:
        if any(value is not None for value in stage_values):
            raise AssetValidationError(
                "E01 behavioral compare mode rejects --phase and --output-dir"
            )
        if any(value is None for value in (args.asset_dir, args.embedding_dump, args.report)):
            raise AssetValidationError(
                "E01 behavioral compare requires --asset-dir, --embedding-dump, and --report"
            )
        if any(value is not None for value in e04_dump_values):
            raise AssetValidationError(
                "E01 behavioral compare rejects E04 dump arguments"
            )
        if args.abs_tolerance != 0.0 or args.rel_tolerance != 0.0:
            raise AssetValidationError(
                "E01 behavioral compare uses its fixed canonical tolerance"
            )
    elif args.compare_e04_m6_classifier_oracle:
        if any(value is not None for value in stage_values):
            raise AssetValidationError(
                "M6 compare mode rejects --phase and --output-dir"
            )
        if any(value is None for value in common_compare_values):
            raise AssetValidationError(
                "M6 compare mode requires --asset-dir, --final-ln-dump, "
                "--logits-dump, and --report"
            )
        if args.probabilities_dump is not None or args.class_result_dump is not None:
            raise AssetValidationError(
                "M6 compare mode rejects behavioral-only dump arguments"
            )
        if args.embedding_dump is not None:
            raise AssetValidationError("E04 M6 compare rejects --embedding-dump")
    elif args.compare_e04_behavioral_golden:
        if any(value is not None for value in stage_values):
            raise AssetValidationError(
                "behavioral compare mode rejects --phase and --output-dir"
            )
        if any(value is None for value in common_compare_values) or any(
            value is None
            for value in (args.probabilities_dump, args.class_result_dump)
        ):
            raise AssetValidationError(
                "behavioral compare mode requires --asset-dir, all four "
                "RTL dumps, and --report"
            )
        if args.abs_tolerance != 0.0 or args.rel_tolerance != 0.0:
            raise AssetValidationError(
                "behavioral compare uses fixed canonical tolerances"
            )
        if args.embedding_dump is not None:
            raise AssetValidationError(
                "E04 behavioral compare rejects --embedding-dump"
            )
    else:
        if any(value is None for value in stage_values):
            raise AssetValidationError(
                "stage mode requires --phase and --output-dir"
            )
        if any(value is not None for value in common_compare_values) or any(
            value is not None
            for value in (
                args.probabilities_dump,
                args.class_result_dump,
                args.embedding_dump,
            )
        ):
            raise AssetValidationError(
                "stage mode rejects dump-comparison arguments"
            )
        if args.abs_tolerance != 0.0 or args.rel_tolerance != 0.0:
            raise AssetValidationError(
                "stage mode rejects nonzero comparison tolerances"
            )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        require_exact_mode_arguments(args)
        if args.compare_e01_m6_current_adder_oracle:
            report, report_sha256 = compare_e01_m6_current_adder_oracle_dump(
                args.asset_dir,
                args.embedding_dump,
                args.report,
            )
            comparison = report["comparison"]
            print(
                f"M7_MODE3_E01_M6_CURRENT_ADDER_ORACLE_COMPARE_{report['decision']} "
                f"embedding={comparison['words']} "
                f"exact_mismatch={comparison['exact_mismatches']} "
                f"actual_nonfinite={comparison['actual_nonfinite']} "
                f"oracle_nonfinite={comparison['oracle_nonfinite']} "
                f"oracle_sha256={comparison['oracle_readmemh_sha256']} "
                f"report_sha256={report_sha256}"
            )
            return 0 if report["decision"] == "PASS" else 1

        if args.compare_e01_behavioral_golden:
            report, report_sha256 = compare_e01_behavioral_golden_dump(
                args.asset_dir,
                args.embedding_dump,
                args.report,
            )
            comparison = report["embedding"]
            print(
                f"M7_MODE3_E01_BEHAVIORAL_GOLDEN_COMPARE_{report['decision']} "
                f"embedding={comparison['words']} "
                f"exact_mismatch={comparison['exact_mismatches']} "
                f"tolerance_failures={comparison['tolerance_failures']} "
                f"abs_tolerance={comparison['abs_tolerance']:.9e} "
                f"max_abs={comparison['max_abs']:.9e} "
                f"mean_abs={comparison['mean_abs']:.9e} "
                f"report_sha256={report_sha256}"
            )
            return 0 if report["decision"] == "PASS" else 1

        if args.compare_e04_m6_classifier_oracle:
            report, report_sha256 = compare_e04_m6_classifier_oracle_dumps(
                args.asset_dir,
                args.final_ln_dump,
                args.logits_dump,
                args.report,
                abs_tolerance=args.abs_tolerance,
                rel_tolerance=args.rel_tolerance,
            )
            comparison = report["comparison"]
            marker = (
                f"M7_MODE3_E04_M6_CLASSIFIER_ORACLE_COMPARE_{report['decision']} "
                f"logits={comparison['words']} "
                f"exact_mismatch={comparison['exact_mismatches']} "
                f"tolerance_failures={comparison['tolerance_failures']} "
                f"abs_tolerance={comparison['abs_tolerance']:.9e} "
                f"rel_tolerance={comparison['rel_tolerance']:.9e} "
                f"max_abs={comparison['max_abs']:.9e} "
                f"mean_abs={comparison['mean_abs']:.9e} "
                f"top1_actual={comparison['actual_top1']} "
                f"top1_oracle={comparison['oracle_top1']} "
                f"report_sha256={report_sha256}"
            )
            print(marker)
            return 0 if report["decision"] == "PASS" else 1

        if args.compare_e04_behavioral_golden:
            report, report_sha256 = compare_e04_behavioral_golden_dumps(
                args.asset_dir,
                args.final_ln_dump,
                args.logits_dump,
                args.probabilities_dump,
                args.class_result_dump,
                args.report,
            )
            final_ln = report["final_layernorm"]
            logits = report["logits"]
            probabilities = report["probabilities"]
            top1 = report["top1_and_class"]
            print(
                f"M7_MODE3_E04_BEHAVIORAL_GOLDEN_COMPARE_{report['decision']} "
                f"final_ln={final_ln['words']} "
                f"final_ln_exact_mismatch={final_ln['exact_mismatches']} "
                f"final_ln_tolerance_failures={final_ln['tolerance_failures']} "
                f"final_ln_max_abs={final_ln['max_abs']:.9e} "
                f"logits={logits['words']} "
                f"logits_exact_mismatch={logits['exact_mismatches']} "
                f"logits_tolerance_failures={logits['tolerance_failures']} "
                f"logits_max_abs={logits['max_abs']:.9e} "
                f"probabilities={probabilities['words']} "
                f"probabilities_exact_mismatch={probabilities['exact_mismatches']} "
                f"probabilities_tolerance_failures={probabilities['tolerance_failures']} "
                f"probabilities_max_abs={probabilities['max_abs']:.9e} "
                f"expected_top1={top1['expected']} "
                f"logits_top1_actual={top1['actual_logits']} "
                f"logits_top1_golden={top1['golden_logits']} "
                f"probabilities_top1_actual={top1['actual_probabilities']} "
                f"probabilities_top1_golden={top1['golden_probabilities']} "
                f"class_result={top1['class_result']} "
                f"class_logit_matches_dump={int(top1['class_result_logit_matches_dump'])} "
                f"report_sha256={report_sha256}"
            )
            return 0 if report["decision"] == "PASS" else 1

        evidence_path, evidence, evidence_sha256 = stage_phase_assets(
            args.phase, args.output_dir
        )
        print(
            "M7_MODE3_ASSET_STAGE_PASS "
            f"phase={evidence['phase']} "
            f"files={len(evidence['staged'])} "
            f"evidence_sha256={evidence_sha256} "
            f"evidence={evidence_path}"
        )
        return 0
    except (AssetValidationError, OSError, ValueError) as exc:
        if args.compare_e01_m6_current_adder_oracle:
            mode = "E01_M6_CURRENT_ADDER_ORACLE_COMPARE"
        elif args.compare_e01_behavioral_golden:
            mode = "E01_BEHAVIORAL_GOLDEN_COMPARE"
        elif args.compare_e04_m6_classifier_oracle:
            mode = "E04_M6_CLASSIFIER_ORACLE_COMPARE"
        elif args.compare_e04_behavioral_golden:
            mode = "E04_BEHAVIORAL_GOLDEN_COMPARE"
        else:
            mode = "ASSET_STAGE"
        print(f"M7_MODE3_{mode}_FAIL reason={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
