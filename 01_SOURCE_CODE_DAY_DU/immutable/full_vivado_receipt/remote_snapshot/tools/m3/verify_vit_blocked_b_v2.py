#!/usr/bin/env python3
"""Verify package v2 hashes, table, boundaries, and bit-exact v1 round-trip."""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import sys
import zlib
from pathlib import Path

import vit_model_schema_v1 as v1
from vit_model_blocked_b_v2 import (
    ALIGNMENT_BYTES,
    BLOCK_K,
    BLOCK_N,
    BLOCK_WORDS,
    EXECUTION_MODE_BLOCKED_B_K16_N2,
    EXPECTED_BLOCKED_TENSORS,
    EXPECTED_MODEL_BYTES,
    EXPECTED_PADDING_WORDS,
    EXPECTED_SCRATCH_WORDS,
    EXPECTED_STORAGE_WORDS,
    HASH_MANIFEST_SCHEMA,
    PACKAGE_SCHEMA,
    TABLE_FLAGS,
    TABLE_MAJOR,
    TABLE_MINOR,
    VERIFICATION_SCHEMA,
    align_words,
    block_fits_4k,
    is_weight_b,
    layout_name,
    little_endian_bytes,
    stored_tensor,
    tensor_storage_layout,
    unpack_blocked_b,
    words_from_little_endian,
)
from pack_vit_blocked_b_v2 import (
    parse_crc32,
    parse_v1_table,
    verify_v1_hash_manifest,
)


SCRIPT = Path(__file__).resolve()
BUNDLE_ROOT = SCRIPT.parents[2]
WORKSPACE_ROOT = BUNDLE_ROOT.parent
DEFAULT_V1 = WORKSPACE_ROOT / "build" / "model_package" / "v1"
DEFAULT_V2 = (
    WORKSPACE_ROOT / "build" / "model_package" / "v2_blocked_b_fp32"
)


def checksum(path: Path) -> dict[str, object]:
    crc32 = 0
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            size += len(chunk)
            crc32 = zlib.crc32(chunk, crc32)
            digest.update(chunk)
    return {
        "path": path.name,
        "size_bytes": size,
        "crc32": f"0x{crc32 & 0xFFFFFFFF:08X}",
        "sha256": digest.hexdigest(),
    }


def parse_entries(path: Path) -> tuple[list, list[dict[str, int]], bytes]:
    data = path.read_bytes()
    expected_size = v1.TABLE_HEADER_BYTES + 200 * v1.TABLE_ENTRY_BYTES
    if len(data) != expected_size:
        raise ValueError("v2 table size is not canonical")
    header = list(v1.TABLE_HEADER_STRUCT.unpack_from(data, 0))
    entries_blob = data[v1.TABLE_HEADER_BYTES :]
    entries = []
    for index in range(200):
        fields = v1.TABLE_ENTRY_STRUCT.unpack_from(
            entries_blob, index * v1.TABLE_ENTRY_BYTES
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
    parser.add_argument("--v1-package", type=Path, default=DEFAULT_V1)
    parser.add_argument("--package-dir", type=Path, default=DEFAULT_V2)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    v1_dir = args.v1_package.resolve(strict=True)
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

    parent = verify_v1_hash_manifest(v1_dir)
    v1_entries = parse_v1_table(v1_dir, parent)
    check(
        "frozen_parent_v1",
        len(v1_entries) == v1.EXPECTED_TENSOR_COUNT,
        {
            "hash_manifest_sha256": parent["hash_manifest_sha256"],
            "tensor_count": len(v1_entries),
        },
    )

    manifest = json.loads(
        (package_dir / "hash_manifest.json").read_text(encoding="utf-8")
    )
    check(
        "manifest_schema",
        manifest.get("schema") == HASH_MANIFEST_SCHEMA,
        manifest.get("schema"),
    )
    manifest_files = manifest.get("files")
    check("manifest_files_array", isinstance(manifest_files, list), type(manifest_files).__name__)
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
    check(
        "manifest_parent_identity",
        manifest.get("parent_v1_hash_manifest_sha256")
        == parent["hash_manifest_sha256"],
        manifest.get("parent_v1_hash_manifest_sha256"),
    )
    actual_files: dict[str, dict[str, object]] = {}
    for filename in sorted(expected_files):
        entry = declared[filename]
        path = package_dir / filename
        actual = checksum(path)
        actual_files[filename] = actual
        check(
            f"hash_{filename}",
            actual["size_bytes"] == entry.get("size_bytes")
            and actual["sha256"] == entry.get("sha256")
            and parse_crc32(actual["crc32"])
            == parse_crc32(entry.get("crc32")),
            {"declared": entry, "actual": actual},
        )

    header, entries, entries_blob = parse_entries(
        package_dir / "vit_model_table.bin"
    )
    header_zero_crc = header.copy()
    header_zero_crc[17] = 0
    expected_header = {
        "magic": header[0] == v1.TABLE_MAGIC,
        "version": (header[1], header[2]) == (TABLE_MAJOR, TABLE_MINOR),
        "header_bytes": header[3] == v1.TABLE_HEADER_BYTES,
        "endian": header[4] == v1.TABLE_ENDIAN_LITTLE,
        "dtype": header[5] == v1.TABLE_DTYPE_FP32_BITS,
        "entry_count": header[6] == 200,
        "entry_bytes": header[7] == v1.TABLE_ENTRY_BYTES,
        "alignment": header[8] == ALIGNMENT_BYTES,
        "flags": header[9] == TABLE_FLAGS,
        "entries_offset": header[10] == v1.TABLE_HEADER_BYTES,
        "table_bytes": header[11]
        == v1.TABLE_HEADER_BYTES
        + v1.EXPECTED_TENSOR_COUNT * v1.TABLE_ENTRY_BYTES,
        "source_words": header[12] == v1.EXPECTED_SOURCE_WORDS,
        "storage_words": header[13] == EXPECTED_STORAGE_WORDS,
        "model_bytes": header[14] == EXPECTED_MODEL_BYTES,
        "model_crc": header[15]
        == parse_crc32(actual_files["vit_model.bin"]["crc32"]),
        "entries_crc": header[16] == (zlib.crc32(entries_blob) & 0xFFFFFFFF),
        "header_crc": header[17]
        == (zlib.crc32(v1.TABLE_HEADER_STRUCT.pack(*header_zero_crc)) & 0xFFFFFFFF),
        "crc_algorithm": header[18] == v1.TABLE_CRC32_ISO_HDLC,
        "model_sha256": header[19].hex()
        == actual_files["vit_model.bin"]["sha256"],
    }
    check("table_header", all(expected_header.values()), expected_header)

    table_json = json.loads(
        (package_dir / "vit_model_table.json").read_text(encoding="utf-8")
    )
    check("table_json_schema", table_json.get("schema") == PACKAGE_SCHEMA, table_json.get("schema"))
    blocked_layout = table_json.get("blocked_layout", {})
    table_json_contract = {
        "address_unit": table_json.get("address_unit") == "FP32_WORD",
        "byte_order": table_json.get("byte_order") == "LITTLE_ENDIAN",
        "dtype": table_json.get("dtype") == "IEEE754_BINARY32_RAW_BITS",
        "alignment_bytes": table_json.get("alignment_bytes") == ALIGNMENT_BYTES,
        "blocked_order": blocked_layout.get("order")
        == ["N_TILE", "K_CHUNK", "COL", "LANE"],
        "block_k": blocked_layout.get("block_k") == BLOCK_K,
        "block_n": blocked_layout.get("block_n") == BLOCK_N,
        "block_words": blocked_layout.get("block_words") == BLOCK_WORDS,
        "model_base_alignment": blocked_layout.get(
            "required_model_base_alignment_bytes"
        )
        == ALIGNMENT_BYTES,
        "parent_identity": table_json.get("parent_v1", {}).get(
            "hash_manifest_sha256"
        )
        == parent["hash_manifest_sha256"],
        "model_sha256": table_json.get("model", {}).get("sha256")
        == actual_files["vit_model.bin"]["sha256"],
        "model_storage_words": table_json.get("model", {}).get(
            "storage_words"
        )
        == EXPECTED_STORAGE_WORDS,
        "model_padding_words": table_json.get("model", {}).get(
            "padding_words"
        )
        == EXPECTED_PADDING_WORDS,
        "model_size_bytes": table_json.get("model", {}).get("size_bytes")
        == EXPECTED_MODEL_BYTES,
        "model_crc32": parse_crc32(
            table_json.get("model", {}).get("crc32", -1)
        )
        == parse_crc32(actual_files["vit_model.bin"]["crc32"]),
        "table_sha256": table_json.get("table", {}).get("sha256")
        == actual_files["vit_model_table.bin"]["sha256"],
        "input_sha256": table_json.get("prepared_input", {}).get("sha256")
        == actual_files["prepared_input.bin"]["sha256"],
    }
    check(
        "table_json_contract",
        all(table_json_contract.values()),
        table_json_contract,
    )
    table_json_entries = table_json.get("entries")
    check(
        "table_json_entry_count",
        isinstance(table_json_entries, list)
        and len(table_json_entries) == v1.EXPECTED_TENSOR_COUNT,
        len(table_json_entries) if isinstance(table_json_entries, list) else None,
    )
    expected_global_offsets: dict[str, int] = {}
    expected_layer_offsets: list[dict[str, int]] = [
        {} for _ in range(12)
    ]
    for spec, entry in zip(v1.tensor_specs(), entries, strict=True):
        if spec.layer == v1.GLOBAL_LAYER_SENTINEL:
            expected_global_offsets[spec.role] = entry["word_offset"]
        else:
            expected_layer_offsets[spec.layer][spec.role] = entry["word_offset"]
    check(
        "table_json_offset_maps",
        table_json.get("global_offsets") == expected_global_offsets
        and table_json.get("layer_offsets") == expected_layer_offsets,
        "200 binary-table addresses represented in JSON maps",
    )
    runtime = json.loads(
        (package_dir / "vit_runtime_config.json").read_text(encoding="utf-8")
    )
    check(
        "runtime_contract",
        runtime.get("schema") == "vit-runtime-config-v2-blocked-b-fp32"
        and runtime.get("package_schema") == PACKAGE_SCHEMA
        and runtime.get("execution_mode") == EXECUTION_MODE_BLOCKED_B_K16_N2
        and runtime.get("model_words") == EXPECTED_STORAGE_WORDS
        and runtime.get("input_words") == v1.EXPECTED_INPUT_WORDS
        and runtime.get("scratch_words") == EXPECTED_SCRATCH_WORDS
        and runtime.get("memory_word_counts")
        == {
            "model": EXPECTED_STORAGE_WORDS,
            "input": v1.EXPECTED_INPUT_WORDS,
            "scratch": EXPECTED_SCRATCH_WORDS,
        }
        and runtime.get("address_unit") == "FP32_WORD"
        and runtime.get("physical_ddr_bases_included") is False
        and runtime.get("source_of_truth") == "vit_model_table.bin"
        and runtime.get("required_model_base_alignment_bytes")
        == ALIGNMENT_BYTES
        and runtime.get("model_b_layout") == "GEMM_B_BLOCKED_K16_N2"
        and runtime.get("blocked_weight_tensor_count") == 74
        and runtime.get("row_major_scratch_gemm_b") is True
        and runtime.get("global_offsets") == expected_global_offsets
        and runtime.get("layer_offsets") == expected_layer_offsets,
        runtime,
    )
    v1_model_path = v1_dir / "vit_model.bin"
    v2_model_path = package_dir / "vit_model.bin"
    check(
        "model_size",
        v2_model_path.stat().st_size == EXPECTED_MODEL_BYTES,
        v2_model_path.stat().st_size,
    )
    padding_words = 0
    blocked_count = 0
    boundary_blocks = 0
    boundary_failures: list[dict[str, object]] = []
    cursor = 0
    compared_words = 0
    tensor_results: list[dict[str, object]] = []
    with v1_model_path.open("rb") as v1_stream, v2_model_path.open("rb") as v2_stream:
        v1_map = mmap.mmap(v1_stream.fileno(), 0, access=mmap.ACCESS_READ)
        v2_map = mmap.mmap(v2_stream.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            for index, (spec, tensor, v1_entry, entry) in enumerate(
                zip(
                    v1.tensor_specs(),
                    tensor_storage_layout(),
                    v1_entries,
                    entries,
                    strict=True,
                )
            ):
                aligned = align_words(cursor)
                padding = aligned - cursor
                if padding:
                    pad = v2_map[cursor * 4 : aligned * 4]
                    check(
                        f"padding_zero_{index}",
                        pad == b"\x00" * len(pad),
                        {"words": padding},
                    )
                    padding_words += padding
                expected_fields = {
                    "tensor_id": spec.tensor_id,
                    "group": spec.group,
                    "layer": spec.layer,
                    "slot": spec.slot,
                    "name_hash": v1.fnv1a64(spec.filename),
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
                v1_start = v1_entry["word_offset"] * 4
                logical_bytes = v1_map[
                    v1_start : v1_start + spec.word_count * 4
                ]
                check(
                    f"parent_tensor_crc_{index:03d}",
                    (zlib.crc32(logical_bytes) & 0xFFFFFFFF)
                    == v1_entry["tensor_crc32"],
                    spec.filename,
                )
                stored_bytes = v2_map[
                    aligned * 4 : (aligned + tensor.stored_words) * 4
                ]
                check(
                    f"tensor_crc_{index:03d}",
                    (zlib.crc32(stored_bytes) & 0xFFFFFFFF)
                    == entry["tensor_crc32"],
                    spec.filename,
                )
                logical_sha256 = hashlib.sha256(logical_bytes).hexdigest()
                stored_sha256 = hashlib.sha256(stored_bytes).hexdigest()
                json_entry = table_json_entries[index]
                expected_json_entry = {
                    "tensor_id": spec.tensor_id,
                    "group": spec.group,
                    "layer": spec.layer,
                    "slot": spec.slot,
                    "role": spec.role,
                    "filename": spec.filename,
                    "name_hash_fnv1a64": f"0x{v1.fnv1a64(spec.filename):016X}",
                    "word_offset": aligned,
                    "byte_offset": aligned * 4,
                    "logical_word_count": spec.word_count,
                    "stored_word_count": tensor.stored_words,
                    "logical_shape": list(spec.shape),
                    "stored_shape": list(tensor.stored_shape),
                    "layout": layout_name(tensor.layout),
                    "layout_id": tensor.layout,
                    "flags": f"0x{tensor.flags:08X}",
                    "blocked": is_weight_b(spec),
                    "block_k": BLOCK_K if is_weight_b(spec) else None,
                    "block_n": BLOCK_N if is_weight_b(spec) else None,
                    "block_words": BLOCK_WORDS if is_weight_b(spec) else None,
                    "tensor_crc32": f"0x{entry['tensor_crc32']:08X}",
                    "tensor_sha256": stored_sha256,
                    "logical_v1_sha256": logical_sha256,
                }
                check(
                    f"json_entry_{index:03d}",
                    isinstance(json_entry, dict)
                    and all(
                        json_entry.get(key) == value
                        for key, value in expected_json_entry.items()
                    ),
                    spec.filename,
                )
                if is_weight_b(spec):
                    blocked_count += 1
                    restored = unpack_blocked_b(
                        words_from_little_endian(stored_bytes),
                        spec.shape[0],
                        spec.shape[1],
                    )
                    restored_bytes = little_endian_bytes(restored)
                    check(
                        f"roundtrip_{index:03d}",
                        restored_bytes == logical_bytes,
                        spec.filename,
                    )
                    for block in range(tensor.stored_words // BLOCK_WORDS):
                        start = aligned + block * BLOCK_WORDS
                        if not block_fits_4k(start) and len(boundary_failures) < 16:
                            boundary_failures.append(
                                {
                                    "tensor": spec.filename,
                                    "block": block,
                                    "word_offset": start,
                                }
                            )
                        boundary_blocks += 1
                else:
                    check(
                        f"unchanged_{index:03d}",
                        stored_bytes == logical_bytes,
                        spec.filename,
                    )
                tensor_results.append(
                    {
                        "index": index,
                        "filename": spec.filename,
                        "blocked": is_weight_b(spec),
                        "logical_words": spec.word_count,
                        "stored_words": tensor.stored_words,
                        "word_offset": aligned,
                    }
                )
                compared_words += spec.word_count
                cursor = aligned + tensor.stored_words
        finally:
            v1_map.close()
            v2_map.close()

    check("tensor_count", len(tensor_results) == 200, len(tensor_results))
    check(
        "all_blocked_blocks_fit_4k",
        not boundary_failures,
        {
            "blocks_checked": boundary_blocks,
            "failure_examples": boundary_failures,
        },
    )
    check("blocked_tensor_count", blocked_count == EXPECTED_BLOCKED_TENSORS, blocked_count)
    check("padding_words", padding_words == EXPECTED_PADDING_WORDS, padding_words)
    check("storage_extent", cursor == EXPECTED_STORAGE_WORDS, cursor)
    check("logical_words_compared", compared_words == v1.EXPECTED_SOURCE_WORDS, compared_words)
    check(
        "prepared_input_unchanged",
        (package_dir / "prepared_input.bin").read_bytes()
        == (v1_dir / "prepared_input.bin").read_bytes(),
        "byte-exact",
    )

    report = {
        "schema": VERIFICATION_SCHEMA,
        "outcome": "PASS",
        "package_dir": str(package_dir),
        "parent_v1_dir": str(v1_dir),
        "checks_passed": len(checks),
        "tensor_count": len(tensor_results),
        "blocked_tensor_count": blocked_count,
        "logical_words_compared": compared_words,
        "blocked_4k_boundary_blocks_checked": boundary_blocks,
        "padding_words": padding_words,
        "model_sha256": actual_files["vit_model.bin"]["sha256"],
        "table_sha256": actual_files["vit_model_table.bin"]["sha256"],
        "input_sha256": actual_files["prepared_input.bin"]["sha256"],
        "checks": checks,
        "tensors": tensor_results,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "M3_PACKAGE_VERIFICATION_PASS "
        f"tensors={len(tensor_results)} blocked={blocked_count} "
        f"logical_words={compared_words} blocks_4k={boundary_blocks} "
        f"checks={len(checks)}"
    )
    print(f"REPORT={report_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"M3_PACKAGE_VERIFICATION_FAIL: {exc}", file=sys.stderr)
        raise
