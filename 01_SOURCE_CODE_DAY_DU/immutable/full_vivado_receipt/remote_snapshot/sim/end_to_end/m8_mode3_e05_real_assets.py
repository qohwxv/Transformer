#!/usr/bin/env python3
"""M8 E05-only package-v3 staging and continuous-model numerical gates.

The qualified E01/E04 helper is imported read-only and hash-pinned.  This
module stages only the input, the 8+192 runtime offsets, and independent FP32
goldens; the 173,685,760-byte model stays in its canonical package and is
consumed directly by the RTL testbench and exact endpoint oracle.
"""

from __future__ import annotations

import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any, Mapping, Sequence

import m7_mode3_real_assets as common


E05_ASSET_SCHEMA = "vit-m8-mode3-e05-real-assets-v1"
E05_HELPER_SHA256 = (
    "f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed"
)
HIDDEN_WORDS = 197 * 768
EXPECTED_TOP1 = 879

# Pre-run, non-circular quality envelope.  The embedding limit is inherited
# from qualified E01.  There is no prior continuous mode-3 layer-error run, so
# the encoder/final limits are deliberately conservative PROPOSED model-
# quality gates, combined with exact endpoint arithmetic, finite/layout and
# exact top-1 gates.  They must not be tuned from the first RTL output.
EMBEDDING_ABS_TOLERANCE = 5.0e-3
ENCODER_ABS_TOLERANCE = 2.5e-1
FINAL_LN_ABS_TOLERANCE = 2.5e-1
LOGITS_ABS_TOLERANCE = 2.5e-1
PROBABILITIES_ABS_TOLERANCE = 2.0e-2
PROBABILITY_SUM_ABS_TOLERANCE = 1.0e-3

GLOBAL_KEYS = (
    "patch_weight_base",
    "patch_bias_base",
    "cls_base",
    "position_base",
    "final_ln_gamma_base",
    "final_ln_beta_base",
    "classifier_weight_base",
    "classifier_bias_base",
)
LAYER_KEYS = (
    "ln1_gamma_base",
    "ln1_beta_base",
    "q_weight_base",
    "q_bias_base",
    "k_weight_base",
    "k_bias_base",
    "v_weight_base",
    "v_bias_base",
    "o_weight_base",
    "o_bias_base",
    "ln2_gamma_base",
    "ln2_beta_base",
    "fc1_weight_base",
    "fc1_bias_base",
    "fc2_weight_base",
    "fc2_bias_base",
)


def _pin(size: int, sha256: str) -> common.FilePin:
    return common.FilePin(size, sha256)


CHECKPOINT_GOLDENS: tuple[tuple[str, Path, common.FilePin], ...] = (
    (
        "checkpoint_00_embedding",
        Path("results/embedding_step_06_hidden_states_f32.hex"),
        _pin(1_361_664, "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18"),
    ),
    (
        "checkpoint_01_encoder_layer_00_step_20",
        Path("results/encoder_layer_00_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "e95ccf94deebc9f85acb7f905e5052f2d1ef56e3ad1ed6449f05884e5fecb552"),
    ),
    (
        "checkpoint_02_encoder_layer_01_step_20",
        Path("results/encoder_layer_01_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "a36b4ff1a042bd24ecf601cbb8accfaeeeec1deb0384530867212a6f5a7a7619"),
    ),
    (
        "checkpoint_03_encoder_layer_02_step_20",
        Path("results/encoder_layer_02_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "1e06c65f2ada90bb172f49917cfa414c25ca4f1911da3e058f57376c65a41297"),
    ),
    (
        "checkpoint_04_encoder_layer_03_step_20",
        Path("results/encoder_layer_03_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "0f1bca089c1d55366c52544e68766f877c73d47fc2e4a22e376d8a9062459d77"),
    ),
    (
        "checkpoint_05_encoder_layer_04_step_20",
        Path("results/encoder_layer_04_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "b34420f5b7026c31553bf167be8fd5eb9d8c4459604bd9155857163e30815ffd"),
    ),
    (
        "checkpoint_06_encoder_layer_05_step_20",
        Path("results/encoder_layer_05_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "2bf04acf166f51b22bcb39a38c9bf2db461254c3366388a3ecf0c312f641f6f6"),
    ),
    (
        "checkpoint_07_encoder_layer_06_step_20",
        Path("results/encoder_layer_06_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "2263736bd4f13997f6ccf275c8084cd106d633d762aa81d1dd30bcd96069666d"),
    ),
    (
        "checkpoint_08_encoder_layer_07_step_20",
        Path("results/encoder_layer_07_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "76e1462cb92dcf2807386f2c2b16a302ca00132b4f11b06194de1ef2c6500b99"),
    ),
    (
        "checkpoint_09_encoder_layer_08_step_20",
        Path("results/encoder_layer_08_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "70e666024df1cb7d1bfa01c53c01ceacfe14d931cc2ceaa82f55f882bf522551"),
    ),
    (
        "checkpoint_10_encoder_layer_09_step_20",
        Path("results/encoder_layer_09_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "8e9a6b28061f7c460248eb6636ec0f69a048c7a80f0db04b8242dcb1460b0480"),
    ),
    (
        "checkpoint_11_encoder_layer_10_step_20",
        Path("results/encoder_layer_10_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "b10a1815d25f973e5ec794034f124f189db5c40c4fb884885251290d75ba07ef"),
    ),
    (
        "checkpoint_12_encoder_layer_11_step_20",
        Path("results/encoder_layer_11_step_20_layer_output_f32.hex"),
        _pin(1_361_664, "5cf34a472d907125dd6bdb0c7bfc5d4b5e353571978aa8ef73b9a8b17bc93359"),
    ),
)

FINAL_GOLDENS: tuple[tuple[str, Path, int, common.FilePin], ...] = (
    (
        "final_layernorm",
        Path("results/post_encoder_step_30_final_layernorm_f32.hex"),
        HIDDEN_WORDS,
        _pin(1_361_664, "d8ac11b3b8c244c4c525da8f2a56352595256290f0673c607944d5581835167d"),
    ),
    (
        "logits",
        Path("results/post_encoder_step_32_logits_f32.hex"),
        1_000,
        _pin(9_000, "fef8118492356377612d95f0b02120d6fde728ff47bef9b4b8c87cf52c4c7143"),
    ),
    (
        "probabilities",
        Path("results/post_encoder_step_33p_probabilities_f32.hex"),
        1_000,
        _pin(9_000, "870497897b0b0453c8dc1335c3db8881e9ffdbf81bf66eba3d40c8c1b169491b"),
    ),
)


def _helper_identity() -> None:
    path = Path(common.__file__).resolve(strict=True)
    if common.sha256_file(path) != E05_HELPER_SHA256:
        raise common.AssetValidationError(
            "qualified E01/E04 helper SHA-256 changed"
        )


def _runtime_offsets(
    validation: common.PackageValidation,
) -> tuple[int, ...]:
    path = common.secure_regular_file(
        validation.workspace_root,
        common.CANONICAL_PACKAGE_RELATIVE / "vit_runtime_config.json",
        description="canonical E05 runtime config",
    )
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise common.AssetValidationError(
            f"cannot parse E05 runtime config: {exc}"
        ) from exc
    exact = {
        "schema": "vit-runtime-config-v3-blocked-b-fp16-mixed",
        "package_schema": common.PACKAGE_SCHEMA,
        "address_unit": "U32_STORAGE_WORD",
        "physical_ddr_bases_included": False,
        "execution_mode": 3,
        "model_words": 43_421_440,
        "input_words": 150_528,
        "scratch_words": 1_990_656,
        "required_model_base_alignment_bytes": 128,
        "blocked_weight_tensor_count": 74,
        "input_storage_fp32": True,
        "scratch_storage_fp32": True,
        "row_major_scratch_gemm_b": True,
        "fp32_to_fp16_activation_conversion_at_gemm_ingress": True,
    }
    if not isinstance(value, Mapping):
        raise common.AssetValidationError("runtime config root is not an object")
    for key, expected in exact.items():
        if value.get(key) != expected:
            raise common.AssetValidationError(
                f"runtime config {key} mismatch"
            )
    globals_value = value.get("global_offsets")
    layers_value = value.get("layer_offsets")
    if (
        not isinstance(globals_value, Mapping)
        or tuple(globals_value) != GLOBAL_KEYS
        or not isinstance(layers_value, list)
        or len(layers_value) != 12
    ):
        raise common.AssetValidationError("runtime offset topology mismatch")

    offsets: list[int] = []
    entries = tuple(validation.entries)
    for key in GLOBAL_KEYS:
        entry = next(
            (item for item in entries if item.layer == 255 and item.role == key),
            None,
        )
        offset = globals_value.get(key)
        if entry is None or offset != entry.word_offset:
            raise common.AssetValidationError(
                f"runtime global offset/table mismatch: {key}"
            )
        offsets.append(int(offset))
    for layer, row in enumerate(layers_value):
        if not isinstance(row, Mapping) or tuple(row) != LAYER_KEYS:
            raise common.AssetValidationError(
                f"runtime layer {layer} key topology mismatch"
            )
        for key in LAYER_KEYS:
            matches = [
                item
                for item in entries
                if item.layer == layer and item.role == key
            ]
            offset = row.get(key)
            if len(matches) != 1 or offset != matches[0].word_offset:
                raise common.AssetValidationError(
                    f"runtime layer {layer} offset/table mismatch: {key}"
                )
            offsets.append(int(offset))
    if len(offsets) != 200 or len(offsets[8:]) != 192:
        raise common.AssetValidationError("runtime offset population is not 8+192")
    if any(offset < 0 or offset >= 43_421_440 or offset % 32 for offset in offsets):
        raise common.AssetValidationError("runtime offset alignment/range mismatch")
    if offsets[0] != 0 or offsets[8] != 834_304 or offsets[-1] != 43_420_672:
        raise common.AssetValidationError("runtime offset endpoint mismatch")
    return tuple(offsets)


def _validate_goldens(root: Path) -> Mapping[str, Mapping[str, object]]:
    records: dict[str, Mapping[str, object]] = {}
    rows = [
        (name, relative, HIDDEN_WORDS, pin)
        for name, relative, pin in CHECKPOINT_GOLDENS
    ] + list(FINAL_GOLDENS)
    for name, relative, words, pin in rows:
        path = common.secure_regular_file(
            root, relative, description=f"canonical E05 golden {name}"
        )
        common.verify_pinned_regular_file(
            path, pin, description=f"canonical E05 golden {name}"
        )
        common.read_u32_readmemh(path, words)
        records[name] = {
            "relative_path": relative.as_posix(),
            "size_bytes": pin.size_bytes,
            "words": words,
            "sha256": pin.sha256,
        }
    return records


def stage_e05_assets(
    output_dir: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Path, Mapping[str, object], str]:
    """Stage the exact 18 lightweight full-E05 files into a new directory."""

    _helper_identity()
    validation = common.validate_canonical_package(workspace_root)
    offsets = _runtime_offsets(validation)
    output, identity = common._secure_new_output_dir(output_dir)
    try:
        staged: list[Mapping[str, object]] = []
        prepared_relative = common.CANONICAL_PACKAGE_RELATIVE / "prepared_input.bin"
        prepared_path = common.secure_regular_file(
            validation.workspace_root,
            prepared_relative,
            description="canonical E05 prepared input",
        )
        staged.append(
            common._stage_binary_u32_hex(
                prepared_path,
                common.CANONICAL_FILE_PINS["prepared_input.bin"],
                output / "prepared_input_f32.hex",
                role="prepared_input",
                source_relative_path=prepared_relative,
            )
        )

        runtime_path = output / "runtime_offsets_u32.hex"
        payload = "".join(f"{offset:08x}\n" for offset in offsets).encode("ascii")
        with runtime_path.open("xb") as stream:
            stream.write(payload)
        staged.append(
            {
                "filename": runtime_path.name,
                "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
                "role": "runtime_offsets",
                "source_relative_path": (
                    common.CANONICAL_PACKAGE_RELATIVE
                    / "vit_runtime_config.json"
                ).as_posix(),
                "source_sha256": common.CANONICAL_FILE_PINS[
                    "vit_runtime_config.json"
                ].sha256,
                "staged_sha256": hashlib.sha256(payload).hexdigest(),
                "stored_words": 200,
                "global_offset_words": 8,
                "layer_aperture_words": 192,
                "text_bytes": len(payload),
            }
        )

        golden_rows = [
            (name, relative, HIDDEN_WORDS, pin)
            for name, relative, pin in CHECKPOINT_GOLDENS
        ] + list(FINAL_GOLDENS)
        for name, relative, words, pin in golden_rows:
            source = common.secure_regular_file(
                validation.workspace_root,
                relative,
                description=f"canonical E05 golden {name}",
            )
            staged.append(
                common._stage_pinned_readmemh(
                    source,
                    pin,
                    output / f"golden_{name}_f32.hex",
                    role=f"golden_{name}",
                    source_relative_path=relative,
                    expected_words=words,
                )
            )

        evidence: dict[str, object] = {
            "schema": E05_ASSET_SCHEMA,
            "phase": "e05",
            "execution_mode": 3,
            "geometry": {"rows": 8, "logical_columns": 2, "fp16_streams": 8},
            "helper": {
                "relative_path": Path(common.__file__).resolve().relative_to(
                    validation.workspace_root
                ).as_posix(),
                "sha256": E05_HELPER_SHA256,
            },
            "package": {
                "relative_directory": common.CANONICAL_PACKAGE_RELATIVE.as_posix(),
                "files": validation.files,
                "table_header": validation.table_header,
                "tensor_table_entries": 200,
            },
            "runtime_offsets": {
                "words": 200,
                "global_words": 8,
                "layer_aperture_words": 192,
            },
            "checkpoint_contract": {
                "embedding": 1,
                "encoder_step20": 12,
                "words_each": HIDDEN_WORDS,
                "layout": "TOKEN_MAJOR_HIDDEN_MINOR_FP32_U32",
            },
            "behavioral_goldens": _validate_goldens(
                validation.workspace_root
            ),
            "quality_envelope": {
                "evidence_class": "PROPOSED_PRE_RUN_NON_CIRCULAR",
                "embedding_abs": EMBEDDING_ABS_TOLERANCE,
                "encoder_abs": ENCODER_ABS_TOLERANCE,
                "final_layernorm_abs": FINAL_LN_ABS_TOLERANCE,
                "logits_abs": LOGITS_ABS_TOLERANCE,
                "probabilities_abs": PROBABILITIES_ABS_TOLERANCE,
                "probability_sum_abs": PROBABILITY_SUM_ABS_TOLERANCE,
                "exact_top1": EXPECTED_TOP1,
            },
            "staged": staged,
        }
        evidence_bytes = (
            json.dumps(evidence, indent=2, sort_keys=True, separators=(",", ": "))
            + "\n"
        ).encode("utf-8")
        evidence_path = output / "asset_evidence.json"
        with evidence_path.open("xb") as stream:
            stream.write(evidence_bytes)
        return evidence_path, evidence, hashlib.sha256(evidence_bytes).hexdigest()
    except BaseException:
        common._cleanup_owned_output(output, identity)
        raise


def _validate_staged_e05(
    asset_dir: Path,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], common.PackageValidation]:
    _helper_identity()
    validation = common.validate_canonical_package(workspace_root)
    offsets = _runtime_offsets(validation)
    directory = common._secure_directory(
        common._absolute_lexical(asset_dir, "E05 asset directory"),
        "E05 asset directory",
    )
    evidence_path = common._secure_absolute_regular_file(
        directory / "asset_evidence.json", "E05 asset evidence"
    )
    evidence = common._strict_json_bytes(
        evidence_path.read_bytes(), "E05 asset evidence"
    )
    if (
        not isinstance(evidence, Mapping)
        or evidence.get("schema") != E05_ASSET_SCHEMA
        or evidence.get("phase") != "e05"
        or evidence.get("execution_mode") != 3
    ):
        raise common.AssetValidationError("asset evidence is not canonical E05 mode3")
    expected_helper = {
        "relative_path": Path(common.__file__).resolve().relative_to(
            validation.workspace_root
        ).as_posix(),
        "sha256": E05_HELPER_SHA256,
    }
    expected_package = {
        "relative_directory": common.CANONICAL_PACKAGE_RELATIVE.as_posix(),
        "files": validation.files,
        "table_header": validation.table_header,
        "tensor_table_entries": 200,
    }
    expected_quality = {
        "evidence_class": "PROPOSED_PRE_RUN_NON_CIRCULAR",
        "embedding_abs": EMBEDDING_ABS_TOLERANCE,
        "encoder_abs": ENCODER_ABS_TOLERANCE,
        "final_layernorm_abs": FINAL_LN_ABS_TOLERANCE,
        "logits_abs": LOGITS_ABS_TOLERANCE,
        "probabilities_abs": PROBABILITIES_ABS_TOLERANCE,
        "probability_sum_abs": PROBABILITY_SUM_ABS_TOLERANCE,
        "exact_top1": EXPECTED_TOP1,
    }
    if evidence.get("geometry") != {
        "rows": 8,
        "logical_columns": 2,
        "fp16_streams": 8,
    }:
        raise common.AssetValidationError("E05 geometry evidence changed")
    if evidence.get("helper") != expected_helper:
        raise common.AssetValidationError("E05 helper evidence changed")
    if evidence.get("package") != expected_package:
        raise common.AssetValidationError("E05 package evidence changed")
    if evidence.get("runtime_offsets") != {
        "words": 200,
        "global_words": 8,
        "layer_aperture_words": 192,
    }:
        raise common.AssetValidationError("E05 runtime-offset evidence changed")
    if evidence.get("checkpoint_contract") != {
        "embedding": 1,
        "encoder_step20": 12,
        "words_each": HIDDEN_WORDS,
        "layout": "TOKEN_MAJOR_HIDDEN_MINOR_FP32_U32",
    }:
        raise common.AssetValidationError("E05 checkpoint evidence changed")
    if evidence.get("quality_envelope") != expected_quality:
        raise common.AssetValidationError("E05 quality envelope changed")
    if evidence.get("behavioral_goldens") != _validate_goldens(
        validation.workspace_root
    ):
        raise common.AssetValidationError("E05 golden pins changed")
    staged = evidence.get("staged")
    if not isinstance(staged, list) or len(staged) != 18:
        raise common.AssetValidationError("E05 staged population is not 18")
    expected_specs: dict[str, tuple[str, int, int, str]] = {
        "prepared_input": (
            "prepared_input_f32.hex",
            150_528,
            150_528 * 9,
            common.E01_STAGED_SHA256_BY_ROLE["prepared_input"],
        ),
        "runtime_offsets": (
            "runtime_offsets_u32.hex",
            200,
            200 * 9,
            hashlib.sha256(
                "".join(f"{offset:08x}\n" for offset in offsets).encode("ascii")
            ).hexdigest(),
        ),
    }
    for name, _, pin in CHECKPOINT_GOLDENS:
        expected_specs[f"golden_{name}"] = (
            f"golden_{name}_f32.hex",
            HIDDEN_WORDS,
            pin.size_bytes,
            pin.sha256,
        )
    for name, _, words, pin in FINAL_GOLDENS:
        expected_specs[f"golden_{name}"] = (
            f"golden_{name}_f32.hex",
            words,
            pin.size_bytes,
            pin.sha256,
        )
    roles: set[str] = set()
    for row in staged:
        if not isinstance(row, Mapping):
            raise common.AssetValidationError("E05 staged row is not an object")
        role = row.get("role")
        filename = row.get("filename")
        if not isinstance(role, str) or role in roles or not isinstance(filename, str):
            raise common.AssetValidationError("E05 staged role/filename mismatch")
        if common._canonical_relative(filename).as_posix() != filename:
            raise common.AssetValidationError(
                f"E05 staged filename is not canonical: {role}"
            )
        if role not in expected_specs:
            raise common.AssetValidationError(f"unexpected E05 staged role: {role}")
        expected_filename, expected_words, expected_bytes, expected_sha256 = (
            expected_specs[role]
        )
        if (
            filename != expected_filename
            or row.get("format") != "U32_HEX_LOWERCASE_8DIGIT_LF"
            or row.get("stored_words") != expected_words
            or row.get("text_bytes") != expected_bytes
            or row.get("staged_sha256") != expected_sha256
        ):
            raise common.AssetValidationError(
                f"E05 staged contract mismatch: {role}"
            )
        path = common._secure_absolute_regular_file(
            directory / filename, f"staged E05 asset {role}"
        )
        if path.stat().st_size != expected_bytes:
            raise common.AssetValidationError(f"staged E05 size mismatch: {role}")
        if common.sha256_file(path) != expected_sha256:
            raise common.AssetValidationError(f"staged E05 hash mismatch: {role}")
        words = row.get("stored_words")
        if not isinstance(words, int):
            raise common.AssetValidationError(f"staged E05 extent absent: {role}")
        common.read_u32_readmemh(path, words)
        roles.add(role)
    if roles != set(expected_specs):
        raise common.AssetValidationError("E05 staged role population is incomplete")
    return evidence, validation


def validate_staged_e05(
    asset_dir: Path,
    *,
    workspace_root: Path | None = None,
) -> Mapping[str, object]:
    """Fail closed unless a staged E05 directory matches every live pin."""

    evidence, _ = _validate_staged_e05(asset_dir, workspace_root)
    return evidence


def _read_model_entry(
    validation: common.PackageValidation,
    *,
    role: str,
    layer: int | None = None,
) -> list[int]:
    matches = [
        entry
        for entry in validation.entries
        if entry.role == role and (layer is None or entry.layer == layer)
    ]
    if len(matches) != 1:
        raise common.AssetValidationError(
            f"model entry selection is not unique: role={role} layer={layer}"
        )
    entry = matches[0]
    model = common.secure_regular_file(
        validation.workspace_root,
        common.CANONICAL_PACKAGE_RELATIVE / "vit_model.bin",
        description="canonical E05 model binary",
    )
    with model.open("rb") as stream:
        stream.seek(entry.word_offset * 4)
        payload = stream.read(entry.word_count * 4)
    if len(payload) != entry.word_count * 4:
        raise common.AssetValidationError(f"model entry is truncated: {role}")
    if hashlib.sha256(payload).hexdigest() != entry.tensor_sha256:
        raise common.AssetValidationError(f"model entry hash mismatch: {role}")
    return [word[0] for word in struct.iter_unpack("<I", payload)]


def _comparison(
    actual: Sequence[int],
    golden: Sequence[int],
    *,
    abs_tolerance: float,
) -> Mapping[str, object]:
    result = dict(
        common._compare_e04_vector(
            actual, golden, abs_tolerance=abs_tolerance
        )
    )
    result["sentinel_words"] = sum(int(word == 0xDEAD_BEEF) for word in actual)
    result["layout"] = "TOKEN_MAJOR_HIDDEN_MINOR_FP32_U32"
    return result


def compare_endpoint_arithmetic(
    asset_dir: Path,
    embedding_dump: Path,
    final_ln_dump: Path,
    logits_dump: Path,
    report_path: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Require exact E01 and classifier M6/current-adder arithmetic endpoints."""

    evidence, validation = _validate_staged_e05(asset_dir, workspace_root)
    directory = common._secure_directory(
        common._absolute_lexical(asset_dir, "E05 asset directory"),
        "E05 asset directory",
    )
    actual_embedding_path = common._secure_absolute_regular_file(
        embedding_dump, "E05 embedding dump"
    )
    actual_embedding = common.read_u32_simulator_dump(
        actual_embedding_path, HIDDEN_WORDS
    )
    prepared = common.read_u32_readmemh(
        common._secure_absolute_regular_file(
            directory / "prepared_input_f32.hex", "staged E05 prepared input"
        ),
        150_528,
    )
    oracle_iterator = common._iter_e01_m6_current_adder_oracle(
        prepared,
        _read_model_entry(validation, role="patch_weight_base"),
        _read_model_entry(validation, role="patch_bias_base"),
        _read_model_entry(validation, role="cls_base"),
        _read_model_entry(validation, role="position_base"),
        workspace_root=validation.workspace_root,
    )
    embedding_mismatches = 0
    first_embedding_mismatch: int | None = None
    oracle_digest = hashlib.sha256()
    oracle_nonfinite = 0
    actual_nonfinite = 0
    for index, (actual, oracle) in enumerate(
        zip(actual_embedding, oracle_iterator, strict=True)
    ):
        oracle_digest.update(f"{oracle:08x}\n".encode("ascii"))
        actual_nonfinite += int(not math.isfinite(common._fp32_bits_to_float(actual)))
        oracle_nonfinite += int(not math.isfinite(common._fp32_bits_to_float(oracle)))
        if actual != oracle:
            embedding_mismatches += 1
            if first_embedding_mismatch is None:
                first_embedding_mismatch = index

    final_ln_path = common._secure_absolute_regular_file(
        final_ln_dump, "E05 final-LN dump"
    )
    logits_path = common._secure_absolute_regular_file(logits_dump, "E05 logits dump")
    final_ln = common.read_u32_simulator_dump(final_ln_path, HIDDEN_WORDS)
    actual_logits = common.read_u32_simulator_dump(logits_path, 1_000)
    oracle_logits = common.e04_logits_oracle(
        final_ln[:768],
        _read_model_entry(validation, role="classifier_weight_base"),
        _read_model_entry(validation, role="classifier_bias_base"),
        workspace_root=validation.workspace_root,
    )
    classifier_mismatches = sum(
        int(actual != oracle)
        for actual, oracle in zip(actual_logits, oracle_logits, strict=True)
    )
    first_classifier_mismatch = next(
        (
            index
            for index, (actual, oracle) in enumerate(
                zip(actual_logits, oracle_logits, strict=True)
            )
            if actual != oracle
        ),
        None,
    )
    classifier_actual_nonfinite = sum(
        int(not math.isfinite(common._fp32_bits_to_float(word)))
        for word in actual_logits
    )
    classifier_oracle_nonfinite = sum(
        int(not math.isfinite(common._fp32_bits_to_float(word)))
        for word in oracle_logits
    )
    actual_top1 = common._argmax_finite(actual_logits, "E05 actual logits")
    oracle_top1 = common._argmax_finite(oracle_logits, "E05 oracle logits")
    passed = (
        embedding_mismatches == 0
        and actual_nonfinite == 0
        and oracle_nonfinite == 0
        and classifier_mismatches == 0
        and classifier_actual_nonfinite == 0
        and classifier_oracle_nonfinite == 0
        and actual_top1 == oracle_top1 == EXPECTED_TOP1
    )
    report: dict[str, object] = {
        "schema": "vit-m8-mode3-e05-endpoint-arithmetic-comparison-v1",
        "decision": "PASS" if passed else "FAIL",
        "execution_mode": 3,
        "inputs": {
            "asset_evidence_sha256": common.sha256_file(
                directory / "asset_evidence.json"
            ),
            "embedding_dump_sha256": common.sha256_file(actual_embedding_path),
            "final_ln_dump_sha256": common.sha256_file(final_ln_path),
            "logits_dump_sha256": common.sha256_file(logits_path),
            "model_sha256": common.CANONICAL_FILE_PINS["vit_model.bin"].sha256,
            "recorded_helper": evidence["helper"],
        },
        "contract": {
            "gate": "EXACT_ENDPOINT_ARITHMETIC_NOT_FULL_LAYER_MODEL_QUALITY",
            "embedding": "M6_EXACT_FP16_PRODUCT_KULISCH_PLUS_CURRENT_FP32_ADDER",
            "classifier": "M6_EXACT_FP16_PRODUCT_KULISCH_PLUS_CURRENT_FP32_ADDER_FROM_RTL_FINAL_LN_CLS",
        },
        "embedding": {
            "words": HIDDEN_WORDS,
            "exact_mismatches": embedding_mismatches,
            "first_exact_mismatch": first_embedding_mismatch,
            "actual_nonfinite": actual_nonfinite,
            "oracle_nonfinite": oracle_nonfinite,
            "oracle_readmemh_sha256": oracle_digest.hexdigest(),
        },
        "classifier": {
            "words": 1_000,
            "exact_mismatches": classifier_mismatches,
            "first_exact_mismatch": first_classifier_mismatch,
            "actual_nonfinite": classifier_actual_nonfinite,
            "oracle_nonfinite": classifier_oracle_nonfinite,
            "actual_top1": actual_top1,
            "oracle_top1": oracle_top1,
        },
    }
    sha256 = common._write_new_deterministic_json(report_path, report)
    return report, sha256


def compare_behavioral_goldens(
    asset_dir: Path,
    checkpoint_dumps: Sequence[Path],
    final_ln_dump: Path,
    logits_dump: Path,
    probabilities_dump: Path,
    class_result_dump: Path,
    report_path: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Gate all 13 boundaries and final outputs against pinned FP32 goldens."""

    evidence, _ = _validate_staged_e05(asset_dir, workspace_root)
    directory = common._secure_directory(
        common._absolute_lexical(asset_dir, "E05 asset directory"),
        "E05 asset directory",
    )
    if len(checkpoint_dumps) != 13:
        raise common.AssetValidationError("E05 requires exactly 13 checkpoint dumps")
    checkpoint_reports: list[Mapping[str, object]] = []
    for index, ((name, _, _), dump) in enumerate(
        zip(CHECKPOINT_GOLDENS, checkpoint_dumps, strict=True)
    ):
        actual_path = common._secure_absolute_regular_file(
            dump, f"E05 checkpoint {index} dump"
        )
        actual = common.read_u32_simulator_dump(actual_path, HIDDEN_WORDS)
        golden_path = common._secure_absolute_regular_file(
            directory / f"golden_{name}_f32.hex",
            f"staged E05 checkpoint {index} golden",
        )
        golden = common.read_u32_readmemh(golden_path, HIDDEN_WORDS)
        tolerance = (
            EMBEDDING_ABS_TOLERANCE if index == 0 else ENCODER_ABS_TOLERANCE
        )
        comparison = dict(_comparison(actual, golden, abs_tolerance=tolerance))
        comparison.update(
            {
                "index": index,
                "name": name,
                "shape": [197, 768],
                "actual_sha256": common.sha256_file(actual_path),
                "golden_sha256": common.sha256_file(golden_path),
                "decision": "PASS"
                if comparison["tolerance_failures"] == 0
                and comparison["actual_nonfinite"] == 0
                and comparison["golden_nonfinite"] == 0
                and comparison["sentinel_words"] == 0
                else "FAIL",
            }
        )
        checkpoint_reports.append(comparison)

    final_specs = {
        "final_layernorm": (final_ln_dump, HIDDEN_WORDS, FINAL_LN_ABS_TOLERANCE),
        "logits": (logits_dump, 1_000, LOGITS_ABS_TOLERANCE),
        "probabilities": (
            probabilities_dump,
            1_000,
            PROBABILITIES_ABS_TOLERANCE,
        ),
    }
    final_reports: dict[str, Mapping[str, object]] = {}
    final_actual: dict[str, list[int]] = {}
    for name, (dump, words, tolerance) in final_specs.items():
        actual_path = common._secure_absolute_regular_file(
            dump, f"E05 {name} dump"
        )
        actual = common.read_u32_simulator_dump(actual_path, words)
        golden_path = common._secure_absolute_regular_file(
            directory / f"golden_{name}_f32.hex", f"staged E05 {name} golden"
        )
        golden = common.read_u32_readmemh(golden_path, words)
        comparison = dict(_comparison(actual, golden, abs_tolerance=tolerance))
        comparison["actual_sha256"] = common.sha256_file(actual_path)
        comparison["golden_sha256"] = common.sha256_file(golden_path)
        comparison["decision"] = (
            "PASS"
            if comparison["tolerance_failures"] == 0
            and comparison["actual_nonfinite"] == 0
            and comparison["golden_nonfinite"] == 0
            and comparison["sentinel_words"] == 0
            else "FAIL"
        )
        final_reports[name] = comparison
        final_actual[name] = actual

    class_path = common._secure_absolute_regular_file(
        class_result_dump, "E05 class-result dump"
    )
    class_result = common.read_u32_simulator_dump(class_path, 2)
    actual_logits_top1 = common._argmax_finite(final_actual["logits"], "E05 logits")
    actual_probabilities_top1 = common._argmax_finite(
        final_actual["probabilities"], "E05 probabilities"
    )
    probability_sum = sum(
        common._fp32_bits_to_float(word)
        for word in final_actual["probabilities"]
    )
    probability_sum_error = abs(probability_sum - 1.0)
    class_pass = (
        class_result[0] == EXPECTED_TOP1
        and class_result[1] == final_actual["logits"][EXPECTED_TOP1]
        and actual_logits_top1 == EXPECTED_TOP1
        and actual_probabilities_top1 == EXPECTED_TOP1
        and math.isfinite(probability_sum)
        and probability_sum_error <= PROBABILITY_SUM_ABS_TOLERANCE
    )
    vector_pass = all(row["decision"] == "PASS" for row in checkpoint_reports)
    vector_pass = vector_pass and all(
        row["decision"] == "PASS" for row in final_reports.values()
    )
    report: dict[str, object] = {
        "schema": "vit-m8-mode3-e05-behavioral-golden-comparison-v1",
        "decision": "PASS" if vector_pass and class_pass else "FAIL",
        "execution_mode": 3,
        "criteria": evidence["quality_envelope"],
        "limitation": (
            "ENCODER_AND_CONTINUOUS_FINAL_ABS_LIMITS_ARE_CONSERVATIVE_"
            "PROPOSED_PRE_RUN_BOUNDS_NOT_MEASURED_MODE3_ENVELOPES"
        ),
        "checkpoints": checkpoint_reports,
        "final_outputs": final_reports,
        "top1_and_class": {
            "decision": "PASS" if class_pass else "FAIL",
            "expected": EXPECTED_TOP1,
            "actual_logits": actual_logits_top1,
            "actual_probabilities": actual_probabilities_top1,
            "class_result": class_result[0],
            "class_logit_word": f"0x{class_result[1]:08X}",
            "class_logit_matches_dump": (
                class_result[1] == final_actual["logits"][EXPECTED_TOP1]
            ),
            "probability_sum": probability_sum,
            "probability_sum_abs_error": probability_sum_error,
            "class_result_dump_sha256": common.sha256_file(class_path),
        },
    }
    sha256 = common._write_new_deterministic_json(report_path, report)
    return report, sha256


__all__ = [
    "CHECKPOINT_GOLDENS",
    "E05_ASSET_SCHEMA",
    "ENCODER_ABS_TOLERANCE",
    "EXPECTED_TOP1",
    "compare_behavioral_goldens",
    "compare_endpoint_arithmetic",
    "stage_e05_assets",
    "validate_staged_e05",
]
