#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_fp32_special_leaf.XXXXXX)"

cleanup() {
    rm -rf -- "${build_dir}"
}
trap cleanup EXIT

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_fp32_special_leaf \
    -o "${build_dir}/tb_vit_fp32_special_leaf.vvp" \
    -c sim/leaf/fp32/vit_fp32_special_leaf_rtl.f \
    sim/leaf/fp32/tb_vit_fp32_special_leaf.sv

vvp "${build_dir}/tb_vit_fp32_special_leaf.vvp"
