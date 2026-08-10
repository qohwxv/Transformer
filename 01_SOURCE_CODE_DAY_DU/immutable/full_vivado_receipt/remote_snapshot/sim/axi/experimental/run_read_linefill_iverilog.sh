#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vit-read-linefill.XXXXXX")"
trap 'rm -rf -- "${BUILD_DIR}"' EXIT

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_axi_read_linefill_experimental \
    -o "${BUILD_DIR}/read_linefill.vvp" \
    "${REPO_ROOT}/experimental/rtl/axi/vit_axi_read_linefill_experimental.sv" \
    "${SCRIPT_DIR}/tb_vit_axi_read_linefill_experimental.sv"

vvp "${BUILD_DIR}/read_linefill.vvp"
