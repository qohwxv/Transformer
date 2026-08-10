#!/usr/bin/env bash
set -euo pipefail

revision_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Gate-2 closes the production scheduler behavior above the already-proven
# depth-2 FIFO leaf: non-final early advance, full replacement, and a final
# drain that may begin at occupancy two.  The dual-mode replay keeps the
# frozen FP32 and non-packed FP16 compatibility paths in the same gate.
bash "${revision_root}/sim/m7/run_m7_result_fifo_iverilog.sh"
bash "${revision_root}/sim/m7/run_m7_fp16_pingpong_gate1_iverilog.sh"
bash "${revision_root}/sim/m7/run_m7_dual_mode_iverilog.sh"

grep -q "full_exchanges=1070" \
  "${revision_root}/build/m7_result_fifo/simulation.log"
grep -q "M7.4_GATE2_FIFO results=7 enq=7 deq=7 max=2" \
  "${revision_root}/build/m7_fp16_pingpong_gate1/simulation.log"
grep -q "M7.4_GATE2_ERROR_DRAIN enq=2 deq=2 results=2 events=8" \
  "${revision_root}/build/m7_fp16_pingpong_gate1/simulation.log"
grep -q "PASS M7.4 scheduler ping-pong Gate-2" \
  "${revision_root}/build/m7_fp16_pingpong_gate1/simulation.log"
grep -q "PASS M7 dual-mode production GEMM" \
  "${revision_root}/build/m7_dual_mode/simulation.log"
grep -q \
  "M7_S8_DUAL_GATE2 results=7 enq=7 deq=7 max=2.*metadata_order=PASS" \
  "${revision_root}/build/m7_dual_mode/simulation.log"

printf '%s\n' \
  "M7_RESULT_FIFO_GATE2_INTEGRATION_PASS" \
  "scope=packed2-S8-two-pass-early-advance-depth2-final-drain legacy-and-nonpacked-direct" \
  "leaf_full_push_pop=PASS scheduler_order_address_generation_backpressure=PASS dual_mode_isolation=PASS"
