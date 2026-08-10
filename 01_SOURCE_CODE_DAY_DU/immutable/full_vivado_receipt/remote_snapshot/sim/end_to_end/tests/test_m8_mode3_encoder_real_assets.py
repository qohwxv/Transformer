#!/usr/bin/env python3
"""Lightweight fail-closed tests for M8 real encoder asset tooling."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


END_TO_END = Path(__file__).resolve().parents[1]
if str(END_TO_END) not in sys.path:
    sys.path.insert(0, str(END_TO_END))

import m8_mode3_encoder_real_assets as assets  # noqa: E402


class M8EncoderPinTests(unittest.TestCase):
    def test_t004_manifest_and_all_encoder_checkpoint_pins(self) -> None:
        root = assets.base.discover_workspace_root()
        pins = assets._load_t004_pins(root)
        self.assertEqual(len(assets.T004_INPUT_PATHS), 12)
        self.assertEqual(len(assets.T004_OUTPUT_PATHS), 12)
        for relative in set(assets.T004_INPUT_PATHS + assets.T004_OUTPUT_PATHS):
            path, pin = assets._validate_t004_checkpoint(root, relative, pins)
            self.assertTrue(path.is_file())
            self.assertEqual(pin.size_bytes, assets.T004_TEXT_BYTES)

    def test_package_v3_layer_roles_and_extents(self) -> None:
        validation = assets.base.validate_canonical_package()
        for layer in (0, 1, 11):
            entries = assets._layer_entries(validation, layer)
            self.assertEqual([entry.slot for entry in entries], list(range(16)))
            self.assertEqual(
                [entry.role for entry in entries],
                [role for role, _ in assets.ROLE_SPECS],
            )
            self.assertEqual(
                sum(entry.word_count for entry in entries), 3_548_928
            )

    def test_invalid_layer_and_fixed_envelopes_fail_closed(self) -> None:
        for value in (-1, 12, True, 1.5, "1"):
            with self.assertRaises(assets.EncoderAssetError):
                assets._validate_layer(value)  # type: ignore[arg-type]
        self.assertEqual(
            assets.QUALITY_ENVELOPES,
            {
                "t004": {"abs_tolerance": 2.0e-2, "rel_tolerance": 5.0e-3},
                "m8-chain": {"abs_tolerance": 8.0e-2, "rel_tolerance": 2.0e-2},
            },
        )


class M8EncoderComparisonTests(unittest.TestCase):
    @staticmethod
    def _write_zero_words(path: Path) -> str:
        payload = b"00000000\n" * assets.HIDDEN_WORDS
        path.write_bytes(payload)
        return hashlib.sha256(payload).hexdigest()

    @staticmethod
    def _evidence(layer: int, input_sha: str, golden_sha: str) -> dict[str, object]:
        return {
            "schema": assets.ASSET_SCHEMA,
            "phase": "e02" if layer == 0 else "e03",
            "layer": layer,
            "execution_mode": 3,
            "t004": {
                "input_sha256": input_sha,
                "golden_sha256": golden_sha,
                "golden_relative_path": assets.T004_OUTPUT_PATHS[layer].as_posix(),
            },
            "staged": [
                {"role": "input_t004", "filename": "input_t004_f32.hex"},
                {"role": "golden_t004", "filename": "golden_t004_f32.hex"},
            ],
        }

    def test_t004_and_continuous_chain_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            layer0 = root / "layer0"
            layer0.mkdir()
            input0 = layer0 / "input_t004_f32.hex"
            golden0 = layer0 / "golden_t004_f32.hex"
            output0 = root / "layer0_output.hex"
            input0_sha = self._write_zero_words(input0)
            golden0_sha = self._write_zero_words(golden0)
            output0_sha = self._write_zero_words(output0)
            (layer0 / "asset_evidence.json").write_text("{}\n", encoding="utf-8")
            evidence0 = self._evidence(0, input0_sha, golden0_sha)
            report0_path = root / "layer0_report.json"
            with mock.patch.object(assets, "_load_staged_evidence", return_value=evidence0):
                report0, _ = assets.compare_encoder_output(
                    layer0,
                    input0,
                    output0,
                    report0_path,
                    input_origin="t004",
                )
            self.assertEqual(report0["decision"], "PASS")
            self.assertEqual(report0["output"]["sha256"], output0_sha)

            layer1 = root / "layer1"
            layer1.mkdir()
            input1_t004 = layer1 / "input_t004_f32.hex"
            golden1 = layer1 / "golden_t004_f32.hex"
            self._write_zero_words(input1_t004)
            golden1_sha = self._write_zero_words(golden1)
            output1 = root / "layer1_output.hex"
            self._write_zero_words(output1)
            (layer1 / "asset_evidence.json").write_text("{}\n", encoding="utf-8")
            evidence1 = self._evidence(1, input0_sha, golden1_sha)
            with mock.patch.object(assets, "_load_staged_evidence", return_value=evidence1):
                report1, _ = assets.compare_encoder_output(
                    layer1,
                    output0,
                    output1,
                    root / "layer1_report.json",
                    input_origin="m8-chain",
                    previous_report=report0_path,
                )
            self.assertEqual(report1["decision"], "PASS")
            self.assertEqual(report1["input"]["origin"], "m8-chain")

    def test_chain_rejects_unbound_previous_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            assets_dir = root / "assets"
            assets_dir.mkdir()
            runtime = root / "runtime.hex"
            golden = assets_dir / "golden_t004_f32.hex"
            input_t004 = assets_dir / "input_t004_f32.hex"
            runtime_sha = self._write_zero_words(runtime)
            golden_sha = self._write_zero_words(golden)
            self._write_zero_words(input_t004)
            output = root / "output.hex"
            self._write_zero_words(output)
            (assets_dir / "asset_evidence.json").write_text("{}\n", encoding="utf-8")
            previous = root / "previous.json"
            previous.write_text(
                json.dumps(
                    {
                        "schema": assets.COMPARISON_SCHEMA,
                        "decision": "PASS",
                        "layer": 0,
                        "output": {"sha256": "0" * 64},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            evidence = self._evidence(1, runtime_sha, golden_sha)
            with mock.patch.object(assets, "_load_staged_evidence", return_value=evidence):
                with self.assertRaisesRegex(assets.EncoderAssetError, "does not bind"):
                    assets.compare_encoder_output(
                        assets_dir,
                        runtime,
                        output,
                        root / "report.json",
                        input_origin="m8-chain",
                        previous_report=previous,
                    )

    def test_split_e03_seed_rejects_unpinned_receipt_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "output.hex"
            report = root / "report.json"
            manifest = root / "RUN_SHA256SUMS.txt"
            source_state = root / "CURRENT_SOURCE_STATE.txt"
            output.write_text("00000000\n", encoding="ascii")
            report.write_text("{}\n", encoding="utf-8")
            manifest.write_text("", encoding="ascii")
            source_state.write_text("state\n", encoding="utf-8")
            with self.assertRaisesRegex(
                assets.EncoderAssetError, "external SHA-256 mismatch"
            ):
                assets.verify_e02_seed_receipt(
                    output,
                    report,
                    manifest,
                    "0" * 64,
                    source_state,
                )

    def test_split_e03_seed_accepts_complete_pinned_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            receipt = root / "e02_receipt"
            asset_dir = receipt / "layers/layer00/assets"
            output_dir = receipt / "layers/layer00/outputs"
            asset_dir.mkdir(parents=True)
            output_dir.mkdir(parents=True)
            input_path = asset_dir / "input_t004_f32.hex"
            golden_path = asset_dir / "golden_t004_f32.hex"
            output_path = output_dir / "encoder_output_rtl_f32.hex"
            input_sha = self._write_zero_words(input_path)
            golden_sha = self._write_zero_words(golden_path)
            output_sha = self._write_zero_words(output_path)
            asset_evidence = asset_dir / "asset_evidence.json"
            asset_evidence.write_text("{}\n", encoding="utf-8")
            comparison = {
                "abs_tolerance": assets.QUALITY_ENVELOPES["t004"][
                    "abs_tolerance"
                ],
                "rel_tolerance": assets.QUALITY_ENVELOPES["t004"][
                    "rel_tolerance"
                ],
                "exact_mismatches": 0,
                "tolerance_failures": 0,
                "max_abs": 0.0,
                "max_abs_index": 0,
                "mean_abs": 0.0,
                "rmse": 0.0,
            }
            report = {
                "schema": assets.COMPARISON_SCHEMA,
                "decision": "PASS",
                "layer": 0,
                "phase": "e02",
                "execution_mode": 3,
                "input": {
                    "origin": "t004",
                    "path": str(input_path),
                    "sha256": input_sha,
                    "previous_report_path": None,
                    "previous_report_sha256": None,
                    "t004_reference_sha256": input_sha,
                },
                "output": {
                    "path": str(output_path),
                    "sha256": output_sha,
                    "words": assets.HIDDEN_WORDS,
                    "actual_nonfinite": 0,
                },
                "golden": {
                    "relative_path": assets.T004_OUTPUT_PATHS[0].as_posix(),
                    "sha256": golden_sha,
                    "words": assets.HIDDEN_WORDS,
                    "nonfinite": 0,
                },
                "comparison": comparison,
                "asset_evidence_sha256": assets.base.sha256_file(asset_evidence),
                "t004_manifest_sha256": assets.T004_MANIFEST_SHA256,
            }
            report_path = output_dir / "t004_comparison.json"
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            source_text = "M8_MODE3_ENCODER_SOURCE_STATE synthetic-test\n"
            (receipt / "SOURCE_STATE_BEFORE.txt").write_text(
                source_text, encoding="utf-8"
            )
            (receipt / "SOURCE_STATE_AFTER.txt").write_text(
                source_text, encoding="utf-8"
            )
            (receipt / "summary.log").write_text(
                "M8_MODE3_ENCODER_SEQUENCE_PASS first_layer=0 last_layer=0 "
                "input_mode=independent layers=1 source_stable=1\n",
                encoding="utf-8",
            )
            current_source = root / "current_source_state.txt"
            current_source.write_text(source_text, encoding="utf-8")
            rows = []
            for path in sorted(item for item in receipt.rglob("*") if item.is_file()):
                relative = path.relative_to(receipt).as_posix()
                rows.append(f"{assets.base.sha256_file(path)}  ./{relative}\n")
            manifest = receipt / "RUN_SHA256SUMS.txt"
            manifest.write_text("".join(rows), encoding="ascii")
            manifest_sha = assets.base.sha256_file(manifest)
            evidence = self._evidence(0, input_sha, golden_sha)
            with mock.patch.object(
                assets, "_load_staged_evidence", return_value=evidence
            ):
                verified = assets.verify_e02_seed_receipt(
                    output_path,
                    report_path,
                    manifest,
                    manifest_sha,
                    current_source,
                )
            self.assertEqual(verified["output_sha256"], output_sha)
            self.assertEqual(verified["receipt_manifest_sha256"], manifest_sha)


if __name__ == "__main__":
    unittest.main()
