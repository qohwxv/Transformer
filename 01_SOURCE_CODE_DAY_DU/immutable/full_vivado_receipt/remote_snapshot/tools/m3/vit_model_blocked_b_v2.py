#!/usr/bin/env python3
"""Shared schema and bit-exact transforms for blocked-B FP32 package v2."""

from __future__ import annotations

import sys
from array import array
from dataclasses import dataclass

import vit_model_schema_v1 as v1


PACKAGE_SCHEMA = "vit-model-package-v2-blocked-b-fp32"
HASH_MANIFEST_SCHEMA = "vit-model-package-hashes-v2-blocked-b-fp32"
VERIFICATION_SCHEMA = "vit-model-package-verification-v2-blocked-b-fp32"

# M3 is a revision of this exact, already verified package-v1 baseline.  Pin
# the payload identities so an internally self-consistent but different model
# or input cannot silently become the parent of a claimed M3 A/B artifact.
EXPECTED_PARENT_HASH_MANIFEST_SHA256 = (
    "12b3b0573f006f49f30fcb25a17d22f846a4f35ea7add1a1733be176b853a982"
)
EXPECTED_PARENT_FILES = {
    "vit_model.bin": {
        "size_bytes": 346_270_656,
        "crc32": "0xE79BE4BE",
        "sha256": "b573df09083b643150b2bdda990aec9f79ea8e51ded41980422f1534ffc8800e",
    },
    "vit_model_table.bin": {
        "size_bytes": 12_928,
        "crc32": "0xF16E1311",
        "sha256": "6af25a98b2dfca525f8320bdd422cae31f3441dd407fa6cd507f02ef344b6380",
    },
    "prepared_input.bin": {
        "size_bytes": 602_112,
        "crc32": "0xA22E4176",
        "sha256": "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54",
    },
}

TABLE_MAJOR = 2
TABLE_MINOR = 0
ALIGNMENT_BYTES = 128
ALIGNMENT_WORDS = ALIGNMENT_BYTES // 4
# Header feature bits retain their v1 meanings.  Package major version 2,
# layout ID 4, and the per-entry flag below identify the blocked payload.
TABLE_FLAGS = v1.TABLE_FLAGS

LAYOUT_GEMM_B_BLOCKED_K16_N2 = 4
FLAG_BLOCKED_B_K16_N2 = 1 << 7
EXECUTION_MODE_BLOCKED_B_K16_N2 = 1 << 0

BLOCK_K = 16
BLOCK_N = 2
BLOCK_WORDS = BLOCK_K * BLOCK_N
BLOCK_BYTES = BLOCK_WORDS * 4
EXPECTED_SCRATCH_WORDS = 0x001E_6000


@dataclass(frozen=True)
class StoredTensor:
    spec: v1.TensorSpec
    layout: int
    flags: int
    stored_words: int
    stored_shape: tuple[int, ...]


def ceil_div(value: int, divisor: int) -> int:
    if value < 0 or divisor <= 0:
        raise ValueError("ceil_div requires value >= 0 and divisor > 0")
    return (value + divisor - 1) // divisor


def align_words(word_offset: int) -> int:
    return (word_offset + ALIGNMENT_WORDS - 1) & ~(ALIGNMENT_WORDS - 1)


def is_weight_b(spec: v1.TensorSpec) -> bool:
    return bool(spec.flags & v1.FLAG_WEIGHT_B)


def stored_tensor(spec: v1.TensorSpec) -> StoredTensor:
    if not is_weight_b(spec):
        return StoredTensor(
            spec=spec,
            layout=spec.layout,
            flags=spec.flags,
            stored_words=spec.word_count,
            stored_shape=spec.shape,
        )
    if len(spec.shape) != 2:
        raise ValueError(f"blocked-B tensor must be rank 2: {spec.filename}")
    reduction, columns = spec.shape
    n_tiles = ceil_div(columns, BLOCK_N)
    k_chunks = ceil_div(reduction, BLOCK_K)
    return StoredTensor(
        spec=spec,
        layout=LAYOUT_GEMM_B_BLOCKED_K16_N2,
        flags=spec.flags | FLAG_BLOCKED_B_K16_N2,
        stored_words=n_tiles * k_chunks * BLOCK_WORDS,
        stored_shape=(n_tiles, k_chunks, BLOCK_N, BLOCK_K),
    )


def tensor_storage_layout() -> tuple[StoredTensor, ...]:
    return tuple(stored_tensor(spec) for spec in v1.tensor_specs())


def blocked_word_index(
    reduction_index: int,
    column_index: int,
    reduction: int,
    columns: int,
) -> int:
    if not (0 <= reduction_index < reduction):
        raise IndexError("reduction index outside logical tensor")
    if not (0 <= column_index < columns):
        raise IndexError("column index outside logical tensor")
    k_chunks = ceil_div(reduction, BLOCK_K)
    n_tile, col = divmod(column_index, BLOCK_N)
    k_chunk, lane = divmod(reduction_index, BLOCK_K)
    return (((n_tile * k_chunks + k_chunk) * BLOCK_N + col) * BLOCK_K + lane)


def _require_u32(values: array) -> None:
    if values.typecode != "I" or values.itemsize != 4:
        raise TypeError("blocked-B transforms require array('I') with 32-bit items")


def pack_blocked_b(logical: array, reduction: int, columns: int) -> array:
    """Pack logical row-major [K,N] words as [N_TILE][K_CHUNK][COL][LANE]."""
    _require_u32(logical)
    if len(logical) != reduction * columns:
        raise ValueError("logical word count does not match [K,N]")
    n_tiles = ceil_div(columns, BLOCK_N)
    k_chunks = ceil_div(reduction, BLOCK_K)
    packed = array("I")
    append = packed.append
    for n_tile in range(n_tiles):
        n_base = n_tile * BLOCK_N
        for k_chunk in range(k_chunks):
            k_base = k_chunk * BLOCK_K
            for col in range(BLOCK_N):
                n_index = n_base + col
                for lane in range(BLOCK_K):
                    k_index = k_base + lane
                    if k_index < reduction and n_index < columns:
                        append(logical[k_index * columns + n_index])
                    else:
                        append(0)
    return packed


def unpack_blocked_b(packed: array, reduction: int, columns: int) -> array:
    """Restore logical row-major [K,N] words and discard zero tail padding."""
    _require_u32(packed)
    expected = (
        ceil_div(columns, BLOCK_N)
        * ceil_div(reduction, BLOCK_K)
        * BLOCK_WORDS
    )
    if len(packed) != expected:
        raise ValueError("packed word count does not match blocked geometry")
    logical = array("I", [0]) * (reduction * columns)
    for k_index in range(reduction):
        logical_base = k_index * columns
        for n_index in range(columns):
            logical[logical_base + n_index] = packed[
                blocked_word_index(
                    k_index, n_index, reduction, columns
                )
            ]
    return logical


def words_from_little_endian(data: bytes) -> array:
    if len(data) % 4:
        raise ValueError("FP32 payload byte count is not word aligned")
    values = array("I")
    values.frombytes(data)
    _require_u32(values)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def little_endian_bytes(values: array) -> bytes:
    _require_u32(values)
    if sys.byteorder == "little":
        return values.tobytes()
    copied = array("I", values)
    copied.byteswap()
    return copied.tobytes()


def block_fits_4k(word_offset: int) -> bool:
    byte_offset = word_offset * 4
    return (byte_offset & 0xFFF) <= (4096 - BLOCK_BYTES)


def expected_storage_words() -> int:
    cursor = 0
    for tensor in tensor_storage_layout():
        cursor = align_words(cursor)
        cursor += tensor.stored_words
    return cursor


EXPECTED_STORAGE_WORDS = expected_storage_words()
EXPECTED_MODEL_BYTES = EXPECTED_STORAGE_WORDS * 4
EXPECTED_PADDING_WORDS = (
    EXPECTED_STORAGE_WORDS
    - sum(tensor.stored_words for tensor in tensor_storage_layout())
)
EXPECTED_BLOCKED_TENSORS = sum(
    1 for tensor in tensor_storage_layout() if is_weight_b(tensor.spec)
)

assert EXPECTED_BLOCKED_TENSORS == 74
assert EXPECTED_STORAGE_WORDS == 86_567_680
assert EXPECTED_MODEL_BYTES == 346_270_720
assert EXPECTED_PADDING_WORDS == 24


def layout_name(layout: int) -> str:
    if layout == LAYOUT_GEMM_B_BLOCKED_K16_N2:
        return "GEMM_B_BLOCKED_K16_N2"
    return v1.layout_name(layout)
