#!/usr/bin/env bash
set -euo pipefail

vit_cache_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_cache_root}"

vit_cache_tmp="$(mktemp -d /tmp/vit_gemm_bias_cache.XXXXXX)"
trap 'rm -rf -- "${vit_cache_tmp}"' EXIT

iverilog \
    -g2012 \
    -s tb_vit_gemm_bias_cache \
    -o "${vit_cache_tmp}/tb.vvp" \
    -c sim/gemm/vit_gemm_bias_cache_iverilog.f

vvp "${vit_cache_tmp}/tb.vvp"
