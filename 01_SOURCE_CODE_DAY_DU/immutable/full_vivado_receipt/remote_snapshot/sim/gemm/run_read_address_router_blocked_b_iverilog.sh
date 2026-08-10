#!/usr/bin/env bash
set -euo pipefail

vit_router_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vit_router_tmp="$(mktemp -d /tmp/vit_read_router_blocked_b.XXXXXX)"
trap 'rm -rf -- "${vit_router_tmp}"' EXIT

cd "${vit_router_root}"

iverilog \
    -g2012 \
    -Wall \
    -s tb_vit_phase_e_read_address_router_blocked_b \
    -o "${vit_router_tmp}/tb.vvp" \
    -c sim/gemm/vit_phase_e_read_address_router_blocked_b_iverilog.f

vvp "${vit_router_tmp}/tb.vvp"
