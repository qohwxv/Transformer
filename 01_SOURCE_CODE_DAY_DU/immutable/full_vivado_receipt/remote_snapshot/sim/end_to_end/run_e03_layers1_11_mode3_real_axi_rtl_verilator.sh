#!/usr/bin/env bash
set -euo pipefail

# E03 deliberately starts from a separately receipt-bound E02 output. The
# generic runner requires output/report/manifest paths plus the externally
# recorded manifest SHA-256 and rejects any mismatch before build or layer 1.
vit_m8_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${vit_m8_script_dir}/run_m8_mode3_encoder_real_axi_rtl_verilator.sh" \
    --first-layer 1 --last-layer 11 --input-mode chain
