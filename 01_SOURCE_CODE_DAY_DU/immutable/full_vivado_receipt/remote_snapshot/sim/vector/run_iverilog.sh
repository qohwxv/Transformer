#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_vector.XXXXXX)"

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_vector_engine_fp32 \
    -o "${build_dir}/tb_vit_vector_engine_fp32.vvp" \
    -c sim/vector/vit_vector_engine_iverilog.f \
    sim/vector/tb_vit_vector_engine_fp32.sv

vvp "${build_dir}/tb_vit_vector_engine_fp32.vvp"
