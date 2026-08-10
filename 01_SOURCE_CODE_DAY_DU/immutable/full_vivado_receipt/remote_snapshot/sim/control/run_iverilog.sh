#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONTROL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vit-control.XXXXXX")"
trap 'rm -rf -- "${CONTROL_TMP}"' EXIT
LOG_FILE="${CONTROL_TMP}/T033_AXI_LITE_CONTROL.log"
SIM_EXE="${CONTROL_TMP}/tb_vit_axi_lite_control_regs.vvp"

cd "${REPO_ROOT}"

{
    echo "T033 AXI4-Lite control register bank verification"
    echo "iverilog: $(iverilog -V 2>&1 | sed -n '1p')"
    echo
    echo "[1/3] Icarus syntax/lint compile"
    iverilog \
        -g2012 \
        -Wall \
        -tnull \
        -s vit_axi_lite_control_regs \
        rtl/axi/control/vit_axi_lite_control_regs.sv
    echo "IVERILOG_RTL_SYNTAX_PASS"
    echo
    echo "[2/3] Verilator lint"
    verilator \
        --lint-only \
        --timing \
        -Wall \
        -Wno-fatal \
        --top-module vit_axi_lite_control_regs \
        rtl/axi/control/vit_axi_lite_control_regs.sv
    echo "VERILATOR_RTL_LINT_PASS"
    echo
    echo "[3/3] Self-checking Icarus simulation"
    iverilog \
        -g2012 \
        -Wall \
        -s tb_vit_axi_lite_control_regs \
        -o "${SIM_EXE}" \
        -c filelists/p4_control_iverilog.f
    vvp "${SIM_EXE}"
} 2>&1 | tee "${LOG_FILE}"

grep -q "IVERILOG_RTL_SYNTAX_PASS" "${LOG_FILE}"
grep -q "VERILATOR_RTL_LINT_PASS" "${LOG_FILE}"
grep -q "P4_AXI_LITE_CONTROL_TEST_PASS" "${LOG_FILE}"
echo "T033_CONTROL_VERIFICATION_PASS" | tee -a "${LOG_FILE}"
