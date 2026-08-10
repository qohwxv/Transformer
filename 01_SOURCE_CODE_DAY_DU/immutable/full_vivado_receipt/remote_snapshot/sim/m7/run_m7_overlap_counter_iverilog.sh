#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="${revision_root}/build/m7_overlap_counter"
compile_log="${build_dir}/iverilog_compile.log"
run_log="${build_dir}/simulation.log"

mkdir -p "${build_dir}"

(
    cd "${revision_root}"
    iverilog -g2012 -Wall \
        -s tb_vit_phase_e_m7_overlap_counters \
        -o "${build_dir}/tb_vit_phase_e_m7_overlap_counters.vvp" \
        -c sim/m7/m7_overlap_counter_iverilog.f \
        >"${compile_log}" 2>&1
)

vvp "${build_dir}/tb_vit_phase_e_m7_overlap_counters.vvp" \
    | tee "${run_log}"
grep -q '^M7_OVERLAP_COUNTER_BANK_PASS checks=' "${run_log}"

printf 'M7_OVERLAP_COUNTER_IVERILOG_PASS compile_log=%s run_log=%s\n' \
    "${compile_log}" "${run_log}"
