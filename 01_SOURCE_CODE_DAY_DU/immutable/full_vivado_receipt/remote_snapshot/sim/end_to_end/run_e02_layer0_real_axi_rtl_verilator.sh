#!/usr/bin/env bash
set -euo pipefail

vit_encoder0_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_encoder0_root}"

for vit_encoder0_tool in verilator timeout; do
    if ! command -v "${vit_encoder0_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' \
            "${vit_encoder0_tool}"
        exit 1
    fi
done

vit_encoder0_tmp="$(mktemp -d /tmp/vit_axi_encoder0_real.XXXXXX)"
trap 'rm -rf -- "${vit_encoder0_tmp}"' EXIT

vit_encoder0_obj_dir="${vit_encoder0_tmp}/obj"
vit_encoder0_binary="vit_axi_e02_layer0_real_rtl_e2e"
vit_encoder0_build_log="${vit_encoder0_tmp}/build.log"
vit_encoder0_cflags="${VIT_VERILATOR_CFLAGS:--O3}"

printf '%s\n' \
    "BUILD production full-dimension E02 layer-0 real-data AXI test (Verilator)" \
    "INFO  Verilator CFLAGS=${vit_encoder0_cflags}"
if ! timeout "${VIT_ENCODER0_BUILD_TIMEOUT_SECONDS:-1200}s" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e02_layer0_real_rtl \
        --Mdir "${vit_encoder0_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_encoder0_cflags}" \
        -f sim/end_to_end/vit_phase_e_axi_e02_layer0_real_rtl_verilator.f \
        -o "${vit_encoder0_binary}" \
        >"${vit_encoder0_build_log}" 2>&1; then
    printf '%s\n' \
        "FAIL production full-dimension E02 layer-0 real-data AXI test: build"
    tail -n 200 "${vit_encoder0_build_log}"
    exit 1
fi

if [[ "${VIT_ENCODER0_BUILD_ONLY:-0}" == "1" ]]; then
    printf '%s\n' \
        "PASS build-only: E02 layer-0 real-data AXI harness is compile-clean"
    exit 0
fi

vit_encoder0_run_timeout="${VIT_ENCODER0_RUN_TIMEOUT_SECONDS:-1800}"
printf '%s\n' \
    "RUN   production full-dimension E02 layer-0 real-data AXI test" \
    "INFO  scalar 32-bit AXI makes this intentionally long; run timeout=${vit_encoder0_run_timeout}s"

set +e
timeout "${vit_encoder0_run_timeout}s" \
    "${vit_encoder0_obj_dir}/${vit_encoder0_binary}"
vit_encoder0_status=$?
set -e

if [[ "${vit_encoder0_status}" == "124" ]]; then
    printf '%s\n' \
        "INCOMPLETE: bounded wall-clock timeout reached before the 20-command real layer finished." \
        "This is not a numerical PASS or RTL failure. Increase VIT_ENCODER0_RUN_TIMEOUT_SECONDS to continue a full run."
    exit 124
fi

exit "${vit_encoder0_status}"
