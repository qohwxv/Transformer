#!/usr/bin/env bash
set -euo pipefail

receipt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${receipt_root}"

sha256sum -c RECEIPT_SHA256SUMS.txt >/dev/null

expected_source_sha="db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
expected_filelist_sha="88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"

source_count="$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | wc -l)"
unique_source_count="$({ tail -n +2 PRODUCTION_SOURCE_STATE.txt | awk '{print $2}'; } | sort -u | wc -l)"
[[ "${source_count}" == "80" ]]
[[ "${unique_source_count}" == "80" ]]

source_sha="$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | sha256sum | awk '{print $1}')"
filelist_sha="$(sha256sum input_snapshot/filelists/full_axi.f | awk '{print $1}')"
[[ "${source_sha}" == "${expected_source_sha}" ]]
[[ "${filelist_sha}" == "${expected_filelist_sha}" ]]

(
    cd input_snapshot
    tail -n +2 ../PRODUCTION_SOURCE_STATE.txt | sha256sum -c - >/dev/null
)

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

first_log="raw_remote_runs/20260808T171600Z-m8-xsim-observation-checkcount/xsim_observation.log"
repeat_log="raw_remote_runs/20260808T172400Z-m8-xsim-exact-repeat/xsim_exact_repeat.log"
signature_pattern='^(VIT_PHASE_E_AXI_MEM_ADAPTER_TEST_PASS|VIT_PHASE_E_AXI_WRAPPER_TEST_PASS|PASS engine logical-memory test:|VIT_PHASE_E_ENGINE_AXI_TEST_PASS|VIT_PHASE_E_PERF_COUNTERS_TEST_PASS|VIT_PHASE_E_PROFILE_COUNTERS_TEST_PASS|M7_OVERLAP_COUNTER_BANK_PASS|VIT_PHASE_E_AXI_E05_COMPACT_RTL_MODE_REJECT_PASS|VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS)'

grep -E "${signature_pattern}" "${first_log}" >"${tmp_root}/first.signatures"
grep -E "${signature_pattern}" "${repeat_log}" >"${tmp_root}/repeat.signatures"
[[ "$(wc -l <"${tmp_root}/first.signatures")" == "10" ]]
[[ "$(wc -l <"${tmp_root}/repeat.signatures")" == "10" ]]
cmp "${tmp_root}/first.signatures" PASS_SIGNATURES_FIRST.txt
cmp "${tmp_root}/repeat.signatures" PASS_SIGNATURES_REPEAT.txt
cmp PASS_SIGNATURES_FIRST.txt PASS_SIGNATURES_REPEAT.txt

grep -E '^VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 ' \
    "${first_log}" >"${tmp_root}/first.metric"
grep -E '^VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 ' \
    "${repeat_log}" >"${tmp_root}/repeat.metric"
[[ "$(wc -l <"${tmp_root}/first.metric")" == "1" ]]
[[ "$(wc -l <"${tmp_root}/repeat.metric")" == "1" ]]
cmp "${tmp_root}/first.metric" COMPACT_MODE3_METRIC_FIRST.txt
cmp "${tmp_root}/repeat.metric" COMPACT_MODE3_METRIC_REPEAT.txt
cmp COMPACT_MODE3_METRIC_FIRST.txt COMPACT_MODE3_METRIC_REPEAT.txt

suite_marker='^PASS: production AXI/engine/profile/M7 smoke plus compact mode0/mode1 rejection and exact mode3 E05 XSim completed$'
[[ "$(grep -Ecx "${suite_marker}" "${first_log}")" == "1" ]]
[[ "$(grep -Ecx "${suite_marker}" "${repeat_log}")" == "1" ]]

severe_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL|Error|Fatal):|(^|[[:space:]])FAIL([[:space:]:]|$)|%Error|%Fatal'
! grep -En -- "${severe_pattern}" "${first_log}"
! grep -En -- "${severe_pattern}" "${repeat_log}"

grep -Fq 'iverilog: command not found' \
    raw_remote_runs/20260808T165200Z-m8-sim-observation/vector_fastpath.log
grep -Fq 'exact M7-S8 parent router identity changed' \
    raw_remote_runs/20260808T165900Z-m8-sim-observation-portable-iverilog/vector_gelu_linefill.log
grep -Fq 'Illegal value "1" passed to "-mt" switch' \
    raw_remote_runs/20260808T170200Z-m8-sim-observation-selfcontained/xsim_observation.log
grep -Fq 'XSim exact PASS marker count for tb_vit_phase_e_engine_memory is 0; expected 1' \
    raw_remote_runs/20260808T171100Z-m8-xsim-observation/xsim_observation.log

printf '%s\n' \
    'M8_XSIM_RECEIPT_VERIFY_PASS sources=80 xsim_cases=10 repeat=exact compact_metric=byte_identical expected_harness_failures=4 disposition=SAFE_FOR_NEXT_M8_NONBOARD_GATE'
