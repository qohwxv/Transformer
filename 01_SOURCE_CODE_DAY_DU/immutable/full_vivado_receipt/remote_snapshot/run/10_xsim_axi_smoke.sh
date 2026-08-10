#!/usr/bin/env bash
set -euo pipefail

vit_xsim_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
cd "${vit_xsim_root}"

vit_xsim_vivado="${VIVADO_BIN:-}"
if [[ -z "${vit_xsim_vivado}" ]]; then
    vit_xsim_vivado="$(command -v vivado || true)"
fi
if [[ -z "${vit_xsim_vivado}" || ! -x "${vit_xsim_vivado}" ]]; then
    printf '%s\n' \
        'ERROR: set VIVADO_BIN or source settings64.sh so vivado is in PATH'
    exit 1
fi
vit_xsim_vivado="$(readlink -f -- "${vit_xsim_vivado}")"
vit_xsim_version="$("${vit_xsim_vivado}" -version 2>&1)"
if [[ "${vit_xsim_version}" != *"v2023.2"* ]]; then
    printf '%s\n' \
        'ERROR: XSim stage requires the Vivado 2023.2 installation'
    printf '%s\n' "${vit_xsim_version}"
    exit 1
fi
vit_xsim_tool_dir="$(cd "$(dirname "${vit_xsim_vivado}")" && pwd)"
vit_xvlog="${vit_xsim_tool_dir}/xvlog"
vit_xelab="${vit_xsim_tool_dir}/xelab"
vit_xsim="${vit_xsim_tool_dir}/xsim"
for vit_xsim_tool in "${vit_xvlog}" "${vit_xelab}" "${vit_xsim}"; do
    if [[ ! -x "${vit_xsim_tool}" ]]; then
        printf 'ERROR: Vivado companion tool is missing: %s\n' \
            "${vit_xsim_tool}"
        exit 1
    fi
done

vit_xsim_threads="${VIT_XSIM_THREADS:-2}"
if [[ "${vit_xsim_threads}" == "1" ]]; then
    printf '%s\n' \
        'ERROR: VIT_XSIM_THREADS=1 is invalid for xelab --mt; use auto, off, or an integer >= 2'
    exit 1
fi
if [[ "${vit_xsim_threads}" != "auto" &&
      "${vit_xsim_threads}" != "off" &&
      ! "${vit_xsim_threads}" =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_XSIM_THREADS must be auto, off, or an integer >= 2'
    exit 1
fi
vit_xsim_timeout="${VIT_XSIM_TIMEOUT_SECONDS:-14400}"
if ! [[ "${vit_xsim_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_XSIM_TIMEOUT_SECONDS must be a positive integer'
    exit 1
fi

mkdir -p server_logs
vit_xsim_tmp_parent="${TMPDIR:-/tmp}"
if [[ ! -d "${vit_xsim_tmp_parent}" ||
      ! -w "${vit_xsim_tmp_parent}" ]]; then
    printf 'ERROR: TMPDIR is not a writable directory: %s\n' \
        "${vit_xsim_tmp_parent}"
    exit 1
fi
vit_xsim_tmp="$(mktemp -d \
    "${vit_xsim_tmp_parent%/}/vit_server_xsim.XXXXXX")"
trap 'rm -rf -- "${vit_xsim_tmp}"' EXIT

vit_xsim_reject_severity() {
    local vit_xsim_check_log="$1"
    local vit_xsim_severity_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL|Error|Fatal):|(^|[[:space:]])FAIL([[:space:]:]|$)|%Error|%Fatal'
    if grep -En -- "${vit_xsim_severity_pattern}" \
        "${vit_xsim_check_log}"; then
        printf 'ERROR: severe XSim marker found in %s\n' \
            "${vit_xsim_check_log}"
        return 1
    fi
}

vit_xsim_abs_filelist="${vit_xsim_tmp}/full_axi_abs.f"
while IFS= read -r vit_xsim_source; do
    printf '%s\n' "${vit_xsim_root}/${vit_xsim_source}" \
        >>"${vit_xsim_abs_filelist}"
done < <(
    awk '
        {
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) != 0) print
        }
    ' filelists/full_axi.f
)

cd "${vit_xsim_tmp}"
timeout --kill-after=30s "${vit_xsim_timeout}s" \
    "${vit_xvlog}" --sv \
    -f "${vit_xsim_abs_filelist}" \
    "${vit_xsim_root}/sim/axi/tb_vit_phase_e_axi_mem_adapter.sv" \
    "${vit_xsim_root}/sim/axi/tb_vit_phase_e_axi_wrapper.sv" \
    "${vit_xsim_root}/sim/axi/tb_vit_phase_e_engine_memory.sv" \
    "${vit_xsim_root}/sim/axi/tb_vit_phase_e_engine_axi.sv" \
    "${vit_xsim_root}/sim/control/tb_vit_phase_e_perf_counters.sv" \
    "${vit_xsim_root}/sim/control/tb_vit_phase_e_profile_counters.sv" \
    "${vit_xsim_root}/sim/m7/tb_vit_phase_e_m7_overlap_counters.sv" \
    "${vit_xsim_root}/sim/axi/vit_axi_ddr_model_128.sv" \
    "${vit_xsim_root}/sim/end_to_end/tb_vit_phase_e_axi_e05_compact_rtl.sv" \
    2>&1 | tee "${vit_xsim_root}/server_logs/10_xvlog.log"
vit_xsim_reject_severity \
    "${vit_xsim_root}/server_logs/10_xvlog.log"

printf '%s\n' 'run all' 'quit' >"${vit_xsim_tmp}/run_all.tcl"

vit_xsim_cases=(
    "tb_vit_phase_e_axi_mem_adapter|^VIT_PHASE_E_AXI_MEM_ADAPTER_TEST_PASS checks=173$"
    "tb_vit_phase_e_axi_wrapper|^VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=178$"
    "tb_vit_phase_e_engine_memory|^PASS engine logical-memory test: checks=1671 transactions=66$"
    "tb_vit_phase_e_engine_axi|^VIT_PHASE_E_ENGINE_AXI_TEST_PASS checks=34 reads=34 writes=17$"
    "tb_vit_phase_e_perf_counters|^VIT_PHASE_E_PERF_COUNTERS_TEST_PASS checks=16$"
    "tb_vit_phase_e_profile_counters|^VIT_PHASE_E_PROFILE_COUNTERS_TEST_PASS checks=170$"
    "tb_vit_phase_e_m7_overlap_counters|^M7_OVERLAP_COUNTER_BANK_PASS checks=246$"
)

for vit_xsim_case in "${vit_xsim_cases[@]}"; do
    vit_xsim_top="${vit_xsim_case%%|*}"
    vit_xsim_marker="${vit_xsim_case#*|}"
    vit_xsim_snapshot="${vit_xsim_top}_snapshot"
    vit_xsim_log="${vit_xsim_root}/server_logs/10_${vit_xsim_top}.log"

    timeout --kill-after=30s "${vit_xsim_timeout}s" \
        "${vit_xelab}" \
        --debug off \
        --mt "${vit_xsim_threads}" \
        "${vit_xsim_top}" \
        -s "${vit_xsim_snapshot}" \
        2>&1 | tee "${vit_xsim_log}"
    timeout --kill-after=30s "${vit_xsim_timeout}s" \
        "${vit_xsim}" \
        "${vit_xsim_snapshot}" \
        -tclbatch "${vit_xsim_tmp}/run_all.tcl" \
        2>&1 | tee -a "${vit_xsim_log}"

    vit_xsim_reject_severity "${vit_xsim_log}"
    vit_xsim_marker_count="$(
        grep -Ecx -- "${vit_xsim_marker}" "${vit_xsim_log}" || true
    )"
    if [[ "${vit_xsim_marker_count}" != "1" ]]; then
        printf 'ERROR: XSim exact PASS marker count for %s is %s; expected 1\n' \
            "${vit_xsim_top}" "${vit_xsim_marker_count}"
        exit 1
    fi
    printf 'PASS XSim: %s\n' "${vit_xsim_top}"
done

# Elaborate the exact production hierarchy three times.  Modes 0 and 1 prove
# that both removed FP32-compute paths fail closed at START without a job,
# profile epoch, or DDR request.  Mode 3 remains the cycle-exact packed-v3
# FP16/result-FIFO/load-compute-store production gate.
for vit_xsim_compact_mode in 0 1 3; do
    vit_xsim_top="tb_vit_phase_e_axi_e05_compact_rtl"
    vit_xsim_snapshot="${vit_xsim_top}_mode${vit_xsim_compact_mode}_snapshot"
    vit_xsim_log="${vit_xsim_root}/server_logs/10_${vit_xsim_top}_mode${vit_xsim_compact_mode}.log"
    if [[ "${vit_xsim_compact_mode}" == "3" ]]; then
        # Exact M8 first-run oracle, independently replayed below before this
        # revision is accepted as the final compact qualification.
        vit_xsim_marker='^VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 rows=8 cols=2 checks=2081 cycles=444212 job_cycles=436680 commands=249 blocked_gemm=74 packed_gemm=74 fp16_gemm=98 row_major_gemm=24 packed_tiles=1175 nonpacked_tiles=264 reads=35139 writes=10646 axi_stalls=2886 model_reads=20829 input_reads=32 scratch_reads=14278 cmd_active=435703 logical_reads=91403 cache_hits=55080 valid_mac=59376 tail_mac=124816 class=3 logit=40e00000$'
    else
        vit_xsim_marker="^VIT_PHASE_E_AXI_E05_COMPACT_RTL_MODE_REJECT_PASS mode=${vit_xsim_compact_mode} checks=36 error=80000003 info=0000000${vit_xsim_compact_mode}$"
    fi

    timeout --kill-after=30s "${vit_xsim_timeout}s" \
        "${vit_xelab}" \
        --debug off \
        --mt "${vit_xsim_threads}" \
        --generic_top "DUT_EXECUTION_MODE=${vit_xsim_compact_mode}" \
        "${vit_xsim_top}" \
        -s "${vit_xsim_snapshot}" \
        2>&1 | tee "${vit_xsim_log}"
    timeout --kill-after=30s "${vit_xsim_timeout}s" \
        "${vit_xsim}" \
        "${vit_xsim_snapshot}" \
        -tclbatch "${vit_xsim_tmp}/run_all.tcl" \
        2>&1 | tee -a "${vit_xsim_log}"

    vit_xsim_reject_severity "${vit_xsim_log}"
    vit_xsim_marker_count="$(
        grep -Ecx -- "${vit_xsim_marker}" "${vit_xsim_log}" || true
    )"
    if [[ "${vit_xsim_marker_count}" != "1" ]]; then
        printf 'ERROR: compact mode %s exact PASS marker count is %s; expected 1\n' \
            "${vit_xsim_compact_mode}" "${vit_xsim_marker_count}"
        exit 1
    fi
    printf 'PASS XSim compact E05: mode=%s\n' \
        "${vit_xsim_compact_mode}"
done

printf '%s\n' \
    'PASS: production AXI/engine/profile/M7 smoke plus compact mode0/mode1 rejection and exact mode3 E05 XSim completed'
