#!/usr/bin/env python3
"""Create deterministic blocked-B FP32 package v2 from a verified package v1."""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
import shutil
import tempfile
import zlib
from pathlib import Path

import vit_model_schema_v1 as v1
from vit_model_blocked_b_v2 import (
    ALIGNMENT_BYTES,
    BLOCK_K,
    BLOCK_N,
    BLOCK_WORDS,
    EXECUTION_MODE_BLOCKED_B_K16_N2,
    EXPECTED_MODEL_BYTES,
    EXPECTED_PARENT_FILES,
    EXPECTED_PARENT_HASH_MANIFEST_SHA256,
    EXPECTED_PADDING_WORDS,
    EXPECTED_SCRATCH_WORDS,
    EXPECTED_STORAGE_WORDS,
    HASH_MANIFEST_SCHEMA,
    PACKAGE_SCHEMA,
    TABLE_FLAGS,
    TABLE_MAJOR,
    TABLE_MINOR,
    align_words,
    is_weight_b,
    layout_name,
    little_endian_bytes,
    pack_blocked_b,
    stored_tensor,
    tensor_storage_layout,
    words_from_little_endian,
)


SCRIPT = Path(__file__).resolve()
BUNDLE_ROOT = SCRIPT.parents[2]
WORKSPACE_ROOT = BUNDLE_ROOT.parent
DEFAULT_V1 = WORKSPACE_ROOT / "build" / "model_package" / "v1"
DEFAULT_OUTPUT = (
    WORKSPACE_ROOT / "build" / "model_package" / "v2_blocked_b_fp32"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def parse_crc32(value: object) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise ValueError(f"invalid CRC32 value: {value!r}")


def verify_v1_hash_manifest(package_dir: Path) -> dict[str, object]:
    manifest_path = package_dir / "hash_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "vit-model-package-hashes-v1":
        raise ValueError("parent package hash manifest is not v1")
    manifest_files = manifest.get("files")
    if not isinstance(manifest_files, list):
        raise ValueError("parent manifest files must be an array")
    declared: dict[str, dict[str, object]] = {}
    for entry in manifest_files:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ValueError("parent manifest contains a malformed file entry")
        filename = str(entry["path"])
        if filename in declared:
            raise ValueError(f"parent manifest repeats {filename}")
        declared[filename] = entry
    if set(declared) != set(EXPECTED_PARENT_FILES):
        raise ValueError(
            "parent manifest file set is not canonical: "
            f"{sorted(declared)}"
        )

    manifest_sha256 = sha256_file(manifest_path)
    if manifest_sha256 != EXPECTED_PARENT_HASH_MANIFEST_SHA256:
        raise ValueError(
            "parent hash_manifest.json identity differs from frozen v1"
        )

    verified: dict[str, dict[str, object]] = {}
    for filename, frozen in EXPECTED_PARENT_FILES.items():
        path = package_dir / filename
        actual = checksum(path)
        pinned = declared[filename]
        if (
            actual["size_bytes"] != pinned["size_bytes"]
            or actual["sha256"] != pinned["sha256"]
            or parse_crc32(actual["crc32"]) != parse_crc32(pinned["crc32"])
        ):
            raise ValueError(f"parent package checksum mismatch: {filename}")
        if (
            actual["size_bytes"] != frozen["size_bytes"]
            or actual["sha256"] != frozen["sha256"]
            or parse_crc32(actual["crc32"]) != parse_crc32(frozen["crc32"])
        ):
            raise ValueError(f"parent package is not frozen v1: {filename}")
        verified[filename] = actual
    return {
        "schema": "vit-model-package-v1",
        "hash_manifest_sha256": manifest_sha256,
        "files": verified,
    }


def parse_v1_table(
    package_dir: Path, parent: dict[str, object]
) -> list[dict[str, int]]:
    data = (package_dir / "vit_model_table.bin").read_bytes()
    expected_table_bytes = (
        v1.TABLE_HEADER_BYTES
        + v1.EXPECTED_TENSOR_COUNT * v1.TABLE_ENTRY_BYTES
    )
    if len(data) != expected_table_bytes:
        raise ValueError("parent v1 table size is not canonical")
    header = list(v1.TABLE_HEADER_STRUCT.unpack_from(data, 0))
    parent_model = parent["files"]["vit_model.bin"]
    expected_header = (
        (header[0], v1.TABLE_MAGIC),
        (header[1], v1.TABLE_MAJOR),
        (header[2], v1.TABLE_MINOR),
        (header[3], v1.TABLE_HEADER_BYTES),
        (header[4], v1.TABLE_ENDIAN_LITTLE),
        (header[5], v1.TABLE_DTYPE_FP32_BITS),
        (header[6], v1.EXPECTED_TENSOR_COUNT),
        (header[7], v1.TABLE_ENTRY_BYTES),
        (header[8], v1.ALIGNMENT_BYTES),
        (header[9], v1.TABLE_FLAGS),
        (header[10], v1.TABLE_HEADER_BYTES),
        (header[11], expected_table_bytes),
        (header[12], v1.EXPECTED_SOURCE_WORDS),
        (header[13], v1.EXPECTED_STORAGE_WORDS),
        (header[14], v1.EXPECTED_MODEL_BYTES),
        (header[15], parse_crc32(parent_model["crc32"])),
        (header[18], v1.TABLE_CRC32_ISO_HDLC),
        (header[19].hex(), parent_model["sha256"]),
    )
    if any(actual != expected for actual, expected in expected_header):
        raise ValueError("parent table header is not canonical v1")
    header_zero_crc = header.copy()
    header_zero_crc[17] = 0
    if header[17] != (
        zlib.crc32(v1.TABLE_HEADER_STRUCT.pack(*header_zero_crc))
        & 0xFFFFFFFF
    ):
        raise ValueError("parent table header CRC32 mismatch")

    entries: list[dict[str, int]] = []
    blob = data[v1.TABLE_HEADER_BYTES :]
    if header[16] != (zlib.crc32(blob) & 0xFFFFFFFF):
        raise ValueError("parent table entries CRC32 mismatch")
    cursor_words = 0
    for index, spec in enumerate(v1.tensor_specs()):
        fields = v1.TABLE_ENTRY_STRUCT.unpack_from(
            blob, index * v1.TABLE_ENTRY_BYTES
        )
        entry = {
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
        cursor_words = v1.align_words(cursor_words)
        expected = (
            spec.tensor_id,
            spec.group,
            spec.layer,
            spec.slot,
            v1.fnv1a64(spec.filename),
            cursor_words,
            spec.word_count,
            spec.rank,
            spec.layout,
            spec.padded_shape,
            spec.flags,
        )
        actual = (
            entry["tensor_id"],
            entry["group"],
            entry["layer"],
            entry["slot"],
            entry["name_hash"],
            entry["word_offset"],
            entry["word_count"],
            entry["rank"],
            entry["layout"],
            entry["dims"],
            entry["flags"],
        )
        if actual != expected:
            raise ValueError(f"parent table entry mismatch: {spec.filename}")
        entries.append(entry)
        cursor_words += spec.word_count
    if cursor_words != v1.EXPECTED_STORAGE_WORDS:
        raise ValueError("parent table storage extent is not canonical v1")
    return entries


def pack_model(
    v1_dir: Path, work_dir: Path, v1_entries: list[dict[str, int]]
) -> tuple[list[dict[str, object]], dict[str, object]]:
    source_path = v1_dir / "vit_model.bin"
    output_path = work_dir / "vit_model.bin"
    entries: list[dict[str, object]] = []
    model_sha = hashlib.sha256()
    model_crc = 0
    cursor_words = 0
    padding_words = 0

    def write_data(stream, data: bytes) -> None:
        nonlocal model_crc
        stream.write(data)
        model_sha.update(data)
        model_crc = zlib.crc32(data, model_crc)

    with source_path.open("rb") as source_stream, output_path.open("wb") as out:
        source_map = mmap.mmap(source_stream.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            for index, (spec, source_entry) in enumerate(
                zip(v1.tensor_specs(), v1_entries, strict=True), start=1
            ):
                aligned = align_words(cursor_words)
                padding = aligned - cursor_words
                if padding:
                    write_data(out, b"\x00" * (padding * 4))
                    padding_words += padding
                cursor_words = aligned

                source_start = source_entry["word_offset"] * 4
                source_end = source_start + spec.word_count * 4
                logical_bytes = source_map[source_start:source_end]
                if (
                    zlib.crc32(logical_bytes) & 0xFFFFFFFF
                ) != source_entry["tensor_crc32"]:
                    raise ValueError(
                        f"parent tensor CRC32 mismatch: {spec.filename}"
                    )
                tensor = stored_tensor(spec)
                if is_weight_b(spec):
                    logical_words = words_from_little_endian(logical_bytes)
                    stored_words = pack_blocked_b(
                        logical_words, spec.shape[0], spec.shape[1]
                    )
                    stored_bytes = little_endian_bytes(stored_words)
                else:
                    stored_bytes = logical_bytes
                if len(stored_bytes) != tensor.stored_words * 4:
                    raise RuntimeError(
                        f"stored extent mismatch: {spec.filename}"
                    )

                write_data(out, stored_bytes)
                tensor_crc = zlib.crc32(stored_bytes) & 0xFFFFFFFF
                tensor_sha = hashlib.sha256(stored_bytes).hexdigest()
                logical_sha = hashlib.sha256(logical_bytes).hexdigest()
                entries.append(
                    {
                        "tensor_id": spec.tensor_id,
                        "group": spec.group,
                        "layer": spec.layer,
                        "slot": spec.slot,
                        "role": spec.role,
                        "filename": spec.filename,
                        "name_hash_fnv1a64": f"0x{v1.fnv1a64(spec.filename):016X}",
                        "word_offset": cursor_words,
                        "byte_offset": cursor_words * 4,
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
                        "tensor_crc32": f"0x{tensor_crc:08X}",
                        "tensor_sha256": tensor_sha,
                        "logical_v1_sha256": logical_sha,
                    }
                )
                cursor_words += tensor.stored_words
                print(
                    f"[{index:03d}/200] offset=0x{aligned:08X} "
                    f"words={tensor.stored_words:9d} layout={layout_name(tensor.layout)} "
                    f"{spec.filename}"
                )
        finally:
            source_map.close()
        out.flush()
        os.fsync(out.fileno())

    if cursor_words != EXPECTED_STORAGE_WORDS:
        raise RuntimeError(
            f"v2 storage words {cursor_words} != {EXPECTED_STORAGE_WORDS}"
        )
    if padding_words != EXPECTED_PADDING_WORDS:
        raise RuntimeError(
            f"v2 padding words {padding_words} != {EXPECTED_PADDING_WORDS}"
        )
    if output_path.stat().st_size != EXPECTED_MODEL_BYTES:
        raise RuntimeError("v2 model byte size is not canonical")
    return entries, {
        "path": output_path.name,
        "source_words": v1.EXPECTED_SOURCE_WORDS,
        "stored_tensor_words": sum(
            int(entry["stored_word_count"]) for entry in entries
        ),
        "storage_words": cursor_words,
        "padding_words": padding_words,
        "size_bytes": output_path.stat().st_size,
        "crc32": model_crc & 0xFFFFFFFF,
        "sha256": model_sha.hexdigest(),
    }


def pack_table(
    work_dir: Path,
    entries: list[dict[str, object]],
    model: dict[str, object],
) -> dict[str, object]:
    chunks: list[bytes] = []
    for entry, tensor in zip(entries, tensor_storage_layout(), strict=True):
        spec = tensor.spec
        chunks.append(
            v1.TABLE_ENTRY_STRUCT.pack(
                spec.tensor_id,
                spec.group,
                spec.layer,
                spec.slot,
                v1.fnv1a64(spec.filename),
                int(entry["word_offset"]),
                tensor.stored_words,
                spec.rank,
                tensor.layout,
                *spec.padded_shape,
                int(str(entry["tensor_crc32"]), 16),
                tensor.flags,
            )
        )
    entries_blob = b"".join(chunks)
    entries_crc = zlib.crc32(entries_blob) & 0xFFFFFFFF
    table_bytes = v1.TABLE_HEADER_BYTES + len(entries_blob)
    values = (
        v1.TABLE_MAGIC,
        TABLE_MAJOR,
        TABLE_MINOR,
        v1.TABLE_HEADER_BYTES,
        v1.TABLE_ENDIAN_LITTLE,
        v1.TABLE_DTYPE_FP32_BITS,
        v1.EXPECTED_TENSOR_COUNT,
        v1.TABLE_ENTRY_BYTES,
        ALIGNMENT_BYTES,
        TABLE_FLAGS,
        v1.TABLE_HEADER_BYTES,
        table_bytes,
        v1.EXPECTED_SOURCE_WORDS,
        EXPECTED_STORAGE_WORDS,
        EXPECTED_MODEL_BYTES,
        int(model["crc32"]),
        entries_crc,
        0,
        v1.TABLE_CRC32_ISO_HDLC,
        bytes.fromhex(str(model["sha256"])),
    )
    zero_header = v1.TABLE_HEADER_STRUCT.pack(*values)
    header_crc = zlib.crc32(zero_header) & 0xFFFFFFFF
    values = (*values[:17], header_crc, *values[18:])
    data = v1.TABLE_HEADER_STRUCT.pack(*values) + entries_blob
    path = work_dir / "vit_model_table.bin"
    path.write_bytes(data)
    result = checksum(path)
    result.update(
        {
            "header_crc32": f"0x{header_crc:08X}",
            "entries_crc32": f"0x{entries_crc:08X}",
        }
    )
    return result


def offset_maps(entries: list[dict[str, object]]) -> tuple[dict, list[dict]]:
    globals_map = {
        str(entry["role"]): int(entry["word_offset"])
        for entry in entries
        if int(entry["layer"]) == v1.GLOBAL_LAYER_SENTINEL
    }
    layers = [
        {
            str(entry["role"]): int(entry["word_offset"])
            for entry in entries
            if int(entry["layer"]) == layer
        }
        for layer in range(12)
    ]
    return globals_map, layers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--v1-package", type=Path, default=DEFAULT_V1)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    v1_dir = args.v1_package.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise SystemExit(
            f"refusing to overwrite existing output directory: {output_dir}"
        )
    output_dir.parent.mkdir(parents=True, exist_ok=True)

    parent = verify_v1_hash_manifest(v1_dir)
    v1_entries = parse_v1_table(v1_dir, parent)
    print("PASS parent package v1: pinned hashes and 200 table entries")

    temporary = Path(
        tempfile.mkdtemp(prefix=output_dir.name + ".tmp.", dir=output_dir.parent)
    )
    try:
        entries, model = pack_model(v1_dir, temporary, v1_entries)
        table = pack_table(temporary, entries, model)
        shutil.copyfile(
            v1_dir / "prepared_input.bin", temporary / "prepared_input.bin"
        )
        prepared_input = checksum(temporary / "prepared_input.bin")
        globals_map, layers_map = offset_maps(entries)

        table_json = {
            "schema": PACKAGE_SCHEMA,
            "address_unit": "FP32_WORD",
            "byte_order": "LITTLE_ENDIAN",
            "dtype": "IEEE754_BINARY32_RAW_BITS",
            "alignment_bytes": ALIGNMENT_BYTES,
            "blocked_layout": {
                "order": ["N_TILE", "K_CHUNK", "COL", "LANE"],
                "block_k": BLOCK_K,
                "block_n": BLOCK_N,
                "block_words": BLOCK_WORDS,
                "required_model_base_alignment_bytes": ALIGNMENT_BYTES,
            },
            "parent_v1": parent,
            "model": {
                **model,
                "crc32": f"0x{int(model['crc32']):08X}",
            },
            "table": table,
            "prepared_input": prepared_input,
            "global_offsets": globals_map,
            "layer_offsets": layers_map,
            "entries": entries,
        }
        write_json(temporary / "vit_model_table.json", table_json)

        runtime = {
            "schema": "vit-runtime-config-v2-blocked-b-fp32",
            "package_schema": PACKAGE_SCHEMA,
            "address_unit": "FP32_WORD",
            "physical_ddr_bases_included": False,
            "source_of_truth": "vit_model_table.bin",
            "execution_mode": EXECUTION_MODE_BLOCKED_B_K16_N2,
            "model_words": EXPECTED_STORAGE_WORDS,
            "input_words": v1.EXPECTED_INPUT_WORDS,
            "scratch_words": EXPECTED_SCRATCH_WORDS,
            "memory_word_counts": {
                "model": EXPECTED_STORAGE_WORDS,
                "input": v1.EXPECTED_INPUT_WORDS,
                "scratch": EXPECTED_SCRATCH_WORDS,
            },
            "required_model_base_alignment_bytes": ALIGNMENT_BYTES,
            "model_b_layout": "GEMM_B_BLOCKED_K16_N2",
            "global_offsets": globals_map,
            "layer_offsets": layers_map,
            "blocked_weight_tensor_count": 74,
            "row_major_scratch_gemm_b": True,
        }
        write_json(temporary / "vit_runtime_config.json", runtime)

        manifest_files = [
            checksum(temporary / name)
            for name in (
                "vit_model.bin",
                "vit_model_table.bin",
                "prepared_input.bin",
                "vit_model_table.json",
                "vit_runtime_config.json",
            )
        ]
        manifest = {
            "schema": HASH_MANIFEST_SCHEMA,
            "parent_v1_hash_manifest_sha256": parent[
                "hash_manifest_sha256"
            ],
            "files": manifest_files,
        }
        write_json(temporary / "hash_manifest.json", manifest)
        os.replace(temporary, output_dir)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    print("PASS package v2: 200 tensors, 74 blocked GEMM-B tensors")
    print(f"MODEL_WORDS={EXPECTED_STORAGE_WORDS}")
    print(f"MODEL_SHA256={model['sha256']}")
    print(f"TABLE_SHA256={table['sha256']}")
    print(f"INPUT_SHA256={prepared_input['sha256']}")
    print(f"OUTPUT_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
