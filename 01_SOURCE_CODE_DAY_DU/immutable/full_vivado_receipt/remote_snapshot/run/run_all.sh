#!/usr/bin/env bash
set -euo pipefail

vit_run_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
cd "${vit_run_root}"

vit_run_vivado="${VIVADO_BIN:-}"
if [[ -z "${vit_run_vivado}" ]]; then
    vit_run_vivado="$(command -v vivado || true)"
fi
if [[ -z "${vit_run_vivado}" || ! -x "${vit_run_vivado}" ]]; then
    printf '%s\n' \
        'ERROR: set VIVADO_BIN or source Vivado 2023.2 settings64.sh'
    exit 1
fi
vit_run_vivado="$(readlink -f -- "${vit_run_vivado}")"

vit_run_timeout="${VIT_VIVADO_TIMEOUT_SECONDS:-86400}"
if ! [[ "${vit_run_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_VIVADO_TIMEOUT_SECONDS must be a positive integer'
    exit 1
fi

mkdir -p server_logs VIT_googlebase_rtl/reports \
    VIT_googlebase_rtl/artifacts

for vit_run_flag in \
    VIT_RUN_XSIM \
    VIT_RUN_OOC_SYNTH \
    VIT_RUN_IMPLEMENTATION; do
    vit_run_flag_value="${!vit_run_flag:-1}"
    if [[ "${vit_run_flag_value}" != "0" &&
          "${vit_run_flag_value}" != "1" ]]; then
        printf 'ERROR: %s must be 0 or 1\n' "${vit_run_flag}"
        exit 1
    fi
done
vit_run_reuse_project="${VIT_REUSE_PROJECT:-0}"
if [[ "${vit_run_reuse_project}" != "0" ]]; then
    printf '%s\n' \
        'ERROR: M8 sign-off requires VIT_REUSE_PROJECT=0; project reuse is forbidden'
    exit 1
fi

# A full implementation claim requires both independent synthesis capacity
# gates.  Reject an unsafe skip request before spending time on project/BD or
# board synthesis; stage 50 repeats the two exact report checks as defense in
# depth.
if [[ "${VIT_RUN_IMPLEMENTATION:-1}" == "1" &&
      "${VIT_RUN_OOC_SYNTH:-1}" != "1" ]]; then
    printf '%s\n' \
        'ERROR: VIT_RUN_IMPLEMENTATION=1 requires VIT_RUN_OOC_SYNTH=1 for the fail-closed CLB-LUT fit gate'
    exit 1
fi

vit_run_reject_severity() {
    local vit_stage="$1"
    shift
    local vit_severity_pattern='(^|[[:space:]])(CRITICAL WARNING|ERROR|FATAL):|(^|[[:space:]])[1-9][0-9]* (Critical Warnings?|Errors?)([[:space:]]|$)'
    if grep -HEn -- "${vit_severity_pattern}" "$@"; then
        printf 'ERROR: severe Vivado marker found after stage %s\n' \
            "${vit_stage}"
        return 1
    fi
}

run_vivado_stage() {
    local vit_stage="$1"
    local vit_script="$2"
    local vit_console_log="server_logs/${vit_stage}.console.log"
    local vit_vivado_log="server_logs/${vit_stage}.vivado.log"
    local vit_vivado_journal="server_logs/${vit_stage}.vivado.jou"

    printf 'RUN %s: %s\n' "${vit_stage}" "${vit_script}"
    timeout --kill-after=60s "${vit_run_timeout}s" \
        "${vit_run_vivado}" \
        -mode batch \
        -notrace \
        -log "${vit_vivado_log}" \
        -journal "${vit_vivado_journal}" \
        -source "${vit_script}" \
        2>&1 | tee "${vit_console_log}"
    vit_run_reject_severity \
        "${vit_stage}" \
        "${vit_console_log}" \
        "${vit_vivado_log}"
    printf 'PASS stage %s\n' "${vit_stage}"
}

# M8 is an explicitly unsealed development revision. Gate the exact current
# source closure; inherited M5/M7 manifests and receipts are provenance only
# and must not be used as the identity of this build.
run/00_verify_m8_development.sh
readonly vit_run_initial_manifest_sha="$(
    sha256sum M8_DEVELOPMENT_SHA256SUMS.txt | awk '{print $1}'
)"

# Remove only generated results from earlier server attempts. Bundle inputs
# are preserved. The project is recreated by default for a clean closure.
for vit_run_generated_dir in \
    server_logs \
    VIT_googlebase_rtl/reports \
    VIT_googlebase_rtl/artifacts \
    VIT_googlebase_rtl/ViT_googlebase \
    .Xil; do
    if [[ -L "${vit_run_generated_dir}" ]]; then
        printf 'ERROR: generated-output path must not be a symlink: %s\n' \
            "${vit_run_generated_dir}"
        exit 1
    fi
done
find server_logs -mindepth 1 -depth -delete
find VIT_googlebase_rtl/reports \
     VIT_googlebase_rtl/artifacts \
    -mindepth 1 -depth ! -name .keep -delete

vit_run_project_dir="VIT_googlebase_rtl/ViT_googlebase"
if [[ -d "${vit_run_project_dir}" ]]; then
    find "${vit_run_project_dir}" -mindepth 1 -depth -delete
    rmdir "${vit_run_project_dir}"
fi
if [[ -d .Xil ]]; then
    find .Xil -mindepth 1 -depth -delete
    rmdir .Xil
fi

run_vivado_stage 00_preflight \
    scripts/server/00_preflight.tcl

vit_run_skipped=()
if [[ "${VIT_RUN_XSIM:-1}" == "1" ]]; then
    VIVADO_BIN="${vit_run_vivado}" run/10_xsim_axi_smoke.sh
else
    vit_run_skipped+=("XSim")
fi

if [[ "${VIT_RUN_OOC_SYNTH:-1}" == "1" ]]; then
    run_vivado_stage 20_ooc_synth \
        scripts/server/20_run_ooc_synth.tcl
else
    vit_run_skipped+=("OOC synthesis")
fi

run_vivado_stage 30_create_bd \
    scripts/server/30_create_clean_project_and_bd.tcl
run_vivado_stage 40_board_synth \
    scripts/server/40_run_board_synth.tcl

if [[ "${VIT_RUN_IMPLEMENTATION:-1}" == "1" ]]; then
    run_vivado_stage 50_board_impl \
        scripts/server/50_run_board_impl.tcl
else
    vit_run_skipped+=("implementation/bitstream/XSA")
fi

vit_run_status_file="VIT_googlebase_rtl/artifacts/RUN_STATUS.txt"
vit_run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
vit_run_manifest_sha="${vit_run_initial_manifest_sha}"
readonly vit_run_ordered_source_sha="db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
readonly vit_run_filelist_sha="88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"
vit_run_version="$("${vit_run_vivado}" -version 2>&1)"
vit_run_version="${vit_run_version%%$'\n'*}"
if (( ${#vit_run_skipped[@]} == 0 )); then
    vit_run_outcome="PENDING_COLLECTION: every requested Vivado/XSim stage passed"
else
    vit_run_outcome="DEVELOPMENT_UNSEALED_PARTIAL: skipped stages: $(
        IFS=', '
        printf '%s' "${vit_run_skipped[*]}"
    )"
fi

# Long Vivado runs create a large drift window after the initial preflight.
# Re-run the strict, manifest-checking verifier immediately before RUN_STATUS
# is committed. The collector binds this exact terminal transcript and its
# hash, so generated artifacts cannot be accepted after any controlled input
# changed during the run.
vit_run_terminal_verifier_log="server_logs/90_terminal_m8_verifier.log"
run/00_verify_m8_development.sh 2>&1 |
    tee "${vit_run_terminal_verifier_log}"
for vit_run_terminal_marker in \
    'M8_RECEIPT_CLOSURE_PASS receipts=6 entries=658 sidecars=3 payload_replay=FULL' \
    'M8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M8_SEAL'; do
    if [[ "$(grep -Fxc \
        "${vit_run_terminal_marker}" \
        "${vit_run_terminal_verifier_log}" || true)" != "1" ]]; then
        printf 'ERROR: terminal strict M8 verifier marker is not unique: %s\n' \
            "${vit_run_terminal_marker}"
        exit 1
    fi
done
vit_run_terminal_manifest_sha="$(
    sha256sum M8_DEVELOPMENT_SHA256SUMS.txt | awk '{print $1}'
)"
if [[ "${vit_run_terminal_manifest_sha}" != \
      "${vit_run_initial_manifest_sha}" ]]; then
    printf 'ERROR: M8 development manifest drifted during the run: initial=%s terminal=%s\n' \
        "${vit_run_initial_manifest_sha}" \
        "${vit_run_terminal_manifest_sha}"
    exit 1
fi
vit_run_terminal_verifier_sha="$(
    sha256sum "${vit_run_terminal_verifier_log}" | awk '{print $1}'
)"

{
    printf '%s\n' "${vit_run_outcome}"
    printf 'RUN_ID %s\n' "${vit_run_id}"
    printf '%s\n' 'MANIFEST_STATUS DEVELOPMENT_UNSEALED'
    printf 'M8_DEVELOPMENT_MANIFEST_SHA256 %s\n' \
        "${vit_run_manifest_sha}"
    printf 'M8_ORDERED_SOURCE_SHA256 %s\n' \
        "${vit_run_ordered_source_sha}"
    printf 'M8_FILELIST_SHA256 %s\n' \
        "${vit_run_filelist_sha}"
    printf '%s\n' 'TERMINAL_M8_VERIFIER_RESULT PASS'
    printf 'TERMINAL_M8_VERIFIER_LOG %s\n' \
        "${vit_run_terminal_verifier_log}"
    printf 'TERMINAL_M8_VERIFIER_SHA256 %s\n' \
        "${vit_run_terminal_verifier_sha}"
    printf 'VIVADO %s\n' "${vit_run_version}"
    printf 'VIT_REUSE_PROJECT %s\n' "${vit_run_reuse_project}"
    printf 'VIT_RUN_XSIM %s\n' "${VIT_RUN_XSIM:-1}"
    printf 'VIT_RUN_OOC_SYNTH %s\n' "${VIT_RUN_OOC_SYNTH:-1}"
    printf 'VIT_RUN_IMPLEMENTATION %s\n' \
        "${VIT_RUN_IMPLEMENTATION:-1}"
} >"${vit_run_status_file}"

run/90_collect_results.sh
if (( ${#vit_run_skipped[@]} == 0 )); then
    for vit_run_final_status_line in \
        'DEVELOPMENT_UNSEALED: every requested Vivado/XSim stage passed' \
        'COLLECTOR_M8_VERIFIER_RESULT PASS' \
        'COLLECTOR_RESULT PASS' \
        'COLLECTOR_TERMINAL_MARKER M8_OUTPUT_COLLECTION_PASS'; do
        if [[ "$(grep -Fxc \
            "${vit_run_final_status_line}" \
            "${vit_run_status_file}" || true)" != "1" ]]; then
            printf 'ERROR: collector exited without atomic final status line: %s\n' \
                "${vit_run_final_status_line}"
            exit 1
        fi
    done
    if [[ ! -s VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS ]]; then
        printf '%s\n' \
            'ERROR: collector exited without a nonempty OUTPUT_SHA256SUMS'
        exit 1
    fi
    vit_run_output_status_record="$({
        grep -E \
            '^[0-9a-f]{64}  VIT_googlebase_rtl/artifacts/RUN_STATUS\.txt$' \
            VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS || true
    })"
    if [[ -z "${vit_run_output_status_record}" ||
          "$(wc -l <<<"${vit_run_output_status_record}")" != "1" ]]; then
        printf '%s\n' \
            'ERROR: OUTPUT_SHA256SUMS does not contain one exact final RUN_STATUS record'
        exit 1
    fi
    # The collector has exited zero. Replay its entire receipt, not only the
    # final-status row, before reporting success so any immediate artifact,
    # report, verifier-transcript or status drift fails closed.
    sha256sum --check --strict \
        VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS >/dev/null
    vit_run_final_bit_sha="$(
        sha256sum VIT_googlebase_rtl/artifacts/vit_system_wrapper.bit |
            awk '{print $1}'
    )"
    vit_run_xsa_receipt="COLLECTOR_XSA_CONTENT_GATE PASS bit_entries=1 hwh_entries=3 hwh_set_equal=1 hwh_set=vit_system.hwh,vit_system_smartconnect_control_0.hwh,vit_system_smartconnect_ddr_0.hwh embedded_bit_equal=1 bit_sha256=${vit_run_final_bit_sha} embedded_bit_sha256=${vit_run_final_bit_sha}"
    if [[ "$(grep -Fxc \
        "${vit_run_xsa_receipt}" \
        "${vit_run_status_file}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: final RUN_STATUS lacks the exact collector XSA/BIT receipt'
        exit 1
    fi
    printf '%s\n' \
        'PASS: DEVELOPMENT_UNSEALED Vivado flow; no sealed/promotion claim'
else
    printf 'DEVELOPMENT_UNSEALED_PARTIAL: flow passed, but skipped stages: %s\n' \
        "$(IFS=', '; printf '%s' "${vit_run_skipped[*]}")"
fi
