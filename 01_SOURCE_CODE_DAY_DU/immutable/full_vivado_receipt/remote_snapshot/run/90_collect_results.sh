#!/usr/bin/env bash
set -euo pipefail

vit_collect_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
cd "${vit_collect_root}"

vit_collect_output="VIT_googlebase_rtl/artifacts/OUTPUT_SHA256SUMS"
mkdir -p \
    VIT_googlebase_rtl/reports \
    VIT_googlebase_rtl/artifacts \
    server_logs

vit_collect_status="VIT_googlebase_rtl/artifacts/RUN_STATUS.txt"
vit_collect_complete=0
vit_collect_candidate=0
vit_collect_pending=0
vit_collect_development_complete=0
if [[ -s "${vit_collect_status}" ]]; then
    vit_collect_status_head="$(head -n 1 "${vit_collect_status}")"
    case "${vit_collect_status_head}" in
        'CANDIDATE_COMPLETE: every bundled Vivado/XSim stage passed')
            vit_collect_candidate=1
            ;;
        'COMPLETE: every bundled Vivado/XSim stage passed')
            vit_collect_complete=1
            ;;
        'PENDING_COLLECTION: every requested Vivado/XSim stage passed')
            vit_collect_pending=1
            ;;
        'DEVELOPMENT_UNSEALED: every requested Vivado/XSim stage passed')
            vit_collect_development_complete=1
            ;;
    esac
fi

if (( vit_collect_candidate == 1 || vit_collect_complete == 1 ||
      vit_collect_pending == 1 ||
      vit_collect_development_complete == 1 )); then
    vit_collect_required=(
        VIT_googlebase_rtl/artifacts/rtl_ooc_post_synth.dcp
        VIT_googlebase_rtl/artifacts/board_post_synth.dcp
        VIT_googlebase_rtl/artifacts/board_post_route.dcp
        VIT_googlebase_rtl/artifacts/vit_system_wrapper.bit
        VIT_googlebase_rtl/artifacts/vit_system_wrapper.xsa
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_dsp.rpt
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_reachability.rpt
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_blackboxes.rpt
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_latches.rpt
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_m8_ram_mapping.rpt
        VIT_googlebase_rtl/reports/rtl_standalone_post_synth_utilization.rpt
        VIT_googlebase_rtl/reports/rtl_ooc_post_synth_lut_fit_gate.rpt
        VIT_googlebase_rtl/reports/rtl_standalone_post_synth_hierarchical.rpt
        VIT_googlebase_rtl/reports/rtl_standalone_post_synth_timing.rpt
        VIT_googlebase_rtl/reports/rtl_standalone_post_synth_combinational_loops.rpt
        VIT_googlebase_rtl/reports/vit_system_geometry.rpt
        VIT_googlebase_rtl/reports/vit_system_axi_contract.rpt
        VIT_googlebase_rtl/reports/board_post_synth_dsp.rpt
        VIT_googlebase_rtl/reports/board_post_synth_reachability.rpt
        VIT_googlebase_rtl/reports/board_post_synth_blackboxes.rpt
        VIT_googlebase_rtl/reports/board_post_synth_latches.rpt
        VIT_googlebase_rtl/reports/board_post_synth_utilization.rpt
        VIT_googlebase_rtl/reports/board_post_synth_lut_fit_gate.rpt
        VIT_googlebase_rtl/reports/board_post_synth_hierarchical.rpt
        VIT_googlebase_rtl/reports/board_post_synth_ram_utilization.rpt
        VIT_googlebase_rtl/reports/board_post_synth_m8_ram_mapping.rpt
        VIT_googlebase_rtl/reports/board_post_synth_timing.rpt
        VIT_googlebase_rtl/reports/board_post_synth_combinational_loops.rpt
        VIT_googlebase_rtl/reports/board_post_route_dsp.rpt
        VIT_googlebase_rtl/reports/board_post_route_reachability.rpt
        VIT_googlebase_rtl/reports/board_post_route_blackboxes.rpt
        VIT_googlebase_rtl/reports/board_post_route_latches.rpt
        VIT_googlebase_rtl/reports/board_post_route_utilization.rpt
        VIT_googlebase_rtl/reports/board_post_route_hierarchical.rpt
        VIT_googlebase_rtl/reports/board_post_route_ram_utilization.rpt
        VIT_googlebase_rtl/reports/board_post_route_m8_ram_mapping.rpt
        VIT_googlebase_rtl/reports/board_post_route_timing.rpt
        VIT_googlebase_rtl/reports/board_post_route_combinational_loops.rpt
        VIT_googlebase_rtl/reports/board_post_route_check_timing.rpt
        VIT_googlebase_rtl/reports/board_post_route_status.rpt
        VIT_googlebase_rtl/reports/board_post_route_timing_gate.rpt
        VIT_googlebase_rtl/reports/board_post_route_constraint_coverage_gate.rpt
        VIT_googlebase_rtl/reports/board_post_route_route_gate.rpt
        VIT_googlebase_rtl/reports/board_post_route_drc.rpt
        VIT_googlebase_rtl/reports/board_post_route_drc_gate.rpt
        VIT_googlebase_rtl/reports/board_post_route_methodology.rpt
        VIT_googlebase_rtl/reports/board_post_route_methodology_gate.rpt
        VIT_googlebase_rtl/reports/board_post_route_xsa_contents.rpt
        server_logs/00_preflight.console.log
        server_logs/20_ooc_synth.console.log
        server_logs/30_create_bd.console.log
        server_logs/40_board_synth.console.log
        server_logs/40_accelerator_child_synth.runme.log
        server_logs/50_board_impl.console.log
        server_logs/10_xvlog.log
        server_logs/10_tb_vit_phase_e_axi_mem_adapter.log
        server_logs/10_tb_vit_phase_e_axi_wrapper.log
        server_logs/10_tb_vit_phase_e_engine_memory.log
        server_logs/10_tb_vit_phase_e_engine_axi.log
        server_logs/10_tb_vit_phase_e_perf_counters.log
        server_logs/10_tb_vit_phase_e_profile_counters.log
        server_logs/10_tb_vit_phase_e_m7_overlap_counters.log
        server_logs/10_tb_vit_phase_e_axi_e05_compact_rtl_mode0.log
        server_logs/10_tb_vit_phase_e_axi_e05_compact_rtl_mode1.log
        server_logs/10_tb_vit_phase_e_axi_e05_compact_rtl_mode3.log
        server_logs/90_terminal_m8_verifier.log
    )
    for vit_collect_required_path in \
        "${vit_collect_required[@]}"; do
        if [[ ! -s "${vit_collect_required_path}" ]]; then
            printf 'ERROR: required complete-flow output is missing: %s\n' \
                "${vit_collect_required_path}"
            exit 1
        fi
    done

    readonly vit_collect_expected_source="db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
    readonly vit_collect_expected_filelist="88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"
    if ! grep -Fxq \
        "M8_ORDERED_SOURCE_SHA256 ${vit_collect_expected_source}" \
        "${vit_collect_status}"; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not bind the exact M8 ordered source identity'
        exit 1
    fi
    if ! grep -Fxq \
        "M8_FILELIST_SHA256 ${vit_collect_expected_filelist}" \
        "${vit_collect_status}"; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not bind the exact M8 production filelist identity'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        'VIT_REUSE_PROJECT 0' \
        "${vit_collect_status}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: M8 sign-off RUN_STATUS must bind VIT_REUSE_PROJECT 0 exactly once'
        exit 1
    fi
    vit_collect_manifest_line="$({
        grep -E \
            '^M8_DEVELOPMENT_MANIFEST_SHA256 [0-9a-f]{64}$' \
            "${vit_collect_status}" || true
    })"
    if [[ "$(wc -l <<<"${vit_collect_manifest_line}")" != "1" ||
          -z "${vit_collect_manifest_line}" ]]; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not contain one exact M8 manifest identity'
        exit 1
    fi
    vit_collect_manifest_sha="${vit_collect_manifest_line##* }"
    vit_collect_actual_manifest_sha="$(
        sha256sum M8_DEVELOPMENT_SHA256SUMS.txt | awk '{print $1}'
    )"
    if [[ "${vit_collect_manifest_sha}" != \
          "${vit_collect_actual_manifest_sha}" ]]; then
        printf 'ERROR: M8 manifest changed after preflight: status=%s current=%s\n' \
            "${vit_collect_manifest_sha}" \
            "${vit_collect_actual_manifest_sha}"
        exit 1
    fi

    vit_collect_terminal_log="server_logs/90_terminal_m8_verifier.log"
    if [[ "$(grep -Fxc \
        'TERMINAL_M8_VERIFIER_RESULT PASS' \
        "${vit_collect_status}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not bind an exact terminal M8 verifier PASS'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        "TERMINAL_M8_VERIFIER_LOG ${vit_collect_terminal_log}" \
        "${vit_collect_status}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not bind the terminal M8 verifier log path'
        exit 1
    fi
    vit_collect_terminal_sha_line="$({
        grep -E \
            '^TERMINAL_M8_VERIFIER_SHA256 [0-9a-f]{64}$' \
            "${vit_collect_status}" || true
    })"
    if [[ "$(wc -l <<<"${vit_collect_terminal_sha_line}")" != "1" ||
          -z "${vit_collect_terminal_sha_line}" ]]; then
        printf '%s\n' \
            'ERROR: RUN_STATUS does not contain one terminal verifier hash'
        exit 1
    fi
    vit_collect_terminal_expected_sha="${vit_collect_terminal_sha_line##* }"
    vit_collect_terminal_actual_sha="$(
        sha256sum "${vit_collect_terminal_log}" | awk '{print $1}'
    )"
    if [[ "${vit_collect_terminal_expected_sha}" != \
          "${vit_collect_terminal_actual_sha}" ]]; then
        printf 'ERROR: terminal verifier log hash mismatch: status=%s current=%s\n' \
            "${vit_collect_terminal_expected_sha}" \
            "${vit_collect_terminal_actual_sha}"
        exit 1
    fi
    vit_collect_terminal_metadata_marker="M8_METADATA_PREFLIGHT_PASS sources=80 ordered=${vit_collect_expected_source} filelist=${vit_collect_expected_filelist} ip=0x0001000D abi=v1.13 parent=M7S8 receipts=BOUND full_vivado=PENDING bit_xsa=NOT_GENERATED"
    if [[ "$(grep -Fxc \
        "${vit_collect_terminal_metadata_marker}" \
        "${vit_collect_terminal_log}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: terminal verifier log lacks the exact M8 metadata identity'
        exit 1
    fi
    if [[ "$(grep -Ec \
        '^M8_DEVELOPMENT_MANIFEST_PASS entries=[1-9][0-9]*$' \
        "${vit_collect_terminal_log}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: terminal verifier log lacks one closed-manifest PASS marker'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        "M8_DEVELOPMENT_MANIFEST_SHA256=${vit_collect_manifest_sha}" \
        "${vit_collect_terminal_log}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: terminal verifier log does not bind the RUN_STATUS manifest hash'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        'M8_RECEIPT_CLOSURE_PASS receipts=6 entries=658 sidecars=3 payload_replay=FULL' \
        "${vit_collect_terminal_log}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: terminal verifier log lacks the full receipt payload replay marker'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        'M8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M8_SEAL' \
        "${vit_collect_terminal_log}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: terminal strict M8 verifier PASS marker is missing'
        exit 1
    fi

    # Close the small post-terminal-verifier race by replaying the same strict
    # verifier inside collection. A PENDING_COLLECTION status is not promoted
    # unless this second transcript rechecks every manifest-controlled file
    # and all excluded-report receipt payloads.
    vit_collect_verifier_log="server_logs/91_collector_m8_verifier.log"
    run/00_verify_m8_development.sh 2>&1 |
        tee "${vit_collect_verifier_log}"
    for vit_collect_verifier_marker in \
        'M8_RECEIPT_CLOSURE_PASS receipts=6 entries=658 sidecars=3 payload_replay=FULL' \
        "M8_DEVELOPMENT_MANIFEST_SHA256=${vit_collect_manifest_sha}" \
        'M8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M8_SEAL'; do
        if [[ "$(grep -Fxc \
            "${vit_collect_verifier_marker}" \
            "${vit_collect_verifier_log}" || true)" != "1" ]]; then
            printf 'ERROR: collector strict verifier marker is missing: %s\n' \
                "${vit_collect_verifier_marker}"
            exit 1
        fi
    done
    vit_collect_verifier_sha="$(
        sha256sum "${vit_collect_verifier_log}" | awk '{print $1}'
    )"
    if (( vit_collect_development_complete == 1 )); then
        for vit_collect_bound_line in \
            'COLLECTOR_M8_VERIFIER_RESULT PASS' \
            "COLLECTOR_M8_VERIFIER_LOG ${vit_collect_verifier_log}" \
            "COLLECTOR_M8_VERIFIER_SHA256 ${vit_collect_verifier_sha}" \
            'COLLECTOR_RESULT PASS' \
            'COLLECTOR_TERMINAL_MARKER M8_OUTPUT_COLLECTION_PASS'; do
            if [[ "$(grep -Fxc \
                "${vit_collect_bound_line}" \
                "${vit_collect_status}" || true)" != "1" ]]; then
                printf 'ERROR: final RUN_STATUS lacks collector binding: %s\n' \
                    "${vit_collect_bound_line}"
                exit 1
            fi
        done
    fi

    vit_collect_geometry="VIT_googlebase_rtl/reports/vit_system_geometry.rpt"
    for vit_collect_geometry_line in \
        'CONFIG.ARRAY_ROWS 8' \
        'CONFIG.ARRAY_COLS 2' \
        'CONFIG.PE_LANES 16' \
        'CONFIG.FP16_STREAMS 8'; do
        if ! grep -Fxq \
            "${vit_collect_geometry_line}" \
            "${vit_collect_geometry}"; then
            printf 'ERROR: exact M8 R8/C2/L16/S8 geometry missing from %s: %s\n' \
                "${vit_collect_geometry}" \
                "${vit_collect_geometry_line}"
            exit 1
        fi
    done

    for vit_collect_fit_stage in \
        rtl_ooc_post_synth \
        board_post_synth; do
        vit_collect_fit_report="VIT_googlebase_rtl/reports/${vit_collect_fit_stage}_lut_fit_gate.rpt"
        vit_collect_fit_prefix_count="$(
            grep -Ec \
                "^M8_CLB_LUT_FIT (PASS|FAIL) stage=${vit_collect_fit_stage}([[:space:]]|$)" \
                "${vit_collect_fit_report}" || true
        )"
        if [[ "${vit_collect_fit_prefix_count}" != "1" ]]; then
            printf 'ERROR: CLB-LUT fit disposition is not unique for %s: %s\n' \
                "${vit_collect_fit_stage}" \
                "${vit_collect_fit_prefix_count}"
            exit 1
        fi
        vit_collect_fit_line="$(
            grep -E \
                "^M8_CLB_LUT_FIT (PASS|FAIL) stage=${vit_collect_fit_stage}([[:space:]]|$)" \
                "${vit_collect_fit_report}"
        )"
        if ! [[
            "${vit_collect_fit_line}" =~ ^M8_CLB_LUT_FIT[[:space:]]PASS[[:space:]]stage=${vit_collect_fit_stage}[[:space:]]used=([0-9]+)[[:space:]]available=([0-9]+)[[:space:]]headroom=([0-9]+)$
        ]]; then
            printf 'ERROR: CLB-LUT fit gate did not PASS exactly for %s: %s\n' \
                "${vit_collect_fit_stage}" \
                "${vit_collect_fit_line}"
            exit 1
        fi
        vit_collect_fit_used="${BASH_REMATCH[1]}"
        vit_collect_fit_available="${BASH_REMATCH[2]}"
        vit_collect_fit_headroom="${BASH_REMATCH[3]}"
        if (( vit_collect_fit_used > vit_collect_fit_available ||
              vit_collect_fit_headroom !=
                  vit_collect_fit_available - vit_collect_fit_used )); then
            printf 'ERROR: inconsistent CLB-LUT fit arithmetic for %s: %s\n' \
                "${vit_collect_fit_stage}" \
                "${vit_collect_fit_line}"
            exit 1
        fi
    done

    for vit_collect_structural_stage in \
        rtl_ooc_post_synth \
        board_post_synth \
        board_post_route; do
        vit_collect_stage_prefix="VIT_googlebase_rtl/reports/${vit_collect_structural_stage}"
        if [[ "$(grep -Fxc \
            'DSP48/DSP58 primitive count: 0' \
            "${vit_collect_stage_prefix}_dsp.rpt" || true)" != "1" ]]; then
            printf 'ERROR: exact DSP48/DSP58=0 gate missing for %s\n' \
                "${vit_collect_structural_stage}"
            exit 1
        fi
        if [[ "$(grep -Fxc \
            "M8_BLACKBOX_GATE PASS stage=${vit_collect_structural_stage} count=0" \
            "${vit_collect_stage_prefix}_blackboxes.rpt" || true)" != "1" ]]; then
            printf 'ERROR: exact blackbox=0 gate missing for %s\n' \
                "${vit_collect_structural_stage}"
            exit 1
        fi
        if [[ "$(grep -Fxc \
            "M8_LATCH_GATE PASS stage=${vit_collect_structural_stage} count=0" \
            "${vit_collect_stage_prefix}_latches.rpt" || true)" != "1" ]]; then
            printf 'ERROR: exact latch=0 gate missing for %s\n' \
                "${vit_collect_structural_stage}"
            exit 1
        fi
        vit_collect_ram_marker="M8_RAM_HIERARCHY PASS stage=${vit_collect_structural_stage} total_ramb36=41 activation=32 bias=4 layernorm=3 softmax=1 layer_param=1 ramb18=0 uram=0 layernorm_lutram=0 softmax_lutram=0"
        if [[ "$(grep -Fxc \
            "${vit_collect_ram_marker}" \
            "${vit_collect_stage_prefix}_m8_ram_mapping.rpt" || true)" != "1" ]]; then
            printf 'ERROR: exact M8 41-RAMB36/no-new-buffer-LUTRAM gate missing for %s\n' \
                "${vit_collect_structural_stage}"
            exit 1
        fi
        if [[ "$(grep -Fxc \
            "M8_COMBINATIONAL_LOOP_GATE PASS stage=${vit_collect_structural_stage} count=0" \
            "${vit_collect_stage_prefix}_combinational_loops.rpt" || true)" != "1" ]]; then
            printf 'ERROR: exact combinational-loop=0 gate missing for %s\n' \
                "${vit_collect_structural_stage}"
            exit 1
        fi
    done

    vit_collect_route_gate="VIT_googlebase_rtl/reports/board_post_route_route_gate.rpt"
    for vit_collect_route_line in \
        'ROUTED_FULLY 1' \
        'ERRORS_IN_ROUTES 0'; do
        if [[ "$(grep -Fxc \
            "${vit_collect_route_line}" \
            "${vit_collect_route_gate}" || true)" != "1" ]]; then
            printf 'ERROR: post-route gate is missing exact line: %s\n' \
                "${vit_collect_route_line}"
            exit 1
        fi
    done

    vit_collect_timing_gate="VIT_googlebase_rtl/reports/board_post_route_timing_gate.rpt"
    env -u PYTHONHOME -u PYTHONPATH \
        /usr/bin/python3 - "${vit_collect_timing_gate}" <<'PY'
import math
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {}
for line in path.read_text(encoding="utf-8").splitlines():
    fields = line.split()
    if len(fields) == 2 and fields[0] in {"setup_wns", "hold_whs"}:
        if fields[0] in values:
            raise SystemExit(f"ERROR: duplicate {fields[0]} in {path}")
        try:
            values[fields[0]] = float(fields[1])
        except ValueError as error:
            raise SystemExit(f"ERROR: invalid {fields[0]} in {path}: {fields[1]}") from error
if set(values) != {"setup_wns", "hold_whs"}:
    raise SystemExit(f"ERROR: incomplete timing gate: {path}")
for name, value in values.items():
    if not math.isfinite(value) or value < 0.0:
        raise SystemExit(f"ERROR: post-route {name} failed: {value}")
PY

    if [[ "$(grep -Fxc \
        'M8_CONSTRAINT_COVERAGE_GATE PASS stage=board_post_route failures=0' \
        VIT_googlebase_rtl/reports/board_post_route_constraint_coverage_gate.rpt || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: exact post-route constraint-coverage gate is missing'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        'M8_DRC_GATE PASS stage=board_post_route total=0 severe=0' \
        VIT_googlebase_rtl/reports/board_post_route_drc_gate.rpt || true)" != "1" ]]; then
        printf '%s\n' 'ERROR: exact zero-total post-route DRC gate is missing'
        exit 1
    fi
    if [[ "$(grep -Fxc \
        'M8_METHODOLOGY_GATE PASS stage=board_post_route total=0 severe=0' \
        VIT_googlebase_rtl/reports/board_post_route_methodology_gate.rpt || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: exact zero-total post-route methodology gate is missing'
        exit 1
    fi

    vit_collect_axi_contract="VIT_googlebase_rtl/reports/vit_system_axi_contract.rpt"
    for vit_collect_axi_line in \
        'M5_AXI128_CONTRACT PASS' \
        'vit_phase_e_axi_0/S_AXI CONFIG.DATA_WIDTH 32 exact 32' \
        'vit_phase_e_axi_0/M_AXI CONFIG.PROTOCOL AXI4 exact AXI4' \
        'vit_phase_e_axi_0/M_AXI CONFIG.DATA_WIDTH 128 exact 128' \
        'vit_phase_e_axi_0/M_AXI CONFIG.SUPPORTS_NARROW_BURST 1 exact 1' \
        'vit_phase_e_axi_0/M_AXI CONFIG.MAX_BURST_LENGTH 4 exact 4' \
        'vit_phase_e_axi_0/M_AXI CONFIG.NUM_READ_OUTSTANDING 2 exact 2' \
        'vit_phase_e_axi_0/M_AXI CONFIG.NUM_WRITE_OUTSTANDING 1 exact 1' \
        'smartconnect_ddr/S00_AXI CONFIG.DATA_WIDTH 128 exact 128' \
        'smartconnect_ddr/M00_AXI CONFIG.DATA_WIDTH 128 exact 128' \
        'zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.DATA_WIDTH 128 exact 128'; do
        if ! grep -Fxq \
            "${vit_collect_axi_line}" \
            "${vit_collect_axi_contract}"; then
            printf 'ERROR: exact M5 AXI-128 contract missing from %s: %s\n' \
                "${vit_collect_axi_contract}" \
                "${vit_collect_axi_line}"
            exit 1
        fi
    done

    vit_collect_xsa="VIT_googlebase_rtl/artifacts/vit_system_wrapper.xsa"
    vit_collect_bit="VIT_googlebase_rtl/artifacts/vit_system_wrapper.bit"
    for vit_collect_hw_artifact in \
        "${vit_collect_xsa}" \
        "${vit_collect_bit}"; do
        if [[ -L "${vit_collect_hw_artifact}" ||
              ! -f "${vit_collect_hw_artifact}" ||
              ! -s "${vit_collect_hw_artifact}" ]]; then
            printf 'ERROR: hardware artifact is missing, empty or symlinked: %s\n' \
                "${vit_collect_hw_artifact}"
            exit 1
        fi
    done
    unzip -tq "${vit_collect_xsa}" >/dev/null
    vit_collect_xsa_entries="$(unzip -Z1 "${vit_collect_xsa}")"
    vit_collect_xsa_bit_entries=()
    vit_collect_xsa_hwh_entries=()
    while IFS= read -r vit_collect_xsa_entry; do
        if [[ "${vit_collect_xsa_entry,,}" == *.bit ]]; then
            vit_collect_xsa_bit_entries+=("${vit_collect_xsa_entry}")
        fi
        if [[ "${vit_collect_xsa_entry,,}" == *.hwh ]]; then
            vit_collect_xsa_hwh_entries+=("${vit_collect_xsa_entry}")
        fi
    done <<<"${vit_collect_xsa_entries}"
    if (( ${#vit_collect_xsa_bit_entries[@]} != 1 )); then
        printf 'ERROR: XSA must contain exactly one BIT; found %d\n' \
            "${#vit_collect_xsa_bit_entries[@]}"
        exit 1
    fi
    readonly vit_collect_expected_hwh_set='vit_system.hwh,vit_system_smartconnect_control_0.hwh,vit_system_smartconnect_ddr_0.hwh'
    vit_collect_actual_hwh_set="$({
        printf '%s\n' "${vit_collect_xsa_hwh_entries[@]}" |
            LC_ALL=C sort |
            paste -sd, -
    })"
    if (( ${#vit_collect_xsa_hwh_entries[@]} != 3 )) ||
       [[ "${vit_collect_actual_hwh_set}" != \
           "${vit_collect_expected_hwh_set}" ]]; then
        printf 'ERROR: XSA must contain exactly three HWH with canonical set %s; found count=%d set=%s\n' \
            "${vit_collect_expected_hwh_set}" \
            "${#vit_collect_xsa_hwh_entries[@]}" \
            "${vit_collect_actual_hwh_set}"
        exit 1
    fi
    vit_collect_xsa_bit_entry="${vit_collect_xsa_bit_entries[0]}"
    vit_collect_bit_sha="$(sha256sum "${vit_collect_bit}" | awk '{print $1}')"
    vit_collect_embedded_bit_sha="$(
        unzip -p "${vit_collect_xsa}" "${vit_collect_xsa_bit_entry}" |
            sha256sum | awk '{print $1}'
    )"
    if [[ "${vit_collect_bit_sha}" != "${vit_collect_embedded_bit_sha}" ]]; then
        printf 'ERROR: XSA embedded BIT hash differs: artifact=%s embedded=%s\n' \
            "${vit_collect_bit_sha}" "${vit_collect_embedded_bit_sha}"
        exit 1
    fi
    if ! unzip -p \
        "${vit_collect_xsa}" "${vit_collect_xsa_bit_entry}" |
        cmp -s "${vit_collect_bit}" -; then
        printf '%s\n' \
            'ERROR: XSA embedded BIT is not byte-for-byte equal to the external BIT'
        exit 1
    fi
    vit_collect_xsa_gate="M8_XSA_CONTENT_GATE PASS stage=board_post_route bit_entries=1 hwh_entries=3 hwh_set_equal=1 hwh_set=${vit_collect_expected_hwh_set} embedded_bit_equal=1 bit_sha256=${vit_collect_bit_sha} embedded_bit_sha256=${vit_collect_embedded_bit_sha}"
    vit_collect_xsa_receipt="COLLECTOR_XSA_CONTENT_GATE PASS bit_entries=1 hwh_entries=3 hwh_set_equal=1 hwh_set=${vit_collect_expected_hwh_set} embedded_bit_equal=1 bit_sha256=${vit_collect_bit_sha} embedded_bit_sha256=${vit_collect_embedded_bit_sha}"
    if [[ "$(grep -Fxc \
        "${vit_collect_xsa_gate}" \
        VIT_googlebase_rtl/reports/board_post_route_xsa_contents.rpt || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: exact XSA cardinality/embedded-BIT equality gate is missing'
        exit 1
    fi
    if (( vit_collect_development_complete == 1 )) &&
       [[ "$(grep -Fxc \
           "${vit_collect_xsa_receipt}" \
           "${vit_collect_status}" || true)" != "1" ]]; then
        printf '%s\n' \
            'ERROR: final RUN_STATUS lacks the exact collector XSA/BIT receipt'
        exit 1
    fi

fi

vit_collect_tmp="$(mktemp)"
vit_collect_status_tmp=""
vit_collect_cleanup() {
    if [[ -n "${vit_collect_tmp}" ]]; then
        rm -f -- "${vit_collect_tmp}"
    fi
    if [[ -n "${vit_collect_status_tmp}" ]]; then
        rm -f -- "${vit_collect_status_tmp}"
    fi
}
trap vit_collect_cleanup EXIT

vit_collect_promote=0
if (( vit_collect_candidate == 1 || vit_collect_pending == 1 )); then
    vit_collect_promote=1
    # Prepare the final receipt and checksum it before atomically promoting
    # the candidate/pending status. A collector failure can therefore never
    # leave a false COMPLETE or DEVELOPMENT_UNSEALED marker behind.
    vit_collect_status_tmp="$(mktemp \
        "${vit_collect_status}.XXXXXX")"
    if (( vit_collect_candidate == 1 )); then
        {
            printf '%s\n' \
                'COMPLETE: every bundled Vivado/XSim stage passed'
            awk 'NR > 1 { print }' "${vit_collect_status}"
        } >"${vit_collect_status_tmp}"
    else
        {
            printf '%s\n' \
                'DEVELOPMENT_UNSEALED: every requested Vivado/XSim stage passed'
            awk 'NR > 1 { print }' "${vit_collect_status}"
            printf '%s\n' 'COLLECTOR_M8_VERIFIER_RESULT PASS'
            printf 'COLLECTOR_M8_VERIFIER_LOG %s\n' \
                "${vit_collect_verifier_log}"
            printf 'COLLECTOR_M8_VERIFIER_SHA256 %s\n' \
                "${vit_collect_verifier_sha}"
            printf '%s\n' "${vit_collect_xsa_receipt}"
            printf '%s\n' 'COLLECTOR_RESULT PASS'
            printf '%s\n' \
                'COLLECTOR_TERMINAL_MARKER M8_OUTPUT_COLLECTION_PASS'
        } >"${vit_collect_status_tmp}"
    fi

    find VIT_googlebase_rtl/reports \
         VIT_googlebase_rtl/artifacts \
         server_logs \
        -type f \
        ! -name OUTPUT_SHA256SUMS \
        ! -name RUN_STATUS.txt \
        ! -name 'RUN_STATUS.txt.*' \
        -print0 |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum >"${vit_collect_tmp}"
    vit_collect_status_sha="$(
        sha256sum "${vit_collect_status_tmp}" |
            awk '{ print $1 }'
    )"
    printf '%s  %s\n' \
        "${vit_collect_status_sha}" \
        "${vit_collect_status}" \
        >>"${vit_collect_tmp}"
else
    find VIT_googlebase_rtl/reports \
         VIT_googlebase_rtl/artifacts \
         server_logs \
        -type f \
        ! -name OUTPUT_SHA256SUMS \
        -print0 |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum >"${vit_collect_tmp}"
fi

mv "${vit_collect_tmp}" "${vit_collect_output}"
vit_collect_tmp=""
if (( vit_collect_promote == 1 )); then
    mv "${vit_collect_status_tmp}" "${vit_collect_status}"
    vit_collect_status_tmp=""
    if (( vit_collect_candidate == 1 )); then
        vit_collect_complete=1
    else
        vit_collect_development_complete=1
    fi
fi
trap - EXIT

if (( vit_collect_complete == 1 )); then
    printf 'PASS: complete output set checksummed at %s\n' \
        "${vit_collect_output}" || true
elif (( vit_collect_development_complete == 1 )); then
    printf 'M8_OUTPUT_COLLECTION_PASS status=%s output=%s\n' \
        "${vit_collect_status}" "${vit_collect_output}" || true
    printf 'PASS: DEVELOPMENT_UNSEALED complete output set checksummed at %s\n' \
        "${vit_collect_output}" || true
else
    printf 'PARTIAL: available outputs checksummed at %s\n' \
        "${vit_collect_output}" || true
fi

# All acceptance-affecting operations precede the atomic status move above.
# Diagnostic stdout is deliberately non-authoritative, so a closed caller pipe
# cannot turn an already committed receipt into a nonzero collector process.
exit 0
