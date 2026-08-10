#!/usr/bin/env bash
set -euo pipefail

revision_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Leaf first: proves the physical depth-2 queue, including a full FIFO doing
# simultaneous pop+push.  The production scheduler remains intentionally
# serialized in Gate1, so its occupancy is expected to peak at one.
bash "${revision_root}/sim/m7/run_m7_result_fifo_iverilog.sh"
bash "${revision_root}/sim/m7/run_m7_fp16_pingpong_gate1_iverilog.sh"
bash "${revision_root}/sim/m7/run_m7_dual_mode_iverilog.sh"

grep -q "full_exchanges=1070" \
  "${revision_root}/build/m7_result_fifo/simulation.log"
grep -q "PASS M7.4 scheduler ping-pong Gate-1" \
  "${revision_root}/build/m7_fp16_pingpong_gate1/simulation.log"
grep -q "PASS M7 dual-mode production GEMM" \
  "${revision_root}/build/m7_dual_mode/simulation.log"

printf '%s\n' \
  "M7_RESULT_FIFO_GATE1_INTEGRATION_PASS" \
  "scope=serialized-packed2-fifo legacy-and-nonpacked-direct" \
  "leaf_full_push_pop=PASS scheduler_address_generation_drain=PASS dual_mode_isolation=PASS"
