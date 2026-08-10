#!/usr/bin/env bash
set -euo pipefail

revision_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${revision_root}/build/m7_fp16_pingpong_gate1"
compile_log="${build_dir}/iverilog_compile.log"
run_log="${build_dir}/simulation.log"

mkdir -p "${build_dir}"

sources=(
  rtl/leaf/fp32/vit_fp32_add_comb.sv
  rtl/leaf/fp16/vit_fp32_to_fp16_rne_gradual.sv
  rtl/leaf/fp16/vit_fp16_mul_to_fp32_comb_nodsp.sv
  rtl/leaf/fp16/vit_fp32_product_to_fixed_exact.sv
  rtl/leaf/fp16/vit_fixed_analyze.sv
  rtl/leaf/fp16/vit_fixed_normalized_to_fp32_rne.sv
  rtl/leaf/fp16/vit_fixed_to_fp32_rne.sv
  rtl/leaf/fp16/vit_fp16_dot_stream_csa_nodsp.sv
  rtl/blocks/gemm/vit_gemm_operand_router.sv
  rtl/blocks/gemm/vit_gemm_fp16_stream_array.sv
  rtl/blocks/gemm/vit_gemm_result_fifo.sv
  rtl/blocks/gemm/vit_gemm_fp16_parallel_scheduler.sv
  sim/m7/tb_m7_fp16_pingpong_scheduler.sv
)

source_paths=()
for source_file in "${sources[@]}"; do
  source_paths+=("${revision_root}/${source_file}")
done

iverilog -g2012 -Wall \
  -s tb_m7_fp16_pingpong_scheduler \
  -o "${build_dir}/tb_m7_fp16_pingpong_scheduler.vvp" \
  "${source_paths[@]}" \
  >"${compile_log}" 2>&1

set +e
timeout 60s vvp "${build_dir}/tb_m7_fp16_pingpong_scheduler.vvp" \
  2>&1 | tee "${run_log}"
simulation_status=${PIPESTATUS[0]}
set -e

if (( simulation_status == 0 )); then
  grep -q "M7.4_INTEGRITY_ATOMIC commit_release_delay=" "${run_log}"
  grep -q \
    "M7.4_INTEGRITY_MULTI results=12 chunks=3 req=36 max_depth=2" \
    "${run_log}"
  grep -q \
    "M7.4_INTEGRITY_ERROR config_error=1 events=8 results=0" \
    "${run_log}"
  grep -q \
    "M7.4_GATE2_FIFO results=7 enq=7 deq=7 max=2" \
    "${run_log}"
  grep -q \
    "PASS M7.4 scheduler ping-pong Gate-2 checks=.* integrity=1" \
    "${run_log}"
  printf 'M7_FP16_PINGPONG_GATE2_INTEGRITY_PASS compile_log=%s run_log=%s\n' \
    "${compile_log}" "${run_log}"
  exit 0
fi

if grep -q "M7.4_GATE1_RED_NO_TWO_BANK_LOOKAHEAD" "${run_log}"; then
  printf '%s\n' \
    "M7_FP16_PINGPONG_GATE1_EXPECTED_RED: current scheduler lacks two-bank look-ahead" \
    "compile_log=${compile_log}" \
    "run_log=${run_log}"
else
  printf '%s\n' \
    "M7_FP16_PINGPONG_GATE1_UNEXPECTED_FAIL status=${simulation_status}" \
    "compile_log=${compile_log}" \
    "run_log=${run_log}" >&2
fi

# Keep the specification gate red until the implementation satisfies it.
exit "${simulation_status}"
