#!/usr/bin/env python3
"""Fast unit tests for M3 blocked-B indexing, tails, and 4 KiB rules."""

from __future__ import annotations

import sys
import unittest
from array import array
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR.parent))

from vit_model_blocked_b_v2 import (  # noqa: E402
    BLOCK_WORDS,
    EXPECTED_BLOCKED_TENSORS,
    EXPECTED_PADDING_WORDS,
    EXPECTED_SCRATCH_WORDS,
    EXPECTED_STORAGE_WORDS,
    align_words,
    block_fits_4k,
    blocked_word_index,
    pack_blocked_b,
    tensor_storage_layout,
    unpack_blocked_b,
)


class BlockedBV2Test(unittest.TestCase):
    def test_small_exact_mapping(self) -> None:
        reduction, columns = 16, 2
        logical = array("I", range(reduction * columns))
        packed = pack_blocked_b(logical, reduction, columns)
        expected = array("I")
        expected.extend(logical[lane * columns] for lane in range(16))
        expected.extend(logical[lane * columns + 1] for lane in range(16))
        self.assertEqual(packed, expected)
        self.assertEqual(unpack_blocked_b(packed, reduction, columns), logical)

    def test_tail_padding_and_roundtrip(self) -> None:
        reduction, columns = 17, 3
        logical = array("I", (0x10000000 + i for i in range(51)))
        packed = pack_blocked_b(logical, reduction, columns)
        self.assertEqual(len(packed), 2 * 2 * BLOCK_WORDS)
        self.assertEqual(unpack_blocked_b(packed, reduction, columns), logical)
        logical_indices = {
            blocked_word_index(k, n, reduction, columns)
            for k in range(reduction)
            for n in range(columns)
        }
        for index, value in enumerate(packed):
            if index not in logical_indices:
                self.assertEqual(value, 0)

    def test_package_geometry(self) -> None:
        tensors = tensor_storage_layout()
        self.assertEqual(len(tensors), 200)
        self.assertEqual(EXPECTED_BLOCKED_TENSORS, 74)
        self.assertEqual(EXPECTED_STORAGE_WORDS, 86_567_680)
        self.assertEqual(EXPECTED_PADDING_WORDS, 24)
        self.assertEqual(EXPECTED_SCRATCH_WORDS, 1_990_656)

    def test_alignment_prevents_4k_crossing(self) -> None:
        cursor = 0
        for tensor in tensor_storage_layout():
            cursor = align_words(cursor)
            self.assertEqual(cursor % 32, 0)
            if tensor.layout == 4:
                for block in range(tensor.stored_words // BLOCK_WORDS):
                    self.assertTrue(block_fits_4k(cursor + block * BLOCK_WORDS))
            cursor += tensor.stored_words
        self.assertEqual(cursor, EXPECTED_STORAGE_WORDS)
        self.assertFalse(block_fits_4k(1008))


if __name__ == "__main__":
    unittest.main()
