#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vit-m5-adapter.XXXXXX")"
trap 'rm -rf -- "${BUILD_DIR}"' EXIT

SEED="${SEED:-310386726}"
ITERATIONS="${ITERATIONS:-40}"

pushd "${SCRIPT_DIR}" >/dev/null
iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_phase_e_axi_mem_adapter_m5 \
    -o "${BUILD_DIR}/tb_vit_phase_e_axi_mem_adapter_m5.vvp" \
    -c vit_phase_e_axi_mem_adapter_m5_iverilog.f
popd >/dev/null

vvp "${BUILD_DIR}/tb_vit_phase_e_axi_mem_adapter_m5.vvp" \
    "+SEED=${SEED}" \
    "+ITERATIONS=${ITERATIONS}"
