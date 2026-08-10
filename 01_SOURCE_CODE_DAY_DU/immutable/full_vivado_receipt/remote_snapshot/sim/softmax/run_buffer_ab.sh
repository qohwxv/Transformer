#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/vit_m8_softmax_ab.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cd "$repo_root"

if command -v verilator >/dev/null 2>&1; then
    verilator \
        --binary \
        --timing \
        -O3 \
        -j 1 \
        -Wno-fatal \
        -Wno-PINCONNECTEMPTY \
        -Wno-UNUSEDSIGNAL \
        -Wno-BLKSEQ \
        --Mdir "$work_dir/obj" \
        -f sim/softmax/vit_softmax_engine_buffer_ab_iverilog.f \
        --top-module tb_vit_softmax_engine_fp32_buffer_ab
    "$work_dir/obj/Vtb_vit_softmax_engine_fp32_buffer_ab"
else
    iverilog \
        -g2012 \
        -s tb_vit_softmax_engine_fp32_buffer_ab \
        -o "$work_dir/softmax_buffer_ab.vvp" \
        -f sim/softmax/vit_softmax_engine_buffer_ab_iverilog.f
    vvp "$work_dir/softmax_buffer_ab.vvp"
fi
