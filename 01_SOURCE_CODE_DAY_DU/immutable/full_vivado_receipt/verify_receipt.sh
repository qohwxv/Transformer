#!/usr/bin/env bash
set -euo pipefail

receipt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${receipt_root}"

expected_snapshot_manifest="9cb13a07c059730f36c1e70634657a465e2e7953790e4476da2459d997e4cc29"
expected_development_manifest="67c18532e3bb16b24ec6983f99cc54a3ffafb05fe6c02cf0385465c316b31078"
expected_ordered_source="db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
expected_filelist="88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"
expected_bundle="25c430d3ef64b23ed083a9a43c2400c924f9c8091920c3de954a8ba4a844c9a5"
expected_abi="b15765c858edb0785c34ea75fa50fa5df873f1d22cd53ed2bc0b898db13d8e90"
expected_strict_verifier="edff30ef9da8b065c3002e6fd6a5ff31efb6ee19fc03470535d9c7cd930bca6f"
expected_output_manifest="02f73467949162224f1140f54259a64e8cfbc7bf5fe63ef40c10baf5da7432d9"
expected_run_status="37c289ecbac5801bd876141614d3e9a7e4b00eef8e7e69aa362d9a80adc30362"
expected_outer_log="1fa94c0852808b30b101c6290956b1af900cbce8d63ff20f5d2fc708b7902dcd"
expected_ooc_dcp="6d8a617b8fe33a7d9b37297226f24b23d7bb168e5606d1acf49c543b393467c5"
expected_board_dcp="59458d0a80211a5832f59f40968b13b85c1fd8a41a457ea4f2c0fc909569f974"
expected_route_dcp="73c5ee9861774e3dc9fb09d44b72953ca9e05b5bbc1d47f0f8bbc2f14f44c409"
expected_bit="462d78a91d9fb35b2cb5832ab222c39952a1052d3ff6766d94e37405f887a275"
expected_xsa="47e764324d9eaedcc343b3cdf66190dbb90635cf8e51b4f6e65b4746c43680ee"

sha256sum -c RECEIPT_SHA256SUMS.txt >/dev/null

receipt_manifest_sha="$(sha256sum RECEIPT_SHA256SUMS.txt | awk '{print $1}')"
[[ "$(cat RECEIPT_MANIFEST.sha256)" == "${receipt_manifest_sha}  RECEIPT_SHA256SUMS.txt" ]]

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT

cut -c67- RECEIPT_SHA256SUMS.txt | LC_ALL=C sort >"${tmp_root}/declared_receipt"
find . -type f -printf '%P\n' \
    | awk '$0 != "RECEIPT_SHA256SUMS.txt" && $0 != "RECEIPT_MANIFEST.sha256"' \
    | LC_ALL=C sort >"${tmp_root}/current_receipt"
cmp "${tmp_root}/declared_receipt" "${tmp_root}/current_receipt"
[[ "$(wc -l <"${tmp_root}/declared_receipt")" == \
   "$(sort -u "${tmp_root}/declared_receipt" | wc -l)" ]]
[[ "$(find . -type l | wc -l)" == "0" ]]

[[ "$(sha256sum REMOTE_SNAPSHOT_SHA256SUMS.txt | awk '{print $1}')" == \
   "${expected_snapshot_manifest}" ]]
[[ "$(wc -l <REMOTE_SNAPSHOT_SHA256SUMS.txt)" == "1193" ]]
cut -c67- REMOTE_SNAPSHOT_SHA256SUMS.txt | LC_ALL=C sort >"${tmp_root}/declared_snapshot"
find remote_snapshot -type f -printf '%P\n' | LC_ALL=C sort >"${tmp_root}/current_snapshot"
cmp "${tmp_root}/declared_snapshot" "${tmp_root}/current_snapshot"
cmp TRANSFER_FILES.txt "${tmp_root}/current_snapshot"
[[ "$(find remote_snapshot -type f -printf '%s\n' | awk '{sum += $1} END {printf "%.0f", sum}')" == \
   "583642787" ]]
(
    cd remote_snapshot
    sha256sum -c ../REMOTE_SNAPSHOT_SHA256SUMS.txt >/dev/null
)

snapshot="remote_snapshot"
run_dir="${snapshot}/reports/m8/server_runs/20260809T032300Z-m8-board-candidate-67c18532"
artifact_dir="${snapshot}/VIT_googlebase_rtl/artifacts"
report_dir="${snapshot}/VIT_googlebase_rtl/reports"

[[ "$(sha256sum "${snapshot}/M8_DEVELOPMENT_SHA256SUMS.txt" | awk '{print $1}')" == \
   "${expected_development_manifest}" ]]
[[ "$(wc -l <"${snapshot}/M8_DEVELOPMENT_SHA256SUMS.txt")" == "409" ]]
(
    cd "${snapshot}"
    sha256sum -c M8_DEVELOPMENT_SHA256SUMS.txt >/dev/null
)

[[ "$(sha256sum "${artifact_dir}/OUTPUT_SHA256SUMS" | awk '{print $1}')" == \
   "${expected_output_manifest}" ]]
[[ "$(wc -l <"${artifact_dir}/OUTPUT_SHA256SUMS")" == "84" ]]
(
    cd "${snapshot}"
    sha256sum -c VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS >/dev/null
)

[[ "$(sha256sum "${snapshot}/filelists/full_axi.f" | awk '{print $1}')" == \
   "${expected_filelist}" ]]
[[ "$(sha256sum "${snapshot}/BUNDLE_INFO.json" | awk '{print $1}')" == \
   "${expected_bundle}" ]]
[[ "$(sha256sum "${snapshot}/docs/PERF_PROFILE_ABI_V1_13.json" | awk '{print $1}')" == \
   "${expected_abi}" ]]
[[ "$(sha256sum "${snapshot}/run/00_verify_m8_development.sh" | awk '{print $1}')" == \
   "${expected_strict_verifier}" ]]

strict_output="$(cd "${snapshot}" && ./run/00_verify_m8_development.sh)"
grep -Fxq \
    'M8_RECEIPT_CLOSURE_PASS receipts=6 entries=658 sidecars=3 payload_replay=FULL' \
    <<<"${strict_output}"
grep -Fxq \
    "M8_METADATA_PREFLIGHT_PASS sources=80 ordered=${expected_ordered_source} filelist=${expected_filelist} ip=0x0001000D abi=v1.13 parent=M7S8 receipts=BOUND full_vivado=PENDING bit_xsa=NOT_GENERATED" \
    <<<"${strict_output}"
grep -Fxq 'M8_DEVELOPMENT_MANIFEST_PASS entries=409' <<<"${strict_output}"
grep -Fxq "M8_DEVELOPMENT_MANIFEST_SHA256=${expected_development_manifest}" \
    <<<"${strict_output}"
grep -Fxq \
    'M8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M8_SEAL' \
    <<<"${strict_output}"

[[ "$(tr -d '[:space:]' <"${run_dir}/OUTER.exit")" == "0" ]]
[[ "$(tr -d '[:space:]' <"${run_dir}/OUTER.pid")" == "1878388" ]]
[[ "$(sha256sum "${run_dir}/OUTER.log" | awk '{print $1}')" == "${expected_outer_log}" ]]
outer_log="${run_dir}/OUTER.log"
[[ "$(grep -Ec '^PASS XSim:' "${outer_log}")" == "7" ]]
[[ "$(grep -Ec '^PASS XSim compact E05:' "${outer_log}")" == "3" ]]
for marker in \
    'PASS stage 00_preflight' \
    'PASS stage 20_ooc_synth' \
    'PASS stage 30_create_bd' \
    'PASS stage 40_board_synth' \
    'PASS stage 50_board_impl' \
    'PASS: production AXI/engine/profile/M7 smoke plus compact mode0/mode1 rejection and exact mode3 E05 XSim completed' \
    'PASS: production board implementation sign-off completed' \
    'M8_OUTPUT_COLLECTION_PASS status=VIT_googlebase_rtl/artifacts/RUN_STATUS.txt output=VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS' \
    'PASS: DEVELOPMENT_UNSEALED Vivado flow; no sealed/promotion claim'; do
    [[ "$(grep -Fxc "${marker}" "${outer_log}")" == "1" ]]
done
severe_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL):|(^|[[:space:]])FAIL([[:space:]:]|$)|%Error|%Fatal'
! grep -En -- "${severe_pattern}" "${outer_log}"

[[ "$(sha256sum "${artifact_dir}/RUN_STATUS.txt" | awk '{print $1}')" == \
   "${expected_run_status}" ]]
status_file="${artifact_dir}/RUN_STATUS.txt"
for marker in \
    'DEVELOPMENT_UNSEALED: every requested Vivado/XSim stage passed' \
    'MANIFEST_STATUS DEVELOPMENT_UNSEALED' \
    "M8_DEVELOPMENT_MANIFEST_SHA256 ${expected_development_manifest}" \
    "M8_ORDERED_SOURCE_SHA256 ${expected_ordered_source}" \
    "M8_FILELIST_SHA256 ${expected_filelist}" \
    'TERMINAL_M8_VERIFIER_RESULT PASS' \
    'COLLECTOR_M8_VERIFIER_RESULT PASS' \
    'VIT_REUSE_PROJECT 0' \
    'VIT_RUN_XSIM 1' \
    'VIT_RUN_OOC_SYNTH 1' \
    'VIT_RUN_IMPLEMENTATION 1' \
    'COLLECTOR_RESULT PASS' \
    'COLLECTOR_TERMINAL_MARKER M8_OUTPUT_COLLECTION_PASS'; do
    grep -Fxq "${marker}" "${status_file}"
done
terminal_verifier="${snapshot}/server_logs/90_terminal_m8_verifier.log"
collector_verifier="${snapshot}/server_logs/91_collector_m8_verifier.log"
[[ "$(sha256sum "${terminal_verifier}" | awk '{print $1}')" == \
   "8cf3db18a469e7afb71772a7e30d14ce8912ee197713205d166ee1e15468ed34" ]]
cmp "${terminal_verifier}" "${collector_verifier}"

grep -Fxq 'setup_wns 0.045' "${report_dir}/board_post_route_timing_gate.rpt"
grep -Fxq 'hold_whs 0.010' "${report_dir}/board_post_route_timing_gate.rpt"
grep -Fxq 'ROUTED_FULLY 1' "${report_dir}/board_post_route_route_gate.rpt"
grep -Fxq 'ERRORS_IN_ROUTES 0' "${report_dir}/board_post_route_route_gate.rpt"
grep -Fxq 'DSP48/DSP58 primitive count: 0' "${report_dir}/board_post_route_dsp.rpt"
grep -Fqx \
    'M8_RAM_HIERARCHY PASS stage=board_post_route total_ramb36=41 activation=32 bias=4 layernorm=3 softmax=1 layer_param=1 ramb18=0 uram=0 layernorm_lutram=0 softmax_lutram=0' \
    "${report_dir}/board_post_route_m8_ram_mapping.rpt"
grep -Fxq 'M8_DRC_GATE PASS stage=board_post_route total=0 severe=0' \
    "${report_dir}/board_post_route_drc_gate.rpt"
grep -Fxq 'M8_METHODOLOGY_GATE PASS stage=board_post_route total=0 severe=0' \
    "${report_dir}/board_post_route_methodology_gate.rpt"
grep -Fxq 'M8_CONSTRAINT_COVERAGE_GATE PASS stage=board_post_route failures=0' \
    "${report_dir}/board_post_route_constraint_coverage_gate.rpt"
grep -Fxq 'M8_BLACKBOX_GATE PASS stage=board_post_route count=0' \
    "${report_dir}/board_post_route_blackboxes.rpt"
grep -Fxq 'M8_LATCH_GATE PASS stage=board_post_route count=0' \
    "${report_dir}/board_post_route_latches.rpt"
grep -Fxq 'M8_COMBINATIONAL_LOOP_GATE PASS stage=board_post_route count=0' \
    "${report_dir}/board_post_route_combinational_loops.rpt"

awk '$1 == "setup_wns" {if ($2 < 0) exit 1; setup=1}
     $1 == "hold_whs" {if ($2 < 0) exit 1; hold=1}
     END {if (!setup || !hold) exit 1}' \
    "${report_dir}/board_post_route_timing_gate.rpt"

check_hash_size() {
    local path="$1"
    local expected_hash="$2"
    local expected_size="$3"
    [[ -f "${path}" && ! -L "${path}" ]]
    [[ "$(stat -c '%s' "${path}")" == "${expected_size}" ]]
    [[ "$(sha256sum "${path}" | awk '{print $1}')" == "${expected_hash}" ]]
}
check_hash_size "${artifact_dir}/rtl_ooc_post_synth.dcp" "${expected_ooc_dcp}" 32307867
check_hash_size "${artifact_dir}/board_post_synth.dcp" "${expected_board_dcp}" 35058563
check_hash_size "${artifact_dir}/board_post_route.dcp" "${expected_route_dcp}" 67855541
check_hash_size "${artifact_dir}/vit_system_wrapper.bit" "${expected_bit}" 7797814
check_hash_size "${artifact_dir}/vit_system_wrapper.xsa" "${expected_xsa}" 3855492

/usr/bin/python3 - "${artifact_dir}/vit_system_wrapper.xsa" \
    "${artifact_dir}/vit_system_wrapper.bit" "${expected_xsa}" "${expected_bit}" <<'PY'
import hashlib
import sys
import zipfile
from pathlib import Path

xsa = Path(sys.argv[1])
bit = Path(sys.argv[2])
expected_xsa = sys.argv[3]
expected_bit = sys.argv[4]
digest = lambda data: hashlib.sha256(data).hexdigest()
xsa_bytes = xsa.read_bytes()
bit_bytes = bit.read_bytes()
assert digest(xsa_bytes) == expected_xsa
assert digest(bit_bytes) == expected_bit
with zipfile.ZipFile(xsa) as archive:
    assert archive.testzip() is None
    bit_entries = sorted(name for name in archive.namelist() if name.endswith(".bit"))
    hwh_entries = sorted(name for name in archive.namelist() if name.endswith(".hwh"))
    assert bit_entries == ["vit_system_wrapper.bit"]
    assert hwh_entries == [
        "vit_system.hwh",
        "vit_system_smartconnect_control_0.hwh",
        "vit_system_smartconnect_ddr_0.hwh",
    ]
    assert archive.read(bit_entries[0]) == bit_bytes
PY

for audit in \
    REMOTE_OUTPUT_MANIFEST_REPLAY.log \
    LOCAL_OUTPUT_MANIFEST_REPLAY.log; do
    grep -Eq '_(REMOTE|LOCAL)_OUTPUT_MANIFEST_REPLAY_PASS|^(REMOTE|LOCAL)_OUTPUT_MANIFEST_REPLAY_PASS' "${audit}"
done
grep -Fq 'REMOTE_DEVELOPMENT_MANIFEST_REPLAY_PASS entries=409' \
    REMOTE_DEVELOPMENT_MANIFEST_REPLAY.log
grep -Fq 'LOCAL_DEVELOPMENT_MANIFEST_REPLAY_PASS entries=409' \
    LOCAL_DEVELOPMENT_MANIFEST_REPLAY.log
grep -Fxq 'REMOTE_STRICT_M8_VERIFIER_REPLAY_PASS' REMOTE_STRICT_M8_VERIFIER_REPLAY.log
grep -Fxq 'LOCAL_STRICT_M8_VERIFIER_REPLAY_PASS' LOCAL_STRICT_M8_VERIFIER_REPLAY.log
grep -Fxq 'REMOTE_REVISION_PROCESS_MATCHES=0' REMOTE_QUIESCENCE.txt
grep -Fxq 'XSA_REQUIRED_CONTENTS=PASS' XSA_INTEGRITY.txt
grep -Fxq 'XSA_EXTERNAL_BIT_EQUAL=PASS' XSA_INTEGRITY.txt

/usr/bin/python3 - STATUS.json <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["overall_status"] == "PASS_SAFE_FOR_BOARD_CANDIDATE_NOT_BOARD_TESTED"
assert status["physical_board_tested"] is False
assert status["source_manifest_status"] == "DEVELOPMENT_UNSEALED"
assert status["remote_local_sha256_compare"] == "PASS_1193_OF_1193"
assert status["implementation"]["setup_wns_ns"] >= 0
assert status["implementation"]["hold_whs_ns"] >= 0
assert status["implementation"]["dsp48_dsp58"] == 0
assert status["implementation"]["ramb36"] == 41
assert status["artifacts"]["xsa_external_bit_equal"] is True
PY

printf '%s\n' \
    "M8_FULL_VIVADO_RECEIPT_VERIFY_PASS snapshot_files=1193 snapshot_bytes=583642787 output_entries=84 development_entries=409 prior_receipts=6 xsim_cases=10 wns_ns=0.045 whs_ns=0.010 dsp=0 ramb36=41 route_errors=0 drc=0 methodology=0 disposition=SAFE_FOR_BOARD_CANDIDATE_NOT_BOARD_TESTED receipt_manifest_sha256=${receipt_manifest_sha}"
