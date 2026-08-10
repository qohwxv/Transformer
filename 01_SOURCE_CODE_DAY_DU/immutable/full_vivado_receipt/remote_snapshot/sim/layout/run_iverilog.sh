#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_layout.XXXXXX)"

cleanup() {
    rm -rf -- "${build_dir}"
}
trap cleanup EXIT

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_layout_engine \
    -o "${build_dir}/tb_vit_layout_engine.vvp" \
    -c sim/layout/vit_layout_engine_iverilog.f \
    sim/layout/tb_vit_layout_engine.sv

vvp "${build_dir}/tb_vit_layout_engine.vvp"
