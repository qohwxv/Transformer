#!/usr/bin/env python3
"""Unit tests for the exact M4 R2/R4/R8 counter oracle."""

from __future__ import annotations

import unittest

from vit_m4_reuse_model import KNOWN, model


class ReuseModelTest(unittest.TestCase):
    def test_known_anchors(self) -> None:
        for rows, expected in KNOWN.items():
            actual = vars(model(rows))
            for key, value in expected.items():
                self.assertEqual(actual[key], value, (rows, key))

    def test_cache_partition(self) -> None:
        for rows in (2, 4, 8):
            value = model(rows)
            self.assertEqual(
                value.cache_lookups,
                value.cache_hits + value.cache_misses,
            )
            self.assertEqual(
                value.gemm_axi_reads,
                value.a_cache_misses
                + value.b_bypass_reads
                + value.bias_cache_misses,
            )

    def test_monotonic_read_reduction(self) -> None:
        r2 = model(2)
        r4 = model(4)
        r8 = model(8)
        self.assertGreater(r2.axi_reads, r4.axi_reads)
        self.assertGreater(r4.axi_reads, r8.axi_reads)
        self.assertEqual(r2.axi_writes, r4.axi_writes)
        self.assertEqual(r4.axi_writes, r8.axi_writes)

    def test_cache_payload(self) -> None:
        self.assertEqual(model(4).cache_payload_bytes, 60 * 1024)
        self.assertEqual(model(8).cache_payload_bytes, 108 * 1024)


if __name__ == "__main__":
    unittest.main(verbosity=2)
