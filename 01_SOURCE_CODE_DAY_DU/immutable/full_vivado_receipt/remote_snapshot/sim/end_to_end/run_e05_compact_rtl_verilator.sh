#!/usr/bin/env bash
set -euo pipefail

vit_e05_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e05_root}"

for vit_e05_tool in verilator timeout; do
    if ! command -v "${vit_e05_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e05_tool}"
        exit 1
    fi
done

vit_e05_tmp="$(mktemp -d /tmp/vit_e05_compact_rtl_verilator.XXXXXX)"
trap 'rm -rf -- "${vit_e05_tmp}"' EXIT

vit_e05_obj_dir="${vit_e05_tmp}/obj"
vit_e05_binary="vit_e05_compact_rtl_e2e"
vit_e05_build_log="${vit_e05_tmp}/build.log"
vit_e05_cflags="${VIT_VERILATOR_CFLAGS:--O3}"

printf '%s\n' \
    "BUILD production compact E05 RTL end-to-end (Verilator, one job)" \
    "INFO  Verilator CFLAGS=${vit_e05_cflags}"
if ! timeout "${VIT_E05_BUILD_TIMEOUT_SECONDS:-600}s" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_npu_e05_compact_rtl \
        --Mdir "${vit_e05_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e05_cflags}" \
        -f sim/end_to_end/vit_phase_e_npu_e05_compact_rtl_verilator.f \
        -o "${vit_e05_binary}" \
        >"${vit_e05_build_log}" 2>&1; then
    printf '%s\n' \
        "FAIL production compact E05 RTL end-to-end: build"
    tail -n 200 "${vit_e05_build_log}"
    exit 1
fi

printf '%s\n' "RUN   production compact E05 RTL end-to-end"
timeout "${VIT_E05_RUN_TIMEOUT_SECONDS:-900}s" \
    "${vit_e05_obj_dir}/${vit_e05_binary}"
