#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vit-m5-axi128.XXXXXX")"
trap 'rm -rf -- "${BUILD_DIR}"' EXIT

SEED="${SEED:-1511464998}"
ITERATIONS="${ITERATIONS:-40}"

pushd "${SCRIPT_DIR}" >/dev/null
iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_axi_ddr_model_128 \
    -o "${BUILD_DIR}/tb_vit_axi_ddr_model_128.vvp" \
    -c vit_axi_ddr_model_128_iverilog.f
popd >/dev/null

vvp "${BUILD_DIR}/tb_vit_axi_ddr_model_128.vvp" \
    "+SEED=${SEED}" \
    "+ITERATIONS=${ITERATIONS}"
