#!/usr/bin/env bash
set -euo pipefail

vit_tile_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_tile_root}"

for vit_tile_tool in iverilog vvp; do
    if ! command -v "${vit_tile_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_tile_tool}"
        exit 1
    fi
done

vit_tile_tmp="$(mktemp -d /tmp/vit_gemm_tile_sweep.XXXXXX)"
trap 'rm -rf -- "${vit_tile_tmp}"' EXIT

vit_tile_shapes=(
    "1 1"
    "4 2"
    "8 2"
    "4 4"
    "8 4"
)

for vit_tile_shape in "${vit_tile_shapes[@]}"; do
    read -r vit_tile_rows vit_tile_cols <<<"${vit_tile_shape}"
    vit_tile_image="${vit_tile_tmp}/gemm_${vit_tile_rows}x${vit_tile_cols}.vvp"
    vit_tile_log="${vit_tile_tmp}/gemm_${vit_tile_rows}x${vit_tile_cols}.log"

    printf 'RUN  GEMM tile shape %sx%s\n' \
        "${vit_tile_rows}" "${vit_tile_cols}"
    if ! iverilog \
        -g2012 \
        -s tb_vit_phase_e_engine_gemm_memory \
        -Ptb_vit_phase_e_engine_gemm_memory.ARRAY_ROWS="${vit_tile_rows}" \
        -Ptb_vit_phase_e_engine_gemm_memory.ARRAY_COLS="${vit_tile_cols}" \
        -o "${vit_tile_image}" \
        -c sim/gemm/vit_phase_e_engine_gemm_memory_iverilog.f \
        >"${vit_tile_log}" 2>&1; then
        tail -n 200 "${vit_tile_log}"
        exit 1
    fi
    vvp "${vit_tile_image}"
done

printf '%s\n' "PASS GEMM tile-shape sweep"
