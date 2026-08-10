#!/usr/bin/env bash
set -euo pipefail

vit_config_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_config_root}"

if ! command -v iverilog >/dev/null 2>&1 ||
   ! command -v vvp >/dev/null 2>&1; then
    printf '%s\n' "ERROR: Icarus Verilog (iverilog + vvp) is required"
    exit 1
fi

vit_config_tmp="$(mktemp -d /tmp/vit_total_words_config.XXXXXX)"
trap 'rm -rf -- "${vit_config_tmp}"' EXIT

printf '%s\n' "RUN total_words configuration boundary test (Icarus)"
iverilog \
    -g2012 \
    -s tb_vit_total_words_config_bounds \
    -o "${vit_config_tmp}/vit_total_words_config_bounds.vvp" \
    -c sim/config/vit_total_words_config_bounds.f \
    >"${vit_config_tmp}/compile.log" 2>&1

vvp "${vit_config_tmp}/vit_total_words_config_bounds.vvp"
