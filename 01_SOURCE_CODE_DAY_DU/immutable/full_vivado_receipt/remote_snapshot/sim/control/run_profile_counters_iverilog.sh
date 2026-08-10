#!/usr/bin/env bash
set -euo pipefail

vit_profile_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vit_profile_root="$(cd "${vit_profile_script_dir}/../.." && pwd)"
vit_profile_tmp="$(mktemp -d \
    "${TMPDIR:-/tmp}/vit-profile-counters.XXXXXX")"
trap 'rm -rf -- "${vit_profile_tmp}"' EXIT
vit_profile_vvp="${vit_profile_tmp}/tb_vit_phase_e_profile_counters.vvp"
vit_profile_log="${vit_profile_tmp}/profile_counters.log"

cd "${vit_profile_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_phase_e_profile_counters \
    -o "${vit_profile_vvp}" \
    -c filelists/vit_phase_e_profile_counters_iverilog.f
vvp "${vit_profile_vvp}" 2>&1 | tee "${vit_profile_log}"

verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-UNUSEDPARAM \
    --top-module vit_phase_e_profile_counters \
    rtl/pkg/vit_phase_e_pkg.sv \
    rtl/axi/control/vit_phase_e_profile_counters.sv

vit_profile_marker_count="$(
    grep -Fxc \
        'VIT_PHASE_E_PROFILE_COUNTERS_TEST_PASS checks=170' \
        "${vit_profile_log}" || true
)"
if [[ "${vit_profile_marker_count}" != "1" ]]; then
    printf 'ERROR: profile counter exact PASS marker count is %s; expected 1\n' \
        "${vit_profile_marker_count}"
    exit 1
fi

printf '%s\n' 'PROFILE_COUNTERS_LOCAL_REGRESSION_PASS'
