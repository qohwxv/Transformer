#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision_root="$(cd "${script_dir}/../../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_fp32_add_feedforward_ab.XXXXXX)"

cleanup() {
    rm -rf -- "${build_dir}"
}
trap cleanup EXIT

cd "${revision_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_fp32_add_feedforward_ab \
    -o "${build_dir}/tb_vit_fp32_add_feedforward_ab.vvp" \
    -c sim/leaf/fp32/vit_fp32_add_feedforward_ab_iverilog.f

vvp "${build_dir}/tb_vit_fp32_add_feedforward_ab.vvp"
