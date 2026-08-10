#!/usr/bin/env bash
set -euo pipefail

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${bundle_root}/build/m7_dual_mode"
mkdir -p "${build_dir}"
compile_log="${build_dir}/iverilog_compile.log"
run_log="${build_dir}/simulation.log"
fp16_only_compile_log="${build_dir}/fp16_only_iverilog_compile.log"
fp16_only_run_log="${build_dir}/fp16_only_simulation.log"

iverilog -g2012 -Wall \
  -s tb_vit_gemm_dual_mode_array \
  -o "${build_dir}/tb_vit_gemm_dual_mode_array.out" \
  -f "${bundle_root}/filelists/vit_gemm_m7_dual_mode_iverilog.f" \
  >"${compile_log}" 2>&1

vvp "${build_dir}/tb_vit_gemm_dual_mode_array.out" | tee "${run_log}"
grep -q "PASS M7 dual-mode production GEMM checks=" "${run_log}"

iverilog -g2012 -Wall \
  -s tb_vit_gemm_dual_mode_array_fp16_only \
  -o "${build_dir}/tb_vit_gemm_dual_mode_array_fp16_only.out" \
  -f "${bundle_root}/filelists/vit_gemm_m7_dual_mode_iverilog.f" \
  "${bundle_root}/sim/m7/tb_vit_gemm_dual_mode_array_fp16_only.sv" \
  >"${fp16_only_compile_log}" 2>&1

# The selected parameter-0 hierarchy must contain the no-legacy generate
# branch and no instantiated u_legacy scope.  This complements the runtime
# rejection checks with an elaboration-level removal check.
grep -q 'gen_no_legacy' \
  "${build_dir}/tb_vit_gemm_dual_mode_array_fp16_only.out"
if grep -q '\.scope module, "u_legacy"' \
    "${build_dir}/tb_vit_gemm_dual_mode_array_fp16_only.out"; then
  printf '%s\n' 'ERROR: FP16-only elaboration retained u_legacy' >&2
  exit 1
fi

vvp "${build_dir}/tb_vit_gemm_dual_mode_array_fp16_only.out" | \
  tee "${fp16_only_run_log}"
grep -q "PASS M7 FP16-only GEMM checks=" "${fp16_only_run_log}"

printf 'M7_DUAL_MODE_IVERILOG_PASS legacy_compile=%s legacy_run=%s fp16_only_compile=%s fp16_only_run=%s\n' \
  "${compile_log}" "${run_log}" "${fp16_only_compile_log}" \
  "${fp16_only_run_log}"
