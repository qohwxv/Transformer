from __future__ import annotations

import json
import subprocess
import sys
import unittest
from dataclasses import asdict
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import m7_cycle_bandwidth_model as model


class M7CycleBandwidthModelTest(unittest.TestCase):
    def test_default_is_exact_s8_two_pass_no_b_cache(self) -> None:
        actual = asdict(model.model())
        self.assertEqual(actual["configuration"], model.S8_CONFIG.name)
        self.assertEqual(actual["evidence_class"], "DERIVED")
        self.assertTrue(actual["two_pass_columns"])
        self.assertFalse(actual["b_cache"])
        for key, expected in model.EXPECTED_S8.items():
            self.assertEqual(actual[key], expected, key)

    def test_explicit_s16_baseline_is_preserved(self) -> None:
        actual = asdict(model.model(model.S16_STREAMS))
        self.assertEqual(actual["configuration"], model.S16_CONFIG.name)
        self.assertFalse(actual["two_pass_columns"])
        for key, expected in model.EXPECTED_S16.items():
            self.assertEqual(actual[key], expected, key)

    def test_s8_physical_passes_skip_odd_padded_column(self) -> None:
        result = model.model(model.S8_STREAMS)
        direct_passes = 0
        padded_two_passes = 0
        for item in model.workloads():
            scale = item.count * item.batch
            m_tiles = model.ceil_div(item.m, model.ARRAY_ROWS)
            k_chunks = model.ceil_div(item.k, model.PE_LANES)
            direct_passes += scale * m_tiles * item.n * k_chunks
            padded_two_passes += (
                scale
                * m_tiles
                * model.ceil_div(item.n, model.LOGICAL_ARRAY_COLS)
                * k_chunks
                * model.LOGICAL_ARRAY_COLS
            )
        self.assertEqual(result.physical_k16_passes, direct_passes)
        self.assertEqual(padded_two_passes - direct_passes, 14_400)

    def test_s8_slot_and_feed_identities(self) -> None:
        result = model.model(model.S8_STREAMS)
        self.assertEqual(
            result.physical_mac_slots,
            result.physical_k16_passes
            * model.ARRAY_ROWS
            * result.physical_array_cols
            * model.PE_LANES,
        )
        self.assertEqual(
            result.ideal_compute_feed_cycles * result.fp16_streams,
            result.physical_mac_slots,
        )
        self.assertEqual(
            result.physical_mac_slots,
            result.valid_mac_terms + result.tail_mac_terms,
        )

    def test_s8_no_b_cache_rereads_packed_word_for_column_one(self) -> None:
        s8 = model.model(model.S8_STREAMS)
        s16 = model.model(model.S16_STREAMS)
        self.assertEqual(
            s8.packed_b_external_read_u32,
            2 * s16.packed_b_external_read_u32,
        )
        self.assertEqual(
            s8.packed_b_external_read_u32,
            s8.persistent_b_source_fp16_elements,
        )

    def test_s8_dynamic_legacy_pair_reread_and_odd_column_skip(self) -> None:
        s8 = model.model(model.S8_STREAMS)
        s16 = model.model(model.S16_STREAMS)
        # QK attention has N=197.  Its final unpaired column is not replayed;
        # all even-width dynamic-B pairs are fetched twice.
        odd_last_column_words = 12 * 12 * model.ceil_div(197, 8) * 64
        self.assertEqual(odd_last_column_words, 230_400)
        self.assertEqual(
            s8.dynamic_b_external_read_u32,
            2 * s16.dynamic_b_external_read_u32 - odd_last_column_words,
        )

    def test_s8_traffic_and_m5_delta_identities(self) -> None:
        result = model.model(model.S8_STREAMS)
        self.assertEqual(
            result.external_read_u32,
            result.packed_b_external_read_u32
            + result.dynamic_b_external_read_u32
            + result.other_a_bias_external_read_u32,
        )
        self.assertEqual(
            result.total_r_beats,
            result.full_width_r_beats + result.narrow_r_beats,
        )
        self.assertEqual(
            result.total_ar_transactions,
            result.full_width_ar_transactions + result.narrow_r_beats,
        )
        self.assertEqual(result.external_read_u32_delta_vs_m5, 90_547_200)
        self.assertEqual(result.r_beat_delta_vs_m5, 90_547_200)
        self.assertEqual(result.ar_delta_vs_m5, 90_547_200)

    def test_self_check_and_cli_default_report_s8(self) -> None:
        checked = subprocess.run(
            [sys.executable, str(TOOLS / "m7_cycle_bandwidth_model.py"),
             "--self-check"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("M7_CYCLE_BANDWIDTH_MODEL_PASS", checked.stdout)
        emitted = subprocess.run(
            [sys.executable, str(TOOLS / "m7_cycle_bandwidth_model.py"),
             "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
        parsed = json.loads(emitted.stdout)
        self.assertEqual(parsed["configuration"], model.S8_CONFIG.name)
        self.assertEqual(parsed["physical_k16_passes"], 139_512_000)

    def test_invalid_stream_count_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported FP16 stream"):
            model.model(4)


if __name__ == "__main__":
    unittest.main()
