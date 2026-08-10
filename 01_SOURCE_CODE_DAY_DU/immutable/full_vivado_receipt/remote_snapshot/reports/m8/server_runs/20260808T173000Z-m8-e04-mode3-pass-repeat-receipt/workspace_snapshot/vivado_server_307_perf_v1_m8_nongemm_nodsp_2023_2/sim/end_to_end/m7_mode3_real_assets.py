#!/usr/bin/env python3
"""Fail-closed package-v3 staging and M7 numerical-oracle helpers.

This module deliberately discovers the repository from its own installed
location, never from the caller's current working directory.  The production
entry point accepts only the hash-pinned mixed FP32/packed-FP16 v3 package.

The numerical helpers bind two existing implementation contracts:

* the M6 exact binary16-product/Kulisch-dot Python reference; and
* the current feed-forward ``vit_fp32_add_comb`` bias/position adder.

No Vivado, RTL simulator, board, or network access is performed here.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import operator
import re
import shutil
import stat
import struct
import sys
import math
import zlib
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from types import ModuleType
from typing import Any, Iterable, Iterator, Mapping, Sequence


ASSET_EVIDENCE_SCHEMA = "vit-m7-mode3-real-assets-v2"
PACKAGE_SCHEMA = "vit-model-package-v3-blocked-b-fp16-mixed"
HASH_MANIFEST_SCHEMA = (
    "vit-model-package-hashes-v3-blocked-b-fp16-mixed"
)
CANONICAL_PACKAGE_RELATIVE = Path(
    "build/model_package/v3_blocked_b_fp16_mixed"
)

TABLE_MAGIC = b"VITMTBL\x00"
TABLE_MAJOR = 3
TABLE_MINOR = 0
TABLE_HEADER_BYTES = 128
TABLE_ENTRY_BYTES = 64
TABLE_ENDIAN_LITTLE = 1
TABLE_DTYPE_MIXED_BY_ENTRY = 2
TABLE_ALIGNMENT_BYTES = 128
TABLE_FLAGS = 0x0000_001F
TABLE_CRC32_ISO_HDLC = 1
TABLE_HEADER_STRUCT = struct.Struct("<8sHH7I5Q4I32s")
TABLE_ENTRY_STRUCT = struct.Struct("<IHBBQQQ" + "I" * 8)

EXPECTED_TENSOR_COUNT = 200
EXPECTED_SOURCE_WORDS = 86_567_656
EXPECTED_STORAGE_WORDS = 43_421_440
EXPECTED_MODEL_BYTES = 173_685_760
EXPECTED_PACKED_TENSORS = 74
EXPECTED_MODEL_CRC32 = 0xB4B92D00

LAYOUT_VECTOR = 1
LAYOUT_ROW_MAJOR = 2
LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2 = 5
FLAG_WEIGHT_B = 1 << 0
FLAG_BLOCKED_B_K16_N2 = 1 << 7
FLAG_FP16_PACKED2 = 1 << 8
PACKED_REQUIRED_FLAGS = (
    FLAG_WEIGHT_B | FLAG_BLOCKED_B_K16_N2 | FLAG_FP16_PACKED2
)
BLOCK_K = 16
BLOCK_N = 2
BLOCK_STORAGE_WORDS = 16

M6_REFERENCE_RELATIVE = Path(
    "experimental/m6_fp16_nodsp_ooc/reference/m6_fp16_reference.py"
)
M6_REFERENCE_SHA256 = (
    "075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35"
)
FP32_ADD_RTL_RELATIVE = Path(
    "vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/"
    "rtl/leaf/fp32/vit_fp32_add_comb.sv"
)
FP32_ADD_RTL_SHA256 = (
    "3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141"
)

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HEX32_RE = re.compile(rb"^[0-9a-fA-F]{8}$")


@dataclass(frozen=True)
class FilePin:
    size_bytes: int
    sha256: str


CANONICAL_FILE_PINS: Mapping[str, FilePin] = {
    "hash_manifest.json": FilePin(
        1_136,
        "74cdd537ba765e1ce9f64f3afc6a5c037dce6d67e47c6b9587e6a8acd82b3324",
    ),
    "prepared_input.bin": FilePin(
        602_112,
        "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54",
    ),
    "verification_report.json": FilePin(
        232_013,
        "1654962e01b45e47939cc4b9144865c30de9a5adfd424993824941bf0ed178d7",
    ),
    "vit_model.bin": FilePin(
        EXPECTED_MODEL_BYTES,
        "d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5",
    ),
    "vit_model_table.bin": FilePin(
        12_928,
        "10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a",
    ),
    "vit_model_table.json": FilePin(
        236_235,
        "22933d5b10e78253f45625384a1ad191051b8965d05ac09b84e23f4e2381b9bb",
    ),
    "vit_runtime_config.json": FilePin(
        7_854,
        "20ee65ab28d8aa32cbd3a0f5f04f99975fe29aae2d4ae66d1c790e94b7ca704d",
    ),
}


# These are the preserved behavioral/full-precision E04 checkpoints used by
# the strongest historical real-E04 gate.  Mode 3 deliberately has a wider
# logit-quality envelope than FP32 because the persistent classifier weights
# and the classifier activation are converted to binary16.  Final LayerNorm
# and class Softmax remain subject to the historical absolute tolerances.
CANONICAL_E04_GOLDEN_PINS: Mapping[str, tuple[Path, int, FilePin]] = {
    "final_layernorm": (
        Path("results/post_encoder_step_30_final_layernorm_f32.hex"),
        197 * 768,
        FilePin(
            1_361_664,
            "d8ac11b3b8c244c4c525da8f2a56352595256290f0673c607944d5581835167d",
        ),
    ),
    "logits": (
        Path("results/post_encoder_step_32_logits_f32.hex"),
        1_000,
        FilePin(
            9_000,
            "fef8118492356377612d95f0b02120d6fde728ff47bef9b4b8c87cf52c4c7143",
        ),
    ),
    "probabilities": (
        Path("results/post_encoder_step_33p_probabilities_f32.hex"),
        1_000,
        FilePin(
            9_000,
            "870497897b0b0453c8dc1335c3db8881e9ffdbf81bf66eba3d40c8c1b169491b",
        ),
    ),
}

E04_EXPECTED_TOP1 = 879
E04_FINAL_LN_ABS_TOLERANCE = 1.0e-4
E04_MODE3_LOGIT_QUALITY_ABS_TOLERANCE = 1.0e-3
E04_PROBABILITY_ABS_TOLERANCE = 1.0e-5

# Independent full-precision embedding checkpoint used to judge the model-
# quality impact of package-v3 FP16 patch projection.  The exact arithmetic
# gate below is deliberately separate: it proves the implemented M6/current-
# adder contract, while this file proves closeness to the original FP32 model.
CANONICAL_E01_GOLDEN_PINS: Mapping[str, tuple[Path, int, FilePin]] = {
    "embedding": (
        Path("results/embedding_step_06_hidden_states_f32.hex"),
        197 * 768,
        FilePin(
            1_361_664,
            "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18",
        ),
    ),
}

E01_MODE3_EMBEDDING_QUALITY_ABS_TOLERANCE = 5.0e-3

E01_EXTERNAL_STAGE_SPECS: tuple[tuple[str, str], ...] = (
    ("prepared_input", "prepared_input_f32.hex"),
    ("embedding_golden", "embedding_golden_f32.hex"),
)

E01_STAGED_SHA256_BY_ROLE: Mapping[str, str] = {
    "patch_weight_base": (
        "076feb08d4f3d25bd0b3675660c62931c526204eda67ee4fbd160bf2fda66d68"
    ),
    "patch_bias_base": (
        "08d02002ce78c2bb4695e12dc10f28c1694fe232773dfb6a840cff3ca1aecf02"
    ),
    "cls_base": (
        "5e5d5ffdc75ed6902dd65eb25377d5adcefa6f0ea8d0eaa3d5db0dcfe3398bdb"
    ),
    "position_base": (
        "02f20c5527ca78d01e4d7394784d204a9b940a69f8a24658e9e5885d9976d134"
    ),
    "prepared_input": (
        "64f529e00d0ed08b4808c582e27821a7c2e39ac44be8694b7613d5a033f23076"
    ),
    "embedding_golden": (
        "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18"
    ),
}


@dataclass(frozen=True)
class TableEntry:
    tensor_id: int
    group: int
    layer: int
    slot: int
    name_hash: int
    word_offset: int
    word_count: int
    rank: int
    layout: int
    dims: tuple[int, int, int, int]
    tensor_crc32: int
    flags: int
    role: str
    filename: str
    logical_shape: tuple[int, ...]
    tensor_sha256: str


@dataclass(frozen=True)
class PackageValidation:
    workspace_root: Path
    package_dir: Path
    files: Mapping[str, Mapping[str, object]]
    entries: tuple[TableEntry, ...]
    entries_by_role: Mapping[str, TableEntry]
    table_header: Mapping[str, object]


@dataclass(frozen=True)
class GemmOracleWord:
    dot_fp32_bits: int
    biased_fp32_bits: int


@dataclass(frozen=True)
class E01OracleWord:
    flat_index: int
    token: int
    hidden: int
    dot_fp32_bits: int | None
    biased_fp32_bits: int | None
    output_fp32_bits: int


class AssetValidationError(RuntimeError):
    """A package, staged asset, or trust anchor failed closed."""


def _canonical_relative(relative: Path | str) -> Path:
    value = Path(relative)
    text = value.as_posix()
    if (
        not text
        or value.is_absolute()
        or text != str(relative).replace(os.sep, "/")
        or any(part in {"", ".", ".."} for part in value.parts)
    ):
        raise AssetValidationError(f"non-canonical relative path: {relative!r}")
    return value


def _absolute_lexical(path: Path | str, description: str) -> Path:
    value = Path(path)
    if not value.is_absolute():
        raise AssetValidationError(f"{description} must be absolute: {value}")
    normalized = Path(os.path.abspath(os.fspath(value)))
    if normalized != value:
        raise AssetValidationError(
            f"{description} must be lexically normalized: {value}"
        )
    return value


def _reject_symlink_components(path: Path, description: str) -> None:
    path = _absolute_lexical(path, description)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as exc:
            raise AssetValidationError(
                f"cannot inspect {description} component {current}: {exc}"
            ) from exc
        if stat.S_ISLNK(mode):
            raise AssetValidationError(
                f"{description} contains symlink component: {current}"
            )


def _secure_directory(path: Path, description: str) -> Path:
    path = _absolute_lexical(path, description)
    _reject_symlink_components(path, description)
    try:
        mode = path.stat().st_mode
    except OSError as exc:
        raise AssetValidationError(f"cannot stat {description}: {exc}") from exc
    if not stat.S_ISDIR(mode):
        raise AssetValidationError(f"{description} is not a directory: {path}")
    return path


def secure_regular_file(
    root: Path,
    relative: Path | str,
    *,
    description: str = "asset",
) -> Path:
    """Resolve one repository-relative regular file without following links."""

    root = _secure_directory(root, "workspace root")
    relative_path = _canonical_relative(relative)
    candidate = root.joinpath(relative_path)
    _reject_symlink_components(candidate, description)
    try:
        mode = candidate.stat().st_mode
    except OSError as exc:
        raise AssetValidationError(
            f"cannot stat {description} {relative_path}: {exc}"
        ) from exc
    if not stat.S_ISREG(mode):
        raise AssetValidationError(
            f"{description} is not a regular file: {relative_path}"
        )
    try:
        candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise AssetValidationError(
            f"{description} escapes workspace root: {relative_path}"
        ) from exc
    return candidate


def discover_workspace_root(start: Path | None = None) -> Path:
    """Find the repository root from this module's path, never from CWD."""

    lexical_start = Path(
        os.path.abspath(os.fspath(Path(__file__) if start is None else start))
    )
    if not lexical_start.is_absolute():
        raise AssetValidationError("workspace discovery start is not absolute")
    if lexical_start.exists() and lexical_start.is_file():
        search = lexical_start.parent
    else:
        search = lexical_start

    for candidate in (search, *search.parents):
        markers = (
            candidate / "AGENTS.md",
            candidate / "docs/PROJECT_MEMORY.md",
            candidate / "docs/ACTIVE_WORK.md",
        )
        if all(marker.exists() for marker in markers):
            root = _secure_directory(candidate, "workspace root")
            for marker in (
                Path("AGENTS.md"),
                Path("docs/PROJECT_MEMORY.md"),
                Path("docs/ACTIVE_WORK.md"),
            ):
                secure_regular_file(root, marker, description="workspace marker")
            return root
    raise AssetValidationError(
        f"cannot discover workspace root from module path {lexical_start}"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_pinned_regular_file(
    path: Path,
    pin: FilePin,
    *,
    description: str = "pinned file",
) -> Path:
    """Fail closed unless an absolute, link-free regular file matches a pin."""

    path = _secure_absolute_regular_file(path, description)
    size = path.stat().st_size
    if size != pin.size_bytes:
        raise AssetValidationError(
            f"{description} size mismatch: expected {pin.size_bytes}, got {size}"
        )
    actual = sha256_file(path)
    if actual != pin.sha256:
        raise AssetValidationError(
            f"{description} SHA-256 mismatch: expected {pin.sha256}, got {actual}"
        )
    return path


def _hash_crc_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    crc = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
            crc = zlib.crc32(block, crc)
    return digest.hexdigest(), crc & 0xFFFF_FFFF


def _strict_json_bytes(data: bytes, description: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise AssetValidationError(
                    f"{description} contains duplicate key {key!r}"
                )
            result[key] = value
        return result

    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AssetValidationError(f"cannot parse {description}: {exc}") from exc


def _parse_hex_u32(value: object, description: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9A-F]{8}", value):
        raise AssetValidationError(f"{description} is not canonical hex u32")
    return int(value, 16)


def _parse_sha256(value: object, description: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise AssetValidationError(f"{description} is not canonical SHA-256")
    return value


def _ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def _fnv1a64(text: str) -> int:
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFF_FFFF_FFFF_FFFF
    return value


def _align_words(value: int) -> int:
    alignment_words = TABLE_ALIGNMENT_BYTES // 4
    return (value + alignment_words - 1) & ~(alignment_words - 1)


def parse_v3_table(
    table_data: bytes,
    table_json: Mapping[str, object],
    *,
    expected_model_sha256: str = CANONICAL_FILE_PINS["vit_model.bin"].sha256,
    expected_model_crc32: int = EXPECTED_MODEL_CRC32,
    expected_tensor_count: int = EXPECTED_TENSOR_COUNT,
    expected_source_words: int = EXPECTED_SOURCE_WORDS,
    expected_storage_words: int = EXPECTED_STORAGE_WORDS,
    expected_model_bytes: int = EXPECTED_MODEL_BYTES,
    expected_packed_tensors: int = EXPECTED_PACKED_TENSORS,
) -> tuple[tuple[TableEntry, ...], Mapping[str, object]]:
    """Parse and semantically validate the binary and JSON v3 tables."""

    expected_table_bytes = TABLE_HEADER_BYTES + expected_tensor_count * TABLE_ENTRY_BYTES
    if len(table_data) != expected_table_bytes:
        raise AssetValidationError(
            f"table size mismatch: expected {expected_table_bytes}, got {len(table_data)}"
        )
    if not isinstance(table_json, Mapping):
        raise AssetValidationError("table JSON root must be an object")

    exact_json_header = {
        "schema": PACKAGE_SCHEMA,
        "address_unit": "U32_STORAGE_WORD",
        "byte_order": "LITTLE_ENDIAN",
        "header_dtype": "MIXED_BY_ENTRY",
        "alignment_bytes": TABLE_ALIGNMENT_BYTES,
        "source_words_field_semantics": "LOGICAL_SOURCE_SCALAR_COUNT",
    }
    for field, expected in exact_json_header.items():
        if table_json.get(field) != expected:
            raise AssetValidationError(
                f"table JSON {field}: expected {expected!r}, got {table_json.get(field)!r}"
            )

    blocked = table_json.get("blocked_layout")
    expected_blocked = {
        "order": ["N_TILE", "K_CHUNK", "LANE", "COL"],
        "block_k": 16,
        "block_n": 2,
        "fp16_elements_per_block": 32,
        "packed_halves_per_word": 2,
        "block_storage_words": 16,
        "block_bytes": 64,
        "u32_low_half": "COL_0",
        "u32_high_half": "COL_1",
        "required_model_base_alignment_bytes": 128,
    }
    if blocked != expected_blocked:
        raise AssetValidationError("table JSON blocked-layout contract mismatch")

    header = list(TABLE_HEADER_STRUCT.unpack_from(table_data, 0))
    expected_header = (
        (header[0], TABLE_MAGIC, "magic"),
        ((header[1], header[2]), (TABLE_MAJOR, TABLE_MINOR), "version"),
        (header[3], TABLE_HEADER_BYTES, "header bytes"),
        (header[4], TABLE_ENDIAN_LITTLE, "endianness"),
        (header[5], TABLE_DTYPE_MIXED_BY_ENTRY, "dtype"),
        (header[6], expected_tensor_count, "tensor count"),
        (header[7], TABLE_ENTRY_BYTES, "entry bytes"),
        (header[8], TABLE_ALIGNMENT_BYTES, "alignment"),
        (header[9], TABLE_FLAGS, "flags"),
        (header[10], TABLE_HEADER_BYTES, "entry offset"),
        (header[11], expected_table_bytes, "table bytes"),
        (header[12], expected_source_words, "source words"),
        (header[13], expected_storage_words, "storage words"),
        (header[14], expected_model_bytes, "model bytes"),
        (header[15], expected_model_crc32, "model CRC32"),
        (header[18], TABLE_CRC32_ISO_HDLC, "CRC algorithm"),
        (header[19].hex(), expected_model_sha256, "model SHA-256"),
    )
    for actual, expected, name in expected_header:
        if actual != expected:
            raise AssetValidationError(
                f"binary table {name}: expected {expected!r}, got {actual!r}"
            )

    entries_blob = table_data[TABLE_HEADER_BYTES:]
    entries_crc32 = zlib.crc32(entries_blob) & 0xFFFF_FFFF
    if header[16] != entries_crc32:
        raise AssetValidationError("binary table entries CRC32 mismatch")
    header_zero_crc = header.copy()
    header_zero_crc[17] = 0
    header_crc32 = zlib.crc32(TABLE_HEADER_STRUCT.pack(*header_zero_crc)) & 0xFFFF_FFFF
    if header[17] != header_crc32:
        raise AssetValidationError("binary table header CRC32 mismatch")

    json_entries = table_json.get("entries")
    if not isinstance(json_entries, list) or len(json_entries) != expected_tensor_count:
        raise AssetValidationError("table JSON entry count mismatch")

    entries: list[TableEntry] = []
    cursor = 0
    packed_count = 0
    logical_count = 0
    for index, json_entry in enumerate(json_entries):
        if not isinstance(json_entry, Mapping):
            raise AssetValidationError(f"table JSON entry {index} is not an object")
        fields = TABLE_ENTRY_STRUCT.unpack_from(entries_blob, index * TABLE_ENTRY_BYTES)
        dims = tuple(int(value) for value in fields[9:13])
        logical_shape_value = json_entry.get("logical_shape")
        if (
            not isinstance(logical_shape_value, list)
            or not logical_shape_value
            or len(logical_shape_value) > 4
            or any(not isinstance(value, int) or value <= 0 for value in logical_shape_value)
        ):
            raise AssetValidationError(f"entry {index} has invalid logical shape")
        logical_shape = tuple(logical_shape_value)
        padded_shape = (*logical_shape, *(0 for _ in range(4 - len(logical_shape))))
        role = json_entry.get("role")
        filename = json_entry.get("filename")
        if not isinstance(role, str) or not role:
            raise AssetValidationError(f"entry {index} has invalid role")
        if not isinstance(filename, str) or not filename or "/" in filename:
            raise AssetValidationError(f"entry {index} has invalid filename")
        flags = _parse_hex_u32(json_entry.get("flags"), f"entry {index} flags")
        tensor_crc32 = _parse_hex_u32(
            json_entry.get("tensor_crc32"), f"entry {index} tensor CRC32"
        )
        tensor_sha256 = _parse_sha256(
            json_entry.get("tensor_sha256"), f"entry {index} tensor SHA-256"
        )
        cursor = _align_words(cursor)
        if json_entry.get("word_offset") != cursor:
            raise AssetValidationError(f"entry {index} JSON word offset mismatch")
        if json_entry.get("byte_offset") != cursor * 4:
            raise AssetValidationError(f"entry {index} JSON byte offset mismatch")
        if (
            not isinstance(json_entry.get("stored_word_count"), int)
            or json_entry.get("stored_word_count") < 0
        ):
            raise AssetValidationError(f"entry {index} JSON stored-word count is invalid")
        expected_common = {
            "tensor_id": index,
            "group": json_entry.get("group"),
            "layer": json_entry.get("layer"),
            "slot": json_entry.get("slot"),
            "name_hash": _fnv1a64(filename),
            "word_offset": cursor,
            "word_count": json_entry.get("stored_word_count"),
            "rank": len(logical_shape),
            "layout": json_entry.get("layout_id"),
            "dims": padded_shape,
            "tensor_crc32": tensor_crc32,
            "flags": flags,
        }
        actual_common = {
            "tensor_id": fields[0],
            "group": fields[1],
            "layer": fields[2],
            "slot": fields[3],
            "name_hash": fields[4],
            "word_offset": fields[5],
            "word_count": fields[6],
            "rank": fields[7],
            "layout": fields[8],
            "dims": dims,
            "tensor_crc32": fields[13],
            "flags": fields[14],
        }
        for field_name, expected in expected_common.items():
            if actual_common[field_name] != expected:
                raise AssetValidationError(
                    f"entry {index} {field_name}: expected {expected!r}, "
                    f"got {actual_common[field_name]!r}"
                )

        logical_elements = 1
        for dimension in logical_shape:
            logical_elements *= dimension
        if json_entry.get("logical_element_count") != logical_elements:
            raise AssetValidationError(f"entry {index} logical element count mismatch")
        logical_count += logical_elements

        layout = int(fields[8])
        stored_words = int(fields[6])
        if layout == LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2:
            if len(logical_shape) != 2:
                raise AssetValidationError(f"entry {index} packed layout is not rank two")
            reduction, columns = logical_shape
            expected_words = (
                _ceil_div(reduction, BLOCK_K)
                * _ceil_div(columns, BLOCK_N)
                * BLOCK_STORAGE_WORDS
            )
            if stored_words != expected_words:
                raise AssetValidationError(f"entry {index} packed word count mismatch")
            if (flags & PACKED_REQUIRED_FLAGS) != PACKED_REQUIRED_FLAGS:
                raise AssetValidationError(f"entry {index} packed flags are incomplete")
            if json_entry.get("element_dtype") != "IEEE754_BINARY16_RNE_GRADUAL":
                raise AssetValidationError(f"entry {index} packed dtype mismatch")
            if json_entry.get("packed_halves_per_word") != 2:
                raise AssetValidationError(f"entry {index} packed-halves mismatch")
            expected_stored_shape = [
                _ceil_div(columns, BLOCK_N),
                _ceil_div(reduction, BLOCK_K),
                BLOCK_K,
                BLOCK_N,
            ]
            expected_word_shape = expected_stored_shape[:-1]
            if json_entry.get("stored_shape") != expected_stored_shape:
                raise AssetValidationError(f"entry {index} packed stored-shape mismatch")
            if json_entry.get("storage_word_shape") != expected_word_shape:
                raise AssetValidationError(f"entry {index} packed word-shape mismatch")
            packed_count += 1
        else:
            if layout not in {LAYOUT_VECTOR, LAYOUT_ROW_MAJOR}:
                raise AssetValidationError(f"entry {index} unsupported nonpacked layout")
            if flags & (FLAG_BLOCKED_B_K16_N2 | FLAG_FP16_PACKED2):
                raise AssetValidationError(f"entry {index} nonpacked flags are invalid")
            if flags & FLAG_WEIGHT_B:
                raise AssetValidationError(f"entry {index} weight-B is not packed layout5")
            if stored_words != logical_elements:
                raise AssetValidationError(f"entry {index} FP32 word count mismatch")
            if json_entry.get("element_dtype") != "IEEE754_BINARY32_RAW_BITS":
                raise AssetValidationError(f"entry {index} FP32 dtype mismatch")
            if json_entry.get("stored_shape") != list(logical_shape):
                raise AssetValidationError(f"entry {index} FP32 stored-shape mismatch")
            if json_entry.get("storage_word_shape") != list(logical_shape):
                raise AssetValidationError(f"entry {index} FP32 word-shape mismatch")

        entry = TableEntry(
            tensor_id=int(fields[0]),
            group=int(fields[1]),
            layer=int(fields[2]),
            slot=int(fields[3]),
            name_hash=int(fields[4]),
            word_offset=int(fields[5]),
            word_count=stored_words,
            rank=int(fields[7]),
            layout=layout,
            dims=dims,
            tensor_crc32=tensor_crc32,
            flags=flags,
            role=role,
            filename=filename,
            logical_shape=logical_shape,
            tensor_sha256=tensor_sha256,
        )
        entries.append(entry)
        cursor += stored_words

    if cursor != expected_storage_words:
        raise AssetValidationError(
            f"table storage extent mismatch: expected {expected_storage_words}, got {cursor}"
        )
    if logical_count != expected_source_words:
        raise AssetValidationError("table logical-source population mismatch")
    if packed_count != expected_packed_tensors:
        raise AssetValidationError(
            f"packed tensor count mismatch: expected {expected_packed_tensors}, got {packed_count}"
        )

    canonical_selected = {
        "patch_weight_base": (0, 0, 294_912, 5),
        "patch_bias_base": (1, 294_912, 768, 1),
        "cls_base": (2, 295_680, 768, 1),
        "position_base": (3, 296_448, 151_296, 2),
        "final_ln_gamma_base": (4, 447_744, 768, 1),
        "final_ln_beta_base": (5, 448_512, 768, 1),
        "classifier_weight_base": (6, 449_280, 384_000, 5),
        "classifier_bias_base": (7, 833_280, 1_000, 1),
    }
    by_role: dict[str, TableEntry] = {}
    for entry in entries:
        if entry.role in canonical_selected:
            if entry.role in by_role:
                raise AssetValidationError(
                    f"canonical global role is duplicated: {entry.role}"
                )
            by_role[entry.role] = entry
    for role, expected in canonical_selected.items():
        if role not in by_role:
            raise AssetValidationError(f"required global tensor is absent: {role}")
        entry = by_role[role]
        actual = (entry.tensor_id, entry.word_offset, entry.word_count, entry.layout)
        if actual != expected:
            raise AssetValidationError(
                f"canonical {role} tuple mismatch: expected {expected}, got {actual}"
            )
    global_offsets = table_json.get("global_offsets")
    if not isinstance(global_offsets, Mapping):
        raise AssetValidationError("table JSON global offsets object is absent")
    for role, (_, offset, _, _) in canonical_selected.items():
        if global_offsets.get(role) != offset:
            raise AssetValidationError(f"table JSON global offset mismatch: {role}")

    return tuple(entries), {
        "magic_ascii": "VITMTBL\\0",
        "version": "3.0",
        "dtype_code": TABLE_DTYPE_MIXED_BY_ENTRY,
        "tensor_count": expected_tensor_count,
        "entry_bytes": TABLE_ENTRY_BYTES,
        "alignment_bytes": TABLE_ALIGNMENT_BYTES,
        "source_words": expected_source_words,
        "storage_words": expected_storage_words,
        "model_bytes": expected_model_bytes,
        "model_crc32": f"0x{expected_model_crc32:08X}",
        "model_sha256": expected_model_sha256,
        "entries_crc32": f"0x{entries_crc32:08X}",
        "header_crc32": f"0x{header_crc32:08X}",
        "layout5_tensors": packed_count,
    }


def _validate_internal_hash_manifest(
    manifest: object,
    file_records: Mapping[str, Mapping[str, object]],
) -> None:
    if not isinstance(manifest, Mapping):
        raise AssetValidationError("hash manifest root must be an object")
    if manifest.get("schema") != HASH_MANIFEST_SCHEMA:
        raise AssetValidationError("hash manifest schema mismatch")
    if manifest.get("parent_v2_hash_manifest_sha256") != (
        "d5686ff0b19b9703817744affdb0ee89a1ca65dda8af64e68e7712fc83570d18"
    ):
        raise AssetValidationError("hash manifest parent identity mismatch")
    rows = manifest.get("files")
    if not isinstance(rows, list):
        raise AssetValidationError("hash manifest files must be a list")
    expected_names = {
        "vit_model.bin",
        "vit_model_table.bin",
        "prepared_input.bin",
        "vit_model_table.json",
        "vit_runtime_config.json",
    }
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, Mapping):
            raise AssetValidationError("hash manifest row must be an object")
        name = row.get("path")
        if not isinstance(name, str) or name not in expected_names or name in seen:
            raise AssetValidationError("hash manifest contains invalid/duplicate path")
        seen.add(name)
        record = file_records[name]
        if row.get("size_bytes") != record["size_bytes"]:
            raise AssetValidationError(f"hash manifest size mismatch for {name}")
        if row.get("sha256") != record["sha256"]:
            raise AssetValidationError(f"hash manifest SHA-256 mismatch for {name}")
        if row.get("crc32") != record["crc32"]:
            raise AssetValidationError(f"hash manifest CRC32 mismatch for {name}")
    if seen != expected_names:
        raise AssetValidationError("hash manifest file population mismatch")


def _validate_model_stream(
    model_path: Path,
    entries: Sequence[TableEntry],
    table_json: Mapping[str, object],
) -> tuple[str, int]:
    json_entries = table_json["entries"]
    digest = hashlib.sha256()
    model_crc = 0
    byte_cursor = 0
    with model_path.open("rb") as stream:
        for entry, json_entry in zip(entries, json_entries, strict=True):
            entry_byte_offset = entry.word_offset * 4
            padding_bytes = entry_byte_offset - byte_cursor
            if padding_bytes < 0:
                raise AssetValidationError("model tensor offsets overlap")
            if padding_bytes:
                padding = stream.read(padding_bytes)
                if len(padding) != padding_bytes or any(padding):
                    raise AssetValidationError(
                        f"model padding before {entry.role} is truncated/nonzero"
                    )
                digest.update(padding)
                model_crc = zlib.crc32(padding, model_crc)
                byte_cursor += padding_bytes

            remaining = entry.word_count * 4
            tensor_digest = hashlib.sha256()
            tensor_crc = 0
            while remaining:
                block = stream.read(min(1024 * 1024, remaining))
                if not block:
                    raise AssetValidationError(f"model tensor {entry.role} is truncated")
                digest.update(block)
                model_crc = zlib.crc32(block, model_crc)
                tensor_digest.update(block)
                tensor_crc = zlib.crc32(block, tensor_crc)
                byte_cursor += len(block)
                remaining -= len(block)
            if (tensor_crc & 0xFFFF_FFFF) != entry.tensor_crc32:
                raise AssetValidationError(f"model tensor CRC32 mismatch: {entry.role}")
            if tensor_digest.hexdigest() != entry.tensor_sha256:
                raise AssetValidationError(f"model tensor SHA-256 mismatch: {entry.role}")
            if json_entry.get("stored_byte_count") != entry.word_count * 4:
                raise AssetValidationError(f"stored byte count mismatch: {entry.role}")

        tail = stream.read()
        digest.update(tail)
        model_crc = zlib.crc32(tail, model_crc)
        byte_cursor += len(tail)
    if byte_cursor != EXPECTED_MODEL_BYTES:
        raise AssetValidationError(
            f"model extent mismatch: expected {EXPECTED_MODEL_BYTES}, got {byte_cursor}"
        )
    return digest.hexdigest(), model_crc & 0xFFFF_FFFF


def validate_canonical_package(
    workspace_root: Path | None = None,
) -> PackageValidation:
    """Validate every pinned package-v3 file and every table/model entry."""

    root = discover_workspace_root() if workspace_root is None else _secure_directory(
        _absolute_lexical(workspace_root, "workspace root"), "workspace root"
    )
    package_relative = CANONICAL_PACKAGE_RELATIVE
    package_dir = _secure_directory(root / package_relative, "canonical package directory")
    paths: dict[str, Path] = {}
    records: dict[str, dict[str, object]] = {}
    for name, pin in CANONICAL_FILE_PINS.items():
        relative = package_relative / name
        path = secure_regular_file(root, relative, description=f"package file {name}")
        size = path.stat().st_size
        if size != pin.size_bytes:
            raise AssetValidationError(
                f"{name} size mismatch: expected {pin.size_bytes}, got {size}"
            )
        paths[name] = path

    table_data = paths["vit_model_table.bin"].read_bytes()
    table_sha, table_crc = _hash_crc_file(paths["vit_model_table.bin"])
    if table_sha != CANONICAL_FILE_PINS["vit_model_table.bin"].sha256:
        raise AssetValidationError("vit_model_table.bin SHA-256 mismatch")
    records["vit_model_table.bin"] = {
        "size_bytes": len(table_data),
        "sha256": table_sha,
        "crc32": f"0x{table_crc:08X}",
    }

    table_json_bytes = paths["vit_model_table.json"].read_bytes()
    table_json_sha, table_json_crc = _hash_crc_file(paths["vit_model_table.json"])
    if table_json_sha != CANONICAL_FILE_PINS["vit_model_table.json"].sha256:
        raise AssetValidationError("vit_model_table.json SHA-256 mismatch")
    records["vit_model_table.json"] = {
        "size_bytes": len(table_json_bytes),
        "sha256": table_json_sha,
        "crc32": f"0x{table_json_crc:08X}",
    }
    table_json = _strict_json_bytes(table_json_bytes, "v3 table JSON")
    entries, table_header = parse_v3_table(table_data, table_json)

    model_sha, model_crc = _validate_model_stream(
        paths["vit_model.bin"], entries, table_json
    )
    if model_sha != CANONICAL_FILE_PINS["vit_model.bin"].sha256:
        raise AssetValidationError("vit_model.bin SHA-256 mismatch")
    if model_crc != EXPECTED_MODEL_CRC32:
        raise AssetValidationError("vit_model.bin CRC32 mismatch")
    records["vit_model.bin"] = {
        "size_bytes": EXPECTED_MODEL_BYTES,
        "sha256": model_sha,
        "crc32": f"0x{model_crc:08X}",
    }

    for name in (
        "prepared_input.bin",
        "vit_runtime_config.json",
        "verification_report.json",
        "hash_manifest.json",
    ):
        sha, crc = _hash_crc_file(paths[name])
        if sha != CANONICAL_FILE_PINS[name].sha256:
            raise AssetValidationError(f"{name} SHA-256 mismatch")
        records[name] = {
            "size_bytes": paths[name].stat().st_size,
            "sha256": sha,
            "crc32": f"0x{crc:08X}",
        }
        if name.endswith(".json"):
            _strict_json_bytes(paths[name].read_bytes(), name)

    manifest = _strict_json_bytes(
        paths["hash_manifest.json"].read_bytes(), "v3 hash manifest"
    )
    _validate_internal_hash_manifest(manifest, records)

    add_path = secure_regular_file(root, FP32_ADD_RTL_RELATIVE, description="FP32 adder RTL")
    if sha256_file(add_path) != FP32_ADD_RTL_SHA256:
        raise AssetValidationError("current FP32 adder RTL SHA-256 mismatch")
    m6_path = secure_regular_file(root, M6_REFERENCE_RELATIVE, description="M6 reference")
    if sha256_file(m6_path) != M6_REFERENCE_SHA256:
        raise AssetValidationError("M6 reference SHA-256 mismatch")

    by_role: dict[str, TableEntry] = {}
    for entry in entries:
        if entry.role in {role for specs in PHASE_STAGE_SPECS.values() for role, _ in specs}:
            if entry.role in by_role:
                raise AssetValidationError(
                    f"phase-staged tensor role is duplicated: {entry.role}"
                )
            by_role[entry.role] = entry
    return PackageValidation(
        workspace_root=root,
        package_dir=package_dir,
        files=records,
        entries=entries,
        entries_by_role=by_role,
        table_header=table_header,
    )


PHASE_STAGE_SPECS: Mapping[str, tuple[tuple[str, str], ...]] = {
    "e01": (
        ("patch_weight_base", "patch_weight_packed_fp16_u32.hex"),
        ("patch_bias_base", "patch_bias_f32.hex"),
        ("cls_base", "cls_token_f32.hex"),
        ("position_base", "position_f32.hex"),
    ),
    "e04": (
        ("final_ln_gamma_base", "final_ln_gamma_f32.hex"),
        ("final_ln_beta_base", "final_ln_beta_f32.hex"),
        (
            "classifier_weight_base",
            "classifier_weight_packed_fp16_u32.hex",
        ),
        ("classifier_bias_base", "classifier_bias_f32.hex"),
    ),
}


def _secure_new_output_dir(output_dir: Path) -> tuple[Path, tuple[int, int]]:
    output_dir = _absolute_lexical(output_dir, "output directory")
    parent = _secure_directory(output_dir.parent, "output parent")
    if output_dir.exists() or output_dir.is_symlink():
        raise AssetValidationError(f"refusing existing output directory: {output_dir}")
    try:
        output_dir.mkdir(mode=0o700)
    except OSError as exc:
        raise AssetValidationError(f"cannot create output directory: {exc}") from exc
    info = output_dir.stat()
    if not stat.S_ISDIR(info.st_mode) or output_dir.is_symlink():
        raise AssetValidationError("new output path is not a real directory")
    try:
        output_dir.resolve(strict=True).relative_to(parent.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise AssetValidationError("new output directory escaped its parent") from exc
    return output_dir, (info.st_dev, info.st_ino)


def _cleanup_owned_output(path: Path, identity: tuple[int, int]) -> None:
    try:
        info = path.lstat()
    except OSError:
        return
    if (
        stat.S_ISDIR(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and (info.st_dev, info.st_ino) == identity
    ):
        shutil.rmtree(path)


def _stage_entry_hex(
    model_path: Path,
    entry: TableEntry,
    output_path: Path,
) -> Mapping[str, object]:
    source_digest = hashlib.sha256()
    staged_digest = hashlib.sha256()
    remaining = entry.word_count * 4
    with model_path.open("rb") as source, output_path.open("xb") as output:
        source.seek(entry.word_offset * 4)
        while remaining:
            block = source.read(min(1024 * 1024, remaining))
            if len(block) == 0 or len(block) % 4:
                raise AssetValidationError(f"truncated/u32-misaligned source slice: {entry.role}")
            source_digest.update(block)
            for (word,) in struct.iter_unpack("<I", block):
                line = f"{word:08x}\n".encode("ascii")
                output.write(line)
                staged_digest.update(line)
            remaining -= len(block)
    if source_digest.hexdigest() != entry.tensor_sha256:
        raise AssetValidationError(f"staged source slice hash mismatch: {entry.role}")
    expected_text_bytes = entry.word_count * 9
    if output_path.stat().st_size != expected_text_bytes:
        raise AssetValidationError(f"staged readmemh size mismatch: {entry.role}")
    return {
        "filename": output_path.name,
        "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
        "role": entry.role,
        "source_binary_sha256": source_digest.hexdigest(),
        "source_byte_offset": entry.word_offset * 4,
        "source_tensor_id": entry.tensor_id,
        "source_word_offset": entry.word_offset,
        "staged_sha256": staged_digest.hexdigest(),
        "stored_bytes": entry.word_count * 4,
        "stored_words": entry.word_count,
        "text_bytes": expected_text_bytes,
    }


def _stage_binary_u32_hex(
    source_path: Path,
    source_pin: FilePin,
    output_path: Path,
    *,
    role: str,
    source_relative_path: Path,
) -> Mapping[str, object]:
    """Stage one pinned little-endian u32 binary as canonical readmemh."""

    verify_pinned_regular_file(
        source_path, source_pin, description=f"canonical {role} binary"
    )
    if source_pin.size_bytes % 4:
        raise AssetValidationError(f"canonical {role} binary is not u32 aligned")
    staged_digest = hashlib.sha256()
    stored_words = 0
    with source_path.open("rb") as source, output_path.open("xb") as output:
        while block := source.read(1024 * 1024):
            if len(block) % 4:
                raise AssetValidationError(f"truncated/u32-misaligned {role} binary")
            for (word,) in struct.iter_unpack("<I", block):
                line = f"{word:08x}\n".encode("ascii")
                output.write(line)
                staged_digest.update(line)
                stored_words += 1
    expected_text_bytes = stored_words * 9
    if output_path.stat().st_size != expected_text_bytes:
        raise AssetValidationError(f"staged readmemh size mismatch: {role}")
    return {
        "filename": output_path.name,
        "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
        "role": role,
        "source_binary_sha256": source_pin.sha256,
        "source_relative_path": source_relative_path.as_posix(),
        "staged_sha256": staged_digest.hexdigest(),
        "stored_bytes": source_pin.size_bytes,
        "stored_words": stored_words,
        "text_bytes": expected_text_bytes,
    }


def _stage_pinned_readmemh(
    source_path: Path,
    source_pin: FilePin,
    output_path: Path,
    *,
    role: str,
    source_relative_path: Path,
    expected_words: int,
) -> Mapping[str, object]:
    """Copy one pinned canonical readmemh file without reformatting it."""

    verify_pinned_regular_file(
        source_path, source_pin, description=f"canonical {role} readmemh"
    )
    read_u32_readmemh(source_path, expected_words)
    digest = hashlib.sha256()
    with source_path.open("rb") as source, output_path.open("xb") as output:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            output.write(block)
            digest.update(block)
    if output_path.stat().st_size != source_pin.size_bytes:
        raise AssetValidationError(f"staged readmemh size mismatch: {role}")
    return {
        "filename": output_path.name,
        "format": "U32_HEX_LOWERCASE_8DIGIT_LF",
        "role": role,
        "source_readmemh_sha256": source_pin.sha256,
        "source_relative_path": source_relative_path.as_posix(),
        "staged_sha256": digest.hexdigest(),
        "stored_bytes": expected_words * 4,
        "stored_words": expected_words,
        "text_bytes": source_pin.size_bytes,
    }


def stage_phase_assets(
    phase: str,
    output_dir: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Path, Mapping[str, object], str]:
    """Validate package v3 and stage one exact phase into a new directory."""

    if phase not in PHASE_STAGE_SPECS:
        raise AssetValidationError(f"unsupported phase {phase!r}")
    validation = validate_canonical_package(workspace_root)
    output, identity = _secure_new_output_dir(output_dir)
    try:
        staged: list[Mapping[str, object]] = []
        model_path = secure_regular_file(
            validation.workspace_root,
            CANONICAL_PACKAGE_RELATIVE / "vit_model.bin",
            description="canonical v3 model",
        )
        for role, filename in PHASE_STAGE_SPECS[phase]:
            staged.append(
                _stage_entry_hex(
                    model_path,
                    validation.entries_by_role[role],
                    output / filename,
                )
            )

        if phase == "e01":
            prepared_relative = CANONICAL_PACKAGE_RELATIVE / "prepared_input.bin"
            prepared_path = secure_regular_file(
                validation.workspace_root,
                prepared_relative,
                description="canonical v3 prepared input",
            )
            staged.append(
                _stage_binary_u32_hex(
                    prepared_path,
                    CANONICAL_FILE_PINS["prepared_input.bin"],
                    output / dict(E01_EXTERNAL_STAGE_SPECS)["prepared_input"],
                    role="prepared_input",
                    source_relative_path=prepared_relative,
                )
            )
            golden_relative, golden_words, golden_pin = (
                CANONICAL_E01_GOLDEN_PINS["embedding"]
            )
            golden_path = secure_regular_file(
                validation.workspace_root,
                golden_relative,
                description="canonical E01 embedding golden",
            )
            staged.append(
                _stage_pinned_readmemh(
                    golden_path,
                    golden_pin,
                    output / dict(E01_EXTERNAL_STAGE_SPECS)["embedding_golden"],
                    role="embedding_golden",
                    source_relative_path=golden_relative,
                    expected_words=golden_words,
                )
            )

        evidence: dict[str, object] = {
            "schema": ASSET_EVIDENCE_SCHEMA,
            "phase": phase,
            "execution_mode": 3,
            "package": {
                "relative_directory": CANONICAL_PACKAGE_RELATIVE.as_posix(),
                "files": validation.files,
                "table_header": validation.table_header,
            },
            "numerical_contract": {
                "activation_conversion": "M6_FP32_TO_FP16_RNE_GRADUAL",
                "dot": "M6_EXACT_FP16_PRODUCTS_KULISCH_2^-48_ROUND_ONCE_FP32",
                "bias_and_position_add": "CURRENT_VIT_FP32_ADD_COMB_FTZ_RNE",
                "m6_reference_path": M6_REFERENCE_RELATIVE.as_posix(),
                "m6_reference_sha256": M6_REFERENCE_SHA256,
                "fp32_add_rtl_path": FP32_ADD_RTL_RELATIVE.as_posix(),
                "fp32_add_rtl_sha256": FP32_ADD_RTL_SHA256,
            },
            "staged": staged,
        }
        if phase == "e04":
            evidence["behavioral_goldens"] = validate_canonical_e04_goldens(
                validation.workspace_root
            )
        elif phase == "e01":
            evidence["behavioral_goldens"] = validate_canonical_e01_goldens(
                validation.workspace_root
            )
        evidence_bytes = (
            json.dumps(evidence, indent=2, sort_keys=True, separators=(",", ": "))
            + "\n"
        ).encode("utf-8")
        evidence_path = output / "asset_evidence.json"
        with evidence_path.open("xb") as stream:
            stream.write(evidence_bytes)
        evidence_sha256 = hashlib.sha256(evidence_bytes).hexdigest()
        return evidence_path, evidence, evidence_sha256
    except BaseException:
        _cleanup_owned_output(output, identity)
        raise


@lru_cache(maxsize=4)
def _load_m6_reference_cached(workspace_root_text: str) -> ModuleType:
    root = _secure_directory(Path(workspace_root_text), "workspace root")
    path = secure_regular_file(root, M6_REFERENCE_RELATIVE, description="M6 reference")
    if sha256_file(path) != M6_REFERENCE_SHA256:
        raise AssetValidationError("M6 reference SHA-256 mismatch")
    module_name = "_vit_m7_hash_pinned_m6_fp16_reference"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise AssetValidationError("cannot construct M6 reference import")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


def load_m6_reference(workspace_root: Path | None = None) -> ModuleType:
    root = discover_workspace_root() if workspace_root is None else _secure_directory(
        _absolute_lexical(workspace_root, "workspace root"), "workspace root"
    )
    return _load_m6_reference_cached(str(root))


def _check_u32(value: int, description: str) -> int:
    if not isinstance(value, int) or value < 0 or value > 0xFFFF_FFFF:
        raise ValueError(f"{description} must be a u32")
    return value


def _check_u16(value: int, description: str) -> int:
    if not isinstance(value, int) or value < 0 or value > 0xFFFF:
        raise ValueError(f"{description} must be a u16")
    return value


def fp32_add_current(a: int, b: int) -> int:
    """Bit-exact Python port of the pinned current ``vit_fp32_add_comb``."""

    a = _check_u32(a, "FP32 add operand a")
    b = _check_u32(b, "FP32 add operand b")
    sign_a, sign_b = (a >> 31) & 1, (b >> 31) & 1
    exp_a, exp_b = (a >> 23) & 0xFF, (b >> 23) & 0xFF
    frac_a, frac_b = a & 0x7F_FFFF, b & 0x7F_FFFF
    a_nan = exp_a == 0xFF and frac_a != 0
    b_nan = exp_b == 0xFF and frac_b != 0
    a_inf = exp_a == 0xFF and frac_a == 0
    b_inf = exp_b == 0xFF and frac_b == 0
    a_zero = exp_a == 0
    b_zero = exp_b == 0
    if a_nan or b_nan or (a_inf and b_inf and sign_a != sign_b):
        return 0x7FC0_0000
    if a_inf:
        return (sign_a << 31) | 0x7F80_0000
    if b_inf:
        return (sign_b << 31) | 0x7F80_0000
    if a_zero and b_zero:
        return (sign_a & sign_b) << 31
    if a_zero:
        return b
    if b_zero:
        return a
    if sign_a != sign_b and (exp_a, frac_a) == (exp_b, frac_b):
        return 0

    a_is_large = (exp_a, frac_a) >= (exp_b, frac_b)
    sign_large = sign_a if a_is_large else sign_b
    sign_small = sign_b if a_is_large else sign_a
    exp_large = exp_a if a_is_large else exp_b
    exp_small = exp_b if a_is_large else exp_a
    frac_large = frac_a if a_is_large else frac_b
    frac_small = frac_b if a_is_large else frac_a
    mant_large = ((1 << 23) | frac_large) << 3
    mant_small = ((1 << 23) | frac_small) << 3
    difference = exp_large - exp_small
    if difference >= 27:
        shifted = 0
        sticky = int(mant_small != 0)
    else:
        shifted = mant_small >> difference
        sticky = int(bool(mant_small & ((1 << difference) - 1))) if difference else 0
    mant_small_aligned = (shifted & ~1) | ((shifted & 1) | sticky)

    if sign_large == sign_small:
        raw = mant_large + mant_small_aligned
        if raw & (1 << 27):
            normal = raw >> 1
            normal = (normal & ~1) | ((normal & 1) | (raw & 1))
            exp_result = exp_large + 1
        else:
            normal = raw
            exp_result = exp_large
    else:
        raw = mant_large - mant_small_aligned
        leading_zero_count = 27 if raw == 0 else 26 - (raw.bit_length() - 1)
        shift_cap = 26 if exp_large > 27 else exp_large - 1
        normalize_shift = min(leading_zero_count, shift_cap)
        normal = (raw << normalize_shift) & ((1 << 27) - 1)
        exp_result = exp_large - normalize_shift

    if normal == 0 or (exp_result == 1 and not (normal & (1 << 26))):
        return sign_large << 31
    mantissa_main = normal >> 3
    guard = (normal >> 2) & 1
    round_bit = (normal >> 1) & 1
    sticky_bit = normal & 1
    increment = guard and (round_bit or sticky_bit or (mantissa_main & 1))
    rounded = mantissa_main + int(bool(increment))
    if rounded & (1 << 24):
        fraction = (rounded >> 1) & 0x7F_FFFF
        exp_result += 1
    else:
        fraction = rounded & 0x7F_FFFF
    if exp_result >= 255:
        return (sign_large << 31) | 0x7F80_0000
    if exp_result <= 0:
        return sign_large << 31
    return (sign_large << 31) | (exp_result << 23) | fraction


def packed_fp16_weight_at(
    packed_words: Sequence[int],
    reduction_index: int,
    column_index: int,
    *,
    reduction: int,
    columns: int,
) -> int:
    """Return one logical halfword from layout5 packed K16/N2 storage."""

    if reduction <= 0 or columns <= 0:
        raise ValueError("reduction and columns must be positive")
    if not 0 <= reduction_index < reduction:
        raise IndexError("reduction index out of range")
    if not 0 <= column_index < columns:
        raise IndexError("column index out of range")
    expected_words = (
        _ceil_div(reduction, BLOCK_K)
        * _ceil_div(columns, BLOCK_N)
        * BLOCK_STORAGE_WORDS
    )
    if len(packed_words) != expected_words:
        raise ValueError(
            f"packed weight extent mismatch: expected {expected_words}, got {len(packed_words)}"
        )
    word_index = (
        (
            (column_index // BLOCK_N) * _ceil_div(reduction, BLOCK_K)
            + (reduction_index // BLOCK_K)
        )
        * BLOCK_STORAGE_WORDS
        + (reduction_index % BLOCK_K)
    )
    word = _check_u32(int(packed_words[word_index]), "packed weight word")
    return (word >> (16 * (column_index % BLOCK_N))) & 0xFFFF


def exact_fp16_dot_from_fp32_activation(
    activation_fp32_words: Sequence[int],
    weight_fp16_words: Sequence[int],
    *,
    workspace_root: Path | None = None,
) -> int:
    """Convert A through M6 FP32->FP16, exact-dot with FP16 B, round once."""

    if len(activation_fp32_words) != len(weight_fp16_words):
        raise ValueError("activation and weight vectors must have equal length")
    m6 = load_m6_reference(workspace_root)
    pairs = (
        (
            m6.fp32_bits_to_fp16_bits(_check_u32(int(a), "activation word")),
            _check_u16(int(b), "weight halfword"),
        )
        for a, b in zip(activation_fp32_words, weight_fp16_words, strict=True)
    )
    return int(m6.dot_fp16_exact(pairs, ftz=False).fp32_bits)


def gemm_oracle_word(
    activation_row_fp32: Sequence[int],
    packed_weights_u32: Sequence[int],
    bias_fp32: int,
    *,
    column: int,
    columns: int,
    workspace_root: Path | None = None,
) -> GemmOracleWord:
    reduction = len(activation_row_fp32)
    weights = [
        packed_fp16_weight_at(
            packed_weights_u32,
            k,
            column,
            reduction=reduction,
            columns=columns,
        )
        for k in range(reduction)
    ]
    dot_bits = exact_fp16_dot_from_fp32_activation(
        activation_row_fp32, weights, workspace_root=workspace_root
    )
    return GemmOracleWord(
        dot_fp32_bits=dot_bits,
        biased_fp32_bits=fp32_add_current(dot_bits, bias_fp32),
    )


def e04_logits_oracle(
    cls_activation_fp32: Sequence[int],
    classifier_packed_u32: Sequence[int],
    classifier_bias_fp32: Sequence[int],
    *,
    workspace_root: Path | None = None,
) -> list[int]:
    """Compute all execution-mode-3 classifier logits for one CLS vector."""

    columns = len(classifier_bias_fp32)
    if columns <= 0:
        raise ValueError("classifier bias must not be empty")
    return [
        gemm_oracle_word(
            cls_activation_fp32,
            classifier_packed_u32,
            _check_u32(int(classifier_bias_fp32[column]), "classifier bias"),
            column=column,
            columns=columns,
            workspace_root=workspace_root,
        ).biased_fp32_bits
        for column in range(columns)
    ]


def e01_output_oracle_word(
    flat_index: int,
    patch_input_fp32: Sequence[int],
    patch_packed_u32: Sequence[int],
    patch_bias_fp32: Sequence[int],
    cls_token_fp32: Sequence[int],
    position_fp32: Sequence[int],
    *,
    workspace_root: Path | None = None,
) -> E01OracleWord:
    """Compute one E01 output word, including CLS/bias/position behavior."""

    hidden_size = len(patch_bias_fp32)
    if hidden_size <= 0 or len(cls_token_fp32) != hidden_size:
        raise ValueError("E01 hidden vectors have inconsistent extents")
    if len(patch_input_fp32) % hidden_size:
        raise ValueError("E01 patch input is not a whole number of tokens")
    patch_tokens = len(patch_input_fp32) // hidden_size
    output_words = (patch_tokens + 1) * hidden_size
    if len(position_fp32) != output_words:
        raise ValueError("E01 position extent mismatch")
    if not isinstance(flat_index, int) or not 0 <= flat_index < output_words:
        raise IndexError("E01 flat output index out of range")
    token, hidden = divmod(flat_index, hidden_size)
    position = _check_u32(int(position_fp32[flat_index]), "position word")
    if token == 0:
        output = fp32_add_current(
            _check_u32(int(cls_token_fp32[hidden]), "CLS word"), position
        )
        return E01OracleWord(flat_index, token, hidden, None, None, output)

    row_begin = (token - 1) * hidden_size
    row = patch_input_fp32[row_begin : row_begin + hidden_size]
    gemm = gemm_oracle_word(
        row,
        patch_packed_u32,
        _check_u32(int(patch_bias_fp32[hidden]), "patch bias"),
        column=hidden,
        columns=hidden_size,
        workspace_root=workspace_root,
    )
    output = fp32_add_current(gemm.biased_fp32_bits, position)
    return E01OracleWord(
        flat_index,
        token,
        hidden,
        gemm.dot_fp32_bits,
        gemm.biased_fp32_bits,
        output,
    )


def e01_outputs_oracle(
    flat_indices: Iterable[int],
    patch_input_fp32: Sequence[int],
    patch_packed_u32: Sequence[int],
    patch_bias_fp32: Sequence[int],
    cls_token_fp32: Sequence[int],
    position_fp32: Sequence[int],
    *,
    workspace_root: Path | None = None,
) -> list[E01OracleWord]:
    """Compute a deterministic requested subset (or caller-supplied full set)."""

    return [
        e01_output_oracle_word(
            index,
            patch_input_fp32,
            patch_packed_u32,
            patch_bias_fp32,
            cls_token_fp32,
            position_fp32,
            workspace_root=workspace_root,
        )
        for index in flat_indices
    ]


def read_u32_readmemh(path: Path, expected_words: int | None = None) -> list[int]:
    """Read the exact one-u32-per-line staging format without accepting junk."""

    path = _absolute_lexical(path, "readmemh path")
    _reject_symlink_components(path, "readmemh path")
    if not stat.S_ISREG(path.stat().st_mode):
        raise AssetValidationError("readmemh path is not a regular file")
    words: list[int] = []
    with path.open("rb") as stream:
        for line_number, raw in enumerate(stream, 1):
            word = raw.rstrip(b"\n")
            if raw != word + b"\n" or not HEX32_RE.fullmatch(word):
                raise AssetValidationError(
                    f"{path}:{line_number}: expected one 8-digit u32 and LF"
                )
            words.append(int(word, 16))
    if expected_words is not None and len(words) != expected_words:
        raise AssetValidationError(
            f"{path}: expected {expected_words} words, got {len(words)}"
        )
    return words


def read_u32_simulator_dump(
    path: Path,
    expected_words: int | None = None,
) -> list[int]:
    """Read a simulator ``$writememh`` dump with only optional comments.

    Verilator may add blank lines or ``//`` address comments around a selected
    memory range.  No other decoration, short word, prefix, X/Z value, or
    trailing token is accepted.
    """

    path = _absolute_lexical(path, "simulator dump path")
    _reject_symlink_components(path, "simulator dump path")
    if not stat.S_ISREG(path.stat().st_mode):
        raise AssetValidationError("simulator dump path is not a regular file")
    words: list[int] = []
    with path.open("rb") as stream:
        for line_number, raw in enumerate(stream, 1):
            line = raw.strip()
            if not line or line.startswith(b"//"):
                continue
            if not HEX32_RE.fullmatch(line):
                raise AssetValidationError(
                    f"{path}:{line_number}: expected one 8-digit u32 or // comment"
                )
            words.append(int(line, 16))
    if expected_words is not None and len(words) != expected_words:
        raise AssetValidationError(
            f"{path}: expected {expected_words} words, got {len(words)}"
        )
    return words


def _secure_absolute_regular_file(path: Path, description: str) -> Path:
    path = _absolute_lexical(path, description)
    _reject_symlink_components(path, description)
    try:
        mode = path.stat().st_mode
    except OSError as exc:
        raise AssetValidationError(f"cannot stat {description}: {exc}") from exc
    if not stat.S_ISREG(mode):
        raise AssetValidationError(f"{description} is not a regular file: {path}")
    return path


def validate_canonical_e04_goldens(
    workspace_root: Path | None = None,
) -> Mapping[str, Mapping[str, object]]:
    """Validate all independent full-precision E04 checkpoints by pin."""

    root = (
        discover_workspace_root()
        if workspace_root is None
        else _secure_directory(
            _absolute_lexical(workspace_root, "workspace root"),
            "workspace root",
        )
    )
    records: dict[str, Mapping[str, object]] = {}
    for name, (relative, words, pin) in CANONICAL_E04_GOLDEN_PINS.items():
        path = secure_regular_file(
            root, relative, description=f"canonical E04 {name} golden"
        )
        verify_pinned_regular_file(
            path, pin, description=f"canonical E04 {name} golden"
        )
        read_u32_readmemh(path, words)
        records[name] = {
            "relative_path": relative.as_posix(),
            "size_bytes": pin.size_bytes,
            "words": words,
            "sha256": pin.sha256,
        }
    return records


def validate_canonical_e01_goldens(
    workspace_root: Path | None = None,
) -> Mapping[str, Mapping[str, object]]:
    """Validate the independent full-precision E01 checkpoint by pin."""

    root = (
        discover_workspace_root()
        if workspace_root is None
        else _secure_directory(
            _absolute_lexical(workspace_root, "workspace root"),
            "workspace root",
        )
    )
    records: dict[str, Mapping[str, object]] = {}
    for name, (relative, words, pin) in CANONICAL_E01_GOLDEN_PINS.items():
        path = secure_regular_file(
            root, relative, description=f"canonical E01 {name} golden"
        )
        verify_pinned_regular_file(
            path, pin, description=f"canonical E01 {name} golden"
        )
        read_u32_readmemh(path, words)
        records[name] = {
            "relative_path": relative.as_posix(),
            "size_bytes": pin.size_bytes,
            "words": words,
            "sha256": pin.sha256,
        }
    return records


def _fp32_bits_to_float(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", _check_u32(bits, "FP32 word")))[0]


def _validate_staged_e01_directory(
    asset_dir: Path,
    workspace_root: Path | None = None,
) -> Mapping[str, object]:
    """Revalidate all six staged E01 files and their canonical provenance."""

    root = (
        discover_workspace_root()
        if workspace_root is None
        else _secure_directory(
            _absolute_lexical(workspace_root, "workspace root"),
            "workspace root",
        )
    )
    asset_dir = _secure_directory(
        _absolute_lexical(asset_dir, "asset directory"), "asset directory"
    )
    evidence_path = _secure_absolute_regular_file(
        asset_dir / "asset_evidence.json", "asset evidence"
    )
    evidence = _strict_json_bytes(evidence_path.read_bytes(), "asset evidence")
    if not isinstance(evidence, Mapping):
        raise AssetValidationError("asset evidence root must be an object")
    if evidence.get("schema") != ASSET_EVIDENCE_SCHEMA or evidence.get("phase") != "e01":
        raise AssetValidationError("asset evidence is not canonical E01 mode3 staging")
    package = evidence.get("package")
    if not isinstance(package, Mapping):
        raise AssetValidationError("asset evidence package object is absent")
    files = package.get("files")
    if not isinstance(files, Mapping):
        raise AssetValidationError("asset evidence package files are absent")
    for name, pin in CANONICAL_FILE_PINS.items():
        row = files.get(name)
        if (
            not isinstance(row, Mapping)
            or row.get("size_bytes") != pin.size_bytes
            or row.get("sha256") != pin.sha256
        ):
            raise AssetValidationError(f"asset evidence package pin mismatch: {name}")

    expected_specs = dict(PHASE_STAGE_SPECS["e01"] + E01_EXTERNAL_STAGE_SPECS)
    staged = evidence.get("staged")
    if not isinstance(staged, list) or len(staged) != len(expected_specs):
        raise AssetValidationError("E01 asset evidence staged population mismatch")
    rows_by_role: dict[str, Mapping[str, object]] = {}
    for row in staged:
        if not isinstance(row, Mapping):
            raise AssetValidationError("E01 staged row is not an object")
        role = row.get("role")
        filename = row.get("filename")
        if (
            not isinstance(role, str)
            or role not in expected_specs
            or role in rows_by_role
            or filename != expected_specs[role]
        ):
            raise AssetValidationError("E01 staged role/filename mismatch")
        staged_path = _secure_absolute_regular_file(
            asset_dir / str(filename), f"staged E01 asset {role}"
        )
        live_sha = sha256_file(staged_path)
        if (
            live_sha != row.get("staged_sha256")
            or live_sha != E01_STAGED_SHA256_BY_ROLE[role]
        ):
            raise AssetValidationError(f"staged E01 asset SHA-256 mismatch: {role}")
        expected_words = row.get("stored_words")
        expected_text_bytes = row.get("text_bytes")
        if (
            not isinstance(expected_words, int)
            or not isinstance(expected_text_bytes, int)
            or staged_path.stat().st_size != expected_text_bytes
        ):
            raise AssetValidationError(f"staged E01 asset extent mismatch: {role}")
        read_u32_readmemh(staged_path, expected_words)
        rows_by_role[role] = row
    if set(rows_by_role) != set(expected_specs):
        raise AssetValidationError("staged E01 roles are incomplete")
    if rows_by_role["prepared_input"].get("stored_words") != 150_528:
        raise AssetValidationError("staged E01 prepared-input word count mismatch")
    if rows_by_role["embedding_golden"].get("stored_words") != 151_296:
        raise AssetValidationError("staged E01 golden word count mismatch")
    recorded_goldens = evidence.get("behavioral_goldens")
    live_goldens = validate_canonical_e01_goldens(root)
    if recorded_goldens != live_goldens:
        raise AssetValidationError(
            "E01 evidence behavioral-golden pins do not match canonical files"
        )
    return evidence


def _validate_staged_e04_directory(
    asset_dir: Path,
    workspace_root: Path | None = None,
) -> Mapping[str, object]:
    asset_dir = _secure_directory(
        _absolute_lexical(asset_dir, "asset directory"), "asset directory"
    )
    evidence_path = _secure_absolute_regular_file(
        asset_dir / "asset_evidence.json", "asset evidence"
    )
    evidence = _strict_json_bytes(evidence_path.read_bytes(), "asset evidence")
    if not isinstance(evidence, Mapping):
        raise AssetValidationError("asset evidence root must be an object")
    if evidence.get("schema") != ASSET_EVIDENCE_SCHEMA or evidence.get("phase") != "e04":
        raise AssetValidationError("asset evidence is not canonical E04 mode3 staging")
    package = evidence.get("package")
    if not isinstance(package, Mapping):
        raise AssetValidationError("asset evidence package object is absent")
    files = package.get("files")
    if not isinstance(files, Mapping):
        raise AssetValidationError("asset evidence package files are absent")
    for name, pin in CANONICAL_FILE_PINS.items():
        row = files.get(name)
        if (
            not isinstance(row, Mapping)
            or row.get("size_bytes") != pin.size_bytes
            or row.get("sha256") != pin.sha256
        ):
            raise AssetValidationError(f"asset evidence package pin mismatch: {name}")

    staged = evidence.get("staged")
    if not isinstance(staged, list) or len(staged) != len(PHASE_STAGE_SPECS["e04"]):
        raise AssetValidationError("asset evidence staged population mismatch")
    rows_by_role: dict[str, Mapping[str, object]] = {}
    expected_specs = dict(PHASE_STAGE_SPECS["e04"])
    for row in staged:
        if not isinstance(row, Mapping):
            raise AssetValidationError("asset evidence staged row is not an object")
        role = row.get("role")
        filename = row.get("filename")
        if (
            not isinstance(role, str)
            or role not in expected_specs
            or role in rows_by_role
            or filename != expected_specs[role]
        ):
            raise AssetValidationError("asset evidence staged role/filename mismatch")
        staged_path = _secure_absolute_regular_file(
            asset_dir / str(filename), f"staged asset {role}"
        )
        if sha256_file(staged_path) != row.get("staged_sha256"):
            raise AssetValidationError(f"staged asset SHA-256 mismatch: {role}")
        expected_text_bytes = row.get("text_bytes")
        if not isinstance(expected_text_bytes, int) or staged_path.stat().st_size != expected_text_bytes:
            raise AssetValidationError(f"staged asset byte count mismatch: {role}")
        rows_by_role[role] = row
    if set(rows_by_role) != set(expected_specs):
        raise AssetValidationError("staged E04 roles are incomplete")
    recorded_goldens = evidence.get("behavioral_goldens")
    live_goldens = validate_canonical_e04_goldens(workspace_root)
    if recorded_goldens != live_goldens:
        raise AssetValidationError(
            "asset evidence behavioral-golden pins do not match live canonical files"
        )
    return evidence


def _write_new_deterministic_json(
    path: Path,
    value: Mapping[str, object],
) -> str:
    path = _absolute_lexical(path, "report path")
    _secure_directory(path.parent, "report parent")
    if path.exists() or path.is_symlink():
        raise AssetValidationError(f"refusing existing report path: {path}")
    payload = (
        json.dumps(value, indent=2, sort_keys=True, separators=(",", ": ")) + "\n"
    ).encode("utf-8")
    try:
        with path.open("xb") as stream:
            stream.write(payload)
    except OSError as exc:
        raise AssetValidationError(f"cannot write comparison report: {exc}") from exc
    return hashlib.sha256(payload).hexdigest()


def _fp16_to_fixed24_exact(bits: int) -> int:
    """Represent one finite binary16 value as an integer times ``2^-24``.

    This is the same exact finite grid used by the pinned M6 reference.  Two
    such integers therefore multiply directly into M6's ``2^-48`` Kulisch
    domain.  Keeping this compact representation makes the full 115,605,504-
    MAC E01 oracle practical without changing any rounding point.
    """

    bits = _check_u16(bits, "binary16 word")
    sign = -1 if bits & 0x8000 else 1
    exponent = (bits >> 10) & 0x1F
    fraction = bits & 0x03FF
    if exponent == 0x1F:
        raise AssetValidationError("E01 oracle encountered non-finite binary16")
    if exponent == 0:
        magnitude = fraction
    else:
        magnitude = (0x0400 | fraction) << (exponent - 1)
    return sign * magnitude


def _iter_e01_m6_current_adder_oracle(
    patch_input_fp32: Sequence[int],
    patch_packed_u32: Sequence[int],
    patch_bias_fp32: Sequence[int],
    cls_token_fp32: Sequence[int],
    position_fp32: Sequence[int],
    *,
    workspace_root: Path | None = None,
) -> Iterator[int]:
    """Yield all 197x768 exact mode-3 E01 output words in row-major order."""

    hidden_size = 768
    patch_count = 196
    if len(patch_input_fp32) != patch_count * hidden_size:
        raise AssetValidationError("E01 oracle prepared-input extent mismatch")
    if len(patch_packed_u32) != 294_912:
        raise AssetValidationError("E01 oracle packed-weight extent mismatch")
    if len(patch_bias_fp32) != hidden_size or len(cls_token_fp32) != hidden_size:
        raise AssetValidationError("E01 oracle bias/CLS extent mismatch")
    if len(position_fp32) != (patch_count + 1) * hidden_size:
        raise AssetValidationError("E01 oracle position extent mismatch")

    m6 = load_m6_reference(workspace_root)
    fixed_weights: list[list[int]] = []
    for column in range(hidden_size):
        fixed_weights.append(
            [
                _fp16_to_fixed24_exact(
                    packed_fp16_weight_at(
                        patch_packed_u32,
                        reduction_index,
                        column,
                        reduction=hidden_size,
                        columns=hidden_size,
                    )
                )
                for reduction_index in range(hidden_size)
            ]
        )

    for hidden in range(hidden_size):
        yield fp32_add_current(
            _check_u32(int(cls_token_fp32[hidden]), "E01 CLS word"),
            _check_u32(int(position_fp32[hidden]), "E01 position word"),
        )

    for patch in range(patch_count):
        row_begin = patch * hidden_size
        row_fixed = [
            _fp16_to_fixed24_exact(
                int(
                    m6.fp32_bits_to_fp16_bits(
                        _check_u32(
                            int(patch_input_fp32[row_begin + reduction_index]),
                            "E01 prepared-input word",
                        )
                    )
                )
            )
            for reduction_index in range(hidden_size)
        ]
        position_begin = (patch + 1) * hidden_size
        for hidden, weight_column in enumerate(fixed_weights):
            fixed_sum = sum(map(operator.mul, row_fixed, weight_column))
            dot_bits = int(m6.fixed_to_fp32_bits(fixed_sum))
            biased_bits = fp32_add_current(
                dot_bits,
                _check_u32(int(patch_bias_fp32[hidden]), "E01 patch bias"),
            )
            yield fp32_add_current(
                biased_bits,
                _check_u32(
                    int(position_fp32[position_begin + hidden]),
                    "E01 position word",
                ),
            )


def compare_e01_m6_current_adder_oracle_dump(
    asset_dir: Path,
    embedding_dump: Path,
    report_path: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Require every E01 RTL word to equal the M6/current-adder oracle."""

    evidence = _validate_staged_e01_directory(asset_dir, workspace_root)
    embedding_path = _secure_absolute_regular_file(
        embedding_dump, "E01 embedding dump"
    )
    actual = read_u32_simulator_dump(embedding_path, 151_296)
    patch_input = read_u32_readmemh(
        Path(asset_dir) / "prepared_input_f32.hex", 150_528
    )
    patch_weight = read_u32_readmemh(
        Path(asset_dir) / "patch_weight_packed_fp16_u32.hex", 294_912
    )
    patch_bias = read_u32_readmemh(
        Path(asset_dir) / "patch_bias_f32.hex", 768
    )
    cls_token = read_u32_readmemh(
        Path(asset_dir) / "cls_token_f32.hex", 768
    )
    position = read_u32_readmemh(
        Path(asset_dir) / "position_f32.hex", 151_296
    )

    exact_mismatches = 0
    first_exact_mismatch: int | None = None
    actual_nonfinite = 0
    oracle_nonfinite = 0
    oracle_words = 0
    oracle_digest = hashlib.sha256()
    for index, (actual_bits, oracle_bits) in enumerate(
        zip(
            actual,
            _iter_e01_m6_current_adder_oracle(
                patch_input,
                patch_weight,
                patch_bias,
                cls_token,
                position,
                workspace_root=workspace_root,
            ),
            strict=True,
        )
    ):
        oracle_words += 1
        oracle_digest.update(f"{oracle_bits:08x}\n".encode("ascii"))
        actual_nonfinite += int(((actual_bits >> 23) & 0xFF) == 0xFF)
        oracle_nonfinite += int(((oracle_bits >> 23) & 0xFF) == 0xFF)
        if actual_bits != oracle_bits:
            exact_mismatches += 1
            if first_exact_mismatch is None:
                first_exact_mismatch = index
    if oracle_words != 151_296:
        raise AssetValidationError(
            f"E01 oracle yielded {oracle_words} words instead of 151296"
        )
    oracle_sha256 = oracle_digest.hexdigest()
    decision = (
        "PASS"
        if exact_mismatches == 0
        and actual_nonfinite == 0
        and oracle_nonfinite == 0
        else "FAIL"
    )
    staged_hashes = {
        str(row["role"]): str(row["staged_sha256"])
        for row in evidence["staged"]
    }
    report: dict[str, object] = {
        "schema": "vit-m7-mode3-e01-m6-current-adder-oracle-comparison-v1",
        "decision": decision,
        "execution_mode": 3,
        "inputs": {
            "asset_evidence_sha256": sha256_file(
                Path(asset_dir) / "asset_evidence.json"
            ),
            "embedding_dump_sha256": sha256_file(embedding_path),
            "embedding_words": len(actual),
            "staged_sha256_by_role": staged_hashes,
        },
        "numerical_contract": {
            "gate": "FULL_E01_ARITHMETIC_EXACT_NOT_FP32_MODEL_QUALITY",
            "activation_conversion": "M6_FP32_TO_FP16_RNE_GRADUAL",
            "dot": "M6_EXACT_FP16_PRODUCTS_KULISCH_2^-48_ROUND_ONCE_FP32",
            "bias_and_position_add": "CURRENT_VIT_FP32_ADD_COMB_FTZ_RNE",
            "m6_reference_sha256": M6_REFERENCE_SHA256,
            "fp32_add_rtl_sha256": FP32_ADD_RTL_SHA256,
        },
        "comparison": {
            "words": len(actual),
            "exact_mismatches": exact_mismatches,
            "first_exact_mismatch": first_exact_mismatch,
            "actual_nonfinite": actual_nonfinite,
            "oracle_nonfinite": oracle_nonfinite,
            "oracle_readmemh_sha256": oracle_sha256,
        },
    }
    report_sha256 = _write_new_deterministic_json(report_path, report)
    return report, report_sha256


def compare_e01_behavioral_golden_dump(
    asset_dir: Path,
    embedding_dump: Path,
    report_path: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Compare all E01 words with the independent FP32 behavioral golden."""

    evidence = _validate_staged_e01_directory(asset_dir, workspace_root)
    embedding_path = _secure_absolute_regular_file(
        embedding_dump, "E01 embedding dump"
    )
    actual = read_u32_simulator_dump(embedding_path, 151_296)
    golden_path = _secure_absolute_regular_file(
        Path(asset_dir) / "embedding_golden_f32.hex",
        "staged E01 behavioral golden",
    )
    golden = read_u32_readmemh(golden_path, 151_296)
    comparison = _compare_e04_vector(
        actual,
        golden,
        abs_tolerance=E01_MODE3_EMBEDDING_QUALITY_ABS_TOLERANCE,
    )
    decision = (
        "PASS"
        if comparison["tolerance_failures"] == 0
        and comparison["actual_nonfinite"] == 0
        and comparison["golden_nonfinite"] == 0
        else "FAIL"
    )
    report: dict[str, object] = {
        "schema": "vit-m7-mode3-e01-behavioral-golden-comparison-v1",
        "decision": decision,
        "execution_mode": 3,
        "inputs": {
            "asset_evidence_sha256": sha256_file(
                Path(asset_dir) / "asset_evidence.json"
            ),
            "embedding_dump_sha256": sha256_file(embedding_path),
            "embedding_golden_sha256": sha256_file(golden_path),
            "canonical_goldens": validate_canonical_e01_goldens(workspace_root),
            "recorded_behavioral_goldens": evidence["behavioral_goldens"],
        },
        "criteria": {
            "embedding_abs_tolerance": (
                E01_MODE3_EMBEDDING_QUALITY_ABS_TOLERANCE
            ),
            "mode3_envelope_anchor_max_abs": 3.846675157547e-3,
            "gate": "INDEPENDENT_FP32_MODEL_QUALITY_NOT_M6_ARITHMETIC",
        },
        "embedding": comparison,
    }
    report_sha256 = _write_new_deterministic_json(report_path, report)
    return report, report_sha256


def compare_e04_m6_classifier_oracle_dumps(
    asset_dir: Path,
    final_ln_dump: Path,
    logits_dump: Path,
    report_path: Path,
    *,
    abs_tolerance: float = 0.0,
    rel_tolerance: float = 0.0,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Gate classifier arithmetic against M6 using the RTL final-LN CLS."""

    if (
        not isinstance(abs_tolerance, (int, float))
        or not isinstance(rel_tolerance, (int, float))
        or not math.isfinite(float(abs_tolerance))
        or not math.isfinite(float(rel_tolerance))
        or abs_tolerance < 0
        or rel_tolerance < 0
    ):
        raise ValueError("comparison tolerances must be finite and non-negative")
    evidence = _validate_staged_e04_directory(asset_dir, workspace_root)
    final_ln_path = _secure_absolute_regular_file(final_ln_dump, "final-LN dump")
    logits_path = _secure_absolute_regular_file(logits_dump, "logits dump")
    final_ln = read_u32_simulator_dump(final_ln_path, 197 * 768)
    actual_logits = read_u32_simulator_dump(logits_path, 1000)
    gamma = read_u32_readmemh(
        Path(asset_dir) / "final_ln_gamma_f32.hex", 768
    )
    beta = read_u32_readmemh(
        Path(asset_dir) / "final_ln_beta_f32.hex", 768
    )
    packed_weights = read_u32_readmemh(
        Path(asset_dir) / "classifier_weight_packed_fp16_u32.hex", 384_000
    )
    bias = read_u32_readmemh(
        Path(asset_dir) / "classifier_bias_f32.hex", 1000
    )
    # Reading gamma/beta is an intentional extent/format gate.  The RTL final
    # LayerNorm is already represented by ``final_ln`` and must not be
    # recomputed from a behavioral checkpoint here.
    if len(gamma) != 768 or len(beta) != 768:
        raise AssertionError("validated E04 gamma/beta extents changed")
    oracle_logits = e04_logits_oracle(
        final_ln[:768],
        packed_weights,
        bias,
        workspace_root=workspace_root,
    )

    exact_mismatches = 0
    tolerance_failures = 0
    finite_pairs = 0
    max_abs = 0.0
    max_abs_index = 0
    sum_abs = 0.0
    first_exact_mismatch: int | None = None
    first_tolerance_failure: int | None = None
    actual_nonfinite = 0
    oracle_nonfinite = 0
    for index, (actual_bits, oracle_bits) in enumerate(
        zip(actual_logits, oracle_logits, strict=True)
    ):
        if actual_bits != oracle_bits:
            exact_mismatches += 1
            if first_exact_mismatch is None:
                first_exact_mismatch = index
        actual_value = _fp32_bits_to_float(actual_bits)
        oracle_value = _fp32_bits_to_float(oracle_bits)
        actual_nonfinite += int(not math.isfinite(actual_value))
        oracle_nonfinite += int(not math.isfinite(oracle_value))
        if math.isfinite(actual_value) and math.isfinite(oracle_value):
            error = abs(actual_value - oracle_value)
            limit = float(abs_tolerance) + float(rel_tolerance) * abs(oracle_value)
            finite_pairs += 1
            sum_abs += error
            if error > max_abs:
                max_abs = error
                max_abs_index = index
            failed = error > limit
        else:
            failed = actual_bits != oracle_bits
        if failed:
            tolerance_failures += 1
            if first_tolerance_failure is None:
                first_tolerance_failure = index

    actual_top1 = max(
        range(len(actual_logits)),
        key=lambda index: _fp32_bits_to_float(actual_logits[index]),
    )
    oracle_top1 = max(
        range(len(oracle_logits)),
        key=lambda index: _fp32_bits_to_float(oracle_logits[index]),
    )
    decision = (
        "PASS"
        if exact_mismatches == 0
        and tolerance_failures == 0
        and actual_nonfinite == 0
        and oracle_nonfinite == 0
        and actual_top1 == oracle_top1
        else "FAIL"
    )
    staged_rows = evidence["staged"]
    staged_hashes = {
        str(row["role"]): str(row["staged_sha256"])
        for row in staged_rows
    }
    report: dict[str, object] = {
        "schema": "vit-m7-mode3-e04-m6-classifier-oracle-comparison-v1",
        "decision": decision,
        "execution_mode": 3,
        "inputs": {
            "asset_evidence_sha256": sha256_file(Path(asset_dir) / "asset_evidence.json"),
            "final_ln_dump_sha256": sha256_file(final_ln_path),
            "final_ln_words": len(final_ln),
            "logits_dump_sha256": sha256_file(logits_path),
            "logits_words": len(actual_logits),
            "staged_sha256_by_role": staged_hashes,
        },
        "numerical_contract": {
            "gate": "CLASSIFIER_ARITHMETIC_ONLY_NOT_MODEL_QUALITY",
            "activation_source": "RTL_FINAL_LN_DUMP_CLS_TOKEN_WORDS_0_TO_767",
            "activation_conversion": "M6_FP32_TO_FP16_RNE_GRADUAL",
            "dot": "M6_EXACT_FP16_PRODUCTS_KULISCH_2^-48_ROUND_ONCE_FP32",
            "bias_add": "CURRENT_VIT_FP32_ADD_COMB_FTZ_RNE",
            "m6_reference_sha256": M6_REFERENCE_SHA256,
            "fp32_add_rtl_sha256": FP32_ADD_RTL_SHA256,
        },
        "comparison": {
            "words": len(actual_logits),
            "exact_mismatches": exact_mismatches,
            "first_exact_mismatch": first_exact_mismatch,
            "abs_tolerance": float(abs_tolerance),
            "rel_tolerance": float(rel_tolerance),
            "tolerance_failures": tolerance_failures,
            "first_tolerance_failure": first_tolerance_failure,
            "finite_pairs": finite_pairs,
            "actual_nonfinite": actual_nonfinite,
            "oracle_nonfinite": oracle_nonfinite,
            "max_abs": max_abs,
            "max_abs_index": max_abs_index,
            "mean_abs": (sum_abs / finite_pairs) if finite_pairs else 0.0,
            "actual_top1": actual_top1,
            "oracle_top1": oracle_top1,
            "actual_top1_word": f"0x{actual_logits[actual_top1]:08X}",
            "oracle_top1_word": f"0x{oracle_logits[oracle_top1]:08X}",
        },
    }
    report_sha256 = _write_new_deterministic_json(report_path, report)
    return report, report_sha256


def _compare_e04_vector(
    actual: Sequence[int],
    golden: Sequence[int],
    *,
    abs_tolerance: float,
) -> Mapping[str, object]:
    if len(actual) != len(golden):
        raise ValueError("E04 actual/golden vector lengths differ")
    exact_mismatches = 0
    tolerance_failures = 0
    actual_nonfinite = 0
    golden_nonfinite = 0
    finite_pairs = 0
    max_abs = 0.0
    max_abs_index = 0
    sum_abs = 0.0
    first_exact_mismatch: int | None = None
    first_tolerance_failure: int | None = None
    for index, (actual_bits, golden_bits) in enumerate(
        zip(actual, golden, strict=True)
    ):
        if actual_bits != golden_bits:
            exact_mismatches += 1
            if first_exact_mismatch is None:
                first_exact_mismatch = index
        actual_value = _fp32_bits_to_float(int(actual_bits))
        golden_value = _fp32_bits_to_float(int(golden_bits))
        actual_finite = math.isfinite(actual_value)
        golden_finite = math.isfinite(golden_value)
        actual_nonfinite += int(not actual_finite)
        golden_nonfinite += int(not golden_finite)
        if actual_finite and golden_finite:
            error = abs(actual_value - golden_value)
            finite_pairs += 1
            sum_abs += error
            if error > max_abs:
                max_abs = error
                max_abs_index = index
            failed = error > abs_tolerance
        else:
            # Match the historical E04 gate: every non-finite pair fails,
            # even if the two raw words happen to be identical.
            failed = True
        if failed:
            tolerance_failures += 1
            if first_tolerance_failure is None:
                first_tolerance_failure = index
    return {
        "words": len(actual),
        "exact_mismatches": exact_mismatches,
        "first_exact_mismatch": first_exact_mismatch,
        "abs_tolerance": abs_tolerance,
        "tolerance_failures": tolerance_failures,
        "first_tolerance_failure": first_tolerance_failure,
        "finite_pairs": finite_pairs,
        "actual_nonfinite": actual_nonfinite,
        "golden_nonfinite": golden_nonfinite,
        "max_abs": max_abs,
        "max_abs_index": max_abs_index,
        "mean_abs": (sum_abs / finite_pairs) if finite_pairs else 0.0,
    }


def _argmax_finite(words: Sequence[int], description: str) -> int:
    values = [_fp32_bits_to_float(int(word)) for word in words]
    if any(not math.isfinite(value) for value in values):
        raise AssetValidationError(f"{description} contains a non-finite FP32 word")
    return max(range(len(values)), key=values.__getitem__)


def compare_e04_behavioral_golden_dumps(
    asset_dir: Path,
    final_ln_dump: Path,
    logits_dump: Path,
    probabilities_dump: Path,
    class_result_dump: Path,
    report_path: Path,
    *,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Gate all E04 checkpoints against independent canonical goldens.

    The M6 classifier oracle is intentionally not used here.  This gate first
    proves every final-LayerNorm word independently, then applies a measured
    FP16 model-quality envelope to all logits, retains the historical
    probability tolerance, and requires the RTL class result and all argmaxes
    to equal the exact expected class 879.
    """

    root = (
        discover_workspace_root()
        if workspace_root is None
        else _secure_directory(
            _absolute_lexical(workspace_root, "workspace root"),
            "workspace root",
        )
    )
    evidence = _validate_staged_e04_directory(asset_dir, root)
    final_ln_path = _secure_absolute_regular_file(final_ln_dump, "final-LN dump")
    logits_path = _secure_absolute_regular_file(logits_dump, "logits dump")
    probabilities_path = _secure_absolute_regular_file(
        probabilities_dump, "probabilities dump"
    )
    class_result_path = _secure_absolute_regular_file(
        class_result_dump, "class-result dump"
    )

    actual_final_ln = read_u32_simulator_dump(final_ln_path, 197 * 768)
    actual_logits = read_u32_simulator_dump(logits_path, 1_000)
    actual_probabilities = read_u32_simulator_dump(probabilities_path, 1_000)
    class_result = read_u32_simulator_dump(class_result_path, 2)
    class_index, class_logit_word = class_result
    if class_index >= 1_000:
        raise AssetValidationError(
            f"class-result index is outside the 1000-class domain: {class_index}"
        )

    golden_records = validate_canonical_e04_goldens(root)
    golden_final_ln = read_u32_readmemh(
        secure_regular_file(
            root,
            CANONICAL_E04_GOLDEN_PINS["final_layernorm"][0],
            description="canonical final-LN golden",
        ),
        197 * 768,
    )
    golden_logits = read_u32_readmemh(
        secure_regular_file(
            root,
            CANONICAL_E04_GOLDEN_PINS["logits"][0],
            description="canonical logits golden",
        ),
        1_000,
    )
    golden_probabilities = read_u32_readmemh(
        secure_regular_file(
            root,
            CANONICAL_E04_GOLDEN_PINS["probabilities"][0],
            description="canonical probabilities golden",
        ),
        1_000,
    )

    final_ln = _compare_e04_vector(
        actual_final_ln,
        golden_final_ln,
        abs_tolerance=E04_FINAL_LN_ABS_TOLERANCE,
    )
    logits = _compare_e04_vector(
        actual_logits,
        golden_logits,
        abs_tolerance=E04_MODE3_LOGIT_QUALITY_ABS_TOLERANCE,
    )
    probabilities = _compare_e04_vector(
        actual_probabilities,
        golden_probabilities,
        abs_tolerance=E04_PROBABILITY_ABS_TOLERANCE,
    )

    actual_logits_top1 = _argmax_finite(actual_logits, "actual logits")
    golden_logits_top1 = _argmax_finite(golden_logits, "golden logits")
    actual_probabilities_top1 = _argmax_finite(
        actual_probabilities, "actual probabilities"
    )
    golden_probabilities_top1 = _argmax_finite(
        golden_probabilities, "golden probabilities"
    )
    selected_actual_word = actual_logits[class_index]
    selected_golden_word = golden_logits[E04_EXPECTED_TOP1]
    selected_actual_value = _fp32_bits_to_float(selected_actual_word)
    selected_golden_value = _fp32_bits_to_float(selected_golden_word)
    selected_abs_error = abs(selected_actual_value - selected_golden_value)
    selected_raw_word_delta = abs(selected_actual_word - selected_golden_word)

    class_contract_pass = (
        class_index == E04_EXPECTED_TOP1
        and class_logit_word == selected_actual_word
        and actual_logits_top1 == E04_EXPECTED_TOP1
        and golden_logits_top1 == E04_EXPECTED_TOP1
        and actual_probabilities_top1 == E04_EXPECTED_TOP1
        and golden_probabilities_top1 == E04_EXPECTED_TOP1
        and math.isfinite(selected_actual_value)
        and math.isfinite(selected_golden_value)
        and selected_abs_error <= E04_MODE3_LOGIT_QUALITY_ABS_TOLERANCE
    )
    vector_contract_pass = all(
        comparison["tolerance_failures"] == 0
        and comparison["actual_nonfinite"] == 0
        and comparison["golden_nonfinite"] == 0
        for comparison in (final_ln, logits, probabilities)
    )
    decision = "PASS" if vector_contract_pass and class_contract_pass else "FAIL"

    report: dict[str, object] = {
        "schema": "vit-m7-mode3-e04-behavioral-golden-comparison-v1",
        "decision": decision,
        "execution_mode": 3,
        "inputs": {
            "asset_evidence_sha256": sha256_file(
                Path(asset_dir) / "asset_evidence.json"
            ),
            "final_ln_dump_sha256": sha256_file(final_ln_path),
            "logits_dump_sha256": sha256_file(logits_path),
            "probabilities_dump_sha256": sha256_file(probabilities_path),
            "class_result_dump_sha256": sha256_file(class_result_path),
            "canonical_goldens": golden_records,
            "recorded_behavioral_goldens": evidence["behavioral_goldens"],
        },
        "criteria": {
            "final_ln_abs_tolerance": E04_FINAL_LN_ABS_TOLERANCE,
            "mode3_logit_quality_abs_tolerance": (
                E04_MODE3_LOGIT_QUALITY_ABS_TOLERANCE
            ),
            "probability_abs_tolerance": E04_PROBABILITY_ABS_TOLERANCE,
            "expected_top1_and_class": E04_EXPECTED_TOP1,
            "mode3_logit_envelope_anchor_max_abs": 8.324980736e-4,
            "mode3_ideal_softmax_envelope_anchor_max_abs": 5.804002285e-6,
            "raw_word_delta": "DIAGNOSTIC_ONLY_NOT_A_MODE3_CRITERION",
        },
        "final_layernorm": final_ln,
        "logits": logits,
        "probabilities": probabilities,
        "top1_and_class": {
            "pass": class_contract_pass,
            "expected": E04_EXPECTED_TOP1,
            "actual_logits": actual_logits_top1,
            "golden_logits": golden_logits_top1,
            "actual_probabilities": actual_probabilities_top1,
            "golden_probabilities": golden_probabilities_top1,
            "class_result": class_index,
            "class_result_logit_word": f"0x{class_logit_word:08X}",
            "actual_selected_logit_word": f"0x{selected_actual_word:08X}",
            "golden_selected_logit_word": f"0x{selected_golden_word:08X}",
            "class_result_logit_matches_dump": (
                class_logit_word == selected_actual_word
            ),
            "selected_logit_abs_error": selected_abs_error,
            "selected_logit_raw_word_delta_diagnostic": selected_raw_word_delta,
        },
    }
    report_sha256 = _write_new_deterministic_json(report_path, report)
    return report, report_sha256


def compare_e04_dumps(
    asset_dir: Path,
    final_ln_dump: Path,
    logits_dump: Path,
    report_path: Path,
    *,
    abs_tolerance: float = 0.0,
    rel_tolerance: float = 0.0,
    workspace_root: Path | None = None,
) -> tuple[Mapping[str, object], str]:
    """Backward-compatible alias for the classifier-arithmetic-only gate."""

    return compare_e04_m6_classifier_oracle_dumps(
        asset_dir,
        final_ln_dump,
        logits_dump,
        report_path,
        abs_tolerance=abs_tolerance,
        rel_tolerance=rel_tolerance,
        workspace_root=workspace_root,
    )


__all__ = [
    "ASSET_EVIDENCE_SCHEMA",
    "AssetValidationError",
    "CANONICAL_E01_GOLDEN_PINS",
    "CANONICAL_E04_GOLDEN_PINS",
    "CANONICAL_FILE_PINS",
    "CANONICAL_PACKAGE_RELATIVE",
    "E04_EXPECTED_TOP1",
    "E04_FINAL_LN_ABS_TOLERANCE",
    "E04_MODE3_LOGIT_QUALITY_ABS_TOLERANCE",
    "E04_PROBABILITY_ABS_TOLERANCE",
    "E01_MODE3_EMBEDDING_QUALITY_ABS_TOLERANCE",
    "E01OracleWord",
    "FP32_ADD_RTL_SHA256",
    "GemmOracleWord",
    "M6_REFERENCE_SHA256",
    "PackageValidation",
    "TableEntry",
    "discover_workspace_root",
    "compare_e01_behavioral_golden_dump",
    "compare_e01_m6_current_adder_oracle_dump",
    "compare_e04_behavioral_golden_dumps",
    "compare_e04_dumps",
    "compare_e04_m6_classifier_oracle_dumps",
    "e01_output_oracle_word",
    "e01_outputs_oracle",
    "e04_logits_oracle",
    "exact_fp16_dot_from_fp32_activation",
    "fp32_add_current",
    "gemm_oracle_word",
    "load_m6_reference",
    "packed_fp16_weight_at",
    "parse_v3_table",
    "read_u32_readmemh",
    "read_u32_simulator_dump",
    "secure_regular_file",
    "stage_phase_assets",
    "validate_canonical_package",
    "validate_canonical_e01_goldens",
    "validate_canonical_e04_goldens",
    "verify_pinned_regular_file",
]
