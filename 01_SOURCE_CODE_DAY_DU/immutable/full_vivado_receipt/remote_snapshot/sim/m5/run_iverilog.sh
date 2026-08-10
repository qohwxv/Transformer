#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../../run/m5_axi128_adapter_iverilog"

mkdir -p "${BUILD_DIR}"
cd "${SCRIPT_DIR}"
iverilog -g2012 -Wall -s tb_vit_phase_e_axi_mem_adapter_128 \
    -o "${BUILD_DIR}/tb_m5_axi128.vvp" \
    -f vit_phase_e_axi_mem_adapter_128_iverilog.f
vvp "${BUILD_DIR}/tb_m5_axi128.vvp"
