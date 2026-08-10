#!/usr/bin/env python3
"""Build deterministic mixed FP32/FP16 blocked-B model package v3."""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
import shutil
import sys
import tempfile
import zlib
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import vit_model_blocked_b_fp16_v3 as v3  # noqa: E402


SCRIPT = Path(__file__).resolve()
BUNDLE_ROOT = SCRIPT.parents[2]
WORKSPACE_ROOT = BUNDLE_ROOT.parent
DEFAULT_V2 = WORKSPACE_ROOT / "build" / "model_package" / "v2_blocked_b_fp32"
DEFAULT_OUTPUT = (
    WORKSPACE_ROOT / "build" / "model_package" / "v3_blocked_b_fp16_mixed"
)


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def pack_model(
    parent_dir: Path,
    work_dir: Path,
    parent_entries: list[dict[str, int]],
) -> tuple[list[dict[str, object]], dict[str, object]]:
    source_path = parent_dir / "vit_model.bin"
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
            for index, (tensor, parent_entry) in enumerate(
                zip(v3.tensor_storage_layout(), parent_entries, strict=True),
                start=1,
            ):
                spec = tensor.spec
                aligned = v3.align_words(cursor_words)
                padding = aligned - cursor_words
                if padding:
                    write_data(out, b"\x00" * (padding * 4))
                    padding_words += padding
                cursor_words = aligned

                parent_start = int(parent_entry["word_offset"]) * 4
                parent_end = parent_start + int(parent_entry["word_count"]) * 4
                parent_bytes = source_map[parent_start:parent_end]
                if (
                    zlib.crc32(parent_bytes) & 0xFFFFFFFF
                ) != int(parent_entry["tensor_crc32"]):
                    raise ValueError(
                        f"parent v2 tensor CRC mismatch: {spec.filename}"
                    )

                if v3.is_weight_b(spec):
                    parent_words = v3.words_from_little_endian(parent_bytes)
                    stored_words = v3.pack_v2_blocked_fp32_to_v3_words(
                        parent_words
                    )
                    stored_bytes = v3.little_endian_u32_bytes(stored_words)
                else:
                    stored_bytes = parent_bytes
                if len(stored_bytes) != tensor.stored_words * 4:
                    raise RuntimeError(
                        f"stored extent mismatch: {spec.filename}"
                    )

                write_data(out, stored_bytes)
                tensor_crc = zlib.crc32(stored_bytes) & 0xFFFFFFFF
                tensor_sha = hashlib.sha256(stored_bytes).hexdigest()
                parent_sha = hashlib.sha256(parent_bytes).hexdigest()
                blocked = v3.is_weight_b(spec)
                entries.append(
                    {
                        "tensor_id": spec.tensor_id,
                        "group": spec.group,
                        "layer": spec.layer,
                        "slot": spec.slot,
                        "role": spec.role,
                        "filename": spec.filename,
                        "name_hash_fnv1a64": (
                            f"0x{v3.v1.fnv1a64(spec.filename):016X}"
                        ),
                        "word_offset": cursor_words,
                        "byte_offset": cursor_words * 4,
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
                        "tensor_crc32": f"0x{tensor_crc:08X}",
                        "tensor_sha256": tensor_sha,
                        "parent_v2_tensor_sha256": parent_sha,
                    }
                )
                cursor_words += tensor.stored_words
                print(
                    f"[{index:03d}/200] offset=0x{aligned:08X} "
                    f"words={tensor.stored_words:9d} "
                    f"layout={v3.layout_name(tensor.layout)} {spec.filename}"
                )
        finally:
            source_map.close()
        out.flush()
        os.fsync(out.fileno())

    if cursor_words != v3.EXPECTED_STORAGE_WORDS:
        raise RuntimeError(
            f"v3 storage words {cursor_words} != {v3.EXPECTED_STORAGE_WORDS}"
        )
    if padding_words != v3.EXPECTED_PADDING_WORDS:
        raise RuntimeError(
            f"v3 padding words {padding_words} != {v3.EXPECTED_PADDING_WORDS}"
        )
    if output_path.stat().st_size != v3.EXPECTED_MODEL_BYTES:
        raise RuntimeError("v3 model byte size is not canonical")
    return entries, {
        "path": output_path.name,
        "logical_source_elements": v3.v1.EXPECTED_SOURCE_WORDS,
        "blocked_fp16_elements": v3.EXPECTED_BLOCKED_FP16_ELEMENTS,
        "blocked_storage_words": v3.EXPECTED_BLOCKED_STORAGE_WORDS,
        "unchanged_fp32_words": v3.EXPECTED_UNCHANGED_FP32_WORDS,
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
    for entry, tensor in zip(entries, v3.tensor_storage_layout(), strict=True):
        spec = tensor.spec
        chunks.append(
            v3.v1.TABLE_ENTRY_STRUCT.pack(
                spec.tensor_id,
                spec.group,
                spec.layer,
                spec.slot,
                v3.v1.fnv1a64(spec.filename),
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
    table_bytes = v3.v1.TABLE_HEADER_BYTES + len(entries_blob)
    values = (
        v3.v1.TABLE_MAGIC,
        v3.TABLE_MAJOR,
        v3.TABLE_MINOR,
        v3.v1.TABLE_HEADER_BYTES,
        v3.v1.TABLE_ENDIAN_LITTLE,
        v3.TABLE_DTYPE_MIXED_BY_ENTRY,
        v3.v1.EXPECTED_TENSOR_COUNT,
        v3.v1.TABLE_ENTRY_BYTES,
        v3.ALIGNMENT_BYTES,
        v3.TABLE_FLAGS,
        v3.v1.TABLE_HEADER_BYTES,
        table_bytes,
        v3.v1.EXPECTED_SOURCE_WORDS,
        v3.EXPECTED_STORAGE_WORDS,
        v3.EXPECTED_MODEL_BYTES,
        int(model["crc32"]),
        entries_crc,
        0,
        v3.v1.TABLE_CRC32_ISO_HDLC,
        bytes.fromhex(str(model["sha256"])),
    )
    zero_header = v3.v1.TABLE_HEADER_STRUCT.pack(*values)
    header_crc = zlib.crc32(zero_header) & 0xFFFFFFFF
    values = (*values[:17], header_crc, *values[18:])
    path = work_dir / "vit_model_table.bin"
    path.write_bytes(v3.v1.TABLE_HEADER_STRUCT.pack(*values) + entries_blob)
    result = v3.checksum(path)
    result.update(
        {
            "header_crc32": f"0x{header_crc:08X}",
            "entries_crc32": f"0x{entries_crc:08X}",
        }
    )
    return result


def offset_maps(
    entries: list[dict[str, object]],
) -> tuple[dict[str, int], list[dict[str, int]]]:
    globals_map = {
        str(entry["role"]): int(entry["word_offset"])
        for entry in entries
        if int(entry["layer"]) == v3.v1.GLOBAL_LAYER_SENTINEL
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
    parser.add_argument("--v2-package", type=Path, default=DEFAULT_V2)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    parent_dir = args.v2_package.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        raise SystemExit(
            f"refusing to overwrite existing output directory: {output_dir}"
        )
    output_dir.parent.mkdir(parents=True, exist_ok=True)

    parent = v3.verify_parent_v2(parent_dir)
    parent_entries = v3.parse_parent_v2_table(parent_dir, parent)
    converter_checks = v3.verify_vector_converter()
    print(
        "PASS parent package v2: pinned hashes and 200 table entries; "
        f"exact converter checks={converter_checks}"
    )

    temporary = Path(
        tempfile.mkdtemp(prefix=output_dir.name + ".tmp.", dir=output_dir.parent)
    )
    try:
        entries, model = pack_model(
            parent_dir, temporary, parent_entries
        )
        table = pack_table(temporary, entries, model)
        shutil.copyfile(
            parent_dir / "prepared_input.bin",
            temporary / "prepared_input.bin",
        )
        prepared_input = v3.checksum(temporary / "prepared_input.bin")
        globals_map, layers_map = offset_maps(entries)

        table_json = {
            "schema": v3.PACKAGE_SCHEMA,
            "address_unit": "U32_STORAGE_WORD",
            "byte_order": "LITTLE_ENDIAN",
            "header_dtype": "MIXED_BY_ENTRY",
            "alignment_bytes": v3.ALIGNMENT_BYTES,
            "source_words_field_semantics": "LOGICAL_SOURCE_SCALAR_COUNT",
            "quantization": {
                "source": "IEEE754_BINARY32_RAW_BITS",
                "target": "IEEE754_BINARY16",
                "rounding": "ROUND_TO_NEAREST_TIES_TO_EVEN",
                "underflow": "GRADUAL",
                "nan": "CANONICAL_POSITIVE_QNAN_0x7E00",
                "scope": "PERSISTENT_WEIGHT_B_ONLY",
            },
            "blocked_layout": {
                "order": ["N_TILE", "K_CHUNK", "LANE", "COL"],
                "block_k": v3.BLOCK_K,
                "block_n": v3.BLOCK_N,
                "fp16_elements_per_block": v3.BLOCK_FP16_ELEMENTS,
                "packed_halves_per_word": v3.PACKED_HALVES_PER_WORD,
                "block_storage_words": v3.BLOCK_STORAGE_WORDS,
                "block_bytes": v3.BLOCK_BYTES,
                "u32_low_half": "COL_0",
                "u32_high_half": "COL_1",
                "required_model_base_alignment_bytes": v3.ALIGNMENT_BYTES,
            },
            "parent_v2": parent,
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
            "schema": v3.RUNTIME_SCHEMA,
            "package_schema": v3.PACKAGE_SCHEMA,
            "address_unit": "U32_STORAGE_WORD",
            "physical_ddr_bases_included": False,
            "source_of_truth": "vit_model_table.bin",
            "execution_mode": v3.EXECUTION_MODE_BLOCKED_B_FP16_PACKED2,
            "execution_mode_bits": {
                "blocked_b_k16_n2": 0,
                "fp16_weight_b_packed2": 1,
            },
            "model_words": v3.EXPECTED_STORAGE_WORDS,
            "input_words": v3.v1.EXPECTED_INPUT_WORDS,
            "scratch_words": v3.EXPECTED_SCRATCH_WORDS,
            "memory_word_counts": {
                "model": v3.EXPECTED_STORAGE_WORDS,
                "input": v3.v1.EXPECTED_INPUT_WORDS,
                "scratch": v3.EXPECTED_SCRATCH_WORDS,
            },
            "memory_storage_dtypes": {
                "model": "MIXED_BY_TABLE_ENTRY",
                "input": "IEEE754_BINARY32_RAW_BITS",
                "scratch": "IEEE754_BINARY32_RAW_BITS",
            },
            "required_model_base_alignment_bytes": v3.ALIGNMENT_BYTES,
            "model_b_layout": (
                "GEMM_B_BLOCKED_K16_N2_FP16_PACKED2_LANE_COL"
            ),
            "model_b_element_dtype": "IEEE754_BINARY16_RNE_GRADUAL",
            "model_b_packed_halves_per_word": v3.PACKED_HALVES_PER_WORD,
            "model_b_block_storage_words": v3.BLOCK_STORAGE_WORDS,
            "blocked_weight_tensor_count": v3.EXPECTED_BLOCKED_TENSORS,
            "input_storage_fp32": True,
            "scratch_storage_fp32": True,
            "row_major_scratch_gemm_b": True,
            "fp32_to_fp16_activation_conversion_at_gemm_ingress": True,
            "global_offsets": globals_map,
            "layer_offsets": layers_map,
        }
        write_json(temporary / "vit_runtime_config.json", runtime)

        manifest_files = [
            v3.checksum(temporary / name)
            for name in (
                "vit_model.bin",
                "vit_model_table.bin",
                "prepared_input.bin",
                "vit_model_table.json",
                "vit_runtime_config.json",
            )
        ]
        manifest = {
            "schema": v3.HASH_MANIFEST_SCHEMA,
            "parent_v2_hash_manifest_sha256": (
                v3.EXPECTED_PARENT_HASH_MANIFEST_SHA256
            ),
            "files": manifest_files,
        }
        write_json(temporary / "hash_manifest.json", manifest)
        os.replace(temporary, output_dir)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    print(
        "PASS package v3: 200 tensors, 74 FP16 packed blocked GEMM-B, "
        "126 byte-exact FP32"
    )
    print(f"MODEL_WORDS={v3.EXPECTED_STORAGE_WORDS}")
    print(f"MODEL_SHA256={model['sha256']}")
    print(f"TABLE_SHA256={table['sha256']}")
    print(f"INPUT_SHA256={prepared_input['sha256']}")
    print(f"OUTPUT_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
