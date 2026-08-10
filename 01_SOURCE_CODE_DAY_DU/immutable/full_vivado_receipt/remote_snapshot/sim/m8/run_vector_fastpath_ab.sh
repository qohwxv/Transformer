#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_m8_vector_ab.XXXXXX)"

cd "${repo_root}"

parent_source="sim/m8/reference/vit_vector_engine_fp32_parent_v1_12.sv"
candidate_source="rtl/blocks/vector/vit_vector_engine_fp32.sv"
testbench="sim/vector/tb_vit_vector_engine_fp32.sv"
expected_parent_sha="0aa640ad395ef79dada35b287fec615e54047bd578d6e5c15fe4b734d55fc1fa"

actual_parent_sha="$(sha256sum "${parent_source}" | awk '{print $1}')"
if [[ "${actual_parent_sha}" != "${expected_parent_sha}" ]]; then
    echo "ERROR: M7 v1.12 vector reference hash mismatch" >&2
    exit 1
fi

common_sources=(
    rtl/pkg/vit_fp32_pkg.sv
    rtl/leaf/common/vit_lane_mask.sv
    rtl/leaf/fp32/vit_fp32_add_comb.sv
    rtl/leaf/fp32/vit_fp32_mul_comb_nodsp.sv
    rtl/blocks/vector/vit_vector_lane_alu.sv
    rtl/blocks/vector/vit_vector_datapath.sv
)

iverilog \
    -g2012 \
    -Wall \
    -DM8_PARENT_BASELINE \
    -s tb_vit_vector_engine_fp32 \
    -o "${build_dir}/parent.vvp" \
    "${common_sources[@]}" \
    "${parent_source}" \
    "${testbench}"
vvp "${build_dir}/parent.vvp" | tee "${build_dir}/parent.log"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_vector_engine_fp32 \
    -o "${build_dir}/candidate.vvp" \
    "${common_sources[@]}" \
    "${candidate_source}" \
    "${testbench}"
vvp "${build_dir}/candidate.vvp" | tee "${build_dir}/candidate.log"

grep -Fq \
    "VECTOR_ENGINE_PASS implementation=M7_PARENT add_cycles=72 scale_mask_cycles=37 scale_nomask_cycles=37" \
    "${build_dir}/parent.log"
grep -Fq \
    "VECTOR_ENGINE_PASS implementation=M8_FASTPATH add_cycles=40 scale_mask_cycles=37 scale_nomask_cycles=21" \
    "${build_dir}/candidate.log"

echo "M8_VECTOR_FASTPATH_AB_PASS add_parent=72 add_m8=40 add_speedup=1.800000000x add_reduction_pct=44.444444444 scale_nomask_parent=37 scale_nomask_m8=21 scale_nomask_speedup=1.761904762x scale_nomask_reduction_pct=43.243243243 masked_cycles_unchanged=37"

