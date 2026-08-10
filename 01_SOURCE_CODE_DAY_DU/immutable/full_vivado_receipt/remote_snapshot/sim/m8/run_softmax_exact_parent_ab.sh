#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/vit_m8_softmax_exact_ab.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cd "$repo_root"

parent_source="sim/m8/reference/vit_softmax_engine_fp32_parent_v1_12.sv"
candidate_source="rtl/blocks/softmax/vit_softmax_engine_fp32.sv"
testbench="sim/softmax/tb_vit_softmax_engine_fp32_exact_parent.sv"
expected_parent_sha="4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da"
actual_parent_sha="$(sha256sum "$parent_source" | awk '{print $1}')"
if [[ "$actual_parent_sha" != "$expected_parent_sha" ]]; then
    echo "SOFTMAX_EXACT_AB_FAIL parent_sha=$actual_parent_sha expected=$expected_parent_sha" >&2
    exit 1
fi

common_sources=(
    rtl/leaf/common/vit_u32_mul_iterative_nodsp.sv
    rtl/leaf/fp32/vit_fp32_add_comb.sv
    rtl/leaf/fp32/vit_fp32_compare.sv
    rtl/leaf/fp32/vit_fp32_mul_comb_nodsp.sv
    rtl/leaf/fp32/vit_fp32_from_u32_comb.sv
    rtl/leaf/fp32/vit_fp32_to_u32_floor_comb.sv
    rtl/leaf/fp32/vit_fp32_scale_pow2_down_comb.sv
)

run_one() {
    local implementation="$1"
    local source_file="$2"
    local define_flag="$3"
    local build_dir="$work_dir/$implementation"
    local signature_file="$work_dir/$implementation.signature.tsv"
    local log_file="$work_dir/$implementation.log"
    local -a defines=()
    if [[ -n "$define_flag" ]]; then
        defines+=("$define_flag")
    fi

    verilator \
        --binary \
        --timing \
        -O3 \
        -j 1 \
        -Wno-fatal \
        -Wno-PINCONNECTEMPTY \
        -Wno-UNUSEDSIGNAL \
        -Wno-BLKSEQ \
        "${defines[@]}" \
        --Mdir "$build_dir" \
        "${common_sources[@]}" \
        "$source_file" \
        "$testbench" \
        --top-module tb_vit_softmax_engine_fp32_exact_parent
    "$build_dir/Vtb_vit_softmax_engine_fp32_exact_parent" \
        "+SIGNATURE_FILE=$signature_file" | tee "$log_file"
    grep -q "SOFTMAX_EXACT_PARENT_HARNESS_PASS implementation=$implementation" \
        "$log_file"
}

run_one M7_PARENT_V1_12 "$parent_source" ""
run_one M8_CANDIDATE "$candidate_source" -DM8_CANDIDATE

cmp "$work_dir/M7_PARENT_V1_12.signature.tsv" \
    "$work_dir/M8_CANDIDATE.signature.tsv"

signature_sha="$(sha256sum "$work_dir/M8_CANDIDATE.signature.tsv" | awk '{print $1}')"
candidate_sha="$(sha256sum "$candidate_source" | awk '{print $1}')"
signature_rows="$(wc -l < "$work_dir/M8_CANDIDATE.signature.tsv")"

echo "SOFTMAX_EXACT_PARENT_AB_PASS parent_sha=$actual_parent_sha candidate_sha=$candidate_sha signature_sha=$signature_sha signature_rows=$signature_rows"
