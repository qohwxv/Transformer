#!/usr/bin/env python3
"""Validate immutable real-data assets consumed by the E01/E04 AXI tests.

The validator does not trust a regenerated manifest merely because it is
internally self-consistent.  It pins the preserved model-package, ModelSim and
preprocessing manifests by SHA-256, checks the exact table records used by the
selected phase, and then validates every HEX file byte-for-byte and word-for-
word before deriving one canonical asset-set identity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]

MODEL_TABLE_PATHS = (
    Path("baseline/model_package/T019_T020_PARAMETER_TABLE.json"),
    Path("build/model_package/v1/vit_model_table.json"),
)
MODELSIM_MANIFEST = Path("baseline/modelsim/T004_MAJOR_CHECKPOINTS.json")
MODELSIM_HASH_LIST = Path(
    "baseline/modelsim/T004_MAJOR_CHECKPOINTS_SHA256.txt"
)
PREPROCESS_MANIFEST = Path("preprocessed/preprocess_manifest.json")

TRUSTED_MODEL_TABLE_SHA256 = (
    "bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038"
)
TRUSTED_MODELSIM_MANIFEST_SHA256 = (
    "d225e16ed2be3c3868c5d71c39860386e3180e0b82671ae4ddc47e9203cac45d"
)
TRUSTED_MODELSIM_HASH_LIST_SHA256 = (
    "d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b"
)
TRUSTED_PREPROCESS_MANIFEST_SHA256 = (
    "08c001878e342779412f991653fe3899c9bc1753fdc9dbc0d893d6c315d735e7"
)

HEX_WORD_RE = re.compile(rb"^[0-9A-Fa-f]{8}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# slot, role, filename, word offset, exact word count
PARAMETERS: dict[str, tuple[tuple[int, str, str, int, int], ...]] = {
    "e01": (
        (0, "patch_weight_base", "embedding_patch_weight_B_f32.hex",
         0x0000_0000, 768 * 768),
        (1, "patch_bias_base", "embedding_patch_bias_f32.hex",
         0x0009_0000, 768),
        (2, "cls_base", "embedding_cls_token_f32.hex",
         0x0009_0300, 768),
        (3, "position_base", "embedding_position_f32.hex",
         0x0009_0600, 197 * 768),
    ),
    "e04": (
        (4, "final_ln_gamma_base", "post_encoder_final_ln_gamma_f32.hex",
         0x000b_5500, 768),
        (5, "final_ln_beta_base", "post_encoder_final_ln_beta_f32.hex",
         0x000b_5800, 768),
        (6, "classifier_weight_base",
         "post_encoder_classifier_weight_B_f32.hex",
         0x000b_5b00, 768 * 1000),
        (7, "classifier_bias_base",
         "post_encoder_classifier_bias_f32.hex",
         0x0017_1300, 1000),
    ),
}

# role, path, exact word count
NON_PARAMETER_ASSETS: dict[str, tuple[tuple[str, str, int], ...]] = {
    "e01": (
        (
            "activation",
            "preprocessed/embedding_input_patch_A_f32.hex",
            196 * 768,
        ),
        (
            "golden",
            "results/embedding_step_06_hidden_states_f32.hex",
            197 * 768,
        ),
    ),
    "e04": (
        (
            "activation",
            "results/encoder_layer_11_step_20_layer_output_f32.hex",
            197 * 768,
        ),
        (
            "golden",
            "results/post_encoder_step_30_final_layernorm_f32.hex",
            197 * 768,
        ),
        (
            "golden",
            "results/post_encoder_step_32_logits_f32.hex",
            1000,
        ),
        (
            "golden",
            "results/post_encoder_step_33p_probabilities_f32.hex",
            1000,
        ),
    ),
}


class AssetError(RuntimeError):
    """A required real-AXI asset or trust anchor is invalid."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def repo_file(relative: Path) -> Path:
    value = relative.as_posix()
    if (
        not value
        or relative.is_absolute()
        or Path(value).as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise AssetError(f"non-canonical repository path: {value!r}")

    current = ROOT
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise AssetError(f"asset path contains a symlink: {value}")
    try:
        current.resolve(strict=True).relative_to(ROOT.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise AssetError(f"asset path escapes repository: {value}") from exc
    if not current.is_file():
        raise AssetError(f"asset is not a regular file: {value}")
    return current


def strict_json_load(relative: Path, description: str) -> Any:
    path = repo_file(relative)

    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise AssetError(
                    f"{description} contains duplicate key {key!r}"
                )
            result[key] = value
        return result

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AssetError(f"cannot parse {description}: {exc}") from exc


def require_pinned_file(
    relative: Path,
    expected_sha256: str,
    description: str,
) -> Path:
    path = repo_file(relative)
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise AssetError(
            f"{description} SHA-256 mismatch: expected {expected_sha256}, "
            f"got {actual}"
        )
    return path


def validate_hex(
    relative: Path,
    expected_words: int,
    expected_source_sha256: str,
    *,
    expected_binary_sha256: str | None = None,
) -> dict[str, object]:
    if not SHA256_RE.fullmatch(expected_source_sha256):
        raise AssetError(
            f"{relative}: trusted source SHA-256 has invalid syntax"
        )
    if (
        expected_binary_sha256 is not None
        and not SHA256_RE.fullmatch(expected_binary_sha256)
    ):
        raise AssetError(
            f"{relative}: trusted binary SHA-256 has invalid syntax"
        )

    path = repo_file(relative)
    source_digest = hashlib.sha256()
    binary_digest = (
        hashlib.sha256() if expected_binary_sha256 is not None else None
    )
    words = 0
    first_word = ""
    last_word = ""

    with path.open("rb") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            source_digest.update(raw_line)
            raw_word = raw_line.rstrip(b"\r\n")
            if not HEX_WORD_RE.fullmatch(raw_word):
                raise AssetError(
                    f"{relative}:{line_number}: expected exactly one "
                    "8-hex-digit word"
                )
            word = raw_word.decode("ascii").lower()
            if words == 0:
                first_word = word
            last_word = word
            words += 1
            if binary_digest is not None:
                binary_digest.update(struct.pack("<I", int(raw_word, 16)))

    if words != expected_words:
        raise AssetError(
            f"{relative}: expected {expected_words} words, found {words}"
        )
    source_sha256 = source_digest.hexdigest()
    if source_sha256 != expected_source_sha256:
        raise AssetError(
            f"{relative}: source SHA-256 mismatch: expected "
            f"{expected_source_sha256}, got {source_sha256}"
        )
    binary_sha256 = (
        binary_digest.hexdigest() if binary_digest is not None else None
    )
    if (
        expected_binary_sha256 is not None
        and binary_sha256 != expected_binary_sha256
    ):
        raise AssetError(
            f"{relative}: packed-binary SHA-256 mismatch: expected "
            f"{expected_binary_sha256}, got {binary_sha256}"
        )

    return {
        "path": relative.as_posix(),
        "words": words,
        "size_bytes": path.stat().st_size,
        "source_sha256": source_sha256,
        "binary_sha256": binary_sha256,
        "first_word": first_word,
        "last_word": last_word,
    }


def load_model_table() -> dict[str, object]:
    table_bytes: bytes | None = None
    for relative in MODEL_TABLE_PATHS:
        path = require_pinned_file(
            relative,
            TRUSTED_MODEL_TABLE_SHA256,
            relative.as_posix(),
        )
        content = path.read_bytes()
        if table_bytes is None:
            table_bytes = content
        elif content != table_bytes:
            raise AssetError(
                "generated model table differs from preserved baseline"
            )

    table = strict_json_load(MODEL_TABLE_PATHS[-1], "model package table")
    if not isinstance(table, dict):
        raise AssetError("model package table must be a JSON object")
    expected_header = {
        "schema": "vit-model-package-v1",
        "address_unit": "FP32_WORD",
        "byte_order": "LITTLE_ENDIAN",
        "alignment_bytes": 64,
        "dtype": "IEEE754_BINARY32_RAW_BITS",
    }
    for field, expected in expected_header.items():
        if table.get(field) != expected:
            raise AssetError(
                f"model package table {field}: expected {expected!r}, "
                f"got {table.get(field)!r}"
            )
    entries = table.get("entries")
    if not isinstance(entries, list):
        raise AssetError("model package table entries must be an array")
    global_offsets = table.get("global_offsets")
    if not isinstance(global_offsets, dict):
        raise AssetError("model package table global_offsets must be an object")
    return table


def load_modelsim_hashes() -> tuple[dict[str, dict[str, object]], dict[str, str]]:
    require_pinned_file(
        MODELSIM_MANIFEST,
        TRUSTED_MODELSIM_MANIFEST_SHA256,
        "trusted ModelSim JSON manifest",
    )
    require_pinned_file(
        MODELSIM_HASH_LIST,
        TRUSTED_MODELSIM_HASH_LIST_SHA256,
        "trusted ModelSim SHA-256 list",
    )
    manifest = strict_json_load(MODELSIM_MANIFEST, "ModelSim manifest")
    if not isinstance(manifest, dict):
        raise AssetError("ModelSim manifest must be a JSON object")
    if manifest.get("schema") != "vit-modelsim-baseline-manifest-v1":
        raise AssetError("unexpected ModelSim manifest schema")
    files = manifest.get("files")
    if (
        not isinstance(files, list)
        or manifest.get("file_count") != 21
        or len(files) != 21
    ):
        raise AssetError("ModelSim manifest must contain exactly 21 files")

    records: dict[str, dict[str, object]] = {}
    for record in files:
        if not isinstance(record, dict):
            raise AssetError("ModelSim file record must be an object")
        path = record.get("path")
        digest = record.get("sha256")
        words = record.get("nonempty_lines")
        size_bytes = record.get("size_bytes")
        if (
            not isinstance(path, str)
            or path in records
            or not isinstance(digest, str)
            or not SHA256_RE.fullmatch(digest)
            or not isinstance(words, int)
            or isinstance(words, bool)
            or words <= 0
            or not isinstance(size_bytes, int)
            or isinstance(size_bytes, bool)
            or size_bytes <= 0
        ):
            raise AssetError("malformed or duplicate ModelSim file record")
        records[path] = record

    hash_list: dict[str, str] = {}
    text = repo_file(MODELSIM_HASH_LIST).read_text(encoding="ascii")
    for line_number, line in enumerate(text.splitlines(), 1):
        parts = line.split(maxsplit=1)
        if (
            len(parts) != 2
            or not SHA256_RE.fullmatch(parts[0])
            or not parts[1].strip()
        ):
            raise AssetError(
                f"{MODELSIM_HASH_LIST}:{line_number}: malformed hash entry"
            )
        path = parts[1].strip()
        if path in hash_list:
            raise AssetError(f"duplicate ModelSim hash-list path: {path}")
        hash_list[path] = parts[0]
    if len(hash_list) != 21 or set(hash_list) != set(records):
        raise AssetError("ModelSim JSON/hash-list file sets differ")
    for path, digest in hash_list.items():
        if records[path].get("sha256") != digest:
            raise AssetError(
                f"ModelSim manifests disagree on SHA-256 for {path}"
            )
    return records, hash_list


def load_preprocess_manifest() -> dict[str, object]:
    require_pinned_file(
        PREPROCESS_MANIFEST,
        TRUSTED_PREPROCESS_MANIFEST_SHA256,
        "trusted preprocessing manifest",
    )
    manifest = strict_json_load(PREPROCESS_MANIFEST, "preprocessing manifest")
    if not isinstance(manifest, dict):
        raise AssetError("preprocessing manifest must be a JSON object")
    if manifest.get("schema") != "vit-preprocessed-input-v1":
        raise AssetError("unexpected preprocessing manifest schema")
    tensor = manifest.get("tensor")
    artifacts = manifest.get("artifacts")
    if not isinstance(tensor, dict) or not isinstance(artifacts, dict):
        raise AssetError("preprocessing tensor/artifacts records are missing")
    if (
        tensor.get("shape") != [1, 196, 768]
        or tensor.get("dtype") != "IEEE754_BINARY32_RAW_BITS"
        or tensor.get("word_count") != 150528
        or tensor.get("layout")
        != "patch_y,patch_x,channel,kernel_y,kernel_x"
        or tensor.get("first_word") != "0x3EDEDEDF"
        or tensor.get("last_word") != "0x3F800000"
    ):
        raise AssetError("preprocessing tensor contract is not canonical")
    hex_record = artifacts.get("hex")
    if not isinstance(hex_record, dict):
        raise AssetError("preprocessing HEX artifact record is missing")
    if (
        hex_record.get("path")
        != "preprocessed/embedding_input_patch_A_f32.hex"
        or hex_record.get("size_bytes") != 1354752
        or hex_record.get("sha256")
        != "64838233b7925e9ee16ce798ff2bdb7e0b25b3c4599c8ab043071fc668c91523"
    ):
        raise AssetError("preprocessing HEX artifact contract changed")
    return manifest


def validate_phase(phase: str) -> str:
    table = load_model_table()
    modelsim_records, _ = load_modelsim_hashes()
    preprocess = load_preprocess_manifest()

    entries = table["entries"]
    global_offsets = table["global_offsets"]
    validated: list[dict[str, object]] = []
    parameter_words = 0

    for slot, role, filename, word_offset, word_count in PARAMETERS[phase]:
        matches = [
            entry
            for entry in entries
            if isinstance(entry, dict)
            and entry.get("group") == 0
            and entry.get("layer") == 255
            and entry.get("slot") == slot
        ]
        if len(matches) != 1:
            raise AssetError(
                f"model table global slot {slot} must occur exactly once"
            )
        entry = matches[0]
        exact_fields = {
            "tensor_id": slot,
            "role": role,
            "filename": filename,
            "word_offset": word_offset,
            "byte_offset": word_offset * 4,
            "word_count": word_count,
        }
        for field, expected in exact_fields.items():
            if entry.get(field) != expected:
                raise AssetError(
                    f"model table slot {slot} {field}: expected "
                    f"{expected!r}, got {entry.get(field)!r}"
                )
        if global_offsets.get(role) != word_offset:
            raise AssetError(
                f"model table global_offsets.{role} is not {word_offset}"
            )
        source_sha256 = entry.get("source_sha256")
        binary_sha256 = entry.get("tensor_sha256")
        if (
            not isinstance(source_sha256, str)
            or not isinstance(binary_sha256, str)
        ):
            raise AssetError(
                f"model table slot {slot} has missing tensor hashes"
            )
        record = validate_hex(
            Path("parameters") / filename,
            word_count,
            source_sha256,
            expected_binary_sha256=binary_sha256,
        )
        if entry.get("first_word") != f"0x{record['first_word'].upper()}":
            raise AssetError(
                f"model table slot {slot} first_word disagrees with HEX"
            )
        if entry.get("last_word") != f"0x{record['last_word'].upper()}":
            raise AssetError(
                f"model table slot {slot} last_word disagrees with HEX"
            )
        record["role"] = "parameter"
        validated.append(record)
        parameter_words += word_count

    activation_words = 0
    golden_words = 0
    for role, path_text, word_count in NON_PARAMETER_ASSETS[phase]:
        baseline_record = modelsim_records.get(path_text)
        if not isinstance(baseline_record, dict):
            raise AssetError(
                f"asset is not pinned by ModelSim manifest: {path_text}"
            )
        if baseline_record.get("nonempty_lines") != word_count:
            raise AssetError(
                f"ModelSim word count for {path_text} is not {word_count}"
            )
        expected_sha256 = baseline_record.get("sha256")
        if not isinstance(expected_sha256, str):
            raise AssetError(f"ModelSim hash is missing for {path_text}")
        record = validate_hex(
            Path(path_text),
            word_count,
            expected_sha256,
        )
        if record["size_bytes"] != baseline_record.get("size_bytes"):
            raise AssetError(
                f"ModelSim size for {path_text} disagrees with file"
            )
        record["role"] = role
        validated.append(record)
        if role == "activation":
            activation_words += word_count
        else:
            golden_words += word_count

    if phase == "e01":
        input_path = "preprocessed/embedding_input_patch_A_f32.hex"
        input_record = next(
            record for record in validated if record["path"] == input_path
        )
        prepared_input = table.get("prepared_input")
        hex_record = preprocess["artifacts"]["hex"]
        tensor = preprocess["tensor"]
        if (
            not isinstance(prepared_input, dict)
            or prepared_input.get("source_sha256")
            != input_record["source_sha256"]
            or prepared_input.get("word_count") != input_record["words"]
            or prepared_input.get("first_word")
            != f"0x{input_record['first_word'].upper()}"
            or prepared_input.get("last_word")
            != f"0x{input_record['last_word'].upper()}"
            or hex_record.get("sha256") != input_record["source_sha256"]
            or hex_record.get("size_bytes") != input_record["size_bytes"]
            or tensor.get("word_count") != input_record["words"]
            or tensor.get("first_word")
            != f"0x{input_record['first_word'].upper()}"
            or tensor.get("last_word")
            != f"0x{input_record['last_word'].upper()}"
        ):
            raise AssetError(
                "prepared input disagrees across model/preprocess/ModelSim "
                "trust anchors"
            )

    manifest_hashes = {
        "model_table_sha256": TRUSTED_MODEL_TABLE_SHA256,
        "modelsim_manifest_sha256": TRUSTED_MODELSIM_MANIFEST_SHA256,
        "modelsim_hash_list_sha256": TRUSTED_MODELSIM_HASH_LIST_SHA256,
        "preprocess_manifest_sha256": TRUSTED_PREPROCESS_MANIFEST_SHA256,
    }
    asset_set_sha256 = hashlib.sha256(
        (
            json.dumps(
                {
                    "schema": "vit-real-axi-assets-v1",
                    "phase": phase,
                    "manifests": manifest_hashes,
                    "files": sorted(
                        validated,
                        key=lambda item: str(item["path"]),
                    ),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    ).hexdigest()

    marker = phase.upper() + "_ASSET_VALIDATION_PASS"
    return (
        f"{marker} files={len(validated)} "
        f"parameter_words={parameter_words} "
        f"activation_words={activation_words} "
        f"golden_words={golden_words} "
        f"model_table_sha256={TRUSTED_MODEL_TABLE_SHA256} "
        f"modelsim_manifest_sha256={TRUSTED_MODELSIM_MANIFEST_SHA256} "
        f"modelsim_hash_list_sha256={TRUSTED_MODELSIM_HASH_LIST_SHA256} "
        f"preprocess_manifest_sha256={TRUSTED_PREPROCESS_MANIFEST_SHA256} "
        f"asset_set_sha256={asset_set_sha256}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--phase",
        choices=("e01", "e04"),
        required=True,
        help="Real AXI phase whose exact consumed files are validated",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        print(validate_phase(args.phase))
    except (AssetError, OSError, UnicodeError) as exc:
        print(
            f"{args.phase.upper()}_ASSET_VALIDATION_FAIL: {exc}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
