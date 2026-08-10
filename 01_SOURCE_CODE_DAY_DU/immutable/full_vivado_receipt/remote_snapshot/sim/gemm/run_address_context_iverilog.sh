#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_gemm_address_context.XXXXXX)"

cleanup() {
    rm -rf -- "${build_dir}"
}
trap cleanup EXIT

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_gemm_memory_address_context \
    -o "${build_dir}/tb_vit_gemm_memory_address_context.vvp" \
    -c sim/gemm/vit_gemm_memory_address_context_iverilog.f

vvp "${build_dir}/tb_vit_gemm_memory_address_context.vvp"
