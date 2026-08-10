#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
build_dir="$(mktemp -d /tmp/vit_activation_norm.XXXXXX)"

cd "${repo_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_activation_norm_leaf_equivalence \
    -o "${build_dir}/tb_vit_activation_norm_leaf_equivalence.vvp" \
    -c sim/blocks/activation_norm/vit_activation_norm_leaf_iverilog.f \
    sim/blocks/activation_norm/tb_vit_activation_norm_leaf_equivalence.sv

vvp "${build_dir}/tb_vit_activation_norm_leaf_equivalence.vvp"
