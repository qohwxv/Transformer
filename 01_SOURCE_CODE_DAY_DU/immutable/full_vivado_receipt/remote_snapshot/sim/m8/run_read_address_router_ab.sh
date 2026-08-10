#!/usr/bin/env bash
set -euo pipefail

m8_sim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m8_root="$(cd "${m8_sim_dir}/../.." && pwd)"
m8_tmp="$(mktemp -d /tmp/vit_m8_router_ab.XXXXXX)"

cleanup() {
    rm -rf -- "${m8_tmp}"
}
trap cleanup EXIT

parent_router="${m8_root}/sim/m8/reference/vit_phase_e_read_address_router_parent_v1_12.sv"
candidate_router="${m8_root}/rtl/core/vit_phase_e_read_address_router.sv"
expected_parent_sha="5e2a44ed50a48a16dfd428d4c9fe36669b11052a5aadc94d23027d22f21a5319"

if [[ "$(sha256sum "${parent_router}" | awk '{print $1}')" != "${expected_parent_sha}" ]]; then
    echo "ERROR: exact M7-S8 parent router identity changed" >&2
    exit 1
fi

cd "${m8_root}"

compile_and_run() {
    local label="$1"
    local router_source="$2"
    local define_arg="$3"
    local compile_log="${m8_tmp}/${label}.compile.log"
    local run_log="${m8_tmp}/${label}.run.log"

    if ! iverilog \
        -g2012 \
        -Wall \
        ${define_arg} \
        -s tb_m8_read_address_router \
        -o "${m8_tmp}/${label}.vvp" \
        rtl/pkg/vit_phase_e_pkg.sv \
        "${router_source}" \
        sim/m8/tb_m8_read_address_router.sv \
        >"${compile_log}" 2>&1; then
        cat "${compile_log}" >&2
        return 1
    fi
    if ! vvp "${m8_tmp}/${label}.vvp" >"${run_log}" 2>&1; then
        cat "${run_log}" >&2
        return 1
    fi
    grep '^M8_ROUTER_PASS ' "${run_log}"
}

compile_and_run parent "${parent_router}" ""
compile_and_run candidate "${candidate_router}" "-DM8_CANDIDATE_ROUTER"

grep '^BASE_TRACE ' "${m8_tmp}/parent.run.log" >"${m8_tmp}/parent.base"
grep '^BASE_TRACE ' "${m8_tmp}/candidate.run.log" >"${m8_tmp}/candidate.base"
grep '^LEGACY_TRACE ' "${m8_tmp}/parent.run.log" >"${m8_tmp}/parent.legacy"
grep '^LEGACY_TRACE ' "${m8_tmp}/candidate.run.log" >"${m8_tmp}/candidate.legacy"

cmp -s "${m8_tmp}/parent.base" "${m8_tmp}/candidate.base"
cmp -s "${m8_tmp}/parent.legacy" "${m8_tmp}/candidate.legacy"

base_sha="$(sha256sum "${m8_tmp}/candidate.base" | awk '{print $1}')"
legacy_sha="$(sha256sum "${m8_tmp}/candidate.legacy" | awk '{print $1}')"
echo "M8_ROUTER_AB_PASS parent_sha=${expected_parent_sha} base_trace_sha=${base_sha} legacy_trace_sha=${legacy_sha}"
