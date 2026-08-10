#!/usr/bin/env bash
set -euo pipefail

vit_perf_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vit_perf_root="$(cd "${vit_perf_script_dir}/../.." && pwd)"
vit_perf_tmp="$(mktemp -d "${TMPDIR:-/tmp}/vit-perf-counters.XXXXXX")"
trap 'rm -rf -- "${vit_perf_tmp}"' EXIT
vit_perf_vvp="${vit_perf_tmp}/tb_vit_phase_e_perf_counters.vvp"

cd "${vit_perf_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_phase_e_perf_counters \
    -o "${vit_perf_vvp}" \
    -c filelists/vit_phase_e_perf_counters_iverilog.f
vvp "${vit_perf_vvp}"

verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module vit_phase_e_perf_counters \
    rtl/axi/control/vit_phase_e_perf_counters.sv

printf '%s\n' 'PERF_COUNTERS_LOCAL_REGRESSION_PASS'
