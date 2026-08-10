#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="${revision_root}/build/m7_result_fifo"
compile_log="${build_dir}/iverilog_compile.log"
run_log="${build_dir}/simulation.log"

mkdir -p "${build_dir}"

(
    cd "${revision_root}"
    iverilog -g2012 -Wall \
        -s tb_m7_result_fifo \
        -o "${build_dir}/tb_m7_result_fifo.vvp" \
        -c sim/m7/m7_result_fifo_iverilog.f \
        >"${compile_log}" 2>&1
)

vvp "${build_dir}/tb_m7_result_fifo.vvp" | tee "${run_log}"
grep -q '^M7_RESULT_FIFO_PASS checks=' "${run_log}"

printf 'M7_RESULT_FIFO_IVERILOG_PASS compile_log=%s run_log=%s\n' \
    "${compile_log}" "${run_log}"
