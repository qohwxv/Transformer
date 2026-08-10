#!/usr/bin/env python3
"""Lightweight fail-closed and numerical tests for M7 mode-3 assets."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock


END_TO_END = Path(__file__).resolve().parents[1]
if str(END_TO_END) not in sys.path:
    sys.path.insert(0, str(END_TO_END))

import m7_mode3_real_assets as assets  # noqa: E402


class M7Mode3TableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = assets.discover_workspace_root()
        cls.package = cls.root / assets.CANONICAL_PACKAGE_RELATIVE
        cls.table_data = (cls.package / "vit_model_table.bin").read_bytes()
        cls.table_json = json.loads(
            (cls.package / "vit_model_table.json").read_text(encoding="utf-8")
        )

    @staticmethod
    def mutate_entry(
        table_data: bytes,
        index: int,
        field_index: int,
        value: int,
    ) -> bytes:
        header = list(assets.TABLE_HEADER_STRUCT.unpack_from(table_data, 0))
        entries = bytearray(table_data[assets.TABLE_HEADER_BYTES :])
        offset = index * assets.TABLE_ENTRY_BYTES
        fields = list(assets.TABLE_ENTRY_STRUCT.unpack_from(entries, offset))
        fields[field_index] = value
        assets.TABLE_ENTRY_STRUCT.pack_into(entries, offset, *fields)
        header[16] = zlib.crc32(entries) & 0xFFFF_FFFF
        header[17] = 0
        header[17] = (
            zlib.crc32(assets.TABLE_HEADER_STRUCT.pack(*header))
            & 0xFFFF_FFFF
        )
        return assets.TABLE_HEADER_STRUCT.pack(*header) + bytes(entries)

    def test_canonical_full_table_and_model_validate(self) -> None:
        validated = assets.validate_canonical_package()
        self.assertEqual(len(validated.entries), 200)
        self.assertEqual(validated.table_header["layout5_tensors"], 74)
        classifier = validated.entries_by_role["classifier_weight_base"]
        self.assertEqual(
            (classifier.word_offset, classifier.word_count, classifier.layout),
            (449_280, 384_000, 5),
        )

    def test_layout5_change_fails_even_with_repaired_crcs(self) -> None:
        changed = self.mutate_entry(self.table_data, 0, 8, assets.LAYOUT_VECTOR)
        sidecar = copy.deepcopy(self.table_json)
        sidecar["entries"][0]["layout_id"] = assets.LAYOUT_VECTOR
        with self.assertRaisesRegex(assets.AssetValidationError, "nonpacked flags"):
            assets.parse_v3_table(changed, sidecar)

    def test_packed_flag_removal_fails_even_with_repaired_crcs(self) -> None:
        original_flags = int(self.table_json["entries"][0]["flags"], 16)
        changed_flags = original_flags & ~assets.FLAG_FP16_PACKED2
        changed = self.mutate_entry(self.table_data, 0, 14, changed_flags)
        sidecar = copy.deepcopy(self.table_json)
        sidecar["entries"][0]["flags"] = f"0x{changed_flags:08X}"
        with self.assertRaisesRegex(assets.AssetValidationError, "packed flags"):
            assets.parse_v3_table(changed, sidecar)

    def test_offset_and_count_corruption_fail(self) -> None:
        changed_offset = self.mutate_entry(self.table_data, 1, 5, 294_913)
        with self.assertRaisesRegex(assets.AssetValidationError, "word_offset"):
            assets.parse_v3_table(changed_offset, self.table_json)
        changed_count = self.mutate_entry(self.table_data, 0, 6, 294_911)
        with self.assertRaisesRegex(assets.AssetValidationError, "word_count"):
            assets.parse_v3_table(changed_count, self.table_json)

    def test_json_offset_corruption_fails(self) -> None:
        sidecar = copy.deepcopy(self.table_json)
        sidecar["entries"][2]["word_offset"] += 1
        with self.assertRaisesRegex(assets.AssetValidationError, "JSON word offset"):
            assets.parse_v3_table(self.table_data, sidecar)

    def test_entry_crc_and_header_version_corruption_fail(self) -> None:
        changed = bytearray(self.table_data)
        changed[-1] ^= 1
        with self.assertRaisesRegex(assets.AssetValidationError, "entries CRC32"):
            assets.parse_v3_table(bytes(changed), self.table_json)
        changed = bytearray(self.table_data)
        struct.pack_into("<H", changed, 8, 4)
        with self.assertRaisesRegex(assets.AssetValidationError, "version"):
            assets.parse_v3_table(bytes(changed), self.table_json)


class M7Mode3SecurityTests(unittest.TestCase):
    def test_workspace_discovery_does_not_use_cwd(self) -> None:
        original = Path.cwd()
        with tempfile.TemporaryDirectory() as temporary:
            try:
                os.chdir(temporary)
                self.assertEqual(
                    assets.discover_workspace_root(),
                    END_TO_END.parents[2],
                )
            finally:
                os.chdir(original)

    def test_hash_mismatch_symlink_and_nonregular_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            payload = base / "payload.bin"
            payload.write_bytes(b"canonical")
            good = assets.FilePin(
                payload.stat().st_size,
                hashlib.sha256(b"canonical").hexdigest(),
            )
            self.assertEqual(
                assets.verify_pinned_regular_file(payload, good), payload
            )
            bad = assets.FilePin(payload.stat().st_size, "0" * 64)
            with self.assertRaisesRegex(assets.AssetValidationError, "SHA-256"):
                assets.verify_pinned_regular_file(payload, bad)
            link = base / "payload-link.bin"
            link.symlink_to(payload)
            with self.assertRaisesRegex(assets.AssetValidationError, "symlink"):
                assets.verify_pinned_regular_file(link, good)
            with self.assertRaisesRegex(assets.AssetValidationError, "regular file"):
                assets.verify_pinned_regular_file(base, good)

    def test_relative_escape_and_symlink_component_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            root.mkdir()
            outside = base / "outside.bin"
            outside.write_bytes(b"x")
            with self.assertRaisesRegex(assets.AssetValidationError, "non-canonical"):
                assets.secure_regular_file(root, Path("../outside.bin"))
            (root / "link").symlink_to(base)
            with self.assertRaisesRegex(assets.AssetValidationError, "symlink"):
                assets.secure_regular_file(root, Path("link/outside.bin"))


class M7Mode3StagingTests(unittest.TestCase):
    def test_e01_e04_staging_and_deterministic_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            e01 = base / "e01"
            e04_a = base / "e04-a"
            e04_b = base / "e04-b"
            evidence_e01, value_e01, hash_e01 = assets.stage_phase_assets("e01", e01)
            evidence_a, value_a, hash_a = assets.stage_phase_assets("e04", e04_a)
            evidence_b, value_b, hash_b = assets.stage_phase_assets("e04", e04_b)
            self.assertEqual(evidence_a.read_bytes(), evidence_b.read_bytes())
            self.assertEqual(value_a, value_b)
            self.assertEqual(hash_a, hash_b)
            self.assertEqual(
                hash_a,
                "d629372977edcf7fa40f7dff5c53fccc46f256bc22e3ea1d1db6795b1f011e7f",
            )
            self.assertEqual(value_a["schema"], "vit-m7-mode3-real-assets-v2")
            self.assertEqual(
                set(value_a["behavioral_goldens"]),
                {"final_layernorm", "logits", "probabilities"},
            )
            self.assertEqual(value_e01["phase"], "e01")
            self.assertEqual(
                hash_e01,
                "8853f0aadb80665f2a0dba7ea0b65c5566133d42fe6d5f9eea33017fda1c7db6",
            )
            self.assertEqual(len(value_e01["staged"]), 6)
            self.assertEqual(
                set(value_e01["behavioral_goldens"]), {"embedding"}
            )
            self.assertTrue(evidence_e01.is_file())
            e01_counts = {
                row["role"]: row["stored_words"]
                for row in value_e01["staged"]
            }
            self.assertEqual(
                e01_counts,
                {
                    "patch_weight_base": 294_912,
                    "patch_bias_base": 768,
                    "cls_base": 768,
                    "position_base": 151_296,
                    "prepared_input": 150_528,
                    "embedding_golden": 151_296,
                },
            )
            self.assertEqual(
                {
                    row["role"]: row["staged_sha256"]
                    for row in value_e01["staged"]
                },
                dict(assets.E01_STAGED_SHA256_BY_ROLE),
            )
            e04_counts = {
                row["role"]: row["stored_words"]
                for row in value_a["staged"]
            }
            self.assertEqual(
                e04_counts,
                {
                    "final_ln_gamma_base": 768,
                    "final_ln_beta_base": 768,
                    "classifier_weight_base": 384_000,
                    "classifier_bias_base": 1_000,
                },
            )
            final_ln = base / "rtl_final_ln.hex"
            final_ln.write_bytes(b"00000000\n" * (197 * 768))
            logits = base / "rtl_logits.hex"
            logits.write_bytes(
                (e04_a / "classifier_bias_f32.hex").read_bytes()
            )
            report_path = base / "e04_compare.json"
            command = (
                sys.executable,
                str(END_TO_END / "stage_m7_mode3_real_assets.py"),
                "--compare-e04-dumps",
                "--asset-dir",
                str(e04_a),
                "--final-ln-dump",
                str(final_ln),
                "--logits-dump",
                str(logits),
                "--report",
                str(report_path),
            )
            completed = subprocess.run(
                command,
                cwd=base,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            marker = completed.stdout.strip()
            match = re.fullmatch(
                r"M7_MODE3_E04_M6_CLASSIFIER_ORACLE_COMPARE_PASS logits=1000 "
                r"exact_mismatch=0 tolerance_failures=0 "
                r"abs_tolerance=0\.000000000e\+00 "
                r"rel_tolerance=0\.000000000e\+00 "
                r"max_abs=0\.000000000e\+00 "
                r"mean_abs=0\.000000000e\+00 "
                r"top1_actual=[0-9]+ top1_oracle=[0-9]+ "
                r"report_sha256=([0-9a-f]{64})",
                marker,
            )
            self.assertIsNotNone(match, marker)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(
                report["schema"],
                "vit-m7-mode3-e04-m6-classifier-oracle-comparison-v1",
            )
            self.assertEqual(report["decision"], "PASS")
            self.assertEqual(report["comparison"]["exact_mismatches"], 0)
            self.assertEqual(report["comparison"]["tolerance_failures"], 0)
            self.assertEqual(
                hashlib.sha256(report_path.read_bytes()).hexdigest(),
                match.group(1),
            )
            with self.assertRaisesRegex(assets.AssetValidationError, "existing"):
                assets.stage_phase_assets("e04", e04_a)

    def test_e01_external_exact_and_behavioral_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            asset_dir = base / "e01-assets"
            assets.stage_phase_assets("e01", asset_dir)
            golden_path = asset_dir / "embedding_golden_f32.hex"
            golden_words = assets.read_u32_readmemh(golden_path, 151_296)
            rtl_dump = base / "embedding_rtl.hex"
            rtl_dump.write_bytes(golden_path.read_bytes())

            with mock.patch.object(
                assets,
                "_iter_e01_m6_current_adder_oracle",
                return_value=iter(golden_words),
            ):
                exact, exact_sha = (
                    assets.compare_e01_m6_current_adder_oracle_dump(
                        asset_dir,
                        rtl_dump,
                        base / "e01-exact-pass.json",
                    )
                )
            self.assertEqual(exact["decision"], "PASS")
            self.assertEqual(exact["comparison"]["words"], 151_296)
            self.assertEqual(exact["comparison"]["exact_mismatches"], 0)
            self.assertEqual(
                exact["comparison"]["oracle_readmemh_sha256"],
                assets.CANONICAL_E01_GOLDEN_PINS["embedding"][2].sha256,
            )
            self.assertEqual(
                hashlib.sha256(
                    (base / "e01-exact-pass.json").read_bytes()
                ).hexdigest(),
                exact_sha,
            )

            quality, quality_sha = assets.compare_e01_behavioral_golden_dump(
                asset_dir,
                rtl_dump,
                base / "e01-quality-pass.json",
            )
            self.assertEqual(quality["decision"], "PASS")
            self.assertEqual(quality["embedding"]["words"], 151_296)
            self.assertEqual(quality["embedding"]["tolerance_failures"], 0)
            self.assertEqual(
                hashlib.sha256(
                    (base / "e01-quality-pass.json").read_bytes()
                ).hexdigest(),
                quality_sha,
            )
            cli_report = base / "e01-quality-cli-pass.json"
            completed = subprocess.run(
                (
                    sys.executable,
                    str(END_TO_END / "stage_m7_mode3_real_assets.py"),
                    "--compare-e01-behavioral-golden",
                    "--asset-dir",
                    str(asset_dir),
                    "--embedding-dump",
                    str(rtl_dump),
                    "--report",
                    str(cli_report),
                ),
                cwd=base,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertRegex(
                completed.stdout.strip(),
                r"^M7_MODE3_E01_BEHAVIORAL_GOLDEN_COMPARE_PASS "
                r"embedding=151296 exact_mismatch=0 tolerance_failures=0 "
                r"abs_tolerance=5\.000000000e-03 .* "
                r"report_sha256=[0-9a-f]{64}$",
            )
            rejected = subprocess.run(
                (
                    sys.executable,
                    str(END_TO_END / "stage_m7_mode3_real_assets.py"),
                    "--compare-e01-m6-current-adder-oracle",
                ),
                cwd=base,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn(
                "M7_MODE3_E01_M6_CURRENT_ADDER_ORACLE_COMPARE_FAIL",
                rejected.stderr,
            )

            bad_dump = base / "embedding_bad.hex"
            bad_words = golden_path.read_text(encoding="ascii").splitlines()
            bad_words[0] = "7f800000"
            bad_dump.write_text("\n".join(bad_words) + "\n", encoding="ascii")
            with mock.patch.object(
                assets,
                "_iter_e01_m6_current_adder_oracle",
                return_value=iter(golden_words),
            ):
                exact_bad, _ = assets.compare_e01_m6_current_adder_oracle_dump(
                    asset_dir,
                    bad_dump,
                    base / "e01-exact-fail.json",
                )
            self.assertEqual(exact_bad["decision"], "FAIL")
            self.assertEqual(exact_bad["comparison"]["exact_mismatches"], 1)
            quality_bad, _ = assets.compare_e01_behavioral_golden_dump(
                asset_dir,
                bad_dump,
                base / "e01-quality-fail.json",
            )
            self.assertEqual(quality_bad["decision"], "FAIL")
            self.assertEqual(
                quality_bad["embedding"]["tolerance_failures"], 1
            )

    def test_behavioral_golden_gate_covers_all_outputs_and_exact_class(self) -> None:
        root = assets.discover_workspace_root()
        golden_final_ln = root / assets.CANONICAL_E04_GOLDEN_PINS[
            "final_layernorm"
        ][0]
        golden_logits = root / assets.CANONICAL_E04_GOLDEN_PINS["logits"][0]
        golden_probabilities = root / assets.CANONICAL_E04_GOLDEN_PINS[
            "probabilities"
        ][0]
        golden_logit_words = assets.read_u32_readmemh(golden_logits, 1_000)

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            asset_dir = base / "assets"
            assets.stage_phase_assets("e04", asset_dir)
            final_ln = base / "final_ln.hex"
            logits = base / "logits.hex"
            probabilities = base / "probabilities.hex"
            class_result = base / "class_result.hex"
            final_ln.write_bytes(golden_final_ln.read_bytes())
            logits.write_bytes(golden_logits.read_bytes())
            probabilities.write_bytes(golden_probabilities.read_bytes())
            class_result.write_text(
                f"{assets.E04_EXPECTED_TOP1:08x}\n"
                f"{golden_logit_words[assets.E04_EXPECTED_TOP1]:08x}\n",
                encoding="ascii",
            )
            report, report_sha = assets.compare_e04_behavioral_golden_dumps(
                asset_dir,
                final_ln,
                logits,
                probabilities,
                class_result,
                base / "behavioral-pass.json",
            )
            self.assertEqual(report["decision"], "PASS")
            self.assertEqual(report["final_layernorm"]["words"], 151_296)
            self.assertEqual(report["logits"]["words"], 1_000)
            self.assertEqual(report["probabilities"]["words"], 1_000)
            self.assertEqual(
                report["top1_and_class"]["class_result"],
                assets.E04_EXPECTED_TOP1,
            )
            self.assertEqual(
                hashlib.sha256((base / "behavioral-pass.json").read_bytes()).hexdigest(),
                report_sha,
            )
            cli_report = base / "behavioral-cli-pass.json"
            completed = subprocess.run(
                (
                    sys.executable,
                    str(END_TO_END / "stage_m7_mode3_real_assets.py"),
                    "--compare-e04-behavioral-golden",
                    "--asset-dir",
                    str(asset_dir),
                    "--final-ln-dump",
                    str(final_ln),
                    "--logits-dump",
                    str(logits),
                    "--probabilities-dump",
                    str(probabilities),
                    "--class-result-dump",
                    str(class_result),
                    "--report",
                    str(cli_report),
                ),
                cwd=base,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertRegex(
                completed.stdout.strip(),
                r"^M7_MODE3_E04_BEHAVIORAL_GOLDEN_COMPARE_PASS "
                r"final_ln=151296 .* logits=1000 .* probabilities=1000 .* "
                r"expected_top1=879 logits_top1_actual=879 "
                r"logits_top1_golden=879 probabilities_top1_actual=879 "
                r"probabilities_top1_golden=879 class_result=879 "
                r"class_logit_matches_dump=1 report_sha256=[0-9a-f]{64}$",
            )

            bad_final_ln = base / "bad_final_ln.hex"
            bad_final_words = golden_final_ln.read_text(encoding="ascii").splitlines()
            bad_final_words[0] = "7f800000"
            bad_final_ln.write_text("\n".join(bad_final_words) + "\n", encoding="ascii")
            failed, _ = assets.compare_e04_behavioral_golden_dumps(
                asset_dir,
                bad_final_ln,
                logits,
                probabilities,
                class_result,
                base / "behavioral-bad-final-ln.json",
            )
            self.assertEqual(failed["decision"], "FAIL")
            self.assertEqual(failed["final_layernorm"]["tolerance_failures"], 1)

            bad_probabilities = base / "bad_probabilities.hex"
            bad_probability_words = golden_probabilities.read_text(
                encoding="ascii"
            ).splitlines()
            bad_probability_words[0] = "3f800000"
            bad_probabilities.write_text(
                "\n".join(bad_probability_words) + "\n", encoding="ascii"
            )
            failed, _ = assets.compare_e04_behavioral_golden_dumps(
                asset_dir,
                final_ln,
                logits,
                bad_probabilities,
                class_result,
                base / "behavioral-bad-probability.json",
            )
            self.assertEqual(failed["decision"], "FAIL")
            self.assertGreater(failed["probabilities"]["tolerance_failures"], 0)

            bad_class_result = base / "bad_class_result.hex"
            bad_class_result.write_text(
                f"{878:08x}\n{golden_logit_words[878]:08x}\n",
                encoding="ascii",
            )
            failed, _ = assets.compare_e04_behavioral_golden_dumps(
                asset_dir,
                final_ln,
                logits,
                probabilities,
                bad_class_result,
                base / "behavioral-bad-class.json",
            )
            self.assertEqual(failed["decision"], "FAIL")
            self.assertFalse(failed["top1_and_class"]["pass"])


class M7Mode3OracleTests(unittest.TestCase):
    @staticmethod
    def fp32(value: float) -> int:
        return struct.unpack("<I", struct.pack("<f", value))[0]

    def test_current_fp32_add_directed_contract(self) -> None:
        cases = (
            (0x3F80_0000, 0x4000_0000, 0x4040_0000),
            (0x3F80_0000, 0xBF80_0000, 0x0000_0000),
            (0x0000_0000, 0x8000_0000, 0x0000_0000),
            (0x8000_0000, 0x8000_0000, 0x8000_0000),
            (0x0000_0001, 0x3F80_0000, 0x3F80_0000),
            (0x7F80_0000, 0xFF80_0000, 0x7FC0_0000),
            (0x7FA1_2345, 0x3F80_0000, 0x7FC0_0000),
            (0x3F80_0000, 0x3380_0000, 0x3F80_0000),
            (0x3F80_0001, 0x3380_0000, 0x3F80_0002),
        )
        for a, b, expected in cases:
            with self.subTest(a=f"{a:08x}", b=f"{b:08x}"):
                self.assertEqual(assets.fp32_add_current(a, b), expected)

    def packed_fixture(self) -> list[int]:
        # K=2, N=2.  Low half is column 0; high half is column 1.
        packed = [0] * 16
        packed[0] = (0xBC00 << 16) | 0x4200  # [-1.0, +3.0]
        packed[1] = (0x3800 << 16) | 0x4400  # [+0.5, +4.0]
        return packed

    def test_layout_unpack_and_m6_exact_dot_bias(self) -> None:
        packed = self.packed_fixture()
        self.assertEqual(
            assets.packed_fp16_weight_at(
                packed, 0, 0, reduction=2, columns=2
            ),
            0x4200,
        )
        self.assertEqual(
            assets.packed_fp16_weight_at(
                packed, 1, 1, reduction=2, columns=2
            ),
            0x3800,
        )
        logits = assets.e04_logits_oracle(
            [self.fp32(1.0), self.fp32(2.0)],
            packed,
            [self.fp32(0.5), self.fp32(2.0)],
        )
        self.assertEqual(logits, [self.fp32(11.5), self.fp32(2.0)])

    def test_e01_cls_patch_bias_and_position_outputs(self) -> None:
        packed = self.packed_fixture()
        results = assets.e01_outputs_oracle(
            range(4),
            [self.fp32(1.0), self.fp32(2.0)],
            packed,
            [self.fp32(0.5), self.fp32(2.0)],
            [self.fp32(10.0), self.fp32(20.0)],
            [
                self.fp32(1.0),
                self.fp32(-1.0),
                self.fp32(0.25),
                self.fp32(-0.5),
            ],
        )
        self.assertEqual(
            [word.output_fp32_bits for word in results],
            [
                self.fp32(11.0),
                self.fp32(19.0),
                self.fp32(11.75),
                self.fp32(1.5),
            ],
        )
        self.assertIsNone(results[0].dot_fp32_bits)
        self.assertEqual(results[2].dot_fp32_bits, self.fp32(11.0))

    def test_fixed24_fast_path_is_exact_m6_product_grid(self) -> None:
        m6 = assets.load_m6_reference()
        finite = (0x0000, 0x0001, 0x03ff, 0x0400, 0x3555, 0x3c00,
                  0xbc00, 0x7bff, 0xfbff)
        for a in finite:
            for b in finite:
                with self.subTest(a=f"{a:04x}", b=f"{b:04x}"):
                    product = m6.fp16_mul_to_fp32(a, b, ftz=False)
                    self.assertEqual(
                        assets._fp16_to_fixed24_exact(a)
                        * assets._fp16_to_fixed24_exact(b),
                        product.fixed_int,
                    )

    def test_extent_and_index_errors_fail_closed(self) -> None:
        packed = self.packed_fixture()
        with self.assertRaisesRegex(ValueError, "extent mismatch"):
            assets.packed_fp16_weight_at(
                packed[:-1], 0, 0, reduction=2, columns=2
            )
        with self.assertRaises(IndexError):
            assets.packed_fp16_weight_at(
                packed, 2, 0, reduction=2, columns=2
            )


if __name__ == "__main__":
    unittest.main()
