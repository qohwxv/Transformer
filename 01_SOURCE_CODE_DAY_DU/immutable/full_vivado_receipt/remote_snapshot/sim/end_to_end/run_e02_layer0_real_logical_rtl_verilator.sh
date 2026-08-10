#!/usr/bin/env bash
set -euo pipefail

# Full production-RTL E02 layer-0 runner.  A bounded probe proves startup,
# descriptor and memory-protocol activity but is never accepted as terminal
# numerical evidence.  A full PASS is authoritative only after exact marker,
# asset, design and verification-identity checks and receipt creation.
vit_e02_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e02_root}"

for vit_e02_tool in \
    verilator timeout nice tee python3 grep sed date mktemp mkdir dirname rm; do
    if ! command -v "${vit_e02_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e02_tool}"
        exit 1
    fi
done

if (($# != 0)); then
    printf '%s\n' \
        'ERROR: this runner accepts environment settings, not positional arguments'
    exit 1
fi

vit_e02_is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

vit_e02_nice="${VIT_E02_LOGICAL_NICE:-15}"
if ! [[ "${vit_e02_nice}" =~ ^([0-9]|1[0-9])$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E02_LOGICAL_NICE must be an integer from 0 to 19'
    exit 1
fi

vit_e02_build_only="${VIT_E02_LOGICAL_BUILD_ONLY:-0}"
if ! [[ "${vit_e02_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E02_LOGICAL_BUILD_ONLY must be exactly 0 or 1'
    exit 1
fi

vit_e02_probe_cycles="${VIT_E02_LOGICAL_PROBE_CYCLES:-0}"
if ! [[ "${vit_e02_probe_cycles}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E02_LOGICAL_PROBE_CYCLES must be a non-negative integer'
    exit 1
fi
if [[ "${vit_e02_build_only}" == "1" ]] &&
   ((10#${vit_e02_probe_cycles} != 0)); then
    printf '%s\n' \
        'ERROR: BUILD_ONLY and a nonzero probe cycle limit are mutually exclusive'
    exit 1
fi

vit_e02_progress_cycles="${VIT_E02_LOGICAL_PROGRESS_CYCLES:-50000000}"
vit_e02_progress_transactions="${VIT_E02_LOGICAL_PROGRESS_TRANSACTIONS:-10000000}"
vit_e02_build_timeout="${VIT_E02_LOGICAL_BUILD_TIMEOUT_SECONDS:-1200}"
vit_e02_run_timeout="${VIT_E02_LOGICAL_RUN_TIMEOUT_SECONDS:-18000}"
for vit_e02_numeric_setting in \
    "${vit_e02_progress_cycles}" \
    "${vit_e02_progress_transactions}" \
    "${vit_e02_build_timeout}" \
    "${vit_e02_run_timeout}"; do
    if ! vit_e02_is_positive_integer "${vit_e02_numeric_setting}"; then
        printf '%s\n' \
            'ERROR: progress intervals and build/run timeouts must be positive integers'
        exit 1
    fi
done

vit_e02_cflags="${VIT_E02_CFLAGS:-${VIT_VERILATOR_CFLAGS:--O3}}"
if [[ -z "${vit_e02_cflags}" ]]; then
    printf '%s\n' 'ERROR: VIT_E02_CFLAGS must not be empty'
    exit 1
fi

vit_e02_run_id="${VIT_E02_EVIDENCE_RUN_ID:-e02-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[
    "${vit_e02_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
]]; then
    printf '%s\n' \
        'ERROR: VIT_E02_EVIDENCE_RUN_ID has an invalid evidence-ID format'
    exit 1
fi

vit_e02_mode="full"
if [[ "${vit_e02_build_only}" == "1" ]]; then
    vit_e02_mode="build_only"
elif ((10#${vit_e02_probe_cycles} > 0)); then
    vit_e02_mode="probe"
fi

if [[ -n "${VIT_E02_LOGICAL_LOG+x}" ]]; then
    vit_e02_run_log="${VIT_E02_LOGICAL_LOG}"
else
    vit_e02_run_log="build/test_logs/vit_e02_layer0_real_logical_rtl_${vit_e02_mode}_${vit_e02_run_id}.log"
fi
if [[ -n "${VIT_E02_LOGICAL_BUILD_LOG+x}" ]]; then
    vit_e02_build_log="${VIT_E02_LOGICAL_BUILD_LOG}"
else
    vit_e02_build_log="build/test_logs/vit_e02_layer0_real_logical_rtl_${vit_e02_mode}_${vit_e02_run_id}.build.log"
fi
vit_e02_sidecar="build/test_logs/vit_e02_layer0_real_logical_rtl_e2e.active.json"

# Refuse absolute/traversing paths and any existing symlink component before
# tee/mkdir can touch a log.  The same check covers the future receipt and the
# full-run selection sidecar.
python3 - \
    "${vit_e02_root}" \
    "${vit_e02_run_log}" \
    "${vit_e02_build_log}" \
    "${vit_e02_run_log}.receipt.json" \
    "${vit_e02_sidecar}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
values = sys.argv[2:]
if values[0] == values[1]:
    raise SystemExit("ERROR: E02 run log and build log must be different")
for value in values:
    relative = Path(value)
    if (
        not value
        or relative.is_absolute()
        or relative.as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise SystemExit(
            f"ERROR: E02 output path must be normalized repository-relative: {value!r}"
        )
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(
                f"ERROR: E02 output path contains symlink component: {value}"
            )
        if not current.exists():
            break
    try:
        (root / relative).resolve(strict=False).relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"ERROR: E02 output path escapes repository root: {value}"
        ) from exc
    if (root / relative).exists() and not (root / relative).is_file():
        raise SystemExit(
            f"ERROR: E02 output path is not a regular file: {value}"
        )
PY

mkdir -p \
    "$(dirname "${vit_e02_run_log}")" \
    "$(dirname "${vit_e02_build_log}")"

vit_e02_design_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-design-sha256
)"
vit_e02_verification_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-verification-sha256
)"
if ! [[ "${vit_e02_design_pre}" =~ ^DESIGN_SHA256=[0-9a-f]{64}$ ]]; then
    printf 'ERROR: malformed design identity: %s\n' "${vit_e02_design_pre}"
    exit 1
fi
if ! [[
    "${vit_e02_verification_pre}" =~ ^VERIFICATION_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed verification identity: %s\n' \
        "${vit_e02_verification_pre}"
    exit 1
fi

# Receipt authority requires these to be exactly the first three non-empty
# lines.  tee without -a deliberately starts a fresh run log.
printf '%s\n' \
    "VIT_EVIDENCE_RUN_ID=${vit_e02_run_id}" \
    "${vit_e02_design_pre}" \
    "${vit_e02_verification_pre}" |
    tee "${vit_e02_run_log}"

vit_e02_tmp="$(mktemp -d /tmp/vit_e02_layer0_real_logical.XXXXXX)"
trap 'rm -rf -- "${vit_e02_tmp}"' EXIT
vit_e02_asset_pre_log="${vit_e02_tmp}/asset-pre.log"
vit_e02_asset_post_log="${vit_e02_tmp}/asset-post.log"

set +e
nice -n "${vit_e02_nice}" \
    python3 sim/end_to_end/validate_e02_layer0_real_assets.py \
    2>&1 | tee "${vit_e02_asset_pre_log}" | tee -a "${vit_e02_run_log}"
vit_e02_asset_pipe_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e02_asset_pipe_status[0]}" != "0" ]] ||
   [[ "${vit_e02_asset_pipe_status[1]}" != "0" ]] ||
   [[ "${vit_e02_asset_pipe_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E02 immutable-asset validation before build'
    exit 1
fi

vit_e02_asset_marker_pattern='^E02_ASSET_VALIDATION_PASS files=18 parameter_words=7087872 checkpoint_words=302592 model_table_sha256=[0-9a-f]{64} checkpoint_manifest_sha256=[0-9a-f]{64} asset_set_sha256=[0-9a-f]{64}$'
vit_e02_asset_marker_count="$(
    grep -Ec \
        "${vit_e02_asset_marker_pattern}" \
        "${vit_e02_asset_pre_log}" || true
)"
if [[ "${vit_e02_asset_marker_count}" != "1" ]]; then
    printf '%s\n' \
        "FAIL E02 asset validation: expected one exact PASS marker, found ${vit_e02_asset_marker_count}"
    exit 1
fi
vit_e02_asset_marker="$(
    grep -E "${vit_e02_asset_marker_pattern}" "${vit_e02_asset_pre_log}"
)"
vit_e02_asset_set_sha256="$(
    sed -n \
        's/.* asset_set_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
        "${vit_e02_asset_pre_log}"
)"
if ! [[ "${vit_e02_asset_set_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'FAIL E02 asset validation: malformed asset-set identity'
    exit 1
fi

vit_e02_obj_dir="${vit_e02_tmp}/obj"
vit_e02_binary="vit_e02_layer0_real_logical_rtl_e2e"
vit_e02_verilator_version="$(verilator --version)"
printf '%s\n' \
    "E02_VERILATOR_VERSION=${vit_e02_verilator_version}" \
    "E02_BUILD_CONFIG nice=${vit_e02_nice} cflags=${vit_e02_cflags} build_timeout_seconds=${vit_e02_build_timeout}" \
    | tee -a "${vit_e02_run_log}"

printf '%s\n' \
    'BUILD production full-dimension E02 layer-0 real logical-memory test'
set +e
timeout "${vit_e02_build_timeout}s" \
    nice -n "${vit_e02_nice}" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_npu_e02_layer0_real_rtl \
        --Mdir "${vit_e02_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e02_cflags}" \
        -f sim/end_to_end/vit_phase_e_npu_e02_layer0_real_rtl_verilator.f \
        -o "${vit_e02_binary}" \
        2>&1 | tee "${vit_e02_build_log}" | tee -a "${vit_e02_run_log}"
vit_e02_build_pipe_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e02_build_pipe_status[1]}" != "0" ]] ||
   [[ "${vit_e02_build_pipe_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E02 build-log pipeline'
    exit 1
fi
if [[ "${vit_e02_build_pipe_status[0]}" != "0" ]]; then
    printf 'FAIL E02 production build: status=%s\n' \
        "${vit_e02_build_pipe_status[0]}"
    exit "${vit_e02_build_pipe_status[0]}"
fi

vit_e02_verify_post_state() {
    local vit_e02_design_post
    local vit_e02_verification_post
    local vit_e02_post_marker
    local vit_e02_post_marker_count
    local vit_e02_post_pipe_status

    set +e
    nice -n "${vit_e02_nice}" \
        python3 sim/end_to_end/validate_e02_layer0_real_assets.py \
        2>&1 | tee "${vit_e02_asset_post_log}"
    vit_e02_post_pipe_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e02_post_pipe_status[0]}" != "0" ]] ||
       [[ "${vit_e02_post_pipe_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E02 immutable-asset validation after execution'
        return 1
    fi
    vit_e02_post_marker_count="$(
        grep -Ec \
            "${vit_e02_asset_marker_pattern}" \
            "${vit_e02_asset_post_log}" || true
    )"
    if [[ "${vit_e02_post_marker_count}" != "1" ]]; then
        printf '%s\n' \
            'FAIL E02 post-execution asset validation marker is not unique'
        return 1
    fi
    vit_e02_post_marker="$(
        grep -E "${vit_e02_asset_marker_pattern}" "${vit_e02_asset_post_log}"
    )"
    if [[ "${vit_e02_post_marker}" != "${vit_e02_asset_marker}" ]]; then
        printf '%s\n' 'FAIL E02 immutable assets changed during execution'
        return 1
    fi

    vit_e02_design_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-design-sha256
    )"
    vit_e02_verification_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-verification-sha256
    )"
    if [[ "${vit_e02_design_post}" != "${vit_e02_design_pre}" ]]; then
        printf '%s\n' 'FAIL E02 production design identity changed during run'
        return 1
    fi
    if [[
        "${vit_e02_verification_post}" != "${vit_e02_verification_pre}"
    ]]; then
        printf '%s\n' \
            'FAIL E02 verification identity changed during run'
        return 1
    fi
}

if [[ "${vit_e02_build_only}" == "1" ]]; then
    vit_e02_verify_post_state
    printf '%s\n' \
        "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_BUILD_ONLY_VERIFIED asset_set_sha256=${vit_e02_asset_set_sha256} ${vit_e02_design_pre} ${vit_e02_verification_pre}" \
        | tee -a "${vit_e02_run_log}"
    exit 0
fi

vit_e02_sim_argv=(
    "${vit_e02_obj_dir}/${vit_e02_binary}"
    "+E02_LOGICAL_PROGRESS_CYCLES=${vit_e02_progress_cycles}"
    "+E02_LOGICAL_PROGRESS_TRANSACTIONS=${vit_e02_progress_transactions}"
    "+E02_LOGICAL_PROBE_CYCLES=${vit_e02_probe_cycles}"
)
vit_e02_command_argv_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(sys.argv[1:], separators=(",",":")))' \
        "${vit_e02_sim_argv[@]}"
)"
vit_e02_configuration_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(dict(x.split("=",1) for x in sys.argv[1:]), sort_keys=True, separators=(",",":")))' \
        "mode=${vit_e02_mode}" \
        "nice=${vit_e02_nice}" \
        "probe_cycles=${vit_e02_probe_cycles}" \
        "progress_cycles=${vit_e02_progress_cycles}" \
        "progress_transactions=${vit_e02_progress_transactions}" \
        "build_timeout_seconds=${vit_e02_build_timeout}" \
        "run_timeout_seconds=${vit_e02_run_timeout}"
)"
vit_e02_cflags_json="$(
    python3 -c \
        'import json,shlex,sys; print(json.dumps(shlex.split(sys.argv[1]), separators=(",",":")))' \
        "${vit_e02_cflags}"
)"
vit_e02_command_marker="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-command-sha256 \
        --receipt-command-argv-json "${vit_e02_command_argv_json}" \
        --receipt-configuration-json "${vit_e02_configuration_json}" \
        --receipt-cflags-json "${vit_e02_cflags_json}"
)"
if ! [[
    "${vit_e02_command_marker}" =~ ^COMMAND_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed command identity: %s\n' \
        "${vit_e02_command_marker}"
    exit 1
fi
vit_e02_command_sha256="${vit_e02_command_marker#COMMAND_SHA256=}"

vit_e02_create_receipt() {
    local vit_e02_receipt_output
    local vit_e02_expected_receipt_path
    local vit_e02_expected_receipt_output

    vit_e02_receipt_output="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --create-receipt \
            --receipt-evidence-key e02_layer0_real_logical \
            --receipt-log "${vit_e02_run_log}" \
            --receipt-run-id "${vit_e02_run_id}" \
            --receipt-exit-code 0 \
            --receipt-tool-name verilator \
            --receipt-tool-version "${vit_e02_verilator_version}" \
            --receipt-command-argv-json "${vit_e02_command_argv_json}" \
            --receipt-configuration-json "${vit_e02_configuration_json}" \
            --receipt-cflags-json "${vit_e02_cflags_json}" \
            --receipt-command-sha256 "${vit_e02_command_sha256}" \
            --receipt-asset-set-sha256 "${vit_e02_asset_set_sha256}"
    )"
    vit_e02_expected_receipt_path="${vit_e02_run_log}.receipt.json"
    vit_e02_expected_receipt_output="PASS verification receipt: ${vit_e02_expected_receipt_path}"
    if [[
        "${vit_e02_receipt_output}" != "${vit_e02_expected_receipt_output}"
    ]] || [[ ! -s "${vit_e02_expected_receipt_path}" ]]; then
        printf '%s\n' \
            'FAIL E02 receipt helper returned an unexpected result or empty receipt'
        return 1
    fi
    # Deliberately do not append this output to the immutable run log.
    printf '%s\n' "${vit_e02_receipt_output}"
}

printf '%s\n' \
    "${vit_e02_command_marker}" \
    "E02_RUN_CONFIG mode=${vit_e02_mode} nice=${vit_e02_nice} timeout_seconds=${vit_e02_run_timeout} probe_cycles=${vit_e02_probe_cycles} progress_cycles=${vit_e02_progress_cycles} progress_transactions=${vit_e02_progress_transactions}" \
    | tee -a "${vit_e02_run_log}"
printf '%s\n' \
    "RUN production full-dimension E02 layer-0 mode=${vit_e02_mode}"

set +e
timeout "${vit_e02_run_timeout}s" \
    nice -n "${vit_e02_nice}" \
    "${vit_e02_sim_argv[@]}" \
    2>&1 | tee -a "${vit_e02_run_log}"
vit_e02_run_pipe_status=("${PIPESTATUS[@]}")
set -e
vit_e02_run_status="${vit_e02_run_pipe_status[0]}"
if [[ "${vit_e02_run_pipe_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E02 run-log pipeline'
    exit 1
fi

# Drift is checked even for a timeout or simulator failure so the failure
# cannot be misattributed to files changing underneath a long run.
vit_e02_verify_post_state

if [[ "${vit_e02_run_status}" == "124" ]]; then
    printf '%s\n' \
        'INCOMPLETE: bounded timeout reached; this is neither PASS nor RTL failure.' \
        "Inspect ${vit_e02_run_log} and increase VIT_E02_LOGICAL_RUN_TIMEOUT_SECONDS."
    exit 124
fi
if [[ "${vit_e02_run_status}" != "0" ]]; then
    printf 'FAIL E02 simulator exited with status=%s\n' \
        "${vit_e02_run_status}"
    exit "${vit_e02_run_status}"
fi

vit_e02_severity_pattern='(^ERROR E02_LAYER0_REAL_LOGICAL|^VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_(E2E_FAIL|PROBE_FAIL) |%Error([-:])|%Fatal([-:])|[Aa]ssertion[[:space:]].*[Ff]ail|[Aa]borted)'
if grep -Eq "${vit_e02_severity_pattern}" "${vit_e02_run_log}"; then
    printf '%s\n' \
        'FAIL E02 log contains an error/fatal/assertion severity marker'
    exit 1
fi

if ((10#${vit_e02_probe_cycles} > 0)); then
    vit_e02_probe_pattern='^VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_PROBE_PASS cycles=[0-9]+ commands=[1-9][0-9]* checkpoints=[0-9]+ reads=[0-9]+ writes=[0-9]+ parameter_reads=[0-9]+ scratch_reads=[0-9]+ requests=[1-9][0-9]* responses=[0-9]+ outstanding=[01] stalls=[1-9][0-9]* forced_stalls=16 invalid=0 failures=0$'
    vit_e02_probe_markers="$(
        grep -Ec "${vit_e02_probe_pattern}" "${vit_e02_run_log}" || true
    )"
    if [[ "${vit_e02_probe_markers}" != "1" ]]; then
        printf '%s\n' \
            "FAIL E02 probe: expected exactly one exact PROBE_PASS marker, found ${vit_e02_probe_markers}"
        exit 1
    fi
    if grep -Eq \
        '^VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_E2E_PASS ' \
        "${vit_e02_run_log}"; then
        printf '%s\n' \
            'FAIL E02 probe: bounded probe log must not claim E2E_PASS'
        exit 1
    fi
    printf '%s\n' \
        "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_PROBE_VERIFIED asset_set_sha256=${vit_e02_asset_set_sha256} ${vit_e02_design_pre} ${vit_e02_verification_pre}" \
        | tee -a "${vit_e02_run_log}"
    # Probe receipts are valid only as outcome=probe_only; they never update
    # the sidecar and can never authorize a terminal full-model PASS.
    vit_e02_create_receipt
    exit 0
fi

vit_e02_e2e_pattern='^VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_E2E_PASS checks=[1-9][0-9]* cycles=[1-9][0-9]* commands=20 reads=737995740 writes=4876932 parameter_reads=701323008 scratch_reads=36672732 input_reads=0 invalid=0 requests=742872672 responses=742872672 outstanding=0 stalls=[1-9][0-9]* forced_stalls=16 tolerance_failures=0 nonfinite=0 unknown=0 exact_mismatch=[0-9]+ max_abs=[-+0-9.]+[eE][-+][0-9]+ mean_abs=[-+0-9.]+[eE][-+][0-9]+$'
vit_e02_e2e_markers="$(
    grep -Ec "${vit_e02_e2e_pattern}" "${vit_e02_run_log}" || true
)"
if [[ "${vit_e02_e2e_markers}" != "1" ]]; then
    printf '%s\n' \
        "FAIL E02 full run: expected exactly one exact terminal E2E_PASS marker, found ${vit_e02_e2e_markers}"
    exit 1
fi
if grep -Eq \
    '^VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_(PROBE_PASS|PROBE_VERIFIED) ' \
    "${vit_e02_run_log}"; then
    printf '%s\n' 'FAIL E02 full run: conflicting probe marker'
    exit 1
fi

# This is the last line appended before the receipt freezes the log hash.
printf '%s\n' \
    "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_TERMINAL_E2E_VERIFIED asset_set_sha256=${vit_e02_asset_set_sha256}" \
    | tee -a "${vit_e02_run_log}"

vit_e02_create_receipt

# Only a receipt-backed full terminal PASS becomes the selected E02 run.
# The atomic sidecar update avoids mtime-based or partial-log selection.
python3 - "${vit_e02_sidecar}" "${vit_e02_run_id}" "${vit_e02_run_log}" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

sidecar = Path(sys.argv[1])
run_id = sys.argv[2]
run_log = sys.argv[3]
if sidecar.is_symlink():
    raise SystemExit("ERROR: refusing to replace symlink E02 sidecar")
sidecar.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "schema": "vit-e02-log-selection-v1",
    "run_id": run_id,
    "log_path": run_log,
}
text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{sidecar.name}.",
    suffix=".tmp",
    dir=sidecar.parent,
)
try:
    os.fchmod(descriptor, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        descriptor = -1
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary_name, sidecar)
    directory_fd = os.open(sidecar.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PY
printf 'E02_ACTIVE_LOG_UPDATED run_id=%s log=%s sidecar=%s\n' \
    "${vit_e02_run_id}" \
    "${vit_e02_run_log}" \
    "${vit_e02_sidecar}"
