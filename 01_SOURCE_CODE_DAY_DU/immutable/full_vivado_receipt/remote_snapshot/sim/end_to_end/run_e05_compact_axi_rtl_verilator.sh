#!/usr/bin/env bash
set -euo pipefail

vit_axi_e05_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_axi_e05_root}"

for vit_axi_e05_tool in verilator timeout; do
    if ! command -v "${vit_axi_e05_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_axi_e05_tool}"
        exit 1
    fi
done

vit_axi_e05_tmp="$(mktemp -d /tmp/vit_axi_e05_compact.XXXXXX)"
trap 'rm -rf -- "${vit_axi_e05_tmp}"' EXIT

vit_axi_e05_obj_dir="${vit_axi_e05_tmp}/obj"
vit_axi_e05_binary="vit_axi_e05_compact_rtl_e2e"
vit_axi_e05_build_log="${vit_axi_e05_tmp}/build.log"
vit_axi_e05_array_rows="${VIT_AXI_E05_ARRAY_ROWS:-8}"
vit_axi_e05_array_cols="${VIT_AXI_E05_ARRAY_COLS:-2}"
vit_axi_e05_execution_mode="${VIT_AXI_E05_EXECUTION_MODE:-1}"
vit_axi_e05_cflags="${VIT_VERILATOR_CFLAGS:--O3}"

if ! [[ "${vit_axi_e05_array_rows}" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "${vit_axi_e05_array_cols}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' \
        "ERROR: VIT_AXI_E05_ARRAY_ROWS/COLS must be positive integers"
    exit 1
fi
if [[ "${vit_axi_e05_execution_mode}" != "1" ]] &&
   [[ "${vit_axi_e05_execution_mode}" != "3" ]]; then
    printf '%s\n' \
        "ERROR: VIT_AXI_E05_EXECUTION_MODE must be 1 (blocked FP32) or 3 (packed-v3 FP16)"
    exit 1
fi

printf 'BUILD production compact E05 through AXI BD wrapper, tile=%sx%s mode=%s (Verilator)\n' \
    "${vit_axi_e05_array_rows}" "${vit_axi_e05_array_cols}" \
    "${vit_axi_e05_execution_mode}"
printf 'INFO  Verilator CFLAGS=%s\n' "${vit_axi_e05_cflags}"
if ! timeout "${VIT_AXI_E05_BUILD_TIMEOUT_SECONDS:-900}s" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e05_compact_rtl \
        -GDUT_ARRAY_ROWS="${vit_axi_e05_array_rows}" \
        -GDUT_ARRAY_COLS="${vit_axi_e05_array_cols}" \
        -GDUT_EXECUTION_MODE="${vit_axi_e05_execution_mode}" \
        --Mdir "${vit_axi_e05_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_axi_e05_cflags}" \
        -f sim/end_to_end/vit_phase_e_axi_e05_compact_rtl_verilator.f \
        -o "${vit_axi_e05_binary}" \
        >"${vit_axi_e05_build_log}" 2>&1; then
    printf '%s\n' \
        "FAIL production compact E05 through AXI BD wrapper: build"
    tail -n 200 "${vit_axi_e05_build_log}"
    exit 1
fi

printf 'RUN   production compact E05 through AXI BD wrapper, mode=%s\n' \
    "${vit_axi_e05_execution_mode}"
timeout "${VIT_AXI_E05_RUN_TIMEOUT_SECONDS:-300}s" \
    "${vit_axi_e05_obj_dir}/${vit_axi_e05_binary}"
