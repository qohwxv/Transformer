#!/usr/bin/env bash
set -euo pipefail

vit_e2e_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e2e_root}"

for vit_e2e_tool in verilator timeout; do
    if ! command -v "${vit_e2e_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e2e_tool}"
        exit 1
    fi
done

vit_e2e_tmp="$(mktemp -d /tmp/vit_e04_rtl_verilator.XXXXXX)"
trap 'rm -rf -- "${vit_e2e_tmp}"' EXIT

vit_e2e_obj_dir="${vit_e2e_tmp}/obj"
vit_e2e_binary="vit_e04_rtl_e2e"
vit_e2e_build_log="${vit_e2e_tmp}/build.log"
vit_e2e_cflags="${VIT_VERILATOR_CFLAGS:--O3}"

printf '%s\n' \
    "BUILD production E04 RTL end-to-end smoke (Verilator, one job)" \
    "INFO  Verilator CFLAGS=${vit_e2e_cflags}"
if ! timeout "${VIT_E04_BUILD_TIMEOUT_SECONDS:-300}s" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_npu_e04_rtl \
        --Mdir "${vit_e2e_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e2e_cflags}" \
        -f sim/end_to_end/vit_phase_e_npu_e04_rtl_verilator.f \
        -o "${vit_e2e_binary}" \
        >"${vit_e2e_build_log}" 2>&1; then
    printf '%s\n' "FAIL production E04 RTL end-to-end smoke: build"
    tail -n 200 "${vit_e2e_build_log}"
    exit 1
fi

printf '%s\n' "RUN   production E04 RTL end-to-end smoke"
timeout "${VIT_E04_RUN_TIMEOUT_SECONDS:-60}s" \
    "${vit_e2e_obj_dir}/${vit_e2e_binary}"
