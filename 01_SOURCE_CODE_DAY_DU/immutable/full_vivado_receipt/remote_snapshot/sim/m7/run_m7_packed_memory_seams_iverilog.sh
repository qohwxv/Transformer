#!/usr/bin/env bash
set -euo pipefail

m7_sim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m7_root="$(cd "${m7_sim_dir}/../.." && pwd)"
m7_tmp="$(mktemp -d /tmp/vit_m7_packed_memory.XXXXXX)"

cleanup() {
    rm -rf -- "${m7_tmp}"
}
trap cleanup EXIT

cd "${m7_root}"

run_case() {
    local case_name="$1"
    local top_name="$2"
    local filelist="$3"
    local compile_log="${m7_tmp}/${case_name}.compile.log"

    if ! iverilog \
        -g2012 \
        -Wall \
        -s "${top_name}" \
        -o "${m7_tmp}/${case_name}.vvp" \
        -c "${filelist}" \
        >"${compile_log}" 2>&1; then
        cat "${compile_log}" >&2
        return 1
    fi

    vvp "${m7_tmp}/${case_name}.vvp"
}

run_case \
    packed_router \
    tb_m7_packed_read_address_router \
    sim/m7/m7_packed_read_address_router_iverilog.f
run_case \
    packed_context \
    tb_m7_packed_address_context \
    sim/m7/m7_packed_address_context_iverilog.f
run_case \
    packed_dispatch \
    tb_m7_packed_engine_dispatch \
    sim/m7/m7_packed_engine_dispatch_iverilog.f
run_case \
    packed_frontend \
    tb_m7_packed_memory_frontend \
    sim/m7/m7_packed_memory_frontend_iverilog.f
run_case \
    vector_activation_cache_frontend \
    tb_m7_vector_activation_cache_frontend \
    sim/m7/m7_packed_memory_frontend_iverilog.f
run_case \
    activation_cache_leaf_pipeline \
    tb_m7_activation_cache_leaf_pipeline \
    sim/m7/m7_activation_cache_leaf_iverilog.f

echo "PASS M7 packed memory seams: 6/6 cases"
