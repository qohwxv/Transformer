#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_root="${M8_SIM_OUTPUT_ROOT:?M8_SIM_OUTPUT_ROOT is required}"
vivado_root="${VIVADO_ROOT:-/tools/Xilinx/Vivado/2023.2}"
iverilog_root="${M8_IVERILOG_ROOT:-}"

if [[ -e "${output_root}" ]]; then
    echo "M8_SIM_OBSERVATION_FAIL output_exists=${output_root}" >&2
    exit 2
fi
mkdir -p "${output_root}"
cd "${root}"

source "${vivado_root}/settings64.sh"
if ! command -v iverilog >/dev/null 2>&1 ||
   ! command -v vvp >/dev/null 2>&1; then
    if [[ -z "${iverilog_root}" ]]; then
        echo "M8_SIM_OBSERVATION_FAIL portable_iverilog_root_missing" >&2
        exit 2
    fi
    export M8_IVERILOG_ROOT="${iverilog_root}"
    export PATH="${root}/sim/m8/tool_wrappers:${PATH}"
fi
iverilog -V >"${output_root}/IVERILOG_VERSION.txt" 2>&1
vvp -V >"${output_root}/VVP_VERSION.txt" 2>&1

python3 - "${root}" >"${output_root}/SOURCE_STATE_BEFORE.txt" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
filelist = root / "filelists/full_axi.f"
sources = [
    line.strip()
    for line in filelist.read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith(("#", "//"))
]
if len(sources) != 80 or len(set(sources)) != 80:
    raise SystemExit("ERROR: production closure is not 80/80 unique")
records = []
for relative in sources:
    path = root / relative
    records.append(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n"
    )
ordered = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
filelist_sha = hashlib.sha256(filelist.read_bytes()).hexdigest()
if ordered != "db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e":
    raise SystemExit(f"ERROR: ordered source mismatch: {ordered}")
if filelist_sha != "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524":
    raise SystemExit(f"ERROR: filelist mismatch: {filelist_sha}")
print(
    "M8_SIM_SOURCE_STATE "
    f"sources=80 ordered_sha256={ordered} filelist_sha256={filelist_sha}"
)
for record in records:
    print(record, end="")
PY

free -h >"${output_root}/HOST_BEFORE.txt"
uptime >>"${output_root}/HOST_BEFORE.txt"
df -h "${root}" /tmp >>"${output_root}/HOST_BEFORE.txt"

run_gate() {
    local label="$1"
    shift
    echo "M8_SIM_GATE_BEGIN label=${label}"
    "$@" 2>&1 | tee "${output_root}/${label}.log"
    echo "M8_SIM_GATE_PASS label=${label}"
}

run_gate vector_fastpath bash sim/m8/run_vector_fastpath_ab.sh
run_gate router_ab bash sim/m8/run_read_address_router_ab.sh
run_gate vector_gelu_linefill bash sim/m8/run_vector_gelu_linefill_ab.sh
run_gate softmax_ab bash sim/m8/run_softmax_exact_parent_ab.sh

echo "M8_SIM_GATE_BEGIN label=layernorm_ab"
M8_LN_AB_OUTPUT_DIR="${output_root}/layernorm_ab_artifacts" \
    bash sim/layernorm/run_m8_layernorm_parent_ab.sh \
    2>&1 | tee "${output_root}/layernorm_ab.log"
echo "M8_SIM_GATE_PASS label=layernorm_ab"

run_gate packed_memory_seams bash sim/m7/run_m7_packed_memory_seams_iverilog.sh
run_gate fifo_gate2 bash sim/m7/run_m7_result_fifo_gate2_integration.sh

echo "M8_SIM_GATE_BEGIN label=production_iverilog"
iverilog -g2012 -Wall -s vit_phase_e_axi_bd_wrapper \
    -o "${output_root}/vit_phase_e_axi_bd_wrapper.vvp" \
    -c filelists/full_axi.f \
    2>&1 | tee "${output_root}/production_iverilog.log"
echo "M8_SIM_GATE_PASS label=production_iverilog"

echo "M8_SIM_GATE_BEGIN label=production_verilator_lint"
verilator --lint-only --timing -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    --top-module vit_phase_e_axi_bd_wrapper \
    -f filelists/full_axi.f \
    2>&1 | tee "${output_root}/production_verilator_lint.log"
if grep -Eq '%Error|UNOPTFLAT|PINMISSING' \
    "${output_root}/production_verilator_lint.log"; then
    echo "M8_SIM_OBSERVATION_FAIL production_lint_severe" >&2
    exit 1
fi
echo "M8_SIM_GATE_PASS label=production_verilator_lint"

echo "M8_SIM_GATE_BEGIN label=xsim_observation"
VIT_XSIM_THREADS=2 VIT_XSIM_TIMEOUT_SECONDS=21600 \
    bash run/10_xsim_axi_smoke.sh \
    2>&1 | tee "${output_root}/xsim_observation.log"
echo "M8_SIM_GATE_PASS label=xsim_observation"

python3 - "${root}" >"${output_root}/SOURCE_STATE_AFTER.txt" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
filelist = root / "filelists/full_axi.f"
sources = [
    line.strip()
    for line in filelist.read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith(("#", "//"))
]
records = [
    f"{hashlib.sha256((root / relative).read_bytes()).hexdigest()}  {relative}\n"
    for relative in sources
]
print(
    "M8_SIM_SOURCE_STATE "
    f"sources={len(sources)} "
    f"ordered_sha256={hashlib.sha256(''.join(records).encode('utf-8')).hexdigest()} "
    f"filelist_sha256={hashlib.sha256(filelist.read_bytes()).hexdigest()}"
)
for record in records:
    print(record, end="")
PY
cmp "${output_root}/SOURCE_STATE_BEFORE.txt" \
    "${output_root}/SOURCE_STATE_AFTER.txt"

free -h >"${output_root}/HOST_AFTER.txt"
uptime >>"${output_root}/HOST_AFTER.txt"
df -h "${root}" /tmp >>"${output_root}/HOST_AFTER.txt"
sha256sum "${output_root}"/*.log \
    "${output_root}/SOURCE_STATE_BEFORE.txt" \
    "${output_root}/SOURCE_STATE_AFTER.txt" \
    >"${output_root}/SHA256SUMS.txt"

echo "M8_SIM_OBSERVATION_PASS output_root=${output_root}"
