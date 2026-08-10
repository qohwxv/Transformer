#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m7_root="$(cd "${script_dir}/../../.." && pwd)"
vivado_bin="${VIVADO_2023_2_BIN:-/home/qh/Downloads/Vivado/Vivado/2023.2/bin/vivado}"

if [[ ! -x "${vivado_bin}" ]]; then
  echo "M7_LEAF_SWEEP_FAIL: Vivado executable missing: ${vivado_bin}" >&2
  exit 1
fi

filelist_rel="filelists/m7/m7_leaf_ooc.f"
constraint_rel="constraints/m7/m7_leaf_ooc.xdc"
preflight_rel="scripts/m7/ooc/preflight_vivado_2023_2.tcl"
case_rel="scripts/m7/ooc/run_leaf_ooc_case.tcl"
sweep_rel="scripts/m7/ooc/run_leaf_ooc_sweep.sh"

input_paths=(
  "${filelist_rel}"
  "${constraint_rel}"
  "${preflight_rel}"
  "${case_rel}"
  "${sweep_rel}"
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
    echo "M7_LEAF_SWEEP_FAIL: missing input ${path}" >&2
    exit 1
  fi
done

run_id="${M7_LEAF_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-local-m7-leaf-$$}"
run_root="${M7_LEAF_RUN_ROOT:-${m7_root}/reports/m7/leaf_ooc_runs/${run_id}}"
mkdir -p "${run_root}"

(
  cd "${m7_root}"
  sha256sum "${input_paths[@]}"
) >"${run_root}/INPUT_SHA256SUMS.txt"

{
  echo "RUN_ID=${run_id}"
  echo "START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "HOST=$(hostname)"
  echo "VIVADO_BIN=${vivado_bin}"
  echo "VIVADO_EXPECTED=2023.2"
  echo "PART=xczu5ev-sfvc784-1-e"
  echo "TOP=vit_gemm_fp16_stream_array"
  echo "CASE_SEQUENCE=streams16_50MHz,streams8_50MHz,streams16_100MHz,streams8_100MHz"
  echo "EVIDENCE_SCOPE=STANDALONE_M7_2_LEAF_OOC_ONLY"
  echo "FULL_CHIP_TIMING_SIGNOFF=0"
} >"${run_root}/RUN_METADATA.txt"

"${vivado_bin}" -mode batch -nojournal -nolog -notrace \
  -source "${m7_root}/${preflight_rel}" \
  >"${run_root}/preflight.log" 2>&1
grep -F "M7_LEAF_PREFLIGHT_PASS" "${run_root}/preflight.log"

for clock_mhz in 50 100; do
  for streams in 16 8; do
    case_dir="${run_root}/streams_${streams}_${clock_mhz}mhz"
    mkdir -p "${case_dir}"
    echo "M7_LEAF_SWEEP_START streams=${streams} clock_mhz=${clock_mhz} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "${vivado_bin}" -mode batch -nojournal -nolog -notrace \
      -source "${m7_root}/${case_rel}" \
      -tclargs "${streams}" "${clock_mhz}" "${case_dir}" \
      >"${case_dir}/vivado.log" 2>&1
    if grep -Eq '^(ERROR:|CRITICAL WARNING:)' "${case_dir}/vivado.log"; then
      echo "M7_LEAF_SWEEP_FAIL: severe Vivado message in ${case_dir}/vivado.log" >&2
      grep -E '^(ERROR:|CRITICAL WARNING:)' "${case_dir}/vivado.log" >&2
      exit 1
    fi
    grep -F "M7_LEAF_OOC_PASS streams=${streams} clock_mhz=${clock_mhz}" \
      "${case_dir}/vivado.log"
    echo "M7_LEAF_SWEEP_DONE streams=${streams} clock_mhz=${clock_mhz} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
done

(
  cd "${m7_root}"
  sha256sum "${input_paths[@]}"
) >"${run_root}/INPUT_SHA256SUMS_AFTER.txt"
if ! cmp -s "${run_root}/INPUT_SHA256SUMS.txt" \
             "${run_root}/INPUT_SHA256SUMS_AFTER.txt"; then
  echo "M7_LEAF_SWEEP_FAIL: OOC inputs changed during the sweep" >&2
  diff -u "${run_root}/INPUT_SHA256SUMS.txt" \
          "${run_root}/INPUT_SHA256SUMS_AFTER.txt" >&2 || true
  exit 1
fi

{
  echo "RESULT=PASS"
  echo "EVIDENCE_CLASS=MEASURED_TOOL_REPORT"
  echo "SCOPE=STANDALONE_M7_2_LEAF_OOC"
  echo "FULL_CHIP_TIMING_SIGNOFF=0"
  for clock_mhz in 50 100; do
    for streams in 16 8; do
      echo "===== streams=${streams} clock_mhz=${clock_mhz} ====="
      cat "${run_root}/streams_${streams}_${clock_mhz}mhz/SUMMARY.txt"
    done
  done
} >"${run_root}/SWEEP_SUMMARY.txt"

{
  echo "DONE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "SWEEP_RESULT=PASS"
  echo "INPUTS_STABLE_DURING_RUN=1"
} >>"${run_root}/RUN_METADATA.txt"

find "${run_root}" -type f ! -name SHA256SUMS.txt -print0 \
  | sort -z | xargs -0 sha256sum \
  >"${run_root}/SHA256SUMS.txt"
sha256sum "${run_root}/SHA256SUMS.txt" \
  >"${run_root}/SHA256SUMS.txt.sha256"

echo "M7_LEAF_SWEEP_PASS run_root=${run_root}"
