#!/usr/bin/env python3
"""Verify package-v3 identity, mixed dtype, packing, and 4 KiB contract."""

from __future__ import annotations

import argparse
import json
import mmap
import random
import sys
import zlib
from pathlib import Path

import numpy as np


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import vit_model_blocked_b_fp16_v3 as v3  # noqa: E402


SCRIPT = Path(__file__).resolve()
BUNDLE_ROOT = SCRIPT.parents[2]
WORKSPACE_ROOT = BUNDLE_ROOT.parent
DEFAULT_V2 = WORKSPACE_ROOT / "build" / "model_package" / "v2_blocked_b_fp32"
DEFAULT_V3 = (
    WORKSPACE_ROOT / "build" / "model_package" / "v3_blocked_b_fp16_mixed"
)


def numpy_fp32_to_fp16_bits(words: np.ndarray) -> np.ndarray:
    """Independent IEEE cast used only by the verifier."""

    source = np.asarray(words, dtype="<u4")
    with np.errstate(over="ignore", invalid="ignore", under="ignore"):
        halves = source.view("<f4").astype("<f2").view("<u2")
    nan = (
        (((source >> np.uint32(23)) & np.uint32(0xFF)) == 0xFF)
        & ((source & np.uint32(0x7FFFFF)) != 0)
    )
    if np.any(nan):
        halves = halves.copy()
        halves[nan] = np.uint16(v3.FP16_CANONICAL_QNAN)
    return halves


def verify_numpy_against_exact(
    seed: int = 0x4D37564E,
    random_words: int = 100_000,
) -> int:
    boundaries = [
        0x00000000,
        0x80000000,
        0x00000001,
        0x007FFFFF,
        0x00800000,
        0x33000000,
        0x33000001,
        0x33800000,
        0x387FC000,
        0x38800000,
        0x3F801000,
        0x3F801001,
        0x477FEFFF,
        0x477FF000,
        0x477FF001,
        0x7F7FFFFF,
        0x7F800000,
        0xFF800000,
        0x7F800001,
        0xFFC12345,
    ]
    rng = random.Random(seed)
    values = boundaries + [rng.getrandbits(32) for _ in range(random_words)]
    actual = numpy_fp32_to_fp16_bits(np.asarray(values, dtype="<u4"))
    for index, (word, got) in enumerate(zip(values, actual, strict=True)):
        expected = v3.fp32_bits_to_fp16_bits(word)
        if int(got) != expected:
            raise ValueError(
                f"NumPy verifier mismatch index={index} fp32=0x{word:08X} "
                f"got=0x{int(got):04X} expected=0x{expected:04X}"
            )
    return len(values)


def parse_v3_table(
    path: Path,
) -> tuple[list[object], list[dict[str, object]], bytes]:
    data = path.read_bytes()
    expected_bytes = v3.v1.TABLE_HEADER_BYTES + 200 * v3.v1.TABLE_ENTRY_BYTES
    if len(data) != expected_bytes:
        raise ValueError("v3 table size is not canonical")
    header = list(v3.v1.TABLE_HEADER_STRUCT.unpack_from(data, 0))
    entries_blob = data[v3.v1.TABLE_HEADER_BYTES :]
    entries: list[dict[str, object]] = []
    for index in range(200):
        fields = v3.v1.TABLE_ENTRY_STRUCT.unpack_from(
            entries_blob, index * v3.v1.TABLE_ENTRY_BYTES
        )
        entries.append(
            {
                "tensor_id": fields[0],
                "group": fields[1],
                "layer": fields[2],
                "slot": fields[3],
                "name_hash": fields[4],
                "word_offset": fields[5],
                "word_count": fields[6],
                "rank": fields[7],
                "layout": fields[8],
                "dims": tuple(fields[9:13]),
                "tensor_crc32": fields[13],
                "flags": fields[14],
            }
        )
    return header, entries, entries_blob


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--v2-package", type=Path, default=DEFAULT_V2)
    parser.add_argument("--package-dir", type=Path, default=DEFAULT_V3)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    parent_dir = args.v2_package.resolve(strict=True)
    package_dir = args.package_dir.resolve(strict=True)
    report_path = (
        args.report.resolve()
        if args.report
        else package_dir / "verification_report.json"
    )
    checks: list[dict[str, object]] = []

    def check(name: str, passed: bool, detail: object) -> None:
        checks.append({"name": name, "pass": bool(passed), "detail": detail})
        if not passed:
            raise ValueError(f"{name}: {detail}")

    parent = v3.verify_parent_v2(parent_dir)
    parent_entries = v3.parse_parent_v2_table(parent_dir, parent)
    check(
        "frozen_parent_v2",
        len(parent_entries) == 200,
        {
            "hash_manifest_sha256": parent["hash_manifest_sha256"],
            "tensor_count": len(parent_entries),
        },
    )
    vector_checks = v3.verify_vector_converter()
    numpy_checks = verify_numpy_against_exact()
    check(
        "fp16_converter_conformance",
        vector_checks == 100_020 and numpy_checks == 100_020,
        {
            "integer_vector_vs_m6_exact": vector_checks,
            "numpy_verifier_vs_m6_exact": numpy_checks,
        },
    )

    manifest_path = package_dir / "hash_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    check(
        "manifest_schema",
        manifest.get("schema") == v3.HASH_MANIFEST_SCHEMA,
        manifest.get("schema"),
    )
    check(
        "manifest_parent_identity",
        manifest.get("parent_v2_hash_manifest_sha256")
        == v3.EXPECTED_PARENT_HASH_MANIFEST_SHA256,
        manifest.get("parent_v2_hash_manifest_sha256"),
    )
    manifest_files = manifest.get("files")
    check(
        "manifest_files_array",
        isinstance(manifest_files, list),
        type(manifest_files).__name__,
    )
    declared: dict[str, dict[str, object]] = {}
    malformed = False
    for entry in manifest_files:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            malformed = True
            continue
        filename = str(entry["path"])
        if filename in declared:
            malformed = True
            continue
        declared[filename] = entry
    expected_files = {
        "vit_model.bin",
        "vit_model_table.bin",
        "prepared_input.bin",
        "vit_model_table.json",
        "vit_runtime_config.json",
    }
    check(
        "manifest_file_set",
        not malformed and set(declared) == expected_files,
        {"actual": sorted(declared), "expected": sorted(expected_files)},
    )
    actual_files: dict[str, dict[str, object]] = {}
    for filename in sorted(expected_files):
        actual = v3.checksum(package_dir / filename)
        actual_files[filename] = actual
        entry = declared[filename]
        check(
            f"hash_{filename}",
            actual["size_bytes"] == entry.get("size_bytes")
            and actual["sha256"] == entry.get("sha256")
            and v3.parse_crc32(actual["crc32"])
            == v3.parse_crc32(entry.get("crc32")),
            {"declared": entry, "actual": actual},
        )

    header, entries, entries_blob = parse_v3_table(
        package_dir / "vit_model_table.bin"
    )
    header_zero_crc = header.copy()
    header_zero_crc[17] = 0
    expected_header = {
        "magic": header[0] == v3.v1.TABLE_MAGIC,
        "version": (header[1], header[2])
        == (v3.TABLE_MAJOR, v3.TABLE_MINOR),
        "header_bytes": header[3] == v3.v1.TABLE_HEADER_BYTES,
        "endian": header[4] == v3.v1.TABLE_ENDIAN_LITTLE,
        "dtype": header[5] == v3.TABLE_DTYPE_MIXED_BY_ENTRY,
        "entry_count": header[6] == 200,
        "entry_bytes": header[7] == v3.v1.TABLE_ENTRY_BYTES,
        "alignment": header[8] == v3.ALIGNMENT_BYTES,
        "flags": header[9] == v3.TABLE_FLAGS,
        "entries_offset": header[10] == v3.v1.TABLE_HEADER_BYTES,
        "table_bytes": header[11]
        == v3.v1.TABLE_HEADER_BYTES + 200 * v3.v1.TABLE_ENTRY_BYTES,
        "source_words": header[12] == v3.v1.EXPECTED_SOURCE_WORDS,
        "storage_words": header[13] == v3.EXPECTED_STORAGE_WORDS,
        "model_bytes": header[14] == v3.EXPECTED_MODEL_BYTES,
        "model_crc": header[15]
        == v3.parse_crc32(actual_files["vit_model.bin"]["crc32"]),
        "entries_crc": header[16] == (zlib.crc32(entries_blob) & 0xFFFFFFFF),
        "header_crc": header[17]
        == (
            zlib.crc32(v3.v1.TABLE_HEADER_STRUCT.pack(*header_zero_crc))
            & 0xFFFFFFFF
        ),
        "crc_algorithm": header[18] == v3.v1.TABLE_CRC32_ISO_HDLC,
        "model_sha256": header[19].hex()
        == actual_files["vit_model.bin"]["sha256"],
    }
    check("table_header", all(expected_header.values()), expected_header)

    table_json = json.loads(
        (package_dir / "vit_model_table.json").read_text(encoding="utf-8")
    )
    blocked_layout = table_json.get("blocked_layout", {})
    quantization = table_json.get("quantization", {})
    table_contract = {
        "schema": table_json.get("schema") == v3.PACKAGE_SCHEMA,
        "address_unit": table_json.get("address_unit") == "U32_STORAGE_WORD",
        "byte_order": table_json.get("byte_order") == "LITTLE_ENDIAN",
        "header_dtype": table_json.get("header_dtype") == "MIXED_BY_ENTRY",
        "alignment": table_json.get("alignment_bytes") == v3.ALIGNMENT_BYTES,
        "source_semantics": table_json.get("source_words_field_semantics")
        == "LOGICAL_SOURCE_SCALAR_COUNT",
        "quantization_scope": quantization.get("scope")
        == "PERSISTENT_WEIGHT_B_ONLY",
        "quantization_rounding": quantization.get("rounding")
        == "ROUND_TO_NEAREST_TIES_TO_EVEN",
        "quantization_underflow": quantization.get("underflow") == "GRADUAL",
        "blocked_order": blocked_layout.get("order")
        == ["N_TILE", "K_CHUNK", "LANE", "COL"],
        "block_k": blocked_layout.get("block_k") == v3.BLOCK_K,
        "block_n": blocked_layout.get("block_n") == v3.BLOCK_N,
        "packed_halves": blocked_layout.get("packed_halves_per_word")
        == v3.PACKED_HALVES_PER_WORD,
        "block_words": blocked_layout.get("block_storage_words")
        == v3.BLOCK_STORAGE_WORDS,
        "block_bytes": blocked_layout.get("block_bytes") == v3.BLOCK_BYTES,
        "low_half": blocked_layout.get("u32_low_half") == "COL_0",
        "high_half": blocked_layout.get("u32_high_half") == "COL_1",
        "model_base_alignment": blocked_layout.get(
            "required_model_base_alignment_bytes"
        )
        == v3.ALIGNMENT_BYTES,
        "parent_identity": table_json.get("parent_v2", {}).get(
            "hash_manifest_sha256"
        )
        == v3.EXPECTED_PARENT_HASH_MANIFEST_SHA256,
        "model_storage_words": table_json.get("model", {}).get("storage_words")
        == v3.EXPECTED_STORAGE_WORDS,
        "model_size": table_json.get("model", {}).get("size_bytes")
        == v3.EXPECTED_MODEL_BYTES,
        "model_hash": table_json.get("model", {}).get("sha256")
        == actual_files["vit_model.bin"]["sha256"],
        "table_hash": table_json.get("table", {}).get("sha256")
        == actual_files["vit_model_table.bin"]["sha256"],
        "input_hash": table_json.get("prepared_input", {}).get("sha256")
        == actual_files["prepared_input.bin"]["sha256"],
    }
    check("table_json_contract", all(table_contract.values()), table_contract)
    table_json_entries = table_json.get("entries")
    check(
        "table_json_entry_count",
        isinstance(table_json_entries, list) and len(table_json_entries) == 200,
        len(table_json_entries) if isinstance(table_json_entries, list) else None,
    )

    expected_global_offsets: dict[str, int] = {}
    expected_layer_offsets: list[dict[str, int]] = [{} for _ in range(12)]
    for tensor, entry in zip(v3.tensor_storage_layout(), entries, strict=True):
        spec = tensor.spec
        if spec.layer == v3.v1.GLOBAL_LAYER_SENTINEL:
            expected_global_offsets[spec.role] = int(entry["word_offset"])
        else:
            expected_layer_offsets[spec.layer][spec.role] = int(
                entry["word_offset"]
            )
    check(
        "table_json_offset_maps",
        table_json.get("global_offsets") == expected_global_offsets
        and table_json.get("layer_offsets") == expected_layer_offsets,
        "all 200 binary-table addresses represented",
    )

    runtime = json.loads(
        (package_dir / "vit_runtime_config.json").read_text(encoding="utf-8")
    )
    runtime_contract = {
        "schema": runtime.get("schema") == v3.RUNTIME_SCHEMA,
        "package": runtime.get("package_schema") == v3.PACKAGE_SCHEMA,
        "address_unit": runtime.get("address_unit") == "U32_STORAGE_WORD",
        "portable": runtime.get("physical_ddr_bases_included") is False,
        "source": runtime.get("source_of_truth") == "vit_model_table.bin",
        "execution_mode": runtime.get("execution_mode")
        == v3.EXECUTION_MODE_BLOCKED_B_FP16_PACKED2,
        "model_words": runtime.get("model_words") == v3.EXPECTED_STORAGE_WORDS,
        "input_words": runtime.get("input_words")
        == v3.v1.EXPECTED_INPUT_WORDS,
        "scratch_words": runtime.get("scratch_words")
        == v3.EXPECTED_SCRATCH_WORDS,
        "word_counts": runtime.get("memory_word_counts")
        == {
            "model": v3.EXPECTED_STORAGE_WORDS,
            "input": v3.v1.EXPECTED_INPUT_WORDS,
            "scratch": v3.EXPECTED_SCRATCH_WORDS,
        },
        "storage_dtypes": runtime.get("memory_storage_dtypes")
        == {
            "model": "MIXED_BY_TABLE_ENTRY",
            "input": "IEEE754_BINARY32_RAW_BITS",
            "scratch": "IEEE754_BINARY32_RAW_BITS",
        },
        "alignment": runtime.get("required_model_base_alignment_bytes")
        == v3.ALIGNMENT_BYTES,
        "model_b_layout": runtime.get("model_b_layout")
        == "GEMM_B_BLOCKED_K16_N2_FP16_PACKED2_LANE_COL",
        "packed_halves": runtime.get("model_b_packed_halves_per_word")
        == v3.PACKED_HALVES_PER_WORD,
        "block_words": runtime.get("model_b_block_storage_words")
        == v3.BLOCK_STORAGE_WORDS,
        "blocked_count": runtime.get("blocked_weight_tensor_count")
        == v3.EXPECTED_BLOCKED_TENSORS,
        "input_fp32": runtime.get("input_storage_fp32") is True,
        "scratch_fp32": runtime.get("scratch_storage_fp32") is True,
        "scratch_b_row_major": runtime.get("row_major_scratch_gemm_b") is True,
        "activation_conversion": runtime.get(
            "fp32_to_fp16_activation_conversion_at_gemm_ingress"
        )
        is True,
        "global_offsets": runtime.get("global_offsets")
        == expected_global_offsets,
        "layer_offsets": runtime.get("layer_offsets") == expected_layer_offsets,
    }
    check("runtime_contract", all(runtime_contract.values()), runtime_contract)

    parent_model_path = parent_dir / "vit_model.bin"
    model_path = package_dir / "vit_model.bin"
    check(
        "model_size",
        model_path.stat().st_size == v3.EXPECTED_MODEL_BYTES,
        model_path.stat().st_size,
    )
    cursor = 0
    padding_words = 0
    blocked_count = 0
    unchanged_count = 0
    compared_logical_elements = 0
    block_count = 0
    boundary_failures: list[dict[str, object]] = []
    half_zero = 0
    half_subnormal = 0
    half_infinity = 0
    half_nan = 0
    tensor_results: list[dict[str, object]] = []

    with parent_model_path.open("rb") as parent_stream, model_path.open(
        "rb"
    ) as model_stream:
        parent_map = mmap.mmap(
            parent_stream.fileno(), 0, access=mmap.ACCESS_READ
        )
        model_map = mmap.mmap(model_stream.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            for index, (tensor, parent_entry, entry) in enumerate(
                zip(
                    v3.tensor_storage_layout(),
                    parent_entries,
                    entries,
                    strict=True,
                )
            ):
                spec = tensor.spec
                aligned = v3.align_words(cursor)
                padding = aligned - cursor
                if padding:
                    padding_bytes = model_map[cursor * 4 : aligned * 4]
                    check(
                        f"padding_zero_{index}",
                        padding_bytes == b"\x00" * len(padding_bytes),
                        {"words": padding},
                    )
                    padding_words += padding

                expected_fields = {
                    "tensor_id": spec.tensor_id,
                    "group": spec.group,
                    "layer": spec.layer,
                    "slot": spec.slot,
                    "name_hash": v3.v1.fnv1a64(spec.filename),
                    "word_offset": aligned,
                    "word_count": tensor.stored_words,
                    "rank": spec.rank,
                    "layout": tensor.layout,
                    "dims": spec.padded_shape,
                    "flags": tensor.flags,
                }
                check(
                    f"entry_{index:03d}",
                    all(entry[key] == value for key, value in expected_fields.items()),
                    expected_fields,
                )

                parent_start = int(parent_entry["word_offset"]) * 4
                parent_bytes = parent_map[
                    parent_start : parent_start
                    + int(parent_entry["word_count"]) * 4
                ]
                check(
                    f"parent_tensor_crc_{index:03d}",
                    (zlib.crc32(parent_bytes) & 0xFFFFFFFF)
                    == int(parent_entry["tensor_crc32"]),
                    spec.filename,
                )
                stored_bytes = model_map[
                    aligned * 4 : (aligned + tensor.stored_words) * 4
                ]
                check(
                    f"tensor_crc_{index:03d}",
                    (zlib.crc32(stored_bytes) & 0xFFFFFFFF)
                    == int(entry["tensor_crc32"]),
                    spec.filename,
                )

                blocked = v3.is_weight_b(spec)
                json_entry = table_json_entries[index]
                expected_json = {
                    "tensor_id": spec.tensor_id,
                    "group": spec.group,
                    "layer": spec.layer,
                    "slot": spec.slot,
                    "role": spec.role,
                    "filename": spec.filename,
                    "word_offset": aligned,
                    "byte_offset": aligned * 4,
                    "logical_element_count": spec.word_count,
                    "parent_v2_word_count": int(parent_entry["word_count"]),
                    "stored_word_count": tensor.stored_words,
                    "stored_byte_count": tensor.stored_words * 4,
                    "logical_shape": list(spec.shape),
                    "stored_shape": list(tensor.stored_shape),
                    "storage_word_shape": list(tensor.storage_word_shape),
                    "layout": v3.layout_name(tensor.layout),
                    "layout_id": tensor.layout,
                    "flags": f"0x{tensor.flags:08X}",
                    "blocked": blocked,
                    "element_dtype": tensor.element_dtype,
                    "packed_halves_per_word": (
                        v3.PACKED_HALVES_PER_WORD if blocked else None
                    ),
                    "block_k": v3.BLOCK_K if blocked else None,
                    "block_n": v3.BLOCK_N if blocked else None,
                    "block_storage_words": (
                        v3.BLOCK_STORAGE_WORDS if blocked else None
                    ),
                    "block_bytes": v3.BLOCK_BYTES if blocked else None,
                }
                check(
                    f"json_entry_{index:03d}",
                    isinstance(json_entry, dict)
                    and all(json_entry.get(key) == value for key, value in expected_json.items()),
                    spec.filename,
                )

                if blocked:
                    blocked_count += 1
                    parent_words = v3.words_from_little_endian(parent_bytes)
                    expected_halves = numpy_fp32_to_fp16_bits(parent_words)
                    actual_words = v3.words_from_little_endian(stored_bytes)
                    actual_halves = v3.unpack_v3_words_to_v2_half_order(
                        actual_words
                    )
                    check(
                        f"fp16_rne_and_lane_col_pack_{index:03d}",
                        np.array_equal(actual_halves, expected_halves),
                        spec.filename,
                    )
                    half_exp = (actual_halves >> np.uint16(10)) & np.uint16(0x1F)
                    half_frac = actual_halves & np.uint16(0x03FF)
                    half_zero += int(
                        np.count_nonzero((half_exp == 0) & (half_frac == 0))
                    )
                    half_subnormal += int(
                        np.count_nonzero((half_exp == 0) & (half_frac != 0))
                    )
                    half_infinity += int(
                        np.count_nonzero((half_exp == 0x1F) & (half_frac == 0))
                    )
                    half_nan += int(
                        np.count_nonzero((half_exp == 0x1F) & (half_frac != 0))
                    )
                    blocks = tensor.stored_words // v3.BLOCK_STORAGE_WORDS
                    for block in range(blocks):
                        start = aligned + block * v3.BLOCK_STORAGE_WORDS
                        if (
                            not v3.block_fits_4k(start)
                            and len(boundary_failures) < 16
                        ):
                            boundary_failures.append(
                                {
                                    "tensor": spec.filename,
                                    "block": block,
                                    "word_offset": start,
                                }
                            )
                    block_count += blocks
                else:
                    unchanged_count += 1
                    check(
                        f"unchanged_fp32_{index:03d}",
                        stored_bytes == parent_bytes,
                        spec.filename,
                    )

                tensor_results.append(
                    {
                        "index": index,
                        "filename": spec.filename,
                        "blocked_fp16": blocked,
                        "logical_elements": spec.word_count,
                        "stored_words": tensor.stored_words,
                        "word_offset": aligned,
                    }
                )
                compared_logical_elements += spec.word_count
                cursor = aligned + tensor.stored_words
        finally:
            parent_map.close()
            model_map.close()

    check("tensor_count", len(tensor_results) == 200, len(tensor_results))
    check(
        "blocked_tensor_count",
        blocked_count == v3.EXPECTED_BLOCKED_TENSORS,
        blocked_count,
    )
    check("unchanged_tensor_count", unchanged_count == 126, unchanged_count)
    check(
        "blocked_4k_boundaries",
        not boundary_failures and block_count == v3.EXPECTED_BLOCK_COUNT,
        {
            "blocks_checked": block_count,
            "failure_examples": boundary_failures,
        },
    )
    check(
        "padding_words",
        padding_words == v3.EXPECTED_PADDING_WORDS,
        padding_words,
    )
    check(
        "storage_extent",
        cursor == v3.EXPECTED_STORAGE_WORDS,
        cursor,
    )
    check(
        "logical_elements_compared",
        compared_logical_elements == v3.v1.EXPECTED_SOURCE_WORDS,
        compared_logical_elements,
    )
    check(
        "prepared_input_fp32_byte_exact",
        (package_dir / "prepared_input.bin").read_bytes()
        == (parent_dir / "prepared_input.bin").read_bytes(),
        "byte-exact",
    )

    report = {
        "schema": v3.VERIFICATION_SCHEMA,
        "outcome": "PASS",
        "package_dir": str(package_dir),
        "parent_v2_dir": str(parent_dir),
        "checks_passed": len(checks),
        "converter_conformance_checks": vector_checks + numpy_checks,
        "tensor_count": len(tensor_results),
        "blocked_fp16_tensor_count": blocked_count,
        "unchanged_fp32_tensor_count": unchanged_count,
        "logical_elements_compared": compared_logical_elements,
        "blocked_4k_boundary_blocks_checked": block_count,
        "padding_words": padding_words,
        "model_storage_words": v3.EXPECTED_STORAGE_WORDS,
        "model_size_bytes": v3.EXPECTED_MODEL_BYTES,
        "quantized_fp16_classification": {
            "zero": half_zero,
            "subnormal": half_subnormal,
            "infinity": half_infinity,
            "nan": half_nan,
        },
        "model_sha256": actual_files["vit_model.bin"]["sha256"],
        "table_sha256": actual_files["vit_model_table.bin"]["sha256"],
        "input_sha256": actual_files["prepared_input.bin"]["sha256"],
        "hash_manifest_sha256": v3.sha256_file(manifest_path),
        "checks": checks,
        "tensors": tensor_results,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "M7_PACKAGE_VERIFICATION_PASS "
        f"tensors={len(tensor_results)} fp16_blocked={blocked_count} "
        f"fp32_unchanged={unchanged_count} logical={compared_logical_elements} "
        f"blocks_4k={block_count} checks={len(checks)}"
    )
    print(f"REPORT={report_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"M7_PACKAGE_VERIFICATION_FAIL: {exc}", file=sys.stderr)
        raise
