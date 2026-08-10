#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 STREAMS CLOCK_MHZ" >&2
  exit 2
fi

streams="$1"
clock_mhz="$2"
if [[ "${streams}" != "8" && "${streams}" != "16" ]]; then
  echo "M7_LEAF_SINGLE_FAIL: STREAMS must be 8 or 16" >&2
  exit 2
fi
if [[ "${clock_mhz}" != "50" && "${clock_mhz}" != "100" ]]; then
  echo "M7_LEAF_SINGLE_FAIL: CLOCK_MHZ must be 50 or 100" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m7_root="$(cd "${script_dir}/../../.." && pwd)"
vivado_bin="${VIVADO_2023_2_BIN:-/home/qh/Downloads/Vivado/Vivado/2023.2/bin/vivado}"
max_threads="${M7_VIVADO_MAX_THREADS:-1}"

if [[ ! -x "${vivado_bin}" ]]; then
  echo "M7_LEAF_SINGLE_FAIL: Vivado executable missing: ${vivado_bin}" >&2
  exit 1
fi
if [[ "${max_threads}" != "1" && "${max_threads}" != "2" ]]; then
  echo "M7_LEAF_SINGLE_FAIL: M7_VIVADO_MAX_THREADS must be 1 or 2" >&2
  exit 2
fi

filelist_rel="filelists/m7/m7_leaf_ooc.f"
constraint_rel="constraints/m7/m7_leaf_ooc.xdc"
preflight_rel="scripts/m7/ooc/preflight_vivado_2023_2.tcl"
case_rel="scripts/m7/ooc/run_leaf_ooc_case.tcl"
single_rel="scripts/m7/ooc/run_leaf_ooc_single.sh"

input_paths=(
  "${filelist_rel}"
  "${constraint_rel}"
  "${preflight_rel}"
  "${case_rel}"
  "${single_rel}"
)
while IFS= read -r line; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "${line}" ]] && continue
  input_paths+=("${line}")
done <"${m7_root}/${filelist_rel}"

for path in "${input_paths[@]}"; do
  if [[ ! -f "${m7_root}/${path}" ]]; then
    echo "M7_LEAF_SINGLE_FAIL: missing input ${path}" >&2
    exit 1
  fi
done

run_id="${M7_LEAF_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-local-m7-leaf-${streams}x${clock_mhz}-$$}"
run_root="${M7_LEAF_RUN_ROOT:-${m7_root}/reports/m7/leaf_ooc_runs/${run_id}}"
case_dir="${run_root}/streams_${streams}_${clock_mhz}mhz"
status_file="${run_root}/RUN_STATUS"
mkdir -p "${case_dir}"

on_exit() {
  rc=$?
  if [[ ${rc} -ne 0 && ! -f "${status_file}" ]]; then
    {
      echo "RUN_STATUS=FAILED"
      echo "EXIT_CODE=${rc}"
      echo "DONE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"${status_file}"
  fi
}
trap on_exit EXIT

(
  cd "${m7_root}"
  sha256sum "${input_paths[@]}"
) >"${run_root}/INPUT_SHA256SUMS.txt"

{
  echo "RUN_ID=${run_id}"
  echo "START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "VIVADO_BIN=${vivado_bin}"
  echo "VIVADO_EXPECTED=2023.2"
  echo "PART=xczu5ev-sfvc784-1-e"
  echo "TOP=vit_gemm_fp16_stream_array"
  echo "STREAMS=${streams}"
  echo "CLOCK_MHZ=${clock_mhz}"
  echo "MAX_THREADS=${max_threads}"
  echo "EVIDENCE_SCOPE=STANDALONE_M7_2_LEAF_OOC_ONLY"
  echo "FULL_CHIP_TIMING_SIGNOFF=0"
} >"${run_root}/RUN_METADATA.txt"
free -h >"${run_root}/MEMORY_BEFORE.txt"

(
  cd "${m7_root}"
  "${vivado_bin}" -mode batch -nojournal -nolog -notrace \
    -source "${m7_root}/${preflight_rel}"
) >"${run_root}/preflight.log" 2>&1
grep -F "M7_LEAF_PREFLIGHT_PASS" "${run_root}/preflight.log"

(
  cd "${m7_root}"
  M7_VIVADO_MAX_THREADS="${max_threads}" \
    "${vivado_bin}" -mode batch -nojournal -nolog -notrace \
    -source "${m7_root}/${case_rel}" \
    -tclargs "${streams}" "${clock_mhz}" "${case_dir}"
) >"${case_dir}/vivado.log" 2>&1

if grep -Eq '^(ERROR:|CRITICAL WARNING:)' "${case_dir}/vivado.log"; then
  echo "M7_LEAF_SINGLE_FAIL: severe Vivado message" >&2
  grep -E '^(ERROR:|CRITICAL WARNING:)' "${case_dir}/vivado.log" >&2
  exit 1
fi
grep -F "M7_LEAF_OOC_PASS streams=${streams} clock_mhz=${clock_mhz}" \
  "${case_dir}/vivado.log"

required_outputs=(
  "SUMMARY.txt"
  "OOC_LIMITATIONS.txt"
  "artifacts/post_synth.dcp"
  "artifacts/post_route.dcp"
  "reports/post_synth_dsp.rpt"
  "reports/post_route_dsp.rpt"
  "reports/post_route_status.rpt"
  "reports/post_route_timing_summary.rpt"
  "reports/post_route_drc.rpt"
  "reports/post_route_methodology.rpt"
)
for path in "${required_outputs[@]}"; do
  if [[ ! -s "${case_dir}/${path}" ]]; then
    echo "M7_LEAF_SINGLE_FAIL: missing or empty output ${path}" >&2
    exit 1
  fi
done

(
  cd "${m7_root}"
  sha256sum "${input_paths[@]}"
) >"${run_root}/INPUT_SHA256SUMS_AFTER.txt"
cmp "${run_root}/INPUT_SHA256SUMS.txt" \
    "${run_root}/INPUT_SHA256SUMS_AFTER.txt"

free -h >"${run_root}/MEMORY_AFTER.txt"
{
  echo "DONE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "INPUTS_STABLE_DURING_RUN=1"
} >>"${run_root}/RUN_METADATA.txt"

find "${run_root}" -type f \
  ! -name SHA256SUMS.txt \
  ! -name SHA256SUMS.txt.sha256 \
  ! -name RUN_STATUS \
  -print0 | sort -z | xargs -0 sha256sum >"${run_root}/SHA256SUMS.txt"
sha256sum "${run_root}/SHA256SUMS.txt" >"${run_root}/SHA256SUMS.txt.sha256"
{
  echo "RUN_STATUS=COMPLETE"
  echo "RESULT=PASS"
  echo "STREAMS=${streams}"
  echo "CLOCK_MHZ=${clock_mhz}"
  echo "DONE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"${status_file}"

echo "M7_LEAF_SINGLE_PASS run_root=${run_root}"
