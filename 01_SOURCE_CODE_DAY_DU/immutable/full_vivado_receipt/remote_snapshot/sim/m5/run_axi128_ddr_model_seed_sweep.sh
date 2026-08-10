#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SEEDS=(1511464998 305419896 195936478 826366246)

for seed in "${SEEDS[@]}"; do
    echo "M5 AXI128 randomized seed ${seed}"
    SEED="${seed}" ITERATIONS="${ITERATIONS:-40}" \
        "${SCRIPT_DIR}/run_axi128_ddr_model_iverilog.sh"
done

for seed in "${SEEDS[@]}"; do
    echo "M5 AXI128 adapter-integration seed ${seed}"
    SEED="${seed}" ITERATIONS="${ITERATIONS:-40}" \
        "${SCRIPT_DIR}/run_axi128_adapter_integration_iverilog.sh"
done
