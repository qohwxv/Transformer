#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_argmax.XXXXXX)"

cleanup() {
    rm -rf -- "${build_dir}"
}
trap cleanup EXIT

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_argmax_engine_fp32 \
    -o "${build_dir}/tb_vit_argmax_engine_fp32.vvp" \
    -c sim/argmax/vit_argmax_engine_iverilog.f \
    sim/argmax/tb_vit_argmax_engine_fp32.sv

vvp "${build_dir}/tb_vit_argmax_engine_fp32.vvp"
