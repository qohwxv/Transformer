#!/usr/bin/env python3
"""Fail-closed asset validation for the production E02 layer-0 harness."""

from __future__ import annotations

import hashlib
import json
import re
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODEL_TABLE = ROOT / "build/model_package/v1/vit_model_table.json"
BASELINE_MODEL_TABLE = (
    ROOT / "baseline/model_package/T019_T020_PARAMETER_TABLE.json"
)
BASELINE_CHECKPOINT_HASHES = (
    ROOT / "baseline/modelsim/T004_MAJOR_CHECKPOINTS_SHA256.txt"
)

# These two immutable digests bind the validator to the preserved successful
# model-package and ModelSim runs. A deliberate golden update must review and
# update these values instead of silently trusting a regenerated manifest.
TRUSTED_MODEL_TABLE_SHA256 = (
    "bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038"
)
TRUSTED_CHECKPOINT_MANIFEST_SHA256 = (
    "d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b"
)

HEX_WORD = re.compile(rb"[0-9A-Fa-f]{8}")
HIDDEN_WORDS = 197 * 768
LAYER0_BASE = 0x0017_16F0
LAYER_WORDS = 0x006C_2700

# role, filename suffix, relative word offset, exact word count
PARAMETERS = (
    ("ln1_gamma_base", "ln_before_gamma", 0x0000_0000, 768),
    ("ln1_beta_base", "ln_before_beta", 0x0000_0300, 768),
    ("q_weight_base", "q_weight_B", 0x0000_0600, 768 * 768),
    ("q_bias_base", "q_bias", 0x0009_0600, 768),
    ("k_weight_base", "k_weight_B", 0x0009_0900, 768 * 768),
    ("k_bias_base", "k_bias", 0x0012_0900, 768),
    ("v_weight_base", "v_weight_B", 0x0012_0C00, 768 * 768),
    ("v_bias_base", "v_bias", 0x001B_0C00, 768),
    ("o_weight_base", "o_weight_B", 0x001B_0F00, 768 * 768),
    ("o_bias_base", "o_bias", 0x0024_0F00, 768),
    ("ln2_gamma_base", "ln_after_gamma", 0x0024_1200, 768),
    ("ln2_beta_base", "ln_after_beta", 0x0024_1500, 768),
    ("fc1_weight_base", "fc1_weight_B", 0x0024_1800, 768 * 3072),
    ("fc1_bias_base", "fc1_bias", 0x0048_1800, 3072),
    ("fc2_weight_base", "fc2_weight_B", 0x0048_2400, 3072 * 768),
    ("fc2_bias_base", "fc2_bias", 0x006C_2400, 768),
)

CHECKPOINTS = (
    ("results/embedding_step_06_hidden_states_f32.hex", HIDDEN_WORDS),
    (
        "results/encoder_layer_00_step_20_layer_output_f32.hex",
        HIDDEN_WORDS,
    ),
)


class AssetError(RuntimeError):
    """One required E02 input is missing, malformed, or not pinned."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_hex(
    path: Path,
    expected_words: int,
    *,
    expected_source_sha256: str,
    expected_binary_sha256: str | None = None,
) -> dict[str, object]:
    if not path.is_file():
        raise AssetError(f"missing HEX asset: {path.relative_to(ROOT)}")

    source_digest = hashlib.sha256()
    binary_digest = hashlib.sha256() if expected_binary_sha256 else None
    line_count = 0
    first_word = ""
    last_word = ""

    with path.open("rb") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            source_digest.update(raw_line)
            word = raw_line.rstrip(b"\r\n")
            if not HEX_WORD.fullmatch(word):
                raise AssetError(
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    "expected exactly one 8-hex-digit FP32 word"
                )
            word_text = word.decode("ascii").lower()
            if line_count == 0:
                first_word = word_text
            last_word = word_text
            line_count += 1
            if binary_digest is not None:
                binary_digest.update(struct.pack("<I", int(word, 16)))

    if line_count != expected_words:
        raise AssetError(
            f"{path.relative_to(ROOT)}: expected {expected_words} lines, "
            f"found {line_count}"
        )

    source_sha256 = source_digest.hexdigest()
    if source_sha256 != expected_source_sha256.lower():
        raise AssetError(
            f"{path.relative_to(ROOT)}: source SHA-256 mismatch: "
            f"expected {expected_source_sha256}, got {source_sha256}"
        )

    binary_sha256 = binary_digest.hexdigest() if binary_digest else None
    if (
        expected_binary_sha256 is not None
        and binary_sha256 != expected_binary_sha256.lower()
    ):
        raise AssetError(
            f"{path.relative_to(ROOT)}: packed-binary SHA-256 mismatch: "
            f"expected {expected_binary_sha256}, got {binary_sha256}"
        )

    return {
        "path": path.relative_to(ROOT).as_posix(),
        "words": line_count,
        "source_sha256": source_sha256,
        "binary_sha256": binary_sha256,
        "first_word": first_word,
        "last_word": last_word,
    }


def load_checkpoint_hashes() -> dict[str, str]:
    if not BASELINE_CHECKPOINT_HASHES.is_file():
        raise AssetError(
            "missing trusted checkpoint manifest: "
            f"{BASELINE_CHECKPOINT_HASHES.relative_to(ROOT)}"
        )
    actual_manifest_hash = sha256_file(BASELINE_CHECKPOINT_HASHES)
    if actual_manifest_hash != TRUSTED_CHECKPOINT_MANIFEST_SHA256:
        raise AssetError(
            "trusted checkpoint manifest SHA-256 mismatch: "
            f"expected {TRUSTED_CHECKPOINT_MANIFEST_SHA256}, "
            f"got {actual_manifest_hash}"
        )

    hashes: dict[str, str] = {}
    for line_number, line in enumerate(
        BASELINE_CHECKPOINT_HASHES.read_text(encoding="ascii").splitlines(),
        1,
    ):
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            raise AssetError(
                f"{BASELINE_CHECKPOINT_HASHES.relative_to(ROOT)}:"
                f"{line_number}: malformed SHA-256 entry"
            )
        relative_path = parts[1].strip()
        if relative_path in hashes:
            raise AssetError(
                f"duplicate trusted checkpoint path: {relative_path}"
            )
        hashes[relative_path] = parts[0]
    return hashes


def load_pinned_model_table() -> dict[str, object]:
    for path in (BASELINE_MODEL_TABLE, MODEL_TABLE):
        if not path.is_file():
            raise AssetError(f"missing model table: {path.relative_to(ROOT)}")
        actual_hash = sha256_file(path)
        if actual_hash != TRUSTED_MODEL_TABLE_SHA256:
            raise AssetError(
                f"{path.relative_to(ROOT)} SHA-256 mismatch: "
                f"expected {TRUSTED_MODEL_TABLE_SHA256}, got {actual_hash}"
            )
    if MODEL_TABLE.read_bytes() != BASELINE_MODEL_TABLE.read_bytes():
        raise AssetError("generated model table differs from pinned baseline")

    try:
        table = json.loads(MODEL_TABLE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AssetError(f"cannot parse model table: {exc}") from exc
    if table.get("schema") != "vit-model-package-v1":
        raise AssetError("model table schema is not vit-model-package-v1")
    if table.get("address_unit") != "FP32_WORD":
        raise AssetError("model table address unit is not FP32_WORD")
    if table.get("dtype") != "IEEE754_BINARY32_RAW_BITS":
        raise AssetError("model table dtype is not IEEE754_BINARY32_RAW_BITS")
    return table


def validate() -> str:
    table = load_pinned_model_table()
    layer_offsets = table.get("layer_offsets")
    if not isinstance(layer_offsets, list) or len(layer_offsets) != 12:
        raise AssetError("model table must have exactly 12 layer-offset records")
    offset_record = layer_offsets[0]

    entries = [
        entry
        for entry in table.get("entries", [])
        if entry.get("group") == 1 and entry.get("layer") == 0
    ]
    entries.sort(key=lambda entry: entry.get("slot", -1))
    if len(entries) != len(PARAMETERS):
        raise AssetError(
            f"model table layer 0 has {len(entries)} entries, expected 16"
        )

    validated: list[dict[str, object]] = []
    total_parameter_words = 0
    for slot, (entry, specification) in enumerate(zip(entries, PARAMETERS)):
        role, suffix, relative_offset, word_count = specification
        expected_filename = f"encoder_layer_00_{suffix}_f32.hex"
        expected_offset = LAYER0_BASE + relative_offset
        exact_fields = {
            "slot": slot,
            "role": role,
            "filename": expected_filename,
            "word_offset": expected_offset,
            "byte_offset": expected_offset * 4,
            "word_count": word_count,
        }
        for field, expected in exact_fields.items():
            if entry.get(field) != expected:
                raise AssetError(
                    f"layer-0 slot {slot} field {field}: "
                    f"expected {expected!r}, got {entry.get(field)!r}"
                )
        if offset_record.get(role) != expected_offset:
            raise AssetError(
                f"layer_offsets[0].{role}: expected {expected_offset}, "
                f"got {offset_record.get(role)!r}"
            )

        source_sha256 = entry.get("source_sha256")
        binary_sha256 = entry.get("tensor_sha256")
        if not isinstance(source_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", source_sha256
        ):
            raise AssetError(f"layer-0 slot {slot} has invalid source_sha256")
        if not isinstance(binary_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", binary_sha256
        ):
            raise AssetError(f"layer-0 slot {slot} has invalid tensor_sha256")

        result = validate_hex(
            ROOT / "parameters" / expected_filename,
            word_count,
            expected_source_sha256=source_sha256,
            expected_binary_sha256=binary_sha256,
        )
        if entry.get("first_word", "").lower() != (
            f"0x{result['first_word']}"
        ):
            raise AssetError(
                f"parameters/{expected_filename}: first word disagrees "
                "with model table"
            )
        if entry.get("last_word", "").lower() != (
            f"0x{result['last_word']}"
        ):
            raise AssetError(
                f"parameters/{expected_filename}: last word disagrees "
                "with model table"
            )
        validated.append(result)
        total_parameter_words += word_count

    if total_parameter_words != LAYER_WORDS:
        raise AssetError(
            f"layer-0 extent is {total_parameter_words}, "
            f"expected {LAYER_WORDS}"
        )

    checkpoint_hashes = load_checkpoint_hashes()
    for relative_path, word_count in CHECKPOINTS:
        expected_hash = checkpoint_hashes.get(relative_path)
        if expected_hash is None:
            raise AssetError(
                f"checkpoint is not pinned by manifest: {relative_path}"
            )
        validated.append(
            validate_hex(
                ROOT / relative_path,
                word_count,
                expected_source_sha256=expected_hash,
            )
        )

    canonical = {
        "schema": "vit-e02-layer0-real-assets-v1",
        "model_table_sha256": TRUSTED_MODEL_TABLE_SHA256,
        "checkpoint_manifest_sha256": (
            TRUSTED_CHECKPOINT_MANIFEST_SHA256
        ),
        "files": sorted(validated, key=lambda item: str(item["path"])),
    }
    asset_set_sha256 = hashlib.sha256(
        json.dumps(
            canonical,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return (
        "E02_ASSET_VALIDATION_PASS "
        f"files={len(validated)} parameter_words={total_parameter_words} "
        f"checkpoint_words={2 * HIDDEN_WORDS} "
        f"model_table_sha256={TRUSTED_MODEL_TABLE_SHA256} "
        "checkpoint_manifest_sha256="
        f"{TRUSTED_CHECKPOINT_MANIFEST_SHA256} "
        f"asset_set_sha256={asset_set_sha256}"
    )


def main() -> int:
    try:
        print(validate())
    except AssetError as exc:
        print(f"E02_ASSET_VALIDATION_FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
