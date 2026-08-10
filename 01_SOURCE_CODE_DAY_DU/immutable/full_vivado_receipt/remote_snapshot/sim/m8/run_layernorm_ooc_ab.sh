#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vivado_bin="${VIVADO_BIN:-/home/qh/Downloads/Vivado/Vivado/2023.2/bin/vivado}"
output_root="${M8_LAYERNORM_OOC_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/vit_m8_layernorm_ooc.XXXXXX")}" 

if [[ ! -x "${vivado_bin}" ]]; then
    echo "M8_LAYERNORM_OOC_AB_FAIL missing_vivado=${vivado_bin}" >&2
    exit 1
fi

mkdir -p "${output_root}"
cd "${repo_root}"

input_paths=(
    rtl/leaf/common/vit_u32_mul_iterative_nodsp.sv
    rtl/leaf/fp32/vit_fp32_add_comb.sv
    rtl/leaf/fp32/vit_fp32_mul_comb_nodsp.sv
    rtl/leaf/fp32/vit_fp32_recip_u32_serial.sv
    rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv
    sim/layernorm/run_m8_layernorm_buffer_ooc.tcl
    sim/m8/run_layernorm_ooc_ab.sh
)
sha256sum "${input_paths[@]}" > "${output_root}/INPUT_SHA256SUMS.txt"

run_case() {
    local label="$1"
    local enable="$2"
    local case_root="${output_root}/${label}"
    mkdir -p "${case_root}"
    "${vivado_bin}" \
        -mode batch \
        -nolog \
        -nojournal \
        -notrace \
        -source sim/layernorm/run_m8_layernorm_buffer_ooc.tcl \
        -tclargs "${enable}" "${case_root}" \
        2>&1 | tee "${output_root}/${label}.console.log"
    grep -Fq "M8_LAYERNORM_OOC_PASS enable=${enable}" \
        "${output_root}/${label}.console.log"
    grep -Fq 'RESULT=PASS' "${case_root}/SUMMARY.txt"
    if grep -Eq '^(ERROR:|CRITICAL WARNING:)' \
        "${output_root}/${label}.console.log"; then
        echo "M8_LAYERNORM_OOC_AB_FAIL severe_message label=${label}" >&2
        exit 1
    fi
}

# The disabled case proves that the optional memories optimize away.  The
# enabled case must infer exactly three RAMB36 tiles and no other RAM class.
run_case disabled 0
run_case candidate 1

sha256sum "${input_paths[@]}" > "${output_root}/INPUT_SHA256SUMS_AFTER.txt"
cmp "${output_root}/INPUT_SHA256SUMS.txt" \
    "${output_root}/INPUT_SHA256SUMS_AFTER.txt"

sha256sum \
    "${output_root}/disabled/SUMMARY.txt" \
    "${output_root}/candidate/SUMMARY.txt" \
    "${output_root}/disabled/artifacts/post_route.dcp" \
    "${output_root}/candidate/artifacts/post_route.dcp" \
    > "${output_root}/OUTPUT_SHA256SUMS.txt"

echo "M8_LAYERNORM_OOC_AB_PASS output_root=${output_root}"
cat "${output_root}/disabled/SUMMARY.txt"
cat "${output_root}/candidate/SUMMARY.txt"
sha256sum "${output_root}/OUTPUT_SHA256SUMS.txt"
