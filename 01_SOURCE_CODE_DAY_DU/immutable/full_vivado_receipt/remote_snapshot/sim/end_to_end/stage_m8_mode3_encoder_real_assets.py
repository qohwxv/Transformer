#!/usr/bin/env python3
"""CLI for M8 package-v3 encoder staging and T004 comparison."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from m8_mode3_encoder_real_assets import (
    EncoderAssetError,
    compare_encoder_output,
    stage_encoder_layer_assets,
    verify_e02_seed_receipt,
)
from m7_mode3_real_assets import AssetValidationError


def layer_number(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("layer must be an integer") from exc
    if not 0 <= parsed <= 11:
        raise argparse.ArgumentTypeError("layer must be in 0..11")
    return parsed


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="stage one pinned M8 encoder layer or compare its RTL dump"
    )
    mode = value.add_mutually_exclusive_group(required=True)
    mode.add_argument("--stage", action="store_true")
    mode.add_argument("--compare", action="store_true")
    mode.add_argument("--verify-seed", action="store_true")
    value.add_argument("--layer", type=layer_number)
    value.add_argument("--output-dir", type=Path)
    value.add_argument("--asset-dir", type=Path)
    value.add_argument("--runtime-input", type=Path)
    value.add_argument("--output-dump", type=Path)
    value.add_argument("--report", type=Path)
    value.add_argument("--input-origin", choices=("t004", "m8-chain"))
    value.add_argument("--previous-report", type=Path)
    value.add_argument("--seed-output", type=Path)
    value.add_argument("--seed-report", type=Path)
    value.add_argument("--receipt-manifest", type=Path)
    value.add_argument("--receipt-manifest-sha256")
    value.add_argument("--expected-source-state-file", type=Path)
    return value


def _validate_arguments(args: argparse.Namespace) -> None:
    seed_arguments = (
        args.seed_output,
        args.seed_report,
        args.receipt_manifest,
        args.receipt_manifest_sha256,
        args.expected_source_state_file,
    )
    if args.stage:
        if args.layer is None or args.output_dir is None:
            raise EncoderAssetError("stage mode requires --layer and --output-dir")
        if any(
            item is not None
            for item in (
                args.asset_dir,
                args.runtime_input,
                args.output_dump,
                args.report,
                args.input_origin,
                args.previous_report,
                *seed_arguments,
            )
        ):
            raise EncoderAssetError("stage mode rejects comparison arguments")
    elif args.compare:
        required = (
            args.asset_dir,
            args.runtime_input,
            args.output_dump,
            args.report,
            args.input_origin,
        )
        if any(item is None for item in required):
            raise EncoderAssetError(
                "compare mode requires --asset-dir, --runtime-input, "
                "--output-dump, --report, and --input-origin"
            )
        if args.layer is not None or args.output_dir is not None:
            raise EncoderAssetError("compare mode rejects --layer and --output-dir")
        if args.input_origin == "t004" and args.previous_report is not None:
            raise EncoderAssetError("T004 compare rejects --previous-report")
        if args.input_origin == "m8-chain" and args.previous_report is None:
            raise EncoderAssetError("M8-chain compare requires --previous-report")
        if any(item is not None for item in seed_arguments):
            raise EncoderAssetError("compare mode rejects seed-receipt arguments")
    else:
        required = seed_arguments
        if any(item is None for item in required):
            raise EncoderAssetError(
                "verify-seed mode requires --seed-output, --seed-report, "
                "--receipt-manifest, --receipt-manifest-sha256, and "
                "--expected-source-state-file"
            )
        if any(
            item is not None
            for item in (
                args.layer,
                args.output_dir,
                args.asset_dir,
                args.runtime_input,
                args.output_dump,
                args.report,
                args.input_origin,
                args.previous_report,
            )
        ):
            raise EncoderAssetError("verify-seed mode rejects stage/compare arguments")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        _validate_arguments(args)
        if args.stage:
            path, evidence, digest = stage_encoder_layer_assets(
                args.layer, args.output_dir
            )
            staged_words = sum(row["stored_words"] for row in evidence["staged"])
            print(
                "M8_MODE3_ENCODER_ASSET_STAGE_PASS "
                f"layer={args.layer} phase={evidence['phase']} files=18 "
                f"staged_words={staged_words} evidence={path} "
                f"evidence_sha256={digest}"
            )
            return 0

        if args.verify_seed:
            receipt = verify_e02_seed_receipt(
                args.seed_output,
                args.seed_report,
                args.receipt_manifest,
                args.receipt_manifest_sha256,
                args.expected_source_state_file,
            )
            print(
                "M8_MODE3_ENCODER_E02_SEED_RECEIPT_PASS "
                f"files={receipt['files']} "
                f"manifest_sha256={receipt['receipt_manifest_sha256']} "
                f"output_sha256={receipt['output_sha256']} "
                f"report_sha256={receipt['report_sha256']}"
            )
            return 0

        report, digest = compare_encoder_output(
            args.asset_dir,
            args.runtime_input,
            args.output_dump,
            args.report,
            input_origin=args.input_origin,
            previous_report=args.previous_report,
        )
        comparison = report["comparison"]
        print(
            f"M8_MODE3_ENCODER_T004_COMPARE_{report['decision']} "
            f"layer={report['layer']} phase={report['phase']} "
            f"input_origin={report['input']['origin']} "
            f"words={report['output']['words']} "
            f"exact_mismatch={comparison['exact_mismatches']} "
            f"tolerance_failures={comparison['tolerance_failures']} "
            f"actual_nonfinite={report['output']['actual_nonfinite']} "
            f"abs_tolerance={comparison['abs_tolerance']:.9e} "
            f"rel_tolerance={comparison['rel_tolerance']:.9e} "
            f"max_abs={comparison['max_abs']:.9e} "
            f"mean_abs={comparison['mean_abs']:.9e} "
            f"rmse={comparison['rmse']:.9e} "
            f"report_sha256={digest}"
        )
        return 0 if report["decision"] == "PASS" else 1
    except (EncoderAssetError, AssetValidationError) as exc:
        print(f"M8_MODE3_ENCODER_ASSET_FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
