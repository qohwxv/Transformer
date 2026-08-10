#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cd "${repo_dir}"

iverilog -g2012 -Wall -Wno-timescale \
    -s tb_m5_profile_burst_queue \
    -o "${tmp_dir}/m5_profile_burst_queue.vvp" \
    -c sim/m5/m5_profile_burst_queue_iverilog.f
vvp "${tmp_dir}/m5_profile_burst_queue.vvp"

iverilog -g2012 -Wall -Wno-timescale \
    -s tb_m5_axi_counter_bank \
    -o "${tmp_dir}/m5_axi_counter_bank.vvp" \
    -c sim/m5/m5_axi_counter_bank_iverilog.f
vvp "${tmp_dir}/m5_axi_counter_bank.vvp"

echo "M5_COUNTER_REGRESSION_PASS"
