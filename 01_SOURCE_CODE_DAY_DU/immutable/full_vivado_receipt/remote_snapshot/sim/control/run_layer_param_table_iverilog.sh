#!/usr/bin/env bash
set -euo pipefail

vit_layer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_layer_root}"

for vit_layer_tool in iverilog vvp; do
    if ! command -v "${vit_layer_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_layer_tool}"
        exit 1
    fi
done

vit_layer_tmp="$(mktemp -d /tmp/vit_layer_param.XXXXXX)"
trap 'rm -rf -- "${vit_layer_tmp}"' EXIT

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_layer_param_table_loader \
    -o "${vit_layer_tmp}/tb.vvp" \
    -c filelists/layer_param_table_loader_iverilog.f

vvp "${vit_layer_tmp}/tb.vvp"
