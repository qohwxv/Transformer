#!/usr/bin/env bash
set -euo pipefail

receipt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${receipt_root}"

sha256sum -c RECEIPT_SHA256SUMS.txt >/dev/null
sha256sum -c RAW_REMOTE_RUNS_SHA256SUMS.txt >/dev/null
sha256sum -c WORKSPACE_SNAPSHOT_SHA256SUMS.txt >/dev/null
sha256sum -c WORKSPACE_INPUT_SHA256SUMS.txt >/dev/null
sha256sum -c RUNNER_STATES_SHA256SUMS.txt >/dev/null

[[ "$(find raw_remote_runs -type f | wc -l)" == "43" ]]
[[ "$(find raw_remote_runs/20260808T173100Z-m8-e04-mode3-observation -type f | wc -l)" == "3" ]]
[[ "$(find raw_remote_runs/20260808T174200Z-m8-e04-mode3-observation-contextfix -type f | wc -l)" == "20" ]]
[[ "$(find raw_remote_runs/20260808T175500Z-m8-e04-mode3-exact-repeat -type f | wc -l)" == "20" ]]
[[ "$(find workspace_snapshot -type f | wc -l)" == "100" ]]
[[ "$(wc -l < WORKSPACE_INPUT_PATHS.txt)" == "20" ]]
[[ "$(wc -l < PRODUCTION_WORKSPACE_PATHS.txt)" == "80" ]]

expected_source_sha="db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
expected_filelist_sha="88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"
m8_name="vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2"
m8_snapshot="workspace_snapshot/${m8_name}"

source_count="$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | wc -l)"
unique_source_count="$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | awk '{print $2}' | sort -u | wc -l)"
[[ "${source_count}" == "80" ]]
[[ "${unique_source_count}" == "80" ]]
source_sha="$(tail -n +2 PRODUCTION_SOURCE_STATE.txt | sha256sum | awk '{print $1}')"
filelist_sha="$(sha256sum "${m8_snapshot}/filelists/full_axi.f" | awk '{print $1}')"
[[ "${source_sha}" == "${expected_source_sha}" ]]
[[ "${filelist_sha}" == "${expected_filelist_sha}" ]]

(
    cd "${m8_snapshot}"
    tail -n +2 "${receipt_root}/PRODUCTION_SOURCE_STATE.txt" | sha256sum -c - >/dev/null
)

tmp_root="$(mktemp -d)"
trap 'rm -rf -- "${tmp_root}"' EXIT
tail -n +2 PRODUCTION_SOURCE_STATE.txt |
    awk -v prefix="${m8_name}" '{print prefix "/" $2}' >"${tmp_root}/production_paths"
cmp "${tmp_root}/production_paths" PRODUCTION_WORKSPACE_PATHS.txt

check_sha() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]]
}

check_sha 56ef0ed5910f152ac4c00744b331eee1b261c01d2569c1a67d040134a4e4e1c6 "${m8_snapshot}/sim/end_to_end/tb_vit_phase_e_axi_e04_mode3_real_rtl.sv"
check_sha ac98cc5a49a53d0f6fb5834639af37d1655244f052564c8b339476d44343d4d6 "${m8_snapshot}/sim/end_to_end/vit_phase_e_axi_e04_mode3_real_rtl_verilator.f"
check_sha 74d7b8e5c737bbb9ef201a378e918eb23cadab9a6272adaed323025499c3ce9f "${m8_snapshot}/sim/end_to_end/run_e04_mode3_real_axi_rtl_verilator.sh"
check_sha 53fa492911285ae1ae3e671f44cd35b280b143227a51388c7cfccec8eba952f9 "${m8_snapshot}/sim/end_to_end/stage_m7_mode3_real_assets.py"
check_sha f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed "${m8_snapshot}/sim/end_to_end/m7_mode3_real_assets.py"
check_sha 40803b5e7e0407173859e4aad82f1563896fbe9c4f50c477e9607fe2f9f03613 "${m8_snapshot}/sim/axi/vit_axi_ddr_model_128.sv"
check_sha 5cf34a472d907125dd6bdb0c7bfc5d4b5e353571978aa8ef73b9a8b17bc93359 workspace_snapshot/results/encoder_layer_11_step_20_layer_output_f32.hex
check_sha d8ac11b3b8c244c4c525da8f2a56352595256290f0673c607944d5581835167d workspace_snapshot/results/post_encoder_step_30_final_layernorm_f32.hex
check_sha fef8118492356377612d95f0b02120d6fde728ff47bef9b4b8c87cf52c4c7143 workspace_snapshot/results/post_encoder_step_32_logits_f32.hex
check_sha 870497897b0b0453c8dc1335c3db8881e9ffdbf81bf66eba3d40c8c1b169491b workspace_snapshot/results/post_encoder_step_33p_probabilities_f32.hex
check_sha 74cdd537ba765e1ce9f64f3afc6a5c037dce6d67e47c6b9587e6a8acd82b3324 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/hash_manifest.json
check_sha 3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/prepared_input.bin
check_sha 1654962e01b45e47939cc4b9144865c30de9a5adfd424993824941bf0ed178d7 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/verification_report.json
check_sha d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5 workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model.bin
check_sha 10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model_table.bin
check_sha 22933d5b10e78253f45625384a1ad191051b8965d05ac09b84e23f4e2381b9bb workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_model_table.json
check_sha 20ee65ab28d8aa32cbd3a0f5f04f99975fe29aae2d4ae66d1c790e94b7ca704d workspace_snapshot/build/model_package/v3_blocked_b_fp16_mixed/vit_runtime_config.json
check_sha 075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35 workspace_snapshot/experimental/m6_fp16_nodsp_ooc/reference/m6_fp16_reference.py
check_sha 3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141 workspace_snapshot/vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/rtl/leaf/fp32/vit_fp32_add_comb.sv
check_sha 3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141 "${m8_snapshot}/rtl/leaf/fp32/vit_fp32_add_comb.sv"
cmp workspace_snapshot/vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/rtl/leaf/fp32/vit_fp32_add_comb.sv "${m8_snapshot}/rtl/leaf/fp32/vit_fp32_add_comb.sv"

observation_runner=runner_states/observation_runner_a7c524a821d3.sh
repeat_runner=runner_states/exact_repeat_runner_74d7b8e5c737.sh
check_sha a7c524a821d39f5ebd538664e42102de9da26c4ab6fa53a1c9f59467e2e30642 "${observation_runner}"
check_sha 74d7b8e5c737bbb9ef201a378e918eb23cadab9a6272adaed323025499c3ce9f "${repeat_runner}"
cmp "${repeat_runner}" "${m8_snapshot}/sim/end_to_end/run_e04_mode3_real_axi_rtl_verilator.sh"
if diff -u --label observation_runner_a7c524a821d3.sh "${observation_runner}" --label exact_repeat_runner_74d7b8e5c737.sh "${repeat_runner}" >"${tmp_root}/runner.diff"; then
    exit 1
else
    [[ "$?" == "1" ]]
fi
cmp "${tmp_root}/runner.diff" runner_states/RUNNER_STATE_DIFF.patch

first_root=raw_remote_runs/20260808T174200Z-m8-e04-mode3-observation-contextfix/e04_run
repeat_root=raw_remote_runs/20260808T175500Z-m8-e04-mode3-exact-repeat/e04_run
cmp "${first_root}/SOURCE_STATE_BEFORE.txt" "${first_root}/SOURCE_STATE_AFTER.txt"
cmp "${repeat_root}/SOURCE_STATE_BEFORE.txt" "${repeat_root}/SOURCE_STATE_AFTER.txt"
grep -Fq 'runner_sha256=a7c524a821d39f5ebd538664e42102de9da26c4ab6fa53a1c9f59467e2e30642' "${first_root}/SOURCE_STATE_BEFORE.txt"
grep -Fq 'runner_sha256=74d7b8e5c737bbb9ef201a378e918eb23cadab9a6272adaed323025499c3ce9f' "${repeat_root}/SOURCE_STATE_BEFORE.txt"
grep -Fq 'production_sources=80 full_axi_sha256=88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524 ordered_source_sha256=db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e' "${first_root}/SOURCE_STATE_BEFORE.txt"
grep -Fq 'production_sources=80 full_axi_sha256=88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524 ordered_source_sha256=db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e' "${repeat_root}/SOURCE_STATE_BEFORE.txt"

failure_root=raw_remote_runs/20260808T173100Z-m8-e04-mode3-observation
failure_marker='M7_MODE3_ASSET_STAGE_FAIL reason=cannot discover workspace root from module path /home/s23520579/Vivado_project/vit_m8_db4e84bbe7b2_workspace/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/sim/end_to_end/m7_mode3_real_assets.py'
[[ "$(grep -Fxc "${failure_marker}" "${failure_root}/e04_observation.log")" == "1" ]]
[[ "$(grep -Fxc 'FAIL: package-v3 E04 asset staging failed' "${failure_root}/e04_observation.log")" == "1" ]]
[[ "$(grep -Fxc "${failure_marker}" "${failure_root}/e04_run/asset_stage.log")" == "1" ]]
[[ ! -e "${failure_root}/e04_run/build.log" ]]
[[ ! -e "${failure_root}/e04_run/run.log" ]]

first_log=raw_remote_runs/20260808T174200Z-m8-e04-mode3-observation-contextfix/e04_observation.log
repeat_log=raw_remote_runs/20260808T175500Z-m8-e04-mode3-exact-repeat/e04_exact_repeat.log
output_structure='M7_MODE3_E04_OUTPUT_STRUCTURE final_ln_words=151296 final_ln_nonfinite=0 final_ln_sentinel=0 layout_mismatch=0 logits_words=1000 logits_nonfinite=0 logits_sentinel=0 probabilities_words=1000 probabilities_nonfinite=0 probabilities_sentinel=0'
result_marker='M7_MODE3_E04_RESULT class=879 logit=414886a0 logit_real=12.532867432 numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES'
traffic_marker='M7_MODE3_E04_TRAFFIC cycles=9010564 logical_reads=1694368 cache_hits=767234 external_u32=927134 ar=207134 r_beats=351134 full_r_beats=192000 narrow_r_beats=159134 linefills=48000 line_hits=720000 writes=154064'
structural_marker='VIT_PHASE_E_AXI_E04_MODE3_REAL_RTL_STRUCTURAL_PASS checks=202 cycles=9010605 commands=5 external_u32=927134 writes=154064 model_reads=771534 scratch_reads=155600 class=879 logit=414886a0 numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES'
behavioral_marker='M7_MODE3_E04_BEHAVIORAL_GOLDEN_COMPARE_PASS final_ln=151296 final_ln_exact_mismatch=128217 final_ln_tolerance_failures=0 final_ln_max_abs=5.722045898e-06 logits=1000 logits_exact_mismatch=1000 logits_tolerance_failures=0 logits_max_abs=8.324980736e-04 probabilities=1000 probabilities_exact_mismatch=1000 probabilities_tolerance_failures=0 probabilities_max_abs=5.863606930e-06 expected_top1=879 logits_top1_actual=879 logits_top1_golden=879 probabilities_top1_actual=879 probabilities_top1_golden=879 class_result=879 class_logit_matches_dump=1 report_sha256=e90073dd10591a897bb40630883c07ca6791bcf105a014854cfe7da8f1ec6c0f'
m6_marker='M7_MODE3_E04_M6_CLASSIFIER_ORACLE_COMPARE_PASS logits=1000 exact_mismatch=0 tolerance_failures=0 abs_tolerance=0.000000000e+00 rel_tolerance=0.000000000e+00 max_abs=0.000000000e+00 mean_abs=0.000000000e+00 top1_actual=879 top1_oracle=879 report_sha256=96c5bb2462d607664f7fc1a570646eaf3fc99f47721b505b24cd73325b43c9a3'
severe_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL|Error|Fatal):|(^|[[:space:]])FAIL([[:space:]:]|$)|%Error|%Fatal'

for pass_log in "${first_log}" "${repeat_log}"; do
    [[ "$(wc -l <"${pass_log}")" == "55" ]]
    [[ "$(grep -Fxc 'M7_MODE3_E04_ASSET_CONTRACT_PASS files=4 words=386536 golden_files=3 golden_words=153296' "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${output_structure}" "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${result_marker}" "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${traffic_marker}" "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${structural_marker}" "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${behavioral_marker}" "${pass_log}")" == "1" ]]
    [[ "$(grep -Fxc "${m6_marker}" "${pass_log}")" == "1" ]]
    [[ "$(grep -c '^M7_MODE3_E04_SOURCE_STATE ' "${pass_log}")" == "2" ]]
    [[ "$(grep -c '^M7_MODE3_E04_NUMERICAL_RUN_PASS ' "${pass_log}")" == "1" ]]
    tail -n 1 "${pass_log}" | grep -Fq 'M7_MODE3_E04_NUMERICAL_RUN_PASS '
    tail -n 1 "${pass_log}" | grep -Fq 'final_ln_tolerance_failures=0 logits_tolerance_failures=0 probabilities_tolerance_failures=0 top1=879 class=879 m6_logits_exact=1000'
    ! grep -En -- "${severe_pattern}" "${pass_log}"
done

first_outputs="${first_root}/outputs"
repeat_outputs="${repeat_root}/outputs"
(
    cd "${first_outputs}"
    sha256sum -c "${receipt_root}/AUTHORITATIVE_OUTPUTS_SHA256.txt" >/dev/null
)
(
    cd "${repeat_outputs}"
    sha256sum -c "${receipt_root}/AUTHORITATIVE_OUTPUTS_SHA256.txt" >/dev/null
)
while read -r _ output_name; do
    cmp "${first_outputs}/${output_name}" "${repeat_outputs}/${output_name}"
done < AUTHORITATIVE_OUTPUTS_SHA256.txt

[[ "$(wc -l <"${first_outputs}/final_layernorm_rtl_f32.hex")" == "151296" ]]
[[ "$(wc -l <"${first_outputs}/logits_rtl_f32.hex")" == "1000" ]]
[[ "$(wc -l <"${first_outputs}/probabilities_rtl_f32.hex")" == "1000" ]]
[[ "$(wc -l <"${first_outputs}/class_result_rtl_u32.hex")" == "2" ]]

for asset_name in asset_evidence.json classifier_bias_f32.hex classifier_weight_packed_fp16_u32.hex final_ln_beta_f32.hex final_ln_gamma_f32.hex; do
    cmp "${first_root}/assets/${asset_name}" "${repeat_root}/assets/${asset_name}"
done

python3 - "${first_outputs}" "${repeat_outputs}" <<'PY'
import json
import pathlib
import sys

for output_dir_arg in sys.argv[1:]:
    output_dir = pathlib.Path(output_dir_arg)
    behavioral = json.loads(
        (output_dir / "m7_mode3_e04_behavioral_golden_comparison.json").read_text()
    )
    assert behavioral["decision"] == "PASS"
    assert behavioral["execution_mode"] == 3
    assert behavioral["final_layernorm"]["words"] == 151296
    assert behavioral["final_layernorm"]["tolerance_failures"] == 0
    assert behavioral["logits"]["words"] == 1000
    assert behavioral["logits"]["tolerance_failures"] == 0
    assert behavioral["probabilities"]["words"] == 1000
    assert behavioral["probabilities"]["tolerance_failures"] == 0
    top1 = behavioral["top1_and_class"]
    assert top1["pass"] is True
    assert top1["expected"] == 879
    assert top1["actual_logits"] == 879
    assert top1["actual_probabilities"] == 879
    assert top1["class_result"] == 879
    assert top1["class_result_logit_matches_dump"] is True

    m6 = json.loads(
        (output_dir / "m7_mode3_e04_m6_classifier_oracle_comparison.json").read_text()
    )
    assert m6["decision"] == "PASS"
    assert m6["execution_mode"] == 3
    comparison = m6["comparison"]
    assert comparison["words"] == 1000
    assert comparison["exact_mismatches"] == 0
    assert comparison["tolerance_failures"] == 0
    assert comparison["actual_top1"] == 879
    assert comparison["oracle_top1"] == 879
    contract = m6["numerical_contract"]
    assert contract["m6_reference_sha256"] == "075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35"
    assert contract["fp32_add_rtl_sha256"] == "3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141"
PY

printf '%s\n' 'M8_E04_RECEIPT_VERIFY_PASS sources=80 initial_context_failure=preserved pass_runs=2 runner_transition=assertion_only authoritative_repeat=6_of_6_byte_identical structural_checks=202 cycles=9010605 class=879 disposition=SAFE_FOR_NEXT_M8_NONBOARD_GATE'
