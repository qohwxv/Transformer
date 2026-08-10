#!/usr/bin/env bash
set -euo pipefail

vit_m8_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${vit_m8_script_dir}/run_m8_mode3_encoder_real_axi_rtl_verilator.sh" \
    --first-layer 0 --last-layer 0 --input-mode independent
