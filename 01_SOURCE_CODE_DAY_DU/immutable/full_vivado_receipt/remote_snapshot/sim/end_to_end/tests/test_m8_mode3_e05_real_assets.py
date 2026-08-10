#!/usr/bin/env python3
"""Fail-closed tests for the M8 continuous package-v3 real-E05 harness."""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


END_TO_END = Path(__file__).resolve().parents[1]
if str(END_TO_END) not in sys.path:
    sys.path.insert(0, str(END_TO_END))

import m8_mode3_e05_real_assets as e05  # noqa: E402
import m8_e05_run_evidence as run_evidence  # noqa: E402
import m7_mode3_real_assets as common  # noqa: E402
import verify_m8_e05_launch_manifest as launch_manifest  # noqa: E402
from m7_mode3_real_assets import AssetValidationError  # noqa: E402


WORKSPACE = END_TO_END.parents[2]


class M8Mode3E05AssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temporary.name).resolve()
        cls.assets_a = cls.base / "assets-a"
        cls.assets_b = cls.base / "assets-b"
        cls.evidence_a, cls.value_a, cls.hash_a = e05.stage_e05_assets(
            cls.assets_a
        )
        cls.evidence_b, cls.value_b, cls.hash_b = e05.stage_e05_assets(
            cls.assets_b
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def _copy_exact_outputs(
        self, label: str
    ) -> tuple[list[Path], Path, Path, Path, Path]:
        outputs = self.base / label
        outputs.mkdir()
        checkpoints = []
        for name, _, _ in e05.CHECKPOINT_GOLDENS:
            source = self.assets_a / f"golden_{name}_f32.hex"
            destination = outputs / f"{name}_rtl.hex"
            destination.write_bytes(source.read_bytes())
            checkpoints.append(destination)
        final_ln = outputs / "final_ln.hex"
        logits = outputs / "logits.hex"
        probabilities = outputs / "probabilities.hex"
        final_ln.write_bytes(
            (self.assets_a / "golden_final_layernorm_f32.hex").read_bytes()
        )
        logits.write_bytes((self.assets_a / "golden_logits_f32.hex").read_bytes())
        probabilities.write_bytes(
            (self.assets_a / "golden_probabilities_f32.hex").read_bytes()
        )
        logit_words = logits.read_text(encoding="ascii").splitlines()
        class_result = outputs / "class.hex"
        class_result.write_text(
            f"{e05.EXPECTED_TOP1:08x}\n{logit_words[e05.EXPECTED_TOP1]}\n",
            encoding="ascii",
        )
        return checkpoints, final_ln, logits, probabilities, class_result

    @staticmethod
    def _replace_hex_word(path: Path, index: int, replacement: str) -> None:
        words = path.read_text(encoding="ascii").splitlines()
        words[index] = replacement
        path.write_text("\n".join(words) + "\n", encoding="ascii")

    @staticmethod
    def _offset_hex_float(word: str, offset: float = 1.0) -> str:
        bits = int(word, 16)
        value = struct.unpack(">f", struct.pack(">I", bits))[0]
        return f"{struct.unpack('>I', struct.pack('>f', value + offset))[0]:08x}"

    def test_stage_is_deterministic_and_complete(self) -> None:
        self.assertEqual(self.evidence_a.read_bytes(), self.evidence_b.read_bytes())
        self.assertEqual(self.value_a, self.value_b)
        self.assertEqual(self.hash_a, self.hash_b)
        self.assertEqual(
            self.hash_a,
            "ed53c37fc8db0d3626b733ef2aa2a0670c405d3aeb70308ab9067f677187be46",
        )
        self.assertEqual(self.value_a["schema"], e05.E05_ASSET_SCHEMA)
        self.assertEqual(len(self.value_a["staged"]), 18)
        self.assertEqual(len(self.value_a["behavioral_goldens"]), 16)
        self.assertEqual(
            self.value_a["checkpoint_contract"],
            {
                "embedding": 1,
                "encoder_step20": 12,
                "words_each": 151_296,
                "layout": "TOKEN_MAJOR_HIDDEN_MINOR_FP32_U32",
            },
        )
        roles = {row["role"] for row in self.value_a["staged"]}
        self.assertEqual(len(roles), 18)
        self.assertIn("prepared_input", roles)
        self.assertIn("runtime_offsets", roles)
        self.assertIn("golden_checkpoint_12_encoder_layer_11_step_20", roles)
        self.assertIn("golden_probabilities", roles)
        self.assertEqual(e05.validate_staged_e05(self.assets_a), self.value_a)

    def test_cli_validate_marker_and_argument_fail_closed(self) -> None:
        stage_command = (
            sys.executable,
            str(END_TO_END / "stage_m8_mode3_e05_real_assets.py"),
            "--stage",
            "--output-dir",
            str(self.base / "assets-cli"),
        )
        staged = subprocess.run(
            stage_command,
            cwd=self.base,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(staged.returncode, 0, staged.stderr)
        self.assertIsNotNone(
            re.fullmatch(
                r"M8_MODE3_E05_ASSET_STAGE_PASS files=18 checkpoints=13 "
                r"runtime_offsets=200 model_words=43421440 input_words=150528 "
                r"scratch_words=1990656 evidence=.+ "
                r"evidence_sha256=" + self.hash_a,
                staged.stdout.strip(),
            ),
            staged.stdout,
        )

        command = (
            sys.executable,
            str(END_TO_END / "stage_m8_mode3_e05_real_assets.py"),
            "--validate",
            "--asset-dir",
            str(self.assets_a),
        )
        completed = subprocess.run(
            command,
            cwd=self.base,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            completed.stdout.strip(),
            "M8_MODE3_E05_ASSET_VALIDATE_PASS files=18 checkpoints=13 "
            "runtime_offsets=200 mode=3 geometry=R8C2L16S8",
        )
        rejected = subprocess.run(
            (*command, "--output-dir", str(self.base / "forbidden")),
            cwd=self.base,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("validate mode rejects", rejected.stderr)

    def test_behavioral_oracle_accepts_exact_independent_goldens(self) -> None:
        checkpoints, final_ln, logits, probabilities, class_result = (
            self._copy_exact_outputs("exact-output")
        )
        outputs = final_ln.parent
        report_path = outputs / "behavioral.json"
        report, report_sha256 = e05.compare_behavioral_goldens(
            self.assets_a,
            checkpoints,
            final_ln,
            logits,
            probabilities,
            class_result,
            report_path,
        )
        self.assertEqual(report["decision"], "PASS")
        self.assertEqual(len(report["checkpoints"]), 13)
        self.assertTrue(
            all(row["decision"] == "PASS" for row in report["checkpoints"])
        )
        self.assertTrue(
            all(
                row["decision"] == "PASS"
                for row in report["final_outputs"].values()
            )
        )
        self.assertEqual(report["top1_and_class"]["class_result"], 879)
        self.assertEqual(
            hashlib.sha256(report_path.read_bytes()).hexdigest(), report_sha256
        )

    def test_endpoint_oracle_rejects_exact_embedding_and_classifier_mutations(
        self,
    ) -> None:
        checkpoints, final_ln, logits, _, _ = self._copy_exact_outputs(
            "endpoint-negative-output"
        )
        embedding_oracle = [
            int(word, 16)
            for word in checkpoints[0].read_text(encoding="ascii").splitlines()
        ]
        classifier_oracle = [
            int(word, 16)
            for word in logits.read_text(encoding="ascii").splitlines()
        ]
        self._replace_hex_word(
            checkpoints[0], 0, f"{embedding_oracle[0] ^ 1:08x}"
        )
        self._replace_hex_word(logits, 0, f"{classifier_oracle[0] ^ 1:08x}")
        report_path = final_ln.parent / "endpoint-negative.json"
        with (
            mock.patch.object(e05, "_read_model_entry", return_value=[]),
            mock.patch.object(
                common,
                "_iter_e01_m6_current_adder_oracle",
                return_value=iter(embedding_oracle),
            ),
            mock.patch.object(
                common, "e04_logits_oracle", return_value=classifier_oracle
            ),
        ):
            report, _ = e05.compare_endpoint_arithmetic(
                self.assets_a,
                checkpoints[0],
                final_ln,
                logits,
                report_path,
            )
        self.assertEqual(report["decision"], "FAIL")
        self.assertEqual(report["embedding"]["exact_mismatches"], 1)
        self.assertEqual(report["embedding"]["first_exact_mismatch"], 0)
        self.assertEqual(report["classifier"]["exact_mismatches"], 1)
        self.assertEqual(report["classifier"]["first_exact_mismatch"], 0)

    def test_behavioral_oracle_rejects_tolerance_nonfinite_sentinel_and_class(
        self,
    ) -> None:
        checkpoints, final_ln, logits, probabilities, class_result = (
            self._copy_exact_outputs("behavioral-negative-output")
        )
        encoder_word = checkpoints[1].read_text(encoding="ascii").splitlines()[0]
        final_ln_word = final_ln.read_text(encoding="ascii").splitlines()[0]
        self._replace_hex_word(
            checkpoints[1], 0, self._offset_hex_float(encoder_word)
        )
        self._replace_hex_word(checkpoints[2], 0, "7f800000")
        self._replace_hex_word(checkpoints[3], 0, "deadbeef")
        self._replace_hex_word(final_ln, 0, self._offset_hex_float(final_ln_word))
        self._replace_hex_word(logits, 0, "7f7fffff")
        self._replace_hex_word(probabilities, 0, "3f000000")
        class_result.write_text("0000036e\n00000000\n", encoding="ascii")
        report, _ = e05.compare_behavioral_goldens(
            self.assets_a,
            checkpoints,
            final_ln,
            logits,
            probabilities,
            class_result,
            final_ln.parent / "behavioral-negative.json",
        )
        self.assertEqual(report["decision"], "FAIL")
        self.assertEqual(report["checkpoints"][1]["decision"], "FAIL")
        self.assertGreater(
            report["checkpoints"][1]["tolerance_failures"], 0
        )
        self.assertGreater(report["checkpoints"][2]["actual_nonfinite"], 0)
        self.assertGreater(report["checkpoints"][3]["sentinel_words"], 0)
        self.assertEqual(report["final_outputs"]["final_layernorm"]["decision"], "FAIL")
        self.assertEqual(report["final_outputs"]["logits"]["decision"], "FAIL")
        self.assertEqual(report["final_outputs"]["probabilities"]["decision"], "FAIL")
        self.assertEqual(report["top1_and_class"]["decision"], "FAIL")
        self.assertEqual(report["top1_and_class"]["class_result"], 878)
        self.assertFalse(
            report["top1_and_class"]["class_logit_matches_dump"]
        )
        self.assertGreater(
            report["top1_and_class"]["probability_sum_abs_error"],
            e05.PROBABILITY_SUM_ABS_TOLERANCE,
        )

    def test_behavioral_oracle_rejects_swapped_checkpoint_order(self) -> None:
        checkpoints, final_ln, logits, probabilities, class_result = (
            self._copy_exact_outputs("behavioral-order-negative-output")
        )
        checkpoints[1], checkpoints[2] = checkpoints[2], checkpoints[1]
        report, _ = e05.compare_behavioral_goldens(
            self.assets_a,
            checkpoints,
            final_ln,
            logits,
            probabilities,
            class_result,
            final_ln.parent / "behavioral-order-negative.json",
        )
        self.assertEqual(report["decision"], "FAIL")
        self.assertEqual(report["checkpoints"][1]["decision"], "FAIL")
        self.assertEqual(report["checkpoints"][2]["decision"], "FAIL")

    def test_recorded_quality_envelope_tamper_fails(self) -> None:
        tampered = self.base / "tampered-assets"
        evidence_path, evidence, _ = e05.stage_e05_assets(tampered)
        evidence["quality_envelope"]["encoder_abs"] = 1.0
        evidence_path.write_text(
            json.dumps(evidence, indent=2, sort_keys=True, separators=(",", ": "))
            + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssetValidationError, "quality envelope"):
            e05.validate_staged_e05(tampered)

        evidence["quality_envelope"]["encoder_abs"] = e05.ENCODER_ABS_TOLERANCE
        prepared = tampered / "prepared_input_f32.hex"
        payload = bytearray(prepared.read_bytes())
        payload[0] = ord("f") if payload[0] != ord("f") else ord("e")
        prepared.write_bytes(payload)
        prepared_row = next(
            row for row in evidence["staged"] if row["role"] == "prepared_input"
        )
        prepared_row["staged_sha256"] = hashlib.sha256(payload).hexdigest()
        evidence_path.write_text(
            json.dumps(evidence, indent=2, sort_keys=True, separators=(",", ": "))
            + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(AssetValidationError, "staged contract"):
            e05.validate_staged_e05(tampered)

    def test_endpoint_gate_rejects_missing_absolute_dump(self) -> None:
        report = self.base / "not-created.json"
        missing = self.base / "missing.hex"
        with self.assertRaisesRegex(AssetValidationError, "cannot inspect"):
            e05.compare_endpoint_arithmetic(
                self.assets_a,
                missing,
                missing,
                missing,
                report,
            )
        self.assertFalse(report.exists())


class M8E05LaunchHardeningTests(unittest.TestCase):
    def test_external_manifest_binds_every_required_file_and_mutation_fails(
        self,
    ) -> None:
        manifest_path = END_TO_END / "m8_e05_launch_manifest.json"
        receipt = launch_manifest.verify_launch_manifest(
            WORKSPACE, manifest_path
        )
        self.assertEqual(receipt["entries"], len(launch_manifest.EXPECTED_PATHS))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(
            [(row["role"], row["path"]) for row in manifest["entries"]],
            list(launch_manifest.EXPECTED_PATHS),
        )

        runner = END_TO_END / "run_e05_mode3_real_axi_rtl_verilator.sh"
        runner_text = runner.read_text(encoding="utf-8")
        self.assertLess(
            runner_text.index("vit_m8_e05_launch_receipt="),
            runner_text.index("mkdir -p \"${vit_m8_e05_run_root}\""),
        )
        self.assertLess(
            runner_text.index("vit_m8_e05_launch_receipt="),
            runner_text.index("--stage --output-dir"),
        )
        self.assertLess(
            runner_text.index("vit_m8_e05_launch_receipt="),
            runner_text.index("nice -n 15 verilator"),
        )
        timeout_branch = runner_text.index(
            'if [[ "${vit_m8_e05_run_status[0]}" == 124 ]]'
        )
        evidence_call = runner_text.index(
            'python3 "${vit_m8_e05_run_evidence_helper}"'
        )
        self.assertLess(timeout_branch, evidence_call)
        salvage_branch = runner_text.index(
            'if [[ "${vit_m8_e05_salvage}" == 1 ]]'
        )
        salvage_exit = runner_text.index("    exit 1", salvage_branch)
        continuous_pass = runner_text.index(
            "M8_MODE3_E05_CONTINUOUS_NUMERICAL_RUN_PASS"
        )
        self.assertLess(salvage_branch, salvage_exit)
        self.assertLess(salvage_exit, continuous_pass)

        with tempfile.TemporaryDirectory() as temporary:
            copied_workspace = Path(temporary).resolve()
            copied_manifest = copied_workspace / "manifest.json"
            copied_manifest.write_bytes(manifest_path.read_bytes())
            for row in manifest["entries"]:
                source = WORKSPACE / row["path"]
                destination = copied_workspace / row["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            launch_manifest.verify_launch_manifest(
                copied_workspace, copied_manifest
            )
            for row in manifest["entries"]:
                target = copied_workspace / row["path"]
                original = target.read_bytes()
                target.write_bytes(original + b"\nM8_E05_MUTATION_TEST\n")
                with self.assertRaisesRegex(
                    launch_manifest.LaunchManifestError,
                    rf"launch input changed: role={re.escape(row['role'])}",
                ):
                    launch_manifest.verify_launch_manifest(
                        copied_workspace, copied_manifest
                    )
                target.write_bytes(original)
            launch_manifest.verify_launch_manifest(
                copied_workspace, copied_manifest
            )

    @staticmethod
    def _structural_pass_marker() -> str:
        return (
            "VIT_PHASE_E_AXI_E05_MODE3_REAL_RTL_STRUCTURAL_PASS "
            "mode=3 rows=8 cols=2 checks=1 cycles=100 job_cycles=90 "
            "commands=249 checkpoints_dumped=13 blocked_gemm=74 packed_gemm=74 "
            "fp16_gemm=98 row_major_gemm=24 packed_tiles=133680000 "
            "nonpacked_tiles=5832000 reads=200 writes=59130368 "
            "axi_stalls=0 model_reads=100 input_reads=1 scratch_reads=99 "
            "cmd_active=50 logical_reads=190 cache_hits=10 "
            "valid_mac=17563828224 tail_mac=293707776 class=879 "
            "logit=3f800000 "
            "numerical_status=PENDING_EXTERNAL_ARITHMETIC_AND_FP32_ORACLES"
        )

    def _make_complete_synthetic_run(
        self, root: Path
    ) -> tuple[Path, Path, run_evidence.OutputContract, list[str]]:
        output = root / "outputs"
        output.mkdir(parents=True)
        contract = run_evidence.OutputContract(
            checkpoint_words_each=2,
            final_ln_words=2,
            logits_words=3,
            probabilities_words=3,
            class_result_words=2,
        )
        for path, words in run_evidence._output_files(output, contract):
            path.write_text("00000000\n" * words, encoding="ascii")
        lines = [
            "M8_MODE3_E05_CHECKPOINT_DUMP index=0 section=EMBEDDING "
            f"layer=15 step=3 words=151296 path={output / 'checkpoint_00_embedding_rtl_f32.hex'}"
        ]
        lines.extend(
            "M8_MODE3_E05_CHECKPOINT_DUMP "
            f"index={layer + 1} section=ENCODER layer={layer} step=19 "
            f"words=151296 path={output / f'checkpoint_{layer + 1:02d}_encoder_layer_{layer:02d}_step_20_rtl_f32.hex'}"
            for layer in range(12)
        )
        lines.extend(
            (
                "M8_MODE3_E05_OUTPUT_DUMPS checkpoints=13 "
                "checkpoint_words_each=2 final_ln_words=2 logits_words=3 "
                "probabilities_words=3 class_result_words=2 "
                f"output_dir={output} "
                "numerical_status=PENDING_EXTERNAL_ARITHMETIC_AND_FP32_ORACLES",
                "M8_MODE3_E05_TRAFFIC_DIAGNOSTIC reads=200 "
                "first_run_gate=ALGEBRA_PROTOCOL_ONLY",
                self._structural_pass_marker(),
            )
        )
        log = root / "run.log"
        log.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return log, output, contract, lines

    def test_raw_gate_accepts_clean_exit_zero_full_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log, output, contract, _ = self._make_complete_synthetic_run(
                Path(temporary).resolve()
            )
            receipt = run_evidence.classify_run_evidence(
                log,
                output,
                simulator_status=0,
                tee_status=0,
                contract=contract,
            )
            self.assertEqual(receipt.decision, "STRUCTURAL_PASS")
            self.assertEqual(receipt.cycles, 100)
            self.assertEqual(receipt.job_cycles, 90)
            self.assertEqual(receipt.reads, 200)

    def test_raw_gate_salvages_only_nonzero_late_structural_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log, output, contract, lines = self._make_complete_synthetic_run(
                Path(temporary).resolve()
            )
            lines[-1] = (
                "[100] %Error: tb.sv:1957: Assertion failed in TOP: "
                "VIT_PHASE_E_AXI_E05_MODE3_REAL_RTL_STRUCTURAL_FAIL "
                "checks=10 failures=1"
            )
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            receipt = run_evidence.classify_run_evidence(
                log,
                output,
                simulator_status=1,
                tee_status=0,
                contract=contract,
            )
            self.assertEqual(receipt.decision, "SALVAGE_NUMERICAL_ONLY")
            self.assertEqual(receipt.simulator_status, 1)

    def test_raw_gate_never_salvages_timeout_or_partial_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            with self.assertRaisesRegex(
                run_evidence.RunEvidenceError, "timeout status 124"
            ):
                run_evidence.classify_run_evidence(
                    root / "missing.log",
                    root / "missing-output",
                    simulator_status=124,
                    tee_status=0,
                )
            log = root / "partial.log"
            output = root / "partial-output"
            output.mkdir()
            log.write_text(
                "M8_MODE3_E05_CHECKPOINT_DUMP index=0 section=EMBEDDING\n"
                "VIT_PHASE_E_AXI_E05_MODE3_REAL_RTL_STRUCTURAL_FAIL\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                run_evidence.RunEvidenceError, "output-dump marker count=0"
            ):
                run_evidence.classify_run_evidence(
                    log,
                    output,
                    simulator_status=1,
                    tee_status=0,
                )

    def test_raw_gate_rejects_missing_malformed_and_reordered_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log, output, contract, lines = self._make_complete_synthetic_run(
                Path(temporary).resolve()
            )
            logits = output / "logits_rtl_f32.hex"
            logits.unlink()
            with self.assertRaisesRegex(
                run_evidence.RunEvidenceError, "is missing/nonregular"
            ):
                run_evidence.classify_run_evidence(
                    log,
                    output,
                    simulator_status=0,
                    tee_status=0,
                    contract=contract,
                )
            logits.write_text("not_hex\n" * 3, encoding="ascii")
            with self.assertRaisesRegex(
                run_evidence.RunEvidenceError, "malformed E05 dump"
            ):
                run_evidence.classify_run_evidence(
                    log,
                    output,
                    simulator_status=0,
                    tee_status=0,
                    contract=contract,
                )
            logits.write_text("00000000\n" * 3, encoding="ascii")
            lines[1], lines[2] = lines[2], lines[1]
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(
                run_evidence.RunEvidenceError,
                "out of order or malformed",
            ):
                run_evidence.classify_run_evidence(
                    log,
                    output,
                    simulator_status=0,
                    tee_status=0,
                    contract=contract,
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
