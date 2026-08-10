#!/usr/bin/env python3
"""Unit tests for M7 mixed FP32/FP16 blocked-B package v3."""

from __future__ import annotations

import importlib.util
import random
import struct
import sys
import unittest
from array import array
from pathlib import Path

import numpy as np


THIS_DIR = Path(__file__).resolve().parent
M7_DIR = THIS_DIR.parent
if str(M7_DIR) not in sys.path:
    sys.path.insert(0, str(M7_DIR))

import vit_model_blocked_b_fp16_v3 as v3  # noqa: E402


def fp32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", value))[0]


def load_m6_reference():
    for ancestor in THIS_DIR.parents:
        candidate = (
            ancestor
            / "experimental"
            / "m6_fp16_nodsp_ooc"
            / "reference"
            / "m6_fp16_reference.py"
        )
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location(
                "m6_fp16_reference_authority", candidate
            )
            if spec is None or spec.loader is None:
                raise RuntimeError("cannot load M6 FP16 authority")
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            return module
    raise RuntimeError("M6 exact FP16 reference not found from repository tree")


class BlockedBFP16V3Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.m6 = load_m6_reference()

    def test_scalar_conversion_is_faithful_to_m6(self) -> None:
        directed = [
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
        rng = random.Random(0x4D375431)
        words = directed + [rng.getrandbits(32) for _ in range(20_000)]
        for word in words:
            self.assertEqual(
                v3.fp32_bits_to_fp16_bits(word),
                self.m6.fp32_bits_to_fp16_bits(word),
            )

    def test_vector_conversion_matches_exact_scalar(self) -> None:
        self.assertEqual(v3.verify_vector_converter(random_words=20_000), 20_020)

    def test_lane_col_packing_and_little_endian_halves(self) -> None:
        col0 = [fp32_bits(float(lane + 1)) for lane in range(v3.BLOCK_K)]
        col1 = [fp32_bits(float(-(lane + 1))) for lane in range(v3.BLOCK_K)]
        parent = np.asarray(col0 + col1, dtype="<u4")
        packed = v3.pack_v2_blocked_fp32_to_v3_words(parent)
        self.assertEqual(packed.size, v3.BLOCK_STORAGE_WORDS)
        for lane, word in enumerate(packed):
            expected_low = v3.fp32_bits_to_fp16_bits(col0[lane])
            expected_high = v3.fp32_bits_to_fp16_bits(col1[lane])
            self.assertEqual(int(word) & 0xFFFF, expected_low)
            self.assertEqual(int(word) >> 16, expected_high)
        unpacked = v3.unpack_v3_words_to_v2_half_order(packed)
        expected = v3.fp32_array_to_fp16_bits(parent)
        np.testing.assert_array_equal(unpacked, expected)
        raw = packed.astype("<u4").tobytes()
        self.assertEqual(raw[0:2], int(packed[0] & 0xFFFF).to_bytes(2, "little"))
        self.assertEqual(raw[2:4], int(packed[0] >> 16).to_bytes(2, "little"))

    def test_generic_k_n_tail_is_zero_padded(self) -> None:
        reduction, columns = 17, 3
        logical_values = [
            fp32_bits((k + 1) * 0.25 + n)
            for k in range(reduction)
            for n in range(columns)
        ]
        logical = array("I", logical_values)
        parent_v2 = v3.v2.pack_blocked_b(logical, reduction, columns)
        packed = v3.pack_v2_blocked_fp32_to_v3_words(
            np.asarray(parent_v2, dtype="<u4")
        )
        expected_words = (
            v3.ceil_div(columns, v3.BLOCK_N)
            * v3.ceil_div(reduction, v3.BLOCK_K)
            * v3.BLOCK_STORAGE_WORDS
        )
        self.assertEqual(packed.size, expected_words)
        for k in range(reduction):
            for n in range(columns):
                word_index, half_select = v3.packed_word_index(
                    k, n, reduction, columns
                )
                word = int(packed[word_index])
                got = (word >> (16 * half_select)) & 0xFFFF
                expected = v3.fp32_bits_to_fp16_bits(
                    logical_values[k * columns + n]
                )
                self.assertEqual(got, expected)

        # K=17,N=3 leaves K and N tail slots.  Every padded parent-v2 zero
        # must remain an encoded positive half zero after [COL][LANE] to
        # [LANE][COL] transposition.
        parent_halves = v3.fp32_array_to_fp16_bits(
            np.asarray(parent_v2, dtype="<u4")
        )
        actual_halves = v3.unpack_v3_words_to_v2_half_order(packed)
        np.testing.assert_array_equal(actual_halves, parent_halves)
        logical_parent_indices = {
            v3.v2.blocked_word_index(k, n, reduction, columns)
            for k in range(reduction)
            for n in range(columns)
        }
        for index, half in enumerate(actual_halves):
            if index not in logical_parent_indices:
                self.assertEqual(int(half), 0)

    def test_package_geometry(self) -> None:
        tensors = v3.tensor_storage_layout()
        self.assertEqual(len(tensors), 200)
        self.assertEqual(v3.EXPECTED_BLOCKED_TENSORS, 74)
        self.assertEqual(v3.EXPECTED_BLOCKED_FP16_ELEMENTS, 86_292_480)
        self.assertEqual(v3.EXPECTED_BLOCKED_STORAGE_WORDS, 43_146_240)
        self.assertEqual(v3.EXPECTED_UNCHANGED_FP32_WORDS, 275_176)
        self.assertEqual(v3.EXPECTED_PADDING_WORDS, 24)
        self.assertEqual(v3.EXPECTED_STORAGE_WORDS, 43_421_440)
        self.assertEqual(v3.EXPECTED_MODEL_BYTES, 173_685_760)
        self.assertEqual(v3.EXPECTED_BLOCK_COUNT, 2_696_640)
        self.assertEqual(v3.EXPECTED_SCRATCH_WORDS, 1_990_656)

    def test_alignment_prevents_4k_crossing(self) -> None:
        cursor = 0
        blocks = 0
        for tensor in v3.tensor_storage_layout():
            cursor = v3.align_words(cursor)
            self.assertEqual(cursor % v3.ALIGNMENT_WORDS, 0)
            if v3.is_weight_b(tensor.spec):
                self.assertEqual(
                    tensor.stored_words % v3.BLOCK_STORAGE_WORDS, 0
                )
                for block in range(
                    tensor.stored_words // v3.BLOCK_STORAGE_WORDS
                ):
                    self.assertTrue(
                        v3.block_fits_4k(
                            cursor + block * v3.BLOCK_STORAGE_WORDS
                        )
                    )
                    blocks += 1
            cursor += tensor.stored_words
        self.assertEqual(blocks, v3.EXPECTED_BLOCK_COUNT)
        self.assertEqual(cursor, v3.EXPECTED_STORAGE_WORDS)
        self.assertFalse(v3.block_fits_4k(1016))

    def test_parent_v2_identity_is_pinned(self) -> None:
        repo_root = next(
            ancestor
            for ancestor in THIS_DIR.parents
            if (ancestor / "build" / "model_package" / "v2_blocked_b_fp32").is_dir()
        )
        parent_dir = repo_root / "build" / "model_package" / "v2_blocked_b_fp32"
        parent = v3.verify_parent_v2(parent_dir)
        entries = v3.parse_parent_v2_table(parent_dir, parent)
        self.assertEqual(
            parent["hash_manifest_sha256"],
            v3.EXPECTED_PARENT_HASH_MANIFEST_SHA256,
        )
        self.assertEqual(len(entries), 200)


if __name__ == "__main__":
    unittest.main()
