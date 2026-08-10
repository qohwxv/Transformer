#!/usr/bin/env python3
"""Fail-closed validation for the production E03 real-layer harness assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODEL_TABLE = ROOT / "build/model_package/v1/vit_model_table.json"
BASELINE_HASHES = ROOT / "baseline/modelsim/T004_MAJOR_CHECKPOINTS_SHA256.txt"
TRUSTED_MODEL_TABLE_SHA256 = (
    "bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038"
)

# This manifest was produced with the preserved, successful ModelSim golden
# run. Pinning the manifest itself prevents a modified checkpoint and modified
# hash list from silently becoming a new E03 reference.
TRUSTED_BASELINE_MANIFEST_SHA256 = (
    "d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b"
)

HEX_WORD = re.compile(rb"[0-9A-Fa-f]{8}")
HIDDEN_WORDS = 197 * 768
LAYER0_BASE = 0x0017_16F0
LAYER_WORDS = 0x006C_2700

# role, filename suffix, relative word offset, word count
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


class AssetError(RuntimeError):
    """An E03 input is missing, malformed, or not the pinned artifact."""


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
) -> tuple[str, str | None, str, str]:
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

    return source_sha256, binary_sha256, first_word, last_word


def load_trusted_checkpoint_hashes() -> dict[str, str]:
    if not BASELINE_HASHES.is_file():
        raise AssetError(
            f"missing trusted baseline manifest: {BASELINE_HASHES.relative_to(ROOT)}"
        )
    manifest_sha256 = sha256_file(BASELINE_HASHES)
    if manifest_sha256 != TRUSTED_BASELINE_MANIFEST_SHA256:
        raise AssetError(
            "trusted baseline manifest SHA-256 mismatch: "
            f"expected {TRUSTED_BASELINE_MANIFEST_SHA256}, got {manifest_sha256}"
        )

    hashes: dict[str, str] = {}
    for line_number, line in enumerate(
        BASELINE_HASHES.read_text(encoding="ascii").splitlines(), 1
    ):
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            raise AssetError(
                f"{BASELINE_HASHES.relative_to(ROOT)}:{line_number}: "
                "malformed SHA-256 manifest entry"
            )
        path = parts[1].strip()
        if path in hashes:
            raise AssetError(f"duplicate trusted baseline path: {path}")
        hashes[path] = parts[0]
    return hashes


def validate_layer(layer: int) -> None:
    if not MODEL_TABLE.is_file():
        raise AssetError(f"missing model table: {MODEL_TABLE.relative_to(ROOT)}")
    model_table_sha256 = sha256_file(MODEL_TABLE)
    if model_table_sha256 != TRUSTED_MODEL_TABLE_SHA256:
        raise AssetError(
            "model table SHA-256 mismatch: "
            f"expected {TRUSTED_MODEL_TABLE_SHA256}, got {model_table_sha256}"
        )
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

    layer_offsets = table.get("layer_offsets")
    if not isinstance(layer_offsets, list) or len(layer_offsets) != 12:
        raise AssetError("model table must contain exactly 12 layer-offset records")
    offset_record = layer_offsets[layer]

    entries = [
        entry
        for entry in table.get("entries", [])
        if entry.get("group") == 1 and entry.get("layer") == layer
    ]
    entries.sort(key=lambda entry: entry.get("slot", -1))
    if len(entries) != len(PARAMETERS):
        raise AssetError(
            f"model table layer {layer} has {len(entries)} entries, expected 16"
        )

    layer_base = LAYER0_BASE + layer * LAYER_WORDS
    total_parameter_words = 0
    validated: list[dict[str, object]] = []
    for slot, (entry, specification) in enumerate(zip(entries, PARAMETERS)):
        role, suffix, relative_offset, word_count = specification
        expected_filename = (
            f"encoder_layer_{layer:02d}_{suffix}_f32.hex"
        )
        expected_offset = layer_base + relative_offset

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
                    f"model table layer {layer} slot {slot} field {field}: "
                    f"expected {expected!r}, got {entry.get(field)!r}"
                )
        if offset_record.get(role) != expected_offset:
            raise AssetError(
                f"model table layer_offsets[{layer}].{role}: "
                f"expected {expected_offset}, got {offset_record.get(role)!r}"
            )

        source_sha256 = entry.get("source_sha256")
        binary_sha256 = entry.get("tensor_sha256")
        if not isinstance(source_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", source_sha256
        ):
            raise AssetError(
                f"model table layer {layer} slot {slot} has invalid source_sha256"
            )
        if not isinstance(binary_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", binary_sha256
        ):
            raise AssetError(
                f"model table layer {layer} slot {slot} has invalid tensor_sha256"
            )

        parameter_path = ROOT / "parameters" / expected_filename
        source_digest, binary_digest, first_word, last_word = validate_hex(
            parameter_path,
            word_count,
            expected_source_sha256=source_sha256,
            expected_binary_sha256=binary_sha256,
        )
        if entry.get("first_word", "").lower() != f"0x{first_word}":
            raise AssetError(
                f"{parameter_path.relative_to(ROOT)}: first word disagrees "
                "with model table"
            )
        if entry.get("last_word", "").lower() != f"0x{last_word}":
            raise AssetError(
                f"{parameter_path.relative_to(ROOT)}: last word disagrees "
                "with model table"
            )
        validated.append(
            {
                "path": parameter_path.relative_to(ROOT).as_posix(),
                "words": word_count,
                "source_sha256": source_digest,
                "binary_sha256": binary_digest,
                "first_word": first_word,
                "last_word": last_word,
            }
        )
        total_parameter_words += word_count

    if total_parameter_words != LAYER_WORDS:
        raise AssetError(
            f"layer parameter extent is {total_parameter_words}, "
            f"expected {LAYER_WORDS}"
        )

    trusted_hashes = load_trusted_checkpoint_hashes()
    checkpoint_paths = (
        f"results/encoder_layer_{layer - 1:02d}_step_20_layer_output_f32.hex",
        f"results/encoder_layer_{layer:02d}_step_20_layer_output_f32.hex",
    )
    for relative_path in checkpoint_paths:
        expected_hash = trusted_hashes.get(relative_path)
        if expected_hash is None:
            raise AssetError(
                f"checkpoint is not pinned by trusted manifest: {relative_path}"
            )
        source_digest, _, first_word, last_word = validate_hex(
            ROOT / relative_path,
            HIDDEN_WORDS,
            expected_source_sha256=expected_hash,
        )
        validated.append(
            {
                "path": relative_path,
                "words": HIDDEN_WORDS,
                "source_sha256": source_digest,
                "binary_sha256": None,
                "first_word": first_word,
                "last_word": last_word,
            }
        )

    asset_set_sha256 = hashlib.sha256(
        json.dumps(
            {
                "schema": "vit-e03-real-layer-assets-v1",
                "layer": layer,
                "model_table_sha256": TRUSTED_MODEL_TABLE_SHA256,
                "checkpoint_manifest_sha256": (
                    TRUSTED_BASELINE_MANIFEST_SHA256
                ),
                "files": sorted(
                    validated,
                    key=lambda item: str(item["path"]),
                ),
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()

    print(
        "E03_ASSET_VALIDATION_PASS "
        f"layer={layer} parameters=16 parameter_words={total_parameter_words} "
        f"checkpoints=2 checkpoint_words={2 * HIDDEN_WORDS} "
        f"model_table_sha256={TRUSTED_MODEL_TABLE_SHA256} "
        f"baseline_manifest_sha256={TRUSTED_BASELINE_MANIFEST_SHA256} "
        f"asset_set_sha256={asset_set_sha256}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--layer", type=int, required=True)
    arguments = parser.parse_args()
    if not 1 <= arguments.layer <= 11:
        parser.error("--layer must be in the range 1..11")
    try:
        validate_layer(arguments.layer)
    except AssetError as exc:
        print(f"E03_ASSET_VALIDATION_FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
