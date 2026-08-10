#!/usr/bin/env bash
set -euo pipefail

vit_protocol_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_protocol_root}"

for vit_protocol_tool in timeout mktemp tee grep; do
    if ! command -v "${vit_protocol_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_protocol_tool}" >&2
        exit 1
    fi
done

vit_protocol_tmp="$(mktemp -d /tmp/vit_npu_protocol_4state.XXXXXX)"
trap 'rm -rf -- "${vit_protocol_tmp}"' EXIT
vit_protocol_log="${vit_protocol_tmp}/simulation.log"
vit_protocol_compile_log="${vit_protocol_tmp}/compile.log"
vit_protocol_tb="sim/protocol/tb_vit_phase_e_npu_memory_protocol_4state.sv"
vit_protocol_top="tb_vit_phase_e_npu_memory_protocol_4state"
vit_protocol_sim="${VIT_PROTOCOL_SIM:-auto}"
vit_protocol_compile_timeout="${VIT_PROTOCOL_COMPILE_TIMEOUT_SECONDS:-180}"
vit_protocol_run_timeout="${VIT_PROTOCOL_RUN_TIMEOUT_SECONDS:-180}"
vit_protocol_iverilog_defines=()
vit_protocol_questa_defines=()

if [[ "${VIT_PROTOCOL_INJECT_X:-0}" == "1" ]]; then
    vit_protocol_iverilog_defines+=("-DVIT_PROTOCOL_INJECT_X")
    vit_protocol_questa_defines+=("+define+VIT_PROTOCOL_INJECT_X")
fi
if [[ "${VIT_PROTOCOL_INJECT_Z:-0}" == "1" ]]; then
    vit_protocol_iverilog_defines+=("-DVIT_PROTOCOL_INJECT_Z")
    vit_protocol_questa_defines+=("+define+VIT_PROTOCOL_INJECT_Z")
fi
if [[ "${VIT_PROTOCOL_INJECT_X:-0}" == "1" ]] &&
   [[ "${VIT_PROTOCOL_INJECT_Z:-0}" == "1" ]]; then
    printf '%s\n' \
        'ERROR: VIT_PROTOCOL_INJECT_X and VIT_PROTOCOL_INJECT_Z are mutually exclusive' >&2
    exit 1
fi

if [[ "${vit_protocol_sim}" == "auto" ]]; then
    if command -v vlog >/dev/null 2>&1 &&
       command -v vsim >/dev/null 2>&1 &&
       command -v vlib >/dev/null 2>&1 &&
       command -v vmap >/dev/null 2>&1; then
        vit_protocol_sim="questa"
    elif command -v iverilog >/dev/null 2>&1 &&
         command -v vvp >/dev/null 2>&1; then
        vit_protocol_sim="iverilog"
    else
        printf '%s\n' \
            'ERROR: neither ModelSim/Questa nor Icarus Verilog is available' >&2
        exit 1
    fi
fi

case "${vit_protocol_sim}" in
    questa|modelsim)
        for vit_protocol_tool in vlog vsim vlib vmap; do
            if ! command -v "${vit_protocol_tool}" >/dev/null 2>&1; then
                printf 'ERROR: required ModelSim/Questa tool is missing: %s\n' \
                    "${vit_protocol_tool}" >&2
                exit 1
            fi
        done
        (
            cd "${vit_protocol_tmp}"
            vmap -c
            vlib work
            vmap work "${vit_protocol_tmp}/work"
        ) >"${vit_protocol_compile_log}" 2>&1
        set +e
        timeout "${vit_protocol_compile_timeout}s" vlog \
            -modelsimini "${vit_protocol_tmp}/modelsim.ini" \
            -sv \
            "${vit_protocol_questa_defines[@]}" \
            -f filelists/core_no_axi.f \
            "${vit_protocol_tb}" \
            >>"${vit_protocol_compile_log}" 2>&1
        vit_protocol_compile_status="$?"
        set -e
        if [[ "${vit_protocol_compile_status}" -ne 0 ]]; then
            cat "${vit_protocol_compile_log}" >&2
            printf 'ERROR: ModelSim/Questa compilation exited with status %s\n' \
                "${vit_protocol_compile_status}" >&2
            exit 1
        fi
        set +e
        timeout "${vit_protocol_run_timeout}s" vsim \
            -modelsimini "${vit_protocol_tmp}/modelsim.ini" \
            -c \
            -onfinish exit \
            "work.${vit_protocol_top}" \
            -do 'run -all; quit -f' \
            2>&1 | tee "${vit_protocol_log}"
        vit_protocol_status="${PIPESTATUS[0]}"
        set -e
        ;;

    iverilog)
        for vit_protocol_tool in iverilog vvp; do
            if ! command -v "${vit_protocol_tool}" >/dev/null 2>&1; then
                printf 'ERROR: required Icarus tool is missing: %s\n' \
                    "${vit_protocol_tool}" >&2
                exit 1
            fi
        done
        set +e
        timeout "${vit_protocol_compile_timeout}s" iverilog \
            -g2012 \
            "${vit_protocol_iverilog_defines[@]}" \
            -s "${vit_protocol_top}" \
            -o "${vit_protocol_tmp}/test.vvp" \
            -f filelists/core_no_axi.f \
            "${vit_protocol_tb}" \
            >"${vit_protocol_compile_log}" 2>&1
        vit_protocol_compile_status="$?"
        set -e
        if [[ "${vit_protocol_compile_status}" -ne 0 ]]; then
            cat "${vit_protocol_compile_log}" >&2
            printf 'ERROR: Icarus compilation exited with status %s\n' \
                "${vit_protocol_compile_status}" >&2
            exit 1
        fi
        set +e
        timeout "${vit_protocol_run_timeout}s" \
            vvp "${vit_protocol_tmp}/test.vvp" \
            2>&1 | tee "${vit_protocol_log}"
        vit_protocol_status="${PIPESTATUS[0]}"
        set -e
        ;;

    *)
        printf 'ERROR: VIT_PROTOCOL_SIM must be auto, questa, modelsim, or iverilog; got %s\n' \
            "${vit_protocol_sim}" >&2
        exit 1
        ;;
esac

if [[ "${vit_protocol_status}" -ne 0 ]]; then
    printf 'ERROR: four-state protocol simulation exited with status %s\n' \
        "${vit_protocol_status}" >&2
    exit 1
fi

vit_protocol_pass_count="$(
    grep -Ec '^(# )?VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_PASS ' \
        "${vit_protocol_log}" || true
)"
if [[ "${vit_protocol_pass_count}" -ne 1 ]]; then
    printf 'ERROR: expected exactly one protocol PASS marker, found %s\n' \
        "${vit_protocol_pass_count}" >&2
    exit 1
fi

vit_protocol_contract_count="$(
    grep -Ec \
        '^(# )?VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_PASS checks=[1-9][0-9]* failures=0 cycles=[1-9][0-9]* aborted=1 restart_requests=13 restart_responses=13 reads=10 writes=3 request_stalls=14 response_stalls=0 max_outstanding=1$' \
        "${vit_protocol_log}" || true
)"
if [[ "${vit_protocol_contract_count}" -ne 1 ]]; then
    printf '%s\n' \
        'ERROR: protocol PASS marker does not satisfy the exact compact E04 accounting contract' >&2
    exit 1
fi

if grep -Eiq \
    'VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_(FAIL|TIMEOUT)|PROTOCOL_4STATE_CHECK_FAILED|failures=[1-9][0-9]*' \
    "${vit_protocol_log}"; then
    printf '%s\n' \
        'ERROR: explicit protocol failure marker appeared in simulation log' >&2
    exit 1
fi

if grep -Eiq \
    '(^|[^[:alnum:]_])(fail(ed|ure)?|error|fatal)([^[:alnum:]_]|$)|\\*\\* (Error|Fatal)' \
    "${vit_protocol_log}"; then
    printf '%s\n' \
        'ERROR: failure-severity text appeared in protocol simulation log' >&2
    exit 1
fi

printf 'PROTOCOL_4STATE_RUNNER_PASS simulator=%s\n' "${vit_protocol_sim}"
