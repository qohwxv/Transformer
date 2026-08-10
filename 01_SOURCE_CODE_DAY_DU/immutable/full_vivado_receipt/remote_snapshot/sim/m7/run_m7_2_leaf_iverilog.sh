#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="${revision_root}/build/m7_2_leaf"
vector_file="${build_dir}/fp32_to_fp16_rne.vec"
filelist="${revision_root}/filelists/vit_gemm_fp16_stream_array_iverilog.f"

mkdir -p "${build_dir}"

python3 "${script_dir}/generate_fp32_to_fp16_vectors.py" \
    --output "${vector_file}" \
    --random-count 16384

(
    cd "${revision_root}"
    iverilog -g2012 -Wall \
        -s tb_vit_fp32_to_fp16_rne \
        -o "${build_dir}/tb_fp32_to_fp16.vvp" \
        -f "${filelist}" \
        >"${build_dir}/compile_fp32_to_fp16.log" 2>&1
)
vvp "${build_dir}/tb_fp32_to_fp16.vvp" \
    +VECTOR_FILE="${vector_file}" \
    | tee "${build_dir}/run_fp32_to_fp16.log"

(
    cd "${revision_root}"
    iverilog -g2012 -Wall \
        -s tb_vit_gemm_fp16_stream_array \
        -Ptb_vit_gemm_fp16_stream_array.STREAMS=16 \
        -o "${build_dir}/tb_stream_array_16.vvp" \
        -f "${filelist}" \
        >"${build_dir}/compile_stream_array_16.log" 2>&1
)
vvp "${build_dir}/tb_stream_array_16.vvp" \
    | tee "${build_dir}/run_stream_array_16.log"

(
    cd "${revision_root}"
    iverilog -g2012 -Wall \
        -s tb_vit_gemm_fp16_stream_array \
        -Ptb_vit_gemm_fp16_stream_array.STREAMS=8 \
        -o "${build_dir}/tb_stream_array_8.vvp" \
        -f "${filelist}" \
        >"${build_dir}/compile_stream_array_8.log" 2>&1
)
vvp "${build_dir}/tb_stream_array_8.vvp" \
    | tee "${build_dir}/run_stream_array_8.log"

(
    cd "${revision_root}"
    verilator --lint-only --timing -Wall -Wno-fatal \
        --top-module vit_gemm_fp16_stream_array \
        -f "${filelist}" \
        >"${build_dir}/verilator_lint.log" 2>&1
)

echo "PASS M7_2_LEAF_REGRESSION"
