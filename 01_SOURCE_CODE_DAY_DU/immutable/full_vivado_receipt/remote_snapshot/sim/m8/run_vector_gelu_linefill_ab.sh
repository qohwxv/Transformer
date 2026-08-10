#!/usr/bin/env bash
set -euo pipefail

m8_sim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
m8_root="$(cd "${m8_sim_dir}/../.." && pwd)"
m8_tmp="$(mktemp -d /tmp/vit_m8_linefill_ab.XXXXXX)"

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

compile_variant() {
    local label="$1"
    local router_source="$2"
    local define_arg="$3"
    local compile_log="${m8_tmp}/${label}.compile.log"
    local -a sources=()
    local source

    while IFS= read -r source; do
        [[ -z "${source}" || "${source}" == \#* ]] && continue
        if [[ "${source}" == "rtl/core/vit_phase_e_read_address_router.sv" ]]; then
            sources+=("${router_source}")
        else
            sources+=("${source}")
        fi
    done < filelists/core_no_axi.f

    if ! iverilog \
        -g2012 \
        -Wall \
        ${define_arg} \
        -s tb_m8_vector_gelu_linefill_integration \
        -o "${m8_tmp}/${label}.vvp" \
        "${sources[@]}" \
        rtl/axi/memory/vit_phase_e_axi_mem_adapter.sv \
        sim/axi/vit_axi_ddr_model_128.sv \
        sim/m8/tb_m8_vector_gelu_linefill_integration.sv \
        >"${compile_log}" 2>&1; then
        cat "${compile_log}" >&2
        return 1
    fi
}

run_case() {
    local label="$1"
    local seed_value="$2"
    local negative_value="$3"
    local run_log="${m8_tmp}/${label}.seed${seed_value}.neg${negative_value}.log"

    if ! vvp "${m8_tmp}/${label}.vvp" \
        +SEED="${seed_value}" \
        +NEGATIVE="${negative_value}" \
        >"${run_log}" 2>&1; then
        cat "${run_log}" >&2
        return 1
    fi
    grep -E '^(TRAFFIC_SUMMARY|M8_LINEFILL_INTEGRATION_PASS) ' "${run_log}"
}

compile_variant parent "${parent_router}" ""
compile_variant candidate "${candidate_router}" "-DM8_CANDIDATE_ROUTER"

run_case parent 1 0
run_case candidate 1 0
run_case candidate 7 0
run_case candidate 305419896 0

run_case parent 17 1
run_case parent 23 2
run_case candidate 17 1
run_case candidate 23 2
run_case candidate 29 3

parent_positive="${m8_tmp}/parent.seed1.neg0.log"
candidate_positive="${m8_tmp}/candidate.seed1.neg0.log"
grep '^REQ_TRACE ' "${parent_positive}" >"${m8_tmp}/parent.req"
grep '^REQ_TRACE ' "${candidate_positive}" >"${m8_tmp}/candidate.req"
grep '^RESULT_TRACE ' "${parent_positive}" >"${m8_tmp}/parent.result"
grep '^RESULT_TRACE ' "${candidate_positive}" >"${m8_tmp}/candidate.result"

cmp -s "${m8_tmp}/parent.req" "${m8_tmp}/candidate.req"
cmp -s "${m8_tmp}/parent.result" "${m8_tmp}/candidate.result"

req_sha="$(sha256sum "${m8_tmp}/candidate.req" | awk '{print $1}')"
result_sha="$(sha256sum "${m8_tmp}/candidate.result" | awk '{print $1}')"
echo "M8_VECTOR_GELU_LINEFILL_AB_PASS parent_router_sha=${expected_parent_sha} req_trace_sha=${req_sha} result_trace_sha=${result_sha} positive_seeds=3 negative_cases=5"
