#!/usr/bin/env bash
set -euo pipefail

vit_e2e_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e2e_root}"

for vit_e2e_tool in iverilog vvp timeout; do
    if ! command -v "${vit_e2e_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e2e_tool}"
        exit 1
    fi
done

vit_e2e_tmp="$(mktemp -d /tmp/vit_e04_rtl_e2e.XXXXXX)"
trap 'rm -rf -- "${vit_e2e_tmp}"' EXIT

timeout 60s iverilog \
    -g2012 \
    -s tb_vit_phase_e_npu_e04_rtl \
    -o "${vit_e2e_tmp}/tb.vvp" \
    -c sim/end_to_end/vit_phase_e_npu_e04_rtl_iverilog.f

timeout "${VIT_E04_TIMEOUT_SECONDS:-600}s" \
    vvp "${vit_e2e_tmp}/tb.vvp"
