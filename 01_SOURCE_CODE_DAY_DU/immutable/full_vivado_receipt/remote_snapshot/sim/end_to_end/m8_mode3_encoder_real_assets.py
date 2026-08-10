#!/usr/bin/env python3
"""Pinned package-v3/T004 assets for M8 real encoder-layer simulation.

This module is deliberately additive.  It imports the already qualified M7
package-v3 parser but does not modify the receipt-bound E01/E04 helpers.  Each
layer stage contains the exact sixteen package-v3 tensor slices plus an
independently pinned T004 FP32 input and output checkpoint.

The post-run comparison supports two explicit provenance modes:

* ``t004`` compares a layer driven by its independent T004 predecessor; and
* ``m8-chain`` requires the preceding M8 PASS report and consumes that
  preceding RTL dump verbatim, so accumulated encoder drift is visible.

No RTL simulator, Vivado, network access, or production-source mutation is
performed here.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from pathlib import Path, PurePosixPath
from typing import Mapping

import m7_mode3_real_assets as base


ASSET_SCHEMA = "vit-m8-mode3-encoder-real-assets-v1"
COMPARISON_SCHEMA = "vit-m8-mode3-encoder-t004-comparison-v1"
T004_MANIFEST_RELATIVE = Path(
    "baseline/modelsim/T004_MAJOR_CHECKPOINTS_SHA256.txt"
)
T004_MANIFEST_SHA256 = (
    "d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b"
)
HIDDEN_WORDS = 197 * 768
T004_TEXT_BYTES = HIDDEN_WORDS * 9

# These envelopes are fixed before a real M8 E02/E03 result is inspected.
# The independent gate is deliberately tighter than the accumulated chain.
QUALITY_ENVELOPES: Mapping[str, Mapping[str, float]] = {
    "t004": {"abs_tolerance": 2.0e-2, "rel_tolerance": 5.0e-3},
    "m8-chain": {"abs_tolerance": 8.0e-2, "rel_tolerance": 2.0e-2},
}

ROLE_SPECS: tuple[tuple[str, str], ...] = (
    ("ln1_gamma_base", "ln1_gamma_f32.hex"),
    ("ln1_beta_base", "ln1_beta_f32.hex"),
    ("q_weight_base", "q_weight_packed_fp16_u32.hex"),
    ("q_bias_base", "q_bias_f32.hex"),
    ("k_weight_base", "k_weight_packed_fp16_u32.hex"),
    ("k_bias_base", "k_bias_f32.hex"),
    ("v_weight_base", "v_weight_packed_fp16_u32.hex"),
    ("v_bias_base", "v_bias_f32.hex"),
    ("o_weight_base", "o_weight_packed_fp16_u32.hex"),
    ("o_bias_base", "o_bias_f32.hex"),
    ("ln2_gamma_base", "ln2_gamma_f32.hex"),
    ("ln2_beta_base", "ln2_beta_f32.hex"),
    ("fc1_weight_base", "fc1_weight_packed_fp16_u32.hex"),
    ("fc1_bias_base", "fc1_bias_f32.hex"),
    ("fc2_weight_base", "fc2_weight_packed_fp16_u32.hex"),
    ("fc2_bias_base", "fc2_bias_f32.hex"),
)

ROLE_WORDS: Mapping[str, int] = {
    "ln1_gamma_base": 768,
    "ln1_beta_base": 768,
    "q_weight_base": 294_912,
    "q_bias_base": 768,
    "k_weight_base": 294_912,
    "k_bias_base": 768,
    "v_weight_base": 294_912,
    "v_bias_base": 768,
    "o_weight_base": 294_912,
    "o_bias_base": 768,
    "ln2_gamma_base": 768,
    "ln2_beta_base": 768,
    "fc1_weight_base": 1_179_648,
    "fc1_bias_base": 3_072,
    "fc2_weight_base": 1_179_648,
    "fc2_bias_base": 768,
}

T004_INPUT_PATHS: tuple[Path, ...] = (
    Path("results/embedding_step_06_hidden_states_f32.hex"),
    *(Path(f"results/encoder_layer_{layer:02d}_step_20_layer_output_f32.hex")
      for layer in range(11)),
)
T004_OUTPUT_PATHS: tuple[Path, ...] = tuple(
    Path(f"results/encoder_layer_{layer:02d}_step_20_layer_output_f32.hex")
    for layer in range(12)
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA256SUM_RE = re.compile(r"^([0-9a-f]{64})  (\./[^\r\n]+)$")


class EncoderAssetError(base.AssetValidationError):
    """An M8 encoder asset, provenance link, or quality gate failed closed."""


def _validate_layer(layer: int) -> int:
    if isinstance(layer, bool) or not isinstance(layer, int) or not 0 <= layer <= 11:
        raise EncoderAssetError(f"encoder layer must be an integer in 0..11: {layer!r}")
    return layer


def _load_t004_pins(
    workspace_root: Path,
) -> Mapping[str, str]:
    manifest = base.secure_regular_file(
        workspace_root,
        T004_MANIFEST_RELATIVE,
        description="pinned T004 checkpoint manifest",
    )
    actual_manifest_sha256 = base.sha256_file(manifest)
    if actual_manifest_sha256 != T004_MANIFEST_SHA256:
        raise EncoderAssetError(
            "T004 manifest SHA-256 mismatch: expected "
            f"{T004_MANIFEST_SHA256}, got {actual_manifest_sha256}"
        )

    pins: dict[str, str] = {}
    for line_number, line in enumerate(
        manifest.read_text(encoding="ascii").splitlines(), 1
    ):
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not SHA256_RE.fullmatch(parts[0]):
            raise EncoderAssetError(
                f"{T004_MANIFEST_RELATIVE}:{line_number}: malformed entry"
            )
        relative = Path(parts[1].strip())
        text = relative.as_posix()
        if relative.is_absolute() or ".." in relative.parts or text != parts[1].strip():
            raise EncoderAssetError(
                f"{T004_MANIFEST_RELATIVE}:{line_number}: unsafe path"
            )
        if text in pins:
            raise EncoderAssetError(f"duplicate T004 checkpoint path: {text}")
        pins[text] = parts[0]

    required = {path.as_posix() for path in T004_INPUT_PATHS + T004_OUTPUT_PATHS}
    missing = sorted(required - set(pins))
    if missing:
        raise EncoderAssetError(
            "T004 manifest lacks encoder checkpoints: " + ", ".join(missing)
        )
    return pins


def _validate_t004_checkpoint(
    workspace_root: Path,
    relative: Path,
    pins: Mapping[str, str],
) -> tuple[Path, base.FilePin]:
    expected_sha256 = pins[relative.as_posix()]
    pin = base.FilePin(T004_TEXT_BYTES, expected_sha256)
    path = base.secure_regular_file(
        workspace_root,
        relative,
        description="pinned T004 encoder checkpoint",
    )
    base.verify_pinned_regular_file(
        path, pin, description="pinned T004 encoder checkpoint"
    )
    base.read_u32_readmemh(path, HIDDEN_WORDS)
    return path, pin


def _layer_entries(
    validation: base.PackageValidation,
    layer: int,
) -> tuple[base.TableEntry, ...]:
    selected = sorted(
        (
            entry
            for entry in validation.entries
            if entry.group == 1 and entry.layer == layer
        ),
        key=lambda entry: entry.slot,
    )
    if len(selected) != len(ROLE_SPECS):
        raise EncoderAssetError(
            f"package-v3 layer {layer} has {len(selected)} entries, expected 16"
        )
    for slot, (entry, (role, _)) in enumerate(zip(selected, ROLE_SPECS, strict=True)):
        if entry.slot != slot or entry.role != role:
            raise EncoderAssetError(
                f"package-v3 layer {layer} slot {slot} role mismatch"
            )
        if entry.word_count != ROLE_WORDS[role]:
            raise EncoderAssetError(
                f"package-v3 layer {layer} role {role} stored-word mismatch"
            )
        is_weight = role.endswith("weight_base")
        if is_weight and entry.layout != base.LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2:
            raise EncoderAssetError(
                f"package-v3 layer {layer} role {role} is not packed K16/N2"
            )
        if not is_weight and entry.layout != base.LAYOUT_VECTOR:
            raise EncoderAssetError(
                f"package-v3 layer {layer} role {role} is not a vector"
            )
    return tuple(selected)


def stage_encoder_layer_assets(
    layer: int,
    output_dir: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Path, Mapping[str, object], str]:
    """Stage one exact package-v3 layer and its independent T004 pair."""

    layer = _validate_layer(layer)
    validation = base.validate_canonical_package(workspace_root)
    pins = _load_t004_pins(validation.workspace_root)
    input_relative = T004_INPUT_PATHS[layer]
    golden_relative = T004_OUTPUT_PATHS[layer]
    input_path, input_pin = _validate_t004_checkpoint(
        validation.workspace_root, input_relative, pins
    )
    golden_path, golden_pin = _validate_t004_checkpoint(
        validation.workspace_root, golden_relative, pins
    )
    entries = _layer_entries(validation, layer)

    output, identity = base._secure_new_output_dir(output_dir)
    try:
        model_path = base.secure_regular_file(
            validation.workspace_root,
            base.CANONICAL_PACKAGE_RELATIVE / "vit_model.bin",
            description="canonical package-v3 model",
        )
        staged: list[Mapping[str, object]] = []
        for entry, (_, filename) in zip(entries, ROLE_SPECS, strict=True):
            staged.append(base._stage_entry_hex(model_path, entry, output / filename))
        staged.append(
            base._stage_pinned_readmemh(
                input_path,
                input_pin,
                output / "input_t004_f32.hex",
                role="input_t004",
                source_relative_path=input_relative,
                expected_words=HIDDEN_WORDS,
            )
        )
        staged.append(
            base._stage_pinned_readmemh(
                golden_path,
                golden_pin,
                output / "golden_t004_f32.hex",
                role="golden_t004",
                source_relative_path=golden_relative,
                expected_words=HIDDEN_WORDS,
            )
        )

        evidence: dict[str, object] = {
            "schema": ASSET_SCHEMA,
            "phase": "e02" if layer == 0 else "e03",
            "layer": layer,
            "execution_mode": 3,
            "package": {
                "relative_directory": base.CANONICAL_PACKAGE_RELATIVE.as_posix(),
                "files": validation.files,
                "table_header": validation.table_header,
            },
            "t004": {
                "manifest_relative_path": T004_MANIFEST_RELATIVE.as_posix(),
                "manifest_sha256": T004_MANIFEST_SHA256,
                "input_relative_path": input_relative.as_posix(),
                "input_sha256": input_pin.sha256,
                "golden_relative_path": golden_relative.as_posix(),
                "golden_sha256": golden_pin.sha256,
                "words": HIDDEN_WORDS,
            },
            "quality_envelopes": QUALITY_ENVELOPES,
            "layer_table": [
                {
                    "slot": entry.slot,
                    "role": entry.role,
                    "word_offset": entry.word_offset,
                    "stored_words": entry.word_count,
                    "layout": entry.layout,
                    "tensor_sha256": entry.tensor_sha256,
                }
                for entry in entries
            ],
            "staged": staged,
        }
        payload = (
            json.dumps(evidence, indent=2, sort_keys=True, separators=(",", ": "))
            + "\n"
        ).encode("utf-8")
        evidence_path = output / "asset_evidence.json"
        with evidence_path.open("xb") as stream:
            stream.write(payload)
        return evidence_path, evidence, hashlib.sha256(payload).hexdigest()
    except Exception:
        base._cleanup_owned_output(output, identity)
        raise


def _load_staged_evidence(asset_dir: Path) -> Mapping[str, object]:
    asset_dir = base._secure_directory(asset_dir, "M8 encoder asset directory")
    evidence_path = base._secure_absolute_regular_file(
        asset_dir / "asset_evidence.json", "M8 encoder asset evidence"
    )
    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EncoderAssetError(f"cannot parse M8 encoder asset evidence: {exc}") from exc
    if not isinstance(evidence, dict):
        raise EncoderAssetError("M8 encoder asset evidence root is not an object")
    if evidence.get("schema") != ASSET_SCHEMA:
        raise EncoderAssetError("M8 encoder asset-evidence schema mismatch")
    layer = _validate_layer(evidence.get("layer"))
    if evidence.get("phase") != ("e02" if layer == 0 else "e03"):
        raise EncoderAssetError("M8 encoder asset-evidence phase mismatch")
    if evidence.get("execution_mode") != 3:
        raise EncoderAssetError("M8 encoder asset evidence is not execution mode 3")
    if evidence.get("quality_envelopes") != QUALITY_ENVELOPES:
        raise EncoderAssetError("M8 encoder quality envelope changed")

    root = base.discover_workspace_root()
    validation = base.validate_canonical_package(root)
    pins = _load_t004_pins(root)
    entries = _layer_entries(validation, layer)
    entry_by_role = {entry.role: entry for entry in entries}
    expected_package = {
        "relative_directory": base.CANONICAL_PACKAGE_RELATIVE.as_posix(),
        "files": validation.files,
        "table_header": validation.table_header,
    }
    if evidence.get("package") != expected_package:
        raise EncoderAssetError("M8 encoder package evidence differs from canonical package")
    expected_layer_table = [
        {
            "slot": entry.slot,
            "role": entry.role,
            "word_offset": entry.word_offset,
            "stored_words": entry.word_count,
            "layout": entry.layout,
            "tensor_sha256": entry.tensor_sha256,
        }
        for entry in entries
    ]
    if evidence.get("layer_table") != expected_layer_table:
        raise EncoderAssetError("M8 encoder recorded layer table is not canonical")

    input_relative = T004_INPUT_PATHS[layer]
    golden_relative = T004_OUTPUT_PATHS[layer]
    _, input_pin = _validate_t004_checkpoint(root, input_relative, pins)
    _, golden_pin = _validate_t004_checkpoint(root, golden_relative, pins)
    expected_t004 = {
        "manifest_relative_path": T004_MANIFEST_RELATIVE.as_posix(),
        "manifest_sha256": T004_MANIFEST_SHA256,
        "input_relative_path": input_relative.as_posix(),
        "input_sha256": input_pin.sha256,
        "golden_relative_path": golden_relative.as_posix(),
        "golden_sha256": golden_pin.sha256,
        "words": HIDDEN_WORDS,
    }
    if evidence.get("t004") != expected_t004:
        raise EncoderAssetError("M8 encoder recorded T004 pins disagree with canonical pins")

    rows = evidence.get("staged")
    if not isinstance(rows, list) or len(rows) != 18:
        raise EncoderAssetError("M8 encoder asset evidence must contain 18 staged files")
    expected_roles = {role for role, _ in ROLE_SPECS} | {"input_t004", "golden_t004"}
    expected_filenames = dict(ROLE_SPECS)
    expected_filenames.update(
        {
            "input_t004": "input_t004_f32.hex",
            "golden_t004": "golden_t004_f32.hex",
        }
    )
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise EncoderAssetError("M8 encoder staged record is not an object")
        role = row.get("role")
        filename = row.get("filename")
        staged_sha256 = row.get("staged_sha256")
        if role not in expected_roles or role in seen:
            raise EncoderAssetError("M8 encoder staged role set is invalid")
        if filename != expected_filenames[role] or Path(filename).name != filename:
            raise EncoderAssetError(f"unsafe staged filename for role {role}")
        path = base._secure_absolute_regular_file(
            asset_dir / filename, f"staged M8 encoder role {role}"
        )
        actual_staged_sha256 = base.sha256_file(path)
        if actual_staged_sha256 != staged_sha256:
            raise EncoderAssetError(f"staged M8 encoder SHA-256 mismatch: {role}")
        expected_words = HIDDEN_WORDS if role in {"input_t004", "golden_t004"} else ROLE_WORDS[role]
        words = base.read_u32_readmemh(path, expected_words)
        if role in {"input_t004", "golden_t004"}:
            pin = input_pin if role == "input_t004" else golden_pin
            relative = input_relative if role == "input_t004" else golden_relative
            expected_row = {
                "filename": filename,
                "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
                "role": role,
                "source_readmemh_sha256": pin.sha256,
                "source_relative_path": relative.as_posix(),
                "staged_sha256": pin.sha256,
                "stored_bytes": HIDDEN_WORDS * 4,
                "stored_words": HIDDEN_WORDS,
                "text_bytes": pin.size_bytes,
            }
        else:
            entry = entry_by_role[role]
            source_digest = hashlib.sha256()
            for word in words:
                source_digest.update(word.to_bytes(4, byteorder="little"))
            if source_digest.hexdigest() != entry.tensor_sha256:
                raise EncoderAssetError(
                    f"staged M8 encoder data differs from package tensor: {role}"
                )
            expected_row = {
                "filename": filename,
                "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
                "role": role,
                "source_binary_sha256": entry.tensor_sha256,
                "source_byte_offset": entry.word_offset * 4,
                "source_tensor_id": entry.tensor_id,
                "source_word_offset": entry.word_offset,
                "staged_sha256": actual_staged_sha256,
                "stored_bytes": entry.word_count * 4,
                "stored_words": entry.word_count,
                "text_bytes": entry.word_count * 9,
            }
        if row != expected_row:
            raise EncoderAssetError(f"staged M8 encoder metadata mismatch: {role}")
        seen.add(role)
    if seen != expected_roles:
        raise EncoderAssetError("M8 encoder staged roles are incomplete")

    return evidence


def _role_paths(asset_dir: Path, evidence: Mapping[str, object]) -> Mapping[str, Path]:
    return {
        row["role"]: asset_dir / row["filename"]
        for row in evidence["staged"]
    }


def verify_e02_seed_receipt(
    seed_output: Path,
    seed_report: Path,
    receipt_manifest: Path,
    receipt_manifest_sha256: str,
    expected_source_state_file: Path,
) -> Mapping[str, object]:
    """Bind a split E03 launch to one externally pinned E02 receipt."""

    if not SHA256_RE.fullmatch(receipt_manifest_sha256):
        raise EncoderAssetError("E02 receipt-manifest SHA-256 is not canonical")
    seed_output = base._secure_absolute_regular_file(
        seed_output, "E02 seed output"
    )
    seed_report = base._secure_absolute_regular_file(
        seed_report, "E02 seed comparison report"
    )
    receipt_manifest = base._secure_absolute_regular_file(
        receipt_manifest, "E02 receipt manifest"
    )
    expected_source_state_file = base._secure_absolute_regular_file(
        expected_source_state_file, "current M8 source-state file"
    )
    if receipt_manifest.name != "RUN_SHA256SUMS.txt":
        raise EncoderAssetError("E02 receipt manifest must be RUN_SHA256SUMS.txt")
    if base.sha256_file(receipt_manifest) != receipt_manifest_sha256:
        raise EncoderAssetError("E02 receipt-manifest external SHA-256 mismatch")
    receipt_root = base._secure_directory(
        receipt_manifest.parent, "E02 receipt root"
    )

    records: dict[str, str] = {}
    try:
        manifest_lines = receipt_manifest.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as exc:
        raise EncoderAssetError(f"cannot read E02 receipt manifest: {exc}") from exc
    for line_number, line in enumerate(manifest_lines, 1):
        match = SHA256SUM_RE.fullmatch(line)
        if match is None:
            raise EncoderAssetError(
                f"E02 receipt manifest line {line_number} is not canonical"
            )
        relative_text = match.group(2)[2:]
        relative = PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() != relative_text
            or relative_text == "RUN_SHA256SUMS.txt"
            or relative_text in records
        ):
            raise EncoderAssetError(
                f"E02 receipt manifest line {line_number} has an unsafe path"
            )
        path = base._secure_absolute_regular_file(
            receipt_root.joinpath(*relative.parts),
            f"E02 receipt member {relative_text}",
        )
        if base.sha256_file(path) != match.group(1):
            raise EncoderAssetError(f"E02 receipt member hash mismatch: {relative_text}")
        records[relative_text] = match.group(1)

    actual_files: set[str] = set()
    for path in receipt_root.rglob("*"):
        if path.is_symlink():
            raise EncoderAssetError(f"E02 receipt contains a symlink: {path}")
        if path.is_file() and path != receipt_manifest:
            actual_files.add(path.relative_to(receipt_root).as_posix())
    if set(records) != actual_files:
        raise EncoderAssetError("E02 receipt manifest does not cover every regular file")

    def receipt_relative(path: Path, description: str) -> str:
        try:
            return path.relative_to(receipt_root).as_posix()
        except ValueError as exc:
            raise EncoderAssetError(f"{description} is outside the E02 receipt") from exc

    output_relative = receipt_relative(seed_output, "E02 seed output")
    report_relative = receipt_relative(seed_report, "E02 seed report")
    if records.get(output_relative) != base.sha256_file(seed_output):
        raise EncoderAssetError("E02 seed output is not bound by the receipt manifest")
    if records.get(report_relative) != base.sha256_file(seed_report):
        raise EncoderAssetError("E02 seed report is not bound by the receipt manifest")

    expected_source_state = expected_source_state_file.read_text(
        encoding="utf-8"
    )
    for name in ("SOURCE_STATE_BEFORE.txt", "SOURCE_STATE_AFTER.txt"):
        path = base._secure_absolute_regular_file(
            receipt_root / name, f"E02 {name}"
        )
        if records.get(name) != base.sha256_file(path):
            raise EncoderAssetError(f"E02 {name} is not receipt-bound")
        if path.read_text(encoding="utf-8") != expected_source_state:
            raise EncoderAssetError(f"E02 {name} differs from current source state")
    summary = base._secure_absolute_regular_file(
        receipt_root / "summary.log", "E02 receipt summary"
    )
    if records.get("summary.log") != base.sha256_file(summary):
        raise EncoderAssetError("E02 summary is not receipt-bound")
    summary_marker = (
        "M8_MODE3_ENCODER_SEQUENCE_PASS first_layer=0 last_layer=0 "
        "input_mode=independent layers=1 source_stable=1"
    )
    if summary.read_text(encoding="utf-8").splitlines().count(summary_marker) != 1:
        raise EncoderAssetError("E02 receipt lacks one exact sequence PASS marker")

    try:
        report = json.loads(seed_report.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EncoderAssetError(f"cannot parse E02 seed report: {exc}") from exc
    if not isinstance(report, dict):
        raise EncoderAssetError("E02 seed report root is not an object")
    asset_dir = base._secure_directory(
        seed_report.parent.parent / "assets", "E02 receipt asset directory"
    )
    evidence = _load_staged_evidence(asset_dir)
    if evidence["layer"] != 0 or evidence["phase"] != "e02":
        raise EncoderAssetError("E02 seed asset evidence is not layer 0/E02")
    asset_evidence = base._secure_absolute_regular_file(
        asset_dir / "asset_evidence.json", "E02 receipt asset evidence"
    )
    asset_evidence_relative = receipt_relative(
        asset_evidence, "E02 asset evidence"
    )
    if records.get(asset_evidence_relative) != base.sha256_file(asset_evidence):
        raise EncoderAssetError("E02 asset evidence is not receipt-bound")

    output_sha256 = base.sha256_file(seed_output)
    input_path = base._secure_absolute_regular_file(
        asset_dir / "input_t004_f32.hex", "E02 pinned runtime input"
    )
    expected_input_sha256 = evidence["t004"]["input_sha256"]
    expected_golden_sha256 = evidence["t004"]["golden_sha256"]
    comparison = report.get("comparison")
    report_input = report.get("input")
    report_output = report.get("output")
    report_golden = report.get("golden")
    if not all(
        isinstance(value, dict)
        for value in (comparison, report_input, report_output, report_golden)
    ):
        raise EncoderAssetError("E02 seed report sections are incomplete")
    if (
        report.get("schema") != COMPARISON_SCHEMA
        or report.get("decision") != "PASS"
        or report.get("layer") != 0
        or report.get("phase") != "e02"
        or report.get("execution_mode") != 3
        or report.get("t004_manifest_sha256") != T004_MANIFEST_SHA256
        or report.get("asset_evidence_sha256") != base.sha256_file(asset_evidence)
        or report_input.get("origin") != "t004"
        or report_input.get("path") != str(input_path)
        or report_input.get("sha256") != expected_input_sha256
        or report_input.get("previous_report_path") is not None
        or report_input.get("previous_report_sha256") is not None
        or report_input.get("t004_reference_sha256") != expected_input_sha256
        or report_output.get("path") != str(seed_output)
        or report_output.get("sha256") != output_sha256
        or report_output.get("words") != HIDDEN_WORDS
        or report_output.get("actual_nonfinite") != 0
        or report_golden.get("relative_path") != T004_OUTPUT_PATHS[0].as_posix()
        or report_golden.get("sha256") != expected_golden_sha256
        or report_golden.get("words") != HIDDEN_WORDS
        or report_golden.get("nonfinite") != 0
        or comparison.get("abs_tolerance") != QUALITY_ENVELOPES["t004"]["abs_tolerance"]
        or comparison.get("rel_tolerance") != QUALITY_ENVELOPES["t004"]["rel_tolerance"]
        or comparison.get("tolerance_failures") != 0
    ):
        raise EncoderAssetError("E02 seed report fails the exact receipt contract")
    actual_words = base.read_u32_simulator_dump(seed_output, HIDDEN_WORDS)
    golden_words = base.read_u32_readmemh(
        asset_dir / "golden_t004_f32.hex", HIDDEN_WORDS
    )
    exact_mismatches = 0
    tolerance_failures = 0
    actual_nonfinite = 0
    golden_nonfinite = 0
    max_abs = 0.0
    max_abs_index = 0
    sum_abs = 0.0
    sum_squared = 0.0
    envelope = QUALITY_ENVELOPES["t004"]
    for index, (actual_bits, golden_bits) in enumerate(
        zip(actual_words, golden_words, strict=True)
    ):
        exact_mismatches += int(actual_bits != golden_bits)
        actual = base._fp32_bits_to_float(actual_bits)
        golden = base._fp32_bits_to_float(golden_bits)
        actual_nonfinite += int(not math.isfinite(actual))
        golden_nonfinite += int(not math.isfinite(golden))
        if not math.isfinite(actual) or not math.isfinite(golden):
            tolerance_failures += 1
            continue
        error = abs(actual - golden)
        tolerance_failures += int(
            error
            > envelope["abs_tolerance"]
            + envelope["rel_tolerance"] * abs(golden)
        )
        sum_abs += error
        sum_squared += error * error
        if error > max_abs:
            max_abs = error
            max_abs_index = index
    recomputed_comparison = {
        "abs_tolerance": envelope["abs_tolerance"],
        "rel_tolerance": envelope["rel_tolerance"],
        "exact_mismatches": exact_mismatches,
        "tolerance_failures": tolerance_failures,
        "max_abs": max_abs,
        "max_abs_index": max_abs_index,
        "mean_abs": sum_abs / HIDDEN_WORDS,
        "rmse": math.sqrt(sum_squared / HIDDEN_WORDS),
    }
    if (
        comparison != recomputed_comparison
        or actual_nonfinite != 0
        or golden_nonfinite != 0
        or tolerance_failures != 0
    ):
        raise EncoderAssetError("E02 seed report metrics do not recompute exactly")
    return {
        "receipt_root": str(receipt_root),
        "receipt_manifest_sha256": receipt_manifest_sha256,
        "files": len(records),
        "output_sha256": output_sha256,
        "report_sha256": base.sha256_file(seed_report),
    }


def compare_encoder_output(
    asset_dir: Path,
    runtime_input: Path,
    output_dump: Path,
    report_path: Path,
    *,
    input_origin: str,
    previous_report: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Compare one real RTL layer output with its pinned T004 checkpoint."""

    if input_origin not in QUALITY_ENVELOPES:
        raise EncoderAssetError(f"unsupported runtime input origin: {input_origin!r}")
    asset_dir = base._secure_directory(asset_dir, "M8 encoder asset directory")
    evidence = _load_staged_evidence(asset_dir)
    layer = int(evidence["layer"])
    paths = _role_paths(asset_dir, evidence)
    runtime_input = base._secure_absolute_regular_file(
        runtime_input, "M8 encoder runtime input"
    )
    output_dump = base._secure_absolute_regular_file(
        output_dump, "M8 encoder RTL output dump"
    )
    runtime_words = base.read_u32_simulator_dump(runtime_input, HIDDEN_WORDS)
    actual_words = base.read_u32_simulator_dump(output_dump, HIDDEN_WORDS)
    golden_words = base.read_u32_readmemh(paths["golden_t004"], HIDDEN_WORDS)
    runtime_sha256 = base.sha256_file(runtime_input)

    previous_report_sha256: str | None = None
    if input_origin == "t004":
        if previous_report is not None:
            raise EncoderAssetError("T004 input mode rejects a previous M8 report")
        if runtime_sha256 != base.sha256_file(paths["input_t004"]):
            raise EncoderAssetError("runtime T004 input differs from the staged pinned input")
    else:
        if layer == 0:
            raise EncoderAssetError("M8 encoder chain input is legal only for layers 1..11")
        if previous_report is None:
            raise EncoderAssetError("M8 chain input requires the preceding PASS report")
        previous_report = base._secure_absolute_regular_file(
            previous_report, "preceding M8 encoder comparison report"
        )
        previous_report_sha256 = base.sha256_file(previous_report)
        try:
            previous = json.loads(previous_report.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise EncoderAssetError(f"cannot parse preceding M8 report: {exc}") from exc
        previous_layer = layer - 1
        previous_origin = "t004" if previous_layer == 0 else "m8-chain"
        previous_input = previous.get("input") if isinstance(previous, dict) else None
        previous_output = previous.get("output") if isinstance(previous, dict) else None
        previous_golden = previous.get("golden") if isinstance(previous, dict) else None
        previous_comparison = (
            previous.get("comparison") if isinstance(previous, dict) else None
        )
        previous_envelope = QUALITY_ENVELOPES[previous_origin]
        if (
            not isinstance(previous, dict)
            or not isinstance(previous_input, dict)
            or not isinstance(previous_output, dict)
            or not isinstance(previous_golden, dict)
            or not isinstance(previous_comparison, dict)
            or previous.get("schema") != COMPARISON_SCHEMA
            or previous.get("decision") != "PASS"
            or previous.get("layer") != previous_layer
            or previous.get("phase") != ("e02" if previous_layer == 0 else "e03")
            or previous.get("execution_mode") != 3
            or previous.get("t004_manifest_sha256") != T004_MANIFEST_SHA256
            or not SHA256_RE.fullmatch(str(previous.get("asset_evidence_sha256", "")))
            or previous_input.get("origin") != previous_origin
            or previous_output.get("path") != str(runtime_input)
            or previous_output.get("sha256") != runtime_sha256
            or previous_output.get("words") != HIDDEN_WORDS
            or previous_output.get("actual_nonfinite") != 0
            or previous_golden.get("words") != HIDDEN_WORDS
            or previous_golden.get("nonfinite") != 0
            or previous_comparison.get("abs_tolerance")
            != previous_envelope["abs_tolerance"]
            or previous_comparison.get("rel_tolerance")
            != previous_envelope["rel_tolerance"]
            or previous_comparison.get("tolerance_failures") != 0
        ):
            raise EncoderAssetError("preceding M8 report does not bind the chain input")

    envelope = QUALITY_ENVELOPES[input_origin]
    abs_tolerance = envelope["abs_tolerance"]
    rel_tolerance = envelope["rel_tolerance"]
    exact_mismatches = 0
    tolerance_failures = 0
    actual_nonfinite = 0
    golden_nonfinite = 0
    max_abs = 0.0
    max_abs_index = 0
    sum_abs = 0.0
    sum_squared = 0.0
    for index, (actual_bits, golden_bits) in enumerate(
        zip(actual_words, golden_words, strict=True)
    ):
        exact_mismatches += int(actual_bits != golden_bits)
        actual = base._fp32_bits_to_float(actual_bits)
        golden = base._fp32_bits_to_float(golden_bits)
        if not math.isfinite(actual):
            actual_nonfinite += 1
        if not math.isfinite(golden):
            golden_nonfinite += 1
        if not math.isfinite(actual) or not math.isfinite(golden):
            tolerance_failures += 1
            continue
        error = abs(actual - golden)
        limit = abs_tolerance + rel_tolerance * abs(golden)
        tolerance_failures += int(error > limit)
        sum_abs += error
        sum_squared += error * error
        if error > max_abs:
            max_abs = error
            max_abs_index = index

    decision = "PASS" if (
        tolerance_failures == 0
        and actual_nonfinite == 0
        and golden_nonfinite == 0
    ) else "FAIL"
    output_sha256 = base.sha256_file(output_dump)
    report: dict[str, object] = {
        "schema": COMPARISON_SCHEMA,
        "decision": decision,
        "layer": layer,
        "phase": evidence["phase"],
        "execution_mode": 3,
        "input": {
            "origin": input_origin,
            "path": str(runtime_input),
            "sha256": runtime_sha256,
            "previous_report_path": str(previous_report) if previous_report else None,
            "previous_report_sha256": previous_report_sha256,
            "t004_reference_sha256": evidence["t004"]["input_sha256"],
        },
        "output": {
            "path": str(output_dump),
            "sha256": output_sha256,
            "words": HIDDEN_WORDS,
            "actual_nonfinite": actual_nonfinite,
        },
        "golden": {
            "relative_path": evidence["t004"]["golden_relative_path"],
            "sha256": evidence["t004"]["golden_sha256"],
            "words": HIDDEN_WORDS,
            "nonfinite": golden_nonfinite,
        },
        "comparison": {
            "abs_tolerance": abs_tolerance,
            "rel_tolerance": rel_tolerance,
            "exact_mismatches": exact_mismatches,
            "tolerance_failures": tolerance_failures,
            "max_abs": max_abs,
            "max_abs_index": max_abs_index,
            "mean_abs": sum_abs / HIDDEN_WORDS,
            "rmse": math.sqrt(sum_squared / HIDDEN_WORDS),
        },
        "asset_evidence_sha256": base.sha256_file(asset_dir / "asset_evidence.json"),
        "t004_manifest_sha256": T004_MANIFEST_SHA256,
    }
    report_sha256 = base._write_new_deterministic_json(report_path, report)
    return report, report_sha256


__all__ = [
    "ASSET_SCHEMA",
    "COMPARISON_SCHEMA",
    "EncoderAssetError",
    "HIDDEN_WORDS",
    "QUALITY_ENVELOPES",
    "ROLE_SPECS",
    "ROLE_WORDS",
    "T004_MANIFEST_SHA256",
    "compare_encoder_output",
    "stage_encoder_layer_assets",
    "verify_e02_seed_receipt",
]
