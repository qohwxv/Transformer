#!/usr/bin/env bash
set -euo pipefail

vit_wrapper_script_dir="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
vit_wrapper_root="$(cd "${vit_wrapper_script_dir}/../.." && pwd)"
vit_wrapper_build_dir="${VIT_AXI_WRAPPER_BUILD_DIR:-${vit_wrapper_root}/build/axi_wrapper_fp16_only}"
vit_wrapper_compile_log="${vit_wrapper_build_dir}/iverilog_compile.log"
vit_wrapper_run_log="${vit_wrapper_build_dir}/simulation.log"
vit_wrapper_exe="${vit_wrapper_build_dir}/tb_vit_phase_e_axi_wrapper.vvp"

for vit_wrapper_tool in iverilog vvp grep tee; do
    if ! command -v "${vit_wrapper_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required wrapper-test tool is missing: %s\n' \
            "${vit_wrapper_tool}"
        exit 1
    fi
done

mkdir -p "${vit_wrapper_build_dir}"
cd "${vit_wrapper_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_phase_e_axi_wrapper \
    -o "${vit_wrapper_exe}" \
    -c filelists/full_axi.f \
    sim/axi/tb_vit_phase_e_axi_wrapper.sv \
    >"${vit_wrapper_compile_log}" 2>&1

vvp "${vit_wrapper_exe}" 2>&1 | tee "${vit_wrapper_run_log}"

vit_wrapper_pass_count="$(
    grep -Ec '^VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=178$' \
        "${vit_wrapper_run_log}" || true
)"
if [[ "${vit_wrapper_pass_count}" != "1" ]]; then
    printf 'ERROR: focused FP16-only wrapper PASS marker count is %s; expected 1\n' \
        "${vit_wrapper_pass_count}"
    exit 1
fi

printf 'M7S8_FP16_ONLY_AXI_WRAPPER_IVERILOG_PASS compile_log=%s run_log=%s\n' \
    "${vit_wrapper_compile_log}" "${vit_wrapper_run_log}"
