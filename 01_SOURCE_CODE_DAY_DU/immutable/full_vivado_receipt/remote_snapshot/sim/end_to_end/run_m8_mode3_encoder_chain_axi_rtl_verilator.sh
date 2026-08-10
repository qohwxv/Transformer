#!/usr/bin/env bash
set -euo pipefail

# One continuous accumulated layer0..11 qualification.  Layer 0 is anchored
# to T004; every later layer is bound to the preceding RTL dump and PASS report.
vit_m8_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${vit_m8_script_dir}/run_m8_mode3_encoder_real_axi_rtl_verilator.sh" \
    --first-layer 0 --last-layer 11 --input-mode chain
