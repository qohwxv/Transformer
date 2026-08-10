#!/usr/bin/env bash
set -euo pipefail

receipt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${receipt_root}"

assertions=0
increment_assertions() {
    assertions=$((assertions + 1))
}
fail() {
    printf 'RECEIPT VERIFY FAIL: %s\n' "$*" >&2
    exit 1
}
assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "${actual}" == "${expected}" ]] ||
        fail "${label}: expected=${expected} actual=${actual}"
    increment_assertions
}
assert_sha() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    assert_eq "${expected}" "${actual}" "sha256:${path}"
}
assert_contains() {
    local needle="$1"
    local path="$2"
    grep -Fq -- "${needle}" "${path}" ||
        fail "missing text in ${path}: ${needle}"
    increment_assertions
}
assert_once() {
    local line="$1"
    local path="$2"
    assert_eq 1 "$(grep -Fxc -- "${line}" "${path}" || true)" \
        "exact-line-count:${path}"
}
check_manifest() {
    local manifest="$1"
    sha256sum -c "${manifest}" >/dev/null ||
        fail "checksum manifest failed: ${manifest}"
    increment_assertions
}

check_manifest RECEIPT_SHA256SUMS.txt
check_manifest RAW_REMOTE_RUNS_SHA256SUMS.txt
check_manifest WORKSPACE_SNAPSHOT_SHA256SUMS.txt
check_manifest WORKSPACE_INPUT_SHA256SUMS.txt
check_manifest RUNNER_STATES_SHA256SUMS.txt

assert_eq 185 "$(wc -l < RECEIPT_SHA256SUMS.txt)" receipt_manifest_entries
assert_eq 62 "$(find raw_remote_runs -type f | wc -l)" raw_remote_file_count
assert_eq 2 "$(find raw_remote_runs/20260808T172200Z-m8-e01-mode3-observation -type f | wc -l)" launch_failure_file_count
for successful_run in \
    20260808T172400Z-m8-e01-mode3-observation \
    20260808T173900Z-m8-e01-mode3-exact-repeat \
    20260808T175400Z-m8-e01-mode3-hash-exact-final; do
    assert_eq 20 "$(find "raw_remote_runs/${successful_run}" -type f | wc -l)" \
        "successful_run_file_count:${successful_run}"
done
assert_eq 98 "$(find workspace_snapshot -type f | wc -l)" workspace_snapshot_files
assert_eq 80 "$(wc -l < PRODUCTION_WORKSPACE_PATHS.txt)" production_path_count
assert_eq 18 "$(wc -l < WORKSPACE_INPUT_PATHS.txt)" workspace_input_path_count
assert_eq 5 "$(find runner_states -type f | wc -l)" runner_state_file_count

expected_source_sha=db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e
expected_filelist_sha=88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524
m8_name=vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2
m8_snapshot="workspace_snapshot/${m8_name}"

assert_eq 80 "$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | wc -l)" production_source_records
assert_eq 80 "$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | awk '{print $2}' | LC_ALL=C sort -u | wc -l)" production_unique_paths
assert_sha "${expected_filelist_sha}" "${m8_snapshot}/filelists/full_axi.f"
assert_eq "${expected_source_sha}" \
    "$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | sha256sum | awk '{print $1}')" \
    production_ordered_sha256

(
    cd "${m8_snapshot}"
    tail -n +2 "${receipt_root}/PRODUCTION_SOURCE_STATE.txt" |
        sha256sum -c - >/dev/null
) || fail production_source_checksums
increment_assertions

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT
tail -n +2 PRODUCTION_SOURCE_STATE.txt |
    awk -v prefix="${m8_name}" '{print prefix "/" $2}' \
    >"${tmp_root}/production_paths"
cmp "${tmp_root}/production_paths" PRODUCTION_WORKSPACE_PATHS.txt ||
    fail production_path_manifest
increment_assertions

awk -v prefix="${m8_name}" '
    {
        line=$0
        sub(/#.*/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line != "") print prefix "/" line
    }
' "${m8_snapshot}/filelists/full_axi.f" >"${tmp_root}/filelist_paths"
cmp "${tmp_root}/filelist_paths" PRODUCTION_WORKSPACE_PATHS.txt ||
    fail production_filelist_order
increment_assertions

while read -r expected path; do
    assert_sha "${expected}" "${path}"
done <<'IDENTITY_CHECKS'
f4ab571dc7a0dcce158ba1a9448ae62220be95272e4127248ad0e4458b18bd2f workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/tb_vit_phase_e_axi_e01_mode3_real_rtl.sv
8ce965dabef7611c75e8f2e90179670711805e4a48563bb40ac2b82d8e2ce79a workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f
0f376c03632d9fa5148b1939004d992ebecf4b88e71cd977ff0573b1c1ab98f6 workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh
53fa492911285ae1ae3e671f44cd35b280b143227a51388c7cfccec8eba952f9 workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/stage_m7_mode3_real_assets.py
f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/m7_mode3_real_assets.py
dd59cdfc56d48c63411e6f73f608957845c5f44fdfdc7bbf209edb12852241f7 workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/tests/test_m7_mode3_real_assets.py
40803b5e7e0407173859e4aad82f1563896fbe9c4f50c477e9607fe2f9f03613 workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/axi/vit_axi_ddr_model_128.sv
47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18 workspace_snapshot/results/embedding_step_06_hidden_states_f32.hex
74cdd537ba765e1ce9f64f3afc6a5c037dce6d67e47c6b9587e6a8acd82b3324 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/hash_manifest.json
3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/prepared_input.bin
1654962e01b45e47939cc4b9144865c30de9a5adfd424993824941bf0ed178d7 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/verification_report.json
d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model.bin
10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model_table.bin
22933d5b10e78253f45625384a1ad191051b8965d05ac09b84e23f4e2381b9bb workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model_table.json
20ee65ab28d8aa32cbd3a0f5f04f99975fe29aae2d4ae66d1c790e94b7ca704d workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_runtime_config.json
075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35 workspace_snapshot/experimental/m6_fp16_nodsp_ooc/reference/m6_fp16_reference.py
3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141 workspace_snapshot/vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/rtl/leaf/fp32/vit_fp32_add_comb.sv
3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141 workspace_snapshot/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/rtl/leaf/fp32/vit_fp32_add_comb.sv
IDENTITY_CHECKS

cmp \
    workspace_snapshot/vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/rtl/leaf/fp32/vit_fp32_add_comb.sv \
    "${m8_snapshot}/rtl/leaf/fp32/vit_fp32_add_comb.sv" ||
    fail parent_current_adder_identity
increment_assertions

observation_runner=runner_states/observation_runner_1a12cdc9ad05.sh
repeat_runner=runner_states/exact_repeat_runner_5a4c39e58a80.sh
final_runner=runner_states/hash_exact_final_runner_0f376c03632d.sh
assert_sha 1a12cdc9ad0567bba8dd01b9505ff8bc0374a6b12c81d7480a9d77813c184beb "${observation_runner}"
assert_sha 5a4c39e58a800eb03a3e11afc54c91de0fe6187c06269bfcd3a3acdc29d8f238 "${repeat_runner}"
assert_sha 0f376c03632d9fa5148b1939004d992ebecf4b88e71cd977ff0573b1c1ab98f6 "${final_runner}"
cmp "${final_runner}" "${m8_snapshot}/sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh" ||
    fail final_runner_workspace_identity
increment_assertions

check_runner_diff() {
    local before_label="$1"
    local before_path="$2"
    local after_label="$3"
    local after_path="$4"
    local expected_patch="$5"
    local generated_patch="${tmp_root}/$(basename "${expected_patch}")"
    local diff_status
    set +e
    diff -u --label "${before_label}" "${before_path}" \
        --label "${after_label}" "${after_path}" >"${generated_patch}"
    diff_status=$?
    set -e
    [[ "${diff_status}" == 1 ]] ||
        fail "runner diff status ${diff_status}: ${expected_patch}"
    cmp "${generated_patch}" "${expected_patch}" ||
        fail "runner diff mismatch: ${expected_patch}"
    increment_assertions
}
check_runner_diff observation_runner_1a12cdc9ad05.sh "${observation_runner}" \
    exact_repeat_runner_5a4c39e58a80.sh "${repeat_runner}" \
    runner_states/OBSERVATION_TO_EXACT_REPEAT.patch
check_runner_diff exact_repeat_runner_5a4c39e58a80.sh "${repeat_runner}" \
    hash_exact_final_runner_0f376c03632d.sh "${final_runner}" \
    runner_states/EXACT_REPEAT_TO_HASH_EXACT_FINAL.patch

runs=(
    20260808T172400Z-m8-e01-mode3-observation
    20260808T173900Z-m8-e01-mode3-exact-repeat
    20260808T175400Z-m8-e01-mode3-hash-exact-final
)
state_hashes=(
    4701037a3ec523a79d972b2d14c490838c74830d01ab973dfeddda73dc3ef7f5
    4160cbc1f75a6ed37ef38352aa80d36be62c47227cee77ceb3e946878e5786c7
    0179e8424162af28a9381b13eca047ab4605e1da373578808e95e6bf303585ec
)
runner_hashes=(
    1a12cdc9ad0567bba8dd01b9505ff8bc0374a6b12c81d7480a9d77813c184beb
    5a4c39e58a800eb03a3e11afc54c91de0fe6187c06269bfcd3a3acdc29d8f238
    0f376c03632d9fa5148b1939004d992ebecf4b88e71cd977ff0573b1c1ab98f6
)
common_source_identity='production_sources=80 full_axi_sha256=88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524 ordered_source_sha256=db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e'

for index in 0 1 2; do
    run="${runs[${index}]}"
    run_root="raw_remote_runs/${run}/e01_run"
    outer_log="raw_remote_runs/${run}/REMOTE_RUNNER.log"
    assert_sha "${state_hashes[${index}]}" "${run_root}/SOURCE_STATE_BEFORE.txt"
    cmp "${run_root}/SOURCE_STATE_BEFORE.txt" "${run_root}/SOURCE_STATE_AFTER.txt" ||
        fail "source before/after changed: ${run}"
    increment_assertions
    cmp "${run_root}/SOURCE_STATE_BEFORE.txt" "${run_root}/SOURCE_STATE_FINAL.txt" ||
        fail "source before/final changed: ${run}"
    increment_assertions
    assert_contains "${common_source_identity}" "${run_root}/SOURCE_STATE_BEFORE.txt"
    assert_contains "runner_sha256=${runner_hashes[${index}]}" \
        "${run_root}/SOURCE_STATE_BEFORE.txt"
    assert_eq 3 "$(grep -c '^M7_MODE3_E01_SOURCE_STATE ' "${outer_log}" || true)" \
        "outer_source_state_count:${run}"
done

failure_root=raw_remote_runs/20260808T172200Z-m8-e01-mode3-observation
failure_log="${failure_root}/REMOTE_RUNNER.log"
failure_marker='ERROR: refusing to reuse output directory: /home/s23520579/Vivado_project/vit_m8_db4e84bbe7b2_workspace/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/reports/m8/server_runs/20260808T172200Z-m8-e01-mode3-observation/e01_run'
assert_eq 1 "$(wc -l < "${failure_log}")" launch_failure_log_lines
assert_once "${failure_marker}" "${failure_log}"
assert_eq 1772348 "$(tr -d '\n' < "${failure_root}/RUNNER_PID.txt")" launch_failure_pid
[[ -d "${failure_root}/e01_run" ]] || fail missing_launch_failure_output_directory
increment_assertions
assert_eq 0 "$(find "${failure_root}/e01_run" -type f | wc -l)" launch_failure_output_files

signature_re='^(E01_REAL_AXI_TRAFFIC |M7_MODE3_E01_BIAS_CACHE |M7_MODE3_E01_TRAFFIC |M7_MODE3_E01_M7_STATUS |M7_MODE3_E01_M7_COUNTERS |M7_MODE3_E01_OUTPUT_STRUCTURE |VIT_PHASE_E_AXI_E01_MODE3_REAL_RTL_STRUCTURAL_PASS |M7_MODE3_E01_M6_CURRENT_ADDER_ORACLE_COMPARE_PASS |M7_MODE3_E01_BEHAVIORAL_GOLDEN_COMPARE_PASS )'
signature_sha=7f05ddfbe299fcc5b15683dba246b12841aac0ba419e86189525f81aa45e0cde
assert_eq 9 "$(wc -l < THREE_RUN_TERMINAL_SIGNATURE.txt)" canonical_signature_lines
assert_sha "${signature_sha}" THREE_RUN_TERMINAL_SIGNATURE.txt
assert_eq 3 "$(wc -l < THREE_RUN_SIGNATURE_SHA256.txt)" signature_hash_records
assert_eq 1 "$(awk '{print $1}' THREE_RUN_SIGNATURE_SHA256.txt | LC_ALL=C sort -u | wc -l)" signature_unique_hashes

severe_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL|Error|Fatal):|(^|[[:space:]])FAIL([[:space:]:]|$)|%Error|%Fatal'
for index in 0 1 2; do
    run="${runs[${index}]}"
    outer_log="raw_remote_runs/${run}/REMOTE_RUNNER.log"
    extracted="${tmp_root}/signature.${index}.txt"
    grep -E "${signature_re}" "${outer_log}" >"${extracted}"
    assert_eq 90 "$(wc -l < "${outer_log}")" "outer_log_lines:${run}"
    assert_eq 9 "$(wc -l < "${extracted}")" "extracted_signature_lines:${run}"
    cmp THREE_RUN_TERMINAL_SIGNATURE.txt "${extracted}" ||
        fail "terminal signature differs: ${run}"
    increment_assertions
    assert_sha "${signature_sha}" "${extracted}"
    assert_eq 1 "$(grep -c '^M7_MODE3_E01_NUMERICAL_RUN_PASS ' "${outer_log}" || true)" \
        "numerical_pass_count:${run}"
    tail -n 1 "${outer_log}" | grep -Fq 'M7_MODE3_E01_NUMERICAL_RUN_PASS ' ||
        fail "outer log does not terminate at numerical PASS: ${run}"
    increment_assertions
    assert_eq 1 "$(grep -c '^M7_MODE3_E01_M6_CURRENT_ADDER_REPORT_PASS ' "${outer_log}" || true)" \
        "m6_report_pass_count:${run}"
    assert_eq 1 "$(grep -c '^M7_MODE3_E01_BEHAVIORAL_REPORT_PASS ' "${outer_log}" || true)" \
        "behavioral_report_pass_count:${run}"
    if grep -En -- "${severe_pattern}" "${outer_log}" >/dev/null; then
        fail "severe marker in successful outer log: ${run}"
    fi
    increment_assertions
done

observation_raw_gate='M7_MODE3_E01_RAW_OUTPUT_GATE_PASS embedding_words=151296 commands=4 external_u32=15351550 writes=453120 numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES'
final_raw_gate='M7_MODE3_E01_RAW_OUTPUT_GATE_PASS embedding_words=151296 commands=4 external_u32=15351550 writes=453120 embedding_sha256=e06079ecc3bcd16678fafeec44c52535ac955876569bd96449b15f01978b7df9 numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES'
assert_once "${observation_raw_gate}" "raw_remote_runs/${runs[0]}/REMOTE_RUNNER.log"
assert_once "${observation_raw_gate}" "raw_remote_runs/${runs[1]}/REMOTE_RUNNER.log"
assert_once "${final_raw_gate}" "raw_remote_runs/${runs[2]}/REMOTE_RUNNER.log"
assert_contains 'cycles=[1-9][0-9]*' "${observation_runner}"
assert_contains 'cycles=82215315' "${repeat_runner}"
assert_contains 'e06079ecc3bcd16678fafeec44c52535ac955876569bd96449b15f01978b7df9' "${final_runner}"
assert_contains 'dfe799398f72578c6135d5b5e573bd75d060bcd0bff18f52e3419b79f5e27dfb' "${final_runner}"
assert_contains '3807e2f88c188a5ac7dab8001aa455c0f7fa1bf942628898551060f609c46b3d' "${final_runner}"
assert_contains 'exact_mismatch=150515' "${final_runner}"
assert_contains 'max_abs=3\.846675158e-03' "${final_runner}"
assert_contains 'mean_abs=2\.339259978e-04' "${final_runner}"

for run in "${runs[@]}"; do
    run_root="raw_remote_runs/${run}/e01_run"
    (
        cd "${run_root}/outputs"
        sha256sum -c "${receipt_root}/AUTHORITATIVE_ARTIFACTS_SHA256.txt" >/dev/null
    ) || fail "authoritative artifact hashes: ${run}"
    increment_assertions
    (
        cd "${run_root}/assets"
        sha256sum -c "${receipt_root}/STAGED_ASSETS_SHA256.txt" >/dev/null
    ) || fail "staged asset hashes: ${run}"
    increment_assertions
    assert_eq 151296 "$(wc -l < "${run_root}/outputs/embedding_rtl_f32.hex")" \
        "embedding_words:${run}"
done

observation_outputs="raw_remote_runs/${runs[0]}/e01_run/outputs"
repeat_outputs="raw_remote_runs/${runs[1]}/e01_run/outputs"
final_outputs="raw_remote_runs/${runs[2]}/e01_run/outputs"
while read -r _ artifact_name; do
    cmp "${observation_outputs}/${artifact_name}" "${repeat_outputs}/${artifact_name}" ||
        fail "observation/repeat artifact mismatch: ${artifact_name}"
    increment_assertions
    cmp "${observation_outputs}/${artifact_name}" "${final_outputs}/${artifact_name}" ||
        fail "observation/final artifact mismatch: ${artifact_name}"
    increment_assertions
done < AUTHORITATIVE_ARTIFACTS_SHA256.txt

observation_assets="raw_remote_runs/${runs[0]}/e01_run/assets"
repeat_assets="raw_remote_runs/${runs[1]}/e01_run/assets"
final_assets="raw_remote_runs/${runs[2]}/e01_run/assets"
while read -r _ asset_name; do
    cmp "${observation_assets}/${asset_name}" "${repeat_assets}/${asset_name}" ||
        fail "observation/repeat staged asset mismatch: ${asset_name}"
    increment_assertions
    cmp "${observation_assets}/${asset_name}" "${final_assets}/${asset_name}" ||
        fail "observation/final staged asset mismatch: ${asset_name}"
    increment_assertions
done < STAGED_ASSETS_SHA256.txt

for oracle_log in m6_current_adder_oracle_compare.log behavioral_golden_compare.log; do
    cmp "raw_remote_runs/${runs[0]}/e01_run/${oracle_log}" \
        "raw_remote_runs/${runs[1]}/e01_run/${oracle_log}" ||
        fail "observation/repeat oracle log mismatch: ${oracle_log}"
    increment_assertions
    cmp "raw_remote_runs/${runs[0]}/e01_run/${oracle_log}" \
        "raw_remote_runs/${runs[2]}/e01_run/${oracle_log}" ||
        fail "observation/final oracle log mismatch: ${oracle_log}"
    increment_assertions
done

json_assertions="$(
python3 - \
    "raw_remote_runs/${runs[0]}/e01_run" \
    "raw_remote_runs/${runs[1]}/e01_run" \
    "raw_remote_runs/${runs[2]}/e01_run" <<'PY'
import json
import pathlib
import sys

assertions = 0
def check(value, label):
    global assertions
    if not value:
        raise AssertionError(label)
    assertions += 1

embedding_sha = "e06079ecc3bcd16678fafeec44c52535ac955876569bd96449b15f01978b7df9"
golden_sha = "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18"
m6_reference_sha = "075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35"
adder_sha = "3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141"
model_sha = "d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5"
prepared_sha = "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54"

for root_arg in sys.argv[1:]:
    root = pathlib.Path(root_arg)
    outputs = root / "outputs"
    m6 = json.loads(
        (outputs / "m7_mode3_e01_m6_current_adder_oracle_comparison.json").read_text()
    )
    comparison = m6["comparison"]
    contract = m6["numerical_contract"]
    check(m6["schema"] == "vit-m7-mode3-e01-m6-current-adder-oracle-comparison-v1", "m6 schema")
    check(m6["decision"] == "PASS", "m6 decision")
    check(m6["execution_mode"] == 3, "m6 mode")
    check(comparison["words"] == 151296, "m6 words")
    check(comparison["exact_mismatches"] == 0, "m6 exact")
    check(comparison["actual_nonfinite"] == 0, "m6 actual finite")
    check(comparison["oracle_nonfinite"] == 0, "m6 oracle finite")
    check(comparison["oracle_readmemh_sha256"] == embedding_sha, "m6 oracle hash")
    check(m6["inputs"]["embedding_dump_sha256"] == embedding_sha, "m6 dump hash")
    check(contract["m6_reference_sha256"] == m6_reference_sha, "m6 reference")
    check(contract["fp32_add_rtl_sha256"] == adder_sha, "m6 adder")

    behavioral = json.loads(
        (outputs / "m7_mode3_e01_behavioral_golden_comparison.json").read_text()
    )
    embedding = behavioral["embedding"]
    check(behavioral["schema"] == "vit-m7-mode3-e01-behavioral-golden-comparison-v1", "behavioral schema")
    check(behavioral["decision"] == "PASS", "behavioral decision")
    check(behavioral["execution_mode"] == 3, "behavioral mode")
    check(embedding["words"] == 151296, "behavioral words")
    check(embedding["exact_mismatches"] == 150515, "behavioral exact mismatches")
    check(embedding["tolerance_failures"] == 0, "behavioral tolerance")
    check(embedding["actual_nonfinite"] == 0, "behavioral actual finite")
    check(embedding["golden_nonfinite"] == 0, "behavioral golden finite")
    check(embedding["abs_tolerance"] == 0.005, "behavioral threshold")
    check(embedding["max_abs"] == 0.003846675157546997, "behavioral max abs")
    check(embedding["mean_abs"] == 0.0002339259977672367, "behavioral mean abs")
    check(behavioral["inputs"]["embedding_dump_sha256"] == embedding_sha, "behavioral dump hash")
    check(behavioral["inputs"]["embedding_golden_sha256"] == golden_sha, "behavioral golden hash")

    evidence = json.loads((root / "assets" / "asset_evidence.json").read_text())
    check(evidence["schema"] == "vit-m7-mode3-real-assets-v2", "asset schema")
    check(evidence["phase"] == "e01", "asset phase")
    check(evidence["execution_mode"] == 3, "asset mode")
    check(len(evidence["staged"]) == 6, "asset count")
    check(evidence["package"]["table_header"]["model_sha256"] == model_sha, "asset model")
    check(evidence["package"]["files"]["prepared_input.bin"]["sha256"] == prepared_sha, "asset prepared input")
    check(evidence["behavioral_goldens"]["embedding"]["sha256"] == golden_sha, "asset golden")
    check(evidence["numerical_contract"]["m6_reference_sha256"] == m6_reference_sha, "asset m6 reference")
    check(evidence["numerical_contract"]["fp32_add_rtl_sha256"] == adder_sha, "asset adder")

print(assertions)
PY
)"
[[ "${json_assertions}" =~ ^[1-9][0-9]*$ ]] ||
    fail "invalid JSON assertion count: ${json_assertions}"
assertions=$((assertions + json_assertions))

assert_contains 'outer_launcher_exit_status_recorded=NO' RUN_COMPLETION_EVIDENCE.txt
assert_contains 'outer_launcher_exit_status_file_count=0' RUN_COMPLETION_EVIDENCE.txt
assert_contains 'successful_run_terminal_pass_markers=3_of_3' RUN_COMPLETION_EVIDENCE.txt
assert_contains 'matching_process_lines=0' REMOTE_QUIESCENCE.txt
assert_contains 'live_checked_run_pids=0' REMOTE_QUIESCENCE.txt
assert_contains 'M8_E01_RECEIPT_STATUS SAFE_FOR_NEXT_M8_NONBOARD_GATE' STATUS.txt
assert_eq 0 "$(find raw_remote_runs -type f \( -iname '*exit*status*' -o -iname '*return*code*' \) | wc -l)" recorded_outer_exit_status_files
assert_eq 0 "$(find . -type f -perm /022 | wc -l)" writable_receipt_files
assert_eq 0 "$(find . -type d -perm /022 | wc -l)" writable_receipt_directories

printf 'M8_E01_RECEIPT_VERIFY_PASS receipt_entries=185 assertions=%s production_sources=80 successful_runs=3 terminal_signature=9_lines_identical_3_of_3 authoritative_artifacts=3_of_3_byte_identical_across_3_runs cycles=82215315 behavioral_tolerance_failures=0 m6_exact=151296_of_151296 outer_exit_status=NOT_RECORDED terminal_pass_and_quiescence=VERIFIED disposition=SAFE_FOR_NEXT_M8_NONBOARD_GATE\n' "${assertions}"
