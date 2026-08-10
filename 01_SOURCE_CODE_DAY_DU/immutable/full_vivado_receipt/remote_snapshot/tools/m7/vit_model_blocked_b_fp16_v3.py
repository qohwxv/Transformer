#!/usr/bin/env python3
"""M7 package-v3 schema, exact FP16 conversion, and packing helpers.

Package v3 keeps the v1/v2 32-bit storage-address ABI.  Only persistent
GEMM-B tensors are quantized to binary16 and packed two values per u32.  One
K16/N2 block is stored as ``[LANE][COL]`` so the low/high halfwords of each
u32 are column 0/1 for one reduction lane.
"""

from __future__ import annotations

import hashlib
import json
import random
import sys
import zlib
from array import array
from dataclasses import dataclass
from pathlib import Path

import numpy as np


THIS_DIR = Path(__file__).resolve().parent
M3_DIR = THIS_DIR.parent / "m3"
if str(M3_DIR) not in sys.path:
    sys.path.insert(0, str(M3_DIR))

import vit_model_blocked_b_v2 as v2  # noqa: E402
import vit_model_schema_v1 as v1  # noqa: E402


PACKAGE_SCHEMA = "vit-model-package-v3-blocked-b-fp16-mixed"
HASH_MANIFEST_SCHEMA = "vit-model-package-hashes-v3-blocked-b-fp16-mixed"
VERIFICATION_SCHEMA = (
    "vit-model-package-verification-v3-blocked-b-fp16-mixed"
)
RUNTIME_SCHEMA = "vit-runtime-config-v3-blocked-b-fp16-mixed"

EXPECTED_PARENT_HASH_MANIFEST_SHA256 = (
    "d5686ff0b19b9703817744affdb0ee89a1ca65dda8af64e68e7712fc83570d18"
)
EXPECTED_PARENT_FILES = {
    "vit_model.bin": {
        "size_bytes": 346_270_720,
        "crc32": "0x58FD6BC1",
        "sha256": (
            "7185df10b292534128c1a94bf211e498fe9a8bfc04975fc2eeaed29140fc7835"
        ),
    },
    "vit_model_table.bin": {
        "size_bytes": 12_928,
        "crc32": "0x0FBE1D21",
        "sha256": (
            "efb9a40ec02f956f1b73630162333495d92b6db614af52ce9942d32e1c31e6cf"
        ),
    },
    "prepared_input.bin": {
        "size_bytes": 602_112,
        "crc32": "0xA22E4176",
        "sha256": (
            "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54"
        ),
    },
    "vit_model_table.json": {
        "size_bytes": 181_517,
        "crc32": "0x7450C024",
        "sha256": (
            "d0c57dcec4b40082d2f48287c724547cea2c2897d6dbf09da5280f11f2bf683d"
        ),
    },
    "vit_runtime_config.json": {
        "size_bytes": 7_334,
        "crc32": "0x520353F5",
        "sha256": (
            "318ddb74cdf586a5d936c0684ee62d1c251447a878a8e7720225425cf6baa6a7"
        ),
    },
}

TABLE_MAJOR = 3
TABLE_MINOR = 0
TABLE_DTYPE_MIXED_BY_ENTRY = 2
TABLE_FLAGS = v1.TABLE_FLAGS
ALIGNMENT_BYTES = 128
ALIGNMENT_WORDS = ALIGNMENT_BYTES // 4

LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2 = 5
FLAG_FP16_PACKED2 = 1 << 8

# bit 0 retains the v2 blocked-B selection; bit 1 selects FP16 packed model B.
EXECUTION_MODE_BLOCKED_B_FP16_PACKED2 = (
    v2.EXECUTION_MODE_BLOCKED_B_K16_N2 | (1 << 1)
)

BLOCK_K = 16
BLOCK_N = 2
BLOCK_FP16_ELEMENTS = BLOCK_K * BLOCK_N
PACKED_HALVES_PER_WORD = 2
BLOCK_STORAGE_WORDS = BLOCK_FP16_ELEMENTS // PACKED_HALVES_PER_WORD
BLOCK_BYTES = BLOCK_STORAGE_WORDS * 4
EXPECTED_SCRATCH_WORDS = v2.EXPECTED_SCRATCH_WORDS

FP16_CANONICAL_QNAN = 0x7E00
FP16_POS_INF = 0x7C00
FP16_NEG_INF = 0xFC00


@dataclass(frozen=True)
class DecodedBinary:
    kind: str
    sign: int
    significand: int = 0
    exponent2: int = 0


@dataclass(frozen=True)
class StoredTensor:
    spec: v1.TensorSpec
    layout: int
    flags: int
    stored_words: int
    stored_shape: tuple[int, ...]
    storage_word_shape: tuple[int, ...]
    element_dtype: str


def _check_unsigned_bits(value: int, width: int, name: str) -> int:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an int")
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{name} must fit in {width} bits")
    return value


def _round_shift_right_rne(value: int, shift: int) -> int:
    if value < 0:
        raise ValueError("rounding helper accepts only non-negative values")
    if shift <= 0:
        return value << (-shift)
    quotient, remainder = divmod(value, 1 << shift)
    halfway = 1 << (shift - 1)
    if remainder > halfway or (remainder == halfway and (quotient & 1)):
        quotient += 1
    return quotient


def _scale_integer_rne(value: int, binary_shift: int) -> int:
    if binary_shift >= 0:
        return value << binary_shift
    return _round_shift_right_rne(value, -binary_shift)


def _encode_finite_binary(
    sign: int,
    significand: int,
    exponent2: int,
    *,
    exponent_bits: int,
    fraction_bits: int,
    bias: int,
) -> int:
    """Faithful copy of the M6 integer IEEE RNE encoder."""

    if sign not in (0, 1):
        raise ValueError("sign must be zero or one")
    if significand < 0:
        raise ValueError("significand must be non-negative")
    sign_field_shift = exponent_bits + fraction_bits
    sign_field = sign << sign_field_shift
    if significand == 0:
        return sign_field

    max_exponent_field = (1 << exponent_bits) - 1
    min_normal_exponent = 1 - bias
    max_normal_exponent = (max_exponent_field - 1) - bias
    precision = fraction_bits + 1
    leading_exponent = significand.bit_length() - 1 + exponent2

    if leading_exponent >= min_normal_exponent:
        if leading_exponent > max_normal_exponent:
            return sign_field | (max_exponent_field << fraction_bits)
        retained = _scale_integer_rne(
            significand,
            exponent2 - leading_exponent + fraction_bits,
        )
        if retained == (1 << precision):
            retained >>= 1
            leading_exponent += 1
            if leading_exponent > max_normal_exponent:
                return sign_field | (max_exponent_field << fraction_bits)
        exponent_field = leading_exponent + bias
        fraction_field = retained - (1 << fraction_bits)
        return sign_field | (exponent_field << fraction_bits) | fraction_field

    subnormal = _scale_integer_rne(
        significand,
        exponent2 - min_normal_exponent + fraction_bits,
    )
    if subnormal == 0:
        return sign_field
    if subnormal >= (1 << fraction_bits):
        return sign_field | (1 << fraction_bits)
    return sign_field | subnormal


def decode_fp32(bits: int) -> DecodedBinary:
    bits = _check_unsigned_bits(bits, 32, "binary32 bits")
    sign = (bits >> 31) & 1
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    if exponent == 0xFF:
        return DecodedBinary("nan" if fraction else "inf", sign)
    if exponent == 0:
        if fraction == 0:
            return DecodedBinary("zero", sign)
        return DecodedBinary("finite", sign, fraction, -149)
    return DecodedBinary("finite", sign, 0x800000 | fraction, exponent - 150)


def fp32_bits_to_fp16_bits(bits: int) -> int:
    """M6-authoritative FP32-to-FP16 RNE conversion with gradual underflow."""

    decoded = decode_fp32(bits)
    if decoded.kind == "nan":
        return FP16_CANONICAL_QNAN
    if decoded.kind == "inf":
        return FP16_NEG_INF if decoded.sign else FP16_POS_INF
    if decoded.kind == "zero":
        return decoded.sign << 15
    return _encode_finite_binary(
        decoded.sign,
        decoded.significand,
        decoded.exponent2,
        exponent_bits=5,
        fraction_bits=10,
        bias=15,
    )


def fp32_array_to_fp16_bits(words: np.ndarray) -> np.ndarray:
    """Vectorized integer translation of :func:`fp32_bits_to_fp16_bits`."""

    source = np.asarray(words, dtype="<u4")
    flat = source.reshape(-1)
    sign = ((flat >> np.uint32(16)) & np.uint32(0x8000)).astype(np.uint16)
    exponent = ((flat >> np.uint32(23)) & np.uint32(0xFF)).astype(np.int16)
    fraction = flat & np.uint32(0x7FFFFF)
    result = sign.copy()

    special = exponent == 0xFF
    infinity = special & (fraction == 0)
    nan = special & (fraction != 0)
    result[infinity] |= np.uint16(0x7C00)
    result[nan] = np.uint16(FP16_CANONICAL_QNAN)

    normal_source = (exponent != 0) & ~special
    unbiased = exponent.astype(np.int32) - 127
    significand = (fraction | np.uint32(0x800000)).astype(np.uint64)

    target_normal = normal_source & (unbiased >= -14) & (unbiased <= 15)
    if np.any(target_normal):
        sig = significand[target_normal]
        quotient = sig >> np.uint64(13)
        remainder = sig & np.uint64(0x1FFF)
        increment = (remainder > np.uint64(0x1000)) | (
            (remainder == np.uint64(0x1000)) & ((quotient & 1) != 0)
        )
        quotient = quotient + increment.astype(np.uint64)
        target_exponent = unbiased[target_normal].astype(np.int32) + 15
        carry = quotient == np.uint64(0x800)
        quotient[carry] = np.uint64(0x400)
        target_exponent[carry] += 1
        encoded = (
            (target_exponent.astype(np.uint32) << np.uint32(10))
            | (quotient.astype(np.uint32) - np.uint32(0x400))
        )
        overflow = target_exponent >= 31
        encoded[overflow] = np.uint32(0x7C00)
        result[target_normal] |= encoded.astype(np.uint16)

    target_subnormal = normal_source & (unbiased >= -25) & (unbiased <= -15)
    if np.any(target_subnormal):
        sig = significand[target_subnormal]
        shift = (-unbiased[target_subnormal] - 1).astype(np.uint64)
        quotient = np.right_shift(sig, shift)
        remainder = sig - np.left_shift(quotient, shift)
        halfway = np.left_shift(np.ones_like(shift, dtype=np.uint64), shift - 1)
        increment = (remainder > halfway) | (
            (remainder == halfway) & ((quotient & 1) != 0)
        )
        quotient = quotient + increment.astype(np.uint64)
        quotient = np.minimum(quotient, np.uint64(0x400))
        result[target_subnormal] |= quotient.astype(np.uint16)

    # Exponents above the finite FP16 range overflow to infinity.  FP32
    # subnormals and normal values below the half-way threshold retain only
    # their sign, which also preserves signed zero.
    overflow = normal_source & (unbiased > 15)
    result[overflow] |= np.uint16(0x7C00)
    return result.reshape(source.shape)


def verify_vector_converter(seed: int = 0x4D37504B, random_words: int = 100_000) -> int:
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
    actual = fp32_array_to_fp16_bits(np.asarray(values, dtype="<u4"))
    for index, (word, got) in enumerate(zip(values, actual, strict=True)):
        expected = fp32_bits_to_fp16_bits(word)
        if int(got) != expected:
            raise ValueError(
                f"vector FP16 mismatch index={index} fp32=0x{word:08X} "
                f"got=0x{int(got):04X} expected=0x{expected:04X}"
            )
    return len(values)


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
            storage_word_shape=spec.shape,
            element_dtype="IEEE754_BINARY32_RAW_BITS",
        )
    if len(spec.shape) != 2:
        raise ValueError(f"blocked-B tensor must be rank 2: {spec.filename}")
    reduction, columns = spec.shape
    n_tiles = ceil_div(columns, BLOCK_N)
    k_chunks = ceil_div(reduction, BLOCK_K)
    fp16_elements = n_tiles * k_chunks * BLOCK_FP16_ELEMENTS
    if fp16_elements % PACKED_HALVES_PER_WORD:
        raise AssertionError("blocked FP16 extent is not packable into u32")
    return StoredTensor(
        spec=spec,
        layout=LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2,
        flags=(spec.flags | v2.FLAG_BLOCKED_B_K16_N2 | FLAG_FP16_PACKED2),
        stored_words=fp16_elements // PACKED_HALVES_PER_WORD,
        stored_shape=(n_tiles, k_chunks, BLOCK_K, BLOCK_N),
        storage_word_shape=(n_tiles, k_chunks, BLOCK_K),
        element_dtype="IEEE754_BINARY16_RNE_GRADUAL",
    )


def tensor_storage_layout() -> tuple[StoredTensor, ...]:
    return tuple(stored_tensor(spec) for spec in v1.tensor_specs())


def pack_v2_blocked_fp32_to_v3_words(parent_words: np.ndarray) -> np.ndarray:
    """Convert v2 ``[COL][LANE]`` FP32 blocks to v3 ``[LANE][COL]`` u32."""

    values = np.asarray(parent_words, dtype="<u4").reshape(-1)
    if values.size % BLOCK_FP16_ELEMENTS:
        raise ValueError("v2 blocked tensor extent is not a whole K16/N2 block")
    halves = fp32_array_to_fp16_bits(values).reshape(-1, BLOCK_N, BLOCK_K)
    low = halves[:, 0, :].astype(np.uint32)
    high = halves[:, 1, :].astype(np.uint32)
    return np.asarray(low | (high << np.uint32(16)), dtype="<u4").reshape(-1)


def unpack_v3_words_to_v2_half_order(packed_words: np.ndarray) -> np.ndarray:
    words = np.asarray(packed_words, dtype="<u4").reshape(-1)
    if words.size % BLOCK_STORAGE_WORDS:
        raise ValueError("v3 blocked tensor extent is not a whole K16/N2 block")
    blocks = words.reshape(-1, BLOCK_K)
    halves = np.empty((blocks.shape[0], BLOCK_N, BLOCK_K), dtype="<u2")
    halves[:, 0, :] = (blocks & np.uint32(0xFFFF)).astype(np.uint16)
    halves[:, 1, :] = (blocks >> np.uint32(16)).astype(np.uint16)
    return halves.reshape(-1)


def packed_word_index(
    reduction_index: int,
    column_index: int,
    reduction: int,
    columns: int,
) -> tuple[int, int]:
    if not 0 <= reduction_index < reduction:
        raise IndexError("reduction index outside logical tensor")
    if not 0 <= column_index < columns:
        raise IndexError("column index outside logical tensor")
    k_chunks = ceil_div(reduction, BLOCK_K)
    n_tile, col = divmod(column_index, BLOCK_N)
    k_chunk, lane = divmod(reduction_index, BLOCK_K)
    word_index = ((n_tile * k_chunks + k_chunk) * BLOCK_K) + lane
    return word_index, col


def block_fits_4k(word_offset: int) -> bool:
    byte_offset = word_offset * 4
    return (byte_offset & 0xFFF) <= 4096 - BLOCK_BYTES


def expected_storage_words() -> int:
    cursor = 0
    for tensor in tensor_storage_layout():
        cursor = align_words(cursor)
        cursor += tensor.stored_words
    return cursor


EXPECTED_BLOCKED_TENSORS = sum(
    1 for tensor in tensor_storage_layout() if is_weight_b(tensor.spec)
)
EXPECTED_BLOCKED_FP16_ELEMENTS = sum(
    v2.stored_tensor(tensor.spec).stored_words
    for tensor in tensor_storage_layout()
    if is_weight_b(tensor.spec)
)
EXPECTED_BLOCKED_STORAGE_WORDS = sum(
    tensor.stored_words
    for tensor in tensor_storage_layout()
    if is_weight_b(tensor.spec)
)
EXPECTED_UNCHANGED_FP32_WORDS = sum(
    tensor.stored_words
    for tensor in tensor_storage_layout()
    if not is_weight_b(tensor.spec)
)
EXPECTED_STORAGE_WORDS = expected_storage_words()
EXPECTED_MODEL_BYTES = EXPECTED_STORAGE_WORDS * 4
EXPECTED_PADDING_WORDS = EXPECTED_STORAGE_WORDS - sum(
    tensor.stored_words for tensor in tensor_storage_layout()
)
EXPECTED_BLOCK_COUNT = EXPECTED_BLOCKED_FP16_ELEMENTS // BLOCK_FP16_ELEMENTS

assert EXPECTED_BLOCKED_TENSORS == 74
assert EXPECTED_BLOCKED_FP16_ELEMENTS == 86_292_480
assert EXPECTED_BLOCKED_STORAGE_WORDS == 43_146_240
assert EXPECTED_UNCHANGED_FP32_WORDS == 275_176
assert EXPECTED_PADDING_WORDS == 24
assert EXPECTED_STORAGE_WORDS == 43_421_440
assert EXPECTED_MODEL_BYTES == 173_685_760
assert EXPECTED_BLOCK_COUNT == 2_696_640


def parse_crc32(value: object) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 0)
    raise ValueError(f"invalid CRC32 value: {value!r}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checksum(path: Path) -> dict[str, object]:
    crc32 = 0
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            size += len(chunk)
            crc32 = zlib.crc32(chunk, crc32)
            digest.update(chunk)
    return {
        "path": path.name,
        "size_bytes": size,
        "crc32": f"0x{crc32 & 0xFFFFFFFF:08X}",
        "sha256": digest.hexdigest(),
    }


def verify_parent_v2(package_dir: Path) -> dict[str, object]:
    manifest_path = package_dir / "hash_manifest.json"
    if sha256_file(manifest_path) != EXPECTED_PARENT_HASH_MANIFEST_SHA256:
        raise ValueError("parent hash_manifest.json is not canonical v2")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != v2.HASH_MANIFEST_SCHEMA:
        raise ValueError("parent package hash manifest schema is not v2")
    declared = {
        str(entry["path"]): entry for entry in manifest.get("files", [])
    }
    if set(declared) != set(EXPECTED_PARENT_FILES):
        raise ValueError("parent v2 manifest file set is not canonical")
    files: dict[str, dict[str, object]] = {}
    for filename, pinned in EXPECTED_PARENT_FILES.items():
        actual = checksum(package_dir / filename)
        declared_entry = declared[filename]
        if not (
            actual["size_bytes"] == pinned["size_bytes"]
            == declared_entry.get("size_bytes")
            and actual["sha256"] == pinned["sha256"]
            == declared_entry.get("sha256")
            and parse_crc32(actual["crc32"])
            == parse_crc32(pinned["crc32"])
            == parse_crc32(declared_entry.get("crc32"))
        ):
            raise ValueError(f"parent v2 checksum mismatch: {filename}")
        files[filename] = actual
    return {
        "schema": v2.PACKAGE_SCHEMA,
        "hash_manifest_sha256": EXPECTED_PARENT_HASH_MANIFEST_SHA256,
        "files": files,
    }


def parse_parent_v2_table(
    package_dir: Path,
    parent: dict[str, object],
) -> list[dict[str, int]]:
    data = (package_dir / "vit_model_table.bin").read_bytes()
    expected_bytes = v1.TABLE_HEADER_BYTES + 200 * v1.TABLE_ENTRY_BYTES
    if len(data) != expected_bytes:
        raise ValueError("parent v2 table size is not canonical")
    header = list(v1.TABLE_HEADER_STRUCT.unpack_from(data, 0))
    model = parent["files"]["vit_model.bin"]
    expected_header = (
        (header[0], v1.TABLE_MAGIC),
        ((header[1], header[2]), (v2.TABLE_MAJOR, v2.TABLE_MINOR)),
        (header[3], v1.TABLE_HEADER_BYTES),
        (header[4], v1.TABLE_ENDIAN_LITTLE),
        (header[5], v1.TABLE_DTYPE_FP32_BITS),
        (header[6], 200),
        (header[7], v1.TABLE_ENTRY_BYTES),
        (header[8], v2.ALIGNMENT_BYTES),
        (header[9], v2.TABLE_FLAGS),
        (header[10], v1.TABLE_HEADER_BYTES),
        (header[11], expected_bytes),
        (header[12], v1.EXPECTED_SOURCE_WORDS),
        (header[13], v2.EXPECTED_STORAGE_WORDS),
        (header[14], v2.EXPECTED_MODEL_BYTES),
        (header[15], parse_crc32(model["crc32"])),
        (header[18], v1.TABLE_CRC32_ISO_HDLC),
        (header[19].hex(), model["sha256"]),
    )
    if any(actual != expected for actual, expected in expected_header):
        raise ValueError("parent v2 table header is not canonical")
    entries_blob = data[v1.TABLE_HEADER_BYTES :]
    if header[16] != (zlib.crc32(entries_blob) & 0xFFFFFFFF):
        raise ValueError("parent v2 entries CRC32 mismatch")
    header_zero_crc = header.copy()
    header_zero_crc[17] = 0
    if header[17] != (
        zlib.crc32(v1.TABLE_HEADER_STRUCT.pack(*header_zero_crc))
        & 0xFFFFFFFF
    ):
        raise ValueError("parent v2 header CRC32 mismatch")

    entries: list[dict[str, int]] = []
    cursor = 0
    for index, tensor in enumerate(v2.tensor_storage_layout()):
        fields = v1.TABLE_ENTRY_STRUCT.unpack_from(
            entries_blob, index * v1.TABLE_ENTRY_BYTES
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
        cursor = v2.align_words(cursor)
        spec = tensor.spec
        expected = {
            "tensor_id": spec.tensor_id,
            "group": spec.group,
            "layer": spec.layer,
            "slot": spec.slot,
            "name_hash": v1.fnv1a64(spec.filename),
            "word_offset": cursor,
            "word_count": tensor.stored_words,
            "rank": spec.rank,
            "layout": tensor.layout,
            "dims": spec.padded_shape,
            "flags": tensor.flags,
        }
        if any(entry[key] != value for key, value in expected.items()):
            raise ValueError(f"parent v2 table mismatch: {spec.filename}")
        entries.append(entry)
        cursor += tensor.stored_words
    if cursor != v2.EXPECTED_STORAGE_WORDS:
        raise ValueError("parent v2 storage extent is not canonical")
    return entries


def layout_name(layout: int) -> str:
    if layout == LAYOUT_GEMM_B_BLOCKED_K16_N2_FP16_PACKED2:
        return "GEMM_B_BLOCKED_K16_N2_FP16_PACKED2"
    return v1.layout_name(layout)


def little_endian_u32_bytes(words: np.ndarray) -> bytes:
    return np.asarray(words, dtype="<u4").tobytes()


def words_from_little_endian(data: bytes) -> np.ndarray:
    if len(data) % 4:
        raise ValueError("payload is not u32 aligned")
    return np.frombuffer(data, dtype="<u4")


def array_u32(values: list[int]) -> array:
    result = array("I", values)
    if result.itemsize != 4:
        raise RuntimeError("host array('I') is not 32 bits")
    return result
