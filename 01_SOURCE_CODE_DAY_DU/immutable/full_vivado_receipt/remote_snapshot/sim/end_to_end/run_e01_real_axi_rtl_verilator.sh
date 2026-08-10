#!/usr/bin/env bash
set -euo pipefail

# Full-dimension production-RTL E01 through AXI-Lite + M_AXI.  A full run is
# selected as evidence only after immutable assets, source identities, exact
# terminal markers, simulator status and the adjacent receipt all agree.
vit_e01_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e01_root}"

for vit_e01_tool in \
    verilator timeout nice tee python3 grep sed date mktemp mkdir dirname rm \
    chmod; do
    if ! command -v "${vit_e01_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e01_tool}" >&2
        exit 1
    fi
done
if (($# != 0)); then
    printf '%s\n' \
        'ERROR: E01 runner accepts environment settings, not arguments' >&2
    exit 1
fi

vit_e01_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

vit_e01_nice="${VIT_AXI_E01_REAL_NICE:-15}"
if ! [[ "${vit_e01_nice}" =~ ^([0-9]|1[0-9])$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E01_REAL_NICE must be an integer from 0 to 19' >&2
    exit 1
fi
vit_e01_build_only="${VIT_AXI_E01_REAL_BUILD_ONLY:-0}"
if ! [[ "${vit_e01_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E01_REAL_BUILD_ONLY must be exactly 0 or 1' >&2
    exit 1
fi
vit_e01_probe_cycles="${VIT_AXI_E01_REAL_PROBE_CYCLES:-0}"
if ! [[ "${vit_e01_probe_cycles}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E01_REAL_PROBE_CYCLES must be non-negative' >&2
    exit 1
fi
if [[ "${vit_e01_build_only}" == "1" ]] &&
   ((10#${vit_e01_probe_cycles} != 0)); then
    printf '%s\n' \
        'ERROR: E01 BUILD_ONLY and probe mode are mutually exclusive' >&2
    exit 1
fi

vit_e01_progress_cycles="${VIT_AXI_E01_REAL_PROGRESS_CYCLES:-5000000}"
vit_e01_progress_reads="${VIT_AXI_E01_REAL_PROGRESS_READS:-1000000}"
vit_e01_build_timeout="${VIT_AXI_E01_REAL_BUILD_TIMEOUT_SECONDS:-900}"
vit_e01_run_timeout="${VIT_AXI_E01_REAL_RUN_TIMEOUT_SECONDS:-21600}"
for vit_e01_number in \
    "${vit_e01_progress_cycles}" \
    "${vit_e01_progress_reads}" \
    "${vit_e01_build_timeout}" \
    "${vit_e01_run_timeout}"; do
    if ! vit_e01_positive_integer "${vit_e01_number}"; then
        printf '%s\n' \
            'ERROR: E01 progress intervals and timeouts must be positive integers' >&2
        exit 1
    fi
done

vit_e01_cflags="${VIT_AXI_E01_REAL_CFLAGS:-${VIT_VERILATOR_CFLAGS:--O3}}"
if [[ -z "${vit_e01_cflags}" ]]; then
    printf '%s\n' 'ERROR: E01 Verilator CFLAGS must not be empty' >&2
    exit 1
fi

vit_e01_run_id="${VIT_AXI_E01_REAL_EVIDENCE_RUN_ID:-e01-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[
    "${vit_e01_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E01_REAL_EVIDENCE_RUN_ID is invalid' >&2
    exit 1
fi

vit_e01_mode="full"
if [[ "${vit_e01_build_only}" == "1" ]]; then
    vit_e01_mode="build_only"
elif ((10#${vit_e01_probe_cycles} > 0)); then
    vit_e01_mode="probe"
fi
if [[ -n "${VIT_AXI_E01_REAL_LOG+x}" ]]; then
    vit_e01_run_log="${VIT_AXI_E01_REAL_LOG}"
else
    vit_e01_run_log="build/test_logs/vit_axi_e01_real_rtl_${vit_e01_mode}_${vit_e01_run_id}.log"
fi
if [[ -n "${VIT_AXI_E01_REAL_BUILD_LOG+x}" ]]; then
    vit_e01_build_log="${VIT_AXI_E01_REAL_BUILD_LOG}"
else
    vit_e01_build_log="build/test_logs/vit_axi_e01_real_rtl_${vit_e01_mode}_${vit_e01_run_id}.build.log"
fi
vit_e01_receipt_path="${vit_e01_run_log}.receipt.json"
vit_e01_sidecar="build/test_logs/vit_axi_e01_real_rtl_e2e.active.json"

# Logs and receipts are immutable per run.  The generic selection sidecar is
# the sole replaceable output and is updated atomically only after a receipt.
python3 - \
    "${vit_e01_root}" \
    "${vit_e01_run_log}" \
    "${vit_e01_build_log}" \
    "${vit_e01_receipt_path}" \
    "${vit_e01_sidecar}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
outputs = sys.argv[2:5]
sidecar_value = sys.argv[5]
values = outputs + [sidecar_value]
if len(set(values)) != len(values):
    raise SystemExit("ERROR: E01 output paths must be distinct")
for value in values:
    relative = Path(value)
    if (
        not value
        or relative.is_absolute()
        or relative.as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise SystemExit(
            f"ERROR: E01 output must be normalized repository-relative: {value!r}"
        )
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(
                f"ERROR: E01 output path contains symlink component: {value}"
            )
        if not current.exists():
            break
    try:
        (root / relative).resolve(strict=False).relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"ERROR: E01 output escapes repository root: {value}"
        ) from exc
for value in outputs:
    if (root / value).exists() or (root / value).is_symlink():
        raise SystemExit(
            f"ERROR: refusing to overwrite existing E01 output: {value}"
        )
sidecar = root / sidecar_value
if sidecar.exists() and not sidecar.is_file():
    raise SystemExit(
        f"ERROR: E01 selection sidecar is not a regular file: {sidecar_value}"
    )
PY

mkdir -p \
    "$(dirname "${vit_e01_run_log}")" \
    "$(dirname "${vit_e01_build_log}")"

vit_e01_design_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py --emit-design-sha256
)"
vit_e01_verification_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-verification-sha256
)"
if ! [[ "${vit_e01_design_pre}" =~ ^DESIGN_SHA256=[0-9a-f]{64}$ ]]; then
    printf 'ERROR: malformed E01 design identity: %s\n' \
        "${vit_e01_design_pre}" >&2
    exit 1
fi
if ! [[
    "${vit_e01_verification_pre}" =~ ^VERIFICATION_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed E01 verification identity: %s\n' \
        "${vit_e01_verification_pre}" >&2
    exit 1
fi

# Receipt authority requires these to be the first three non-empty lines.
set +e
printf '%s\n' \
    "VIT_EVIDENCE_RUN_ID=${vit_e01_run_id}" \
    "${vit_e01_design_pre}" \
    "${vit_e01_verification_pre}" |
    tee "${vit_e01_run_log}"
vit_e01_provenance_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_provenance_status[0]}" != "0" ]] ||
   [[ "${vit_e01_provenance_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 provenance-log pipeline' >&2
    exit 1
fi

vit_e01_tmp="$(mktemp -d /tmp/vit_axi_e01_real.XXXXXX)"
trap 'rm -rf -- "${vit_e01_tmp}"' EXIT
vit_e01_asset_pre_log="${vit_e01_tmp}/asset-pre.log"
vit_e01_asset_post_log="${vit_e01_tmp}/asset-post.log"

set +e
nice -n "${vit_e01_nice}" \
    python3 sim/end_to_end/validate_e01_e04_real_axi_assets.py \
        --phase e01 \
    2>&1 | tee "${vit_e01_asset_pre_log}" | tee -a "${vit_e01_run_log}"
vit_e01_asset_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_asset_status[0]}" != "0" ]] ||
   [[ "${vit_e01_asset_status[1]}" != "0" ]] ||
   [[ "${vit_e01_asset_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 immutable-asset validation before build' >&2
    exit 1
fi

vit_e01_asset_pattern='^E01_ASSET_VALIDATION_PASS files=6 parameter_words=742656 activation_words=150528 golden_words=151296 model_table_sha256=bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038 modelsim_manifest_sha256=d225e16ed2be3c3868c5d71c39860386e3180e0b82671ae4ddc47e9203cac45d modelsim_hash_list_sha256=d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b preprocess_manifest_sha256=08c001878e342779412f991653fe3899c9bc1753fdc9dbc0d893d6c315d735e7 asset_set_sha256=914775872910e2b27cc8fcb75820190877be0d7ee007ffc7718a0d9cf4ad2e22$'
vit_e01_asset_count="$(
    grep -Ec "${vit_e01_asset_pattern}" "${vit_e01_asset_pre_log}" || true
)"
vit_e01_asset_prefix_count="$(
    grep -Ec '^E01_ASSET_VALIDATION_PASS([[:space:]]|$)' \
        "${vit_e01_asset_pre_log}" || true
)"
if [[ "${vit_e01_asset_count}" != "1" ]] ||
   [[ "${vit_e01_asset_prefix_count}" != "1" ]]; then
    printf 'FAIL E01 asset marker exact=%s prefix=%s\n' \
        "${vit_e01_asset_count}" "${vit_e01_asset_prefix_count}" >&2
    exit 1
fi
vit_e01_asset_marker="$(
    grep -E "${vit_e01_asset_pattern}" "${vit_e01_asset_pre_log}"
)"
vit_e01_asset_set_sha256="$(
    sed -n \
        's/.* asset_set_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
        "${vit_e01_asset_pre_log}"
)"
if [[
    "${vit_e01_asset_set_sha256}" != \
    "914775872910e2b27cc8fcb75820190877be0d7ee007ffc7718a0d9cf4ad2e22"
]]; then
    printf '%s\n' 'FAIL E01 malformed/untrusted asset-set identity' >&2
    exit 1
fi

vit_e01_verify_post_state() {
    local vit_e01_design_post
    local vit_e01_verification_post
    local vit_e01_post_marker
    local vit_e01_post_count
    local vit_e01_post_prefix_count
    local -a vit_e01_post_status

    set +e
    nice -n "${vit_e01_nice}" \
        python3 sim/end_to_end/validate_e01_e04_real_axi_assets.py \
            --phase e01 \
        2>&1 | tee "${vit_e01_asset_post_log}"
    vit_e01_post_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e01_post_status[0]}" != "0" ]] ||
       [[ "${vit_e01_post_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E01 post-run immutable-asset validation' >&2
        return 1
    fi
    vit_e01_post_count="$(
        grep -Ec "${vit_e01_asset_pattern}" \
            "${vit_e01_asset_post_log}" || true
    )"
    vit_e01_post_prefix_count="$(
        grep -Ec '^E01_ASSET_VALIDATION_PASS([[:space:]]|$)' \
            "${vit_e01_asset_post_log}" || true
    )"
    if [[ "${vit_e01_post_count}" != "1" ]] ||
       [[ "${vit_e01_post_prefix_count}" != "1" ]]; then
        printf '%s\n' 'FAIL E01 post-run asset marker is not unique/exact' >&2
        return 1
    fi
    vit_e01_post_marker="$(
        grep -E "${vit_e01_asset_pattern}" "${vit_e01_asset_post_log}"
    )"
    if [[ "${vit_e01_post_marker}" != "${vit_e01_asset_marker}" ]]; then
        printf '%s\n' 'FAIL E01 immutable assets changed during run' >&2
        return 1
    fi
    vit_e01_design_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-design-sha256
    )"
    vit_e01_verification_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-verification-sha256
    )"
    if [[ "${vit_e01_design_post}" != "${vit_e01_design_pre}" ]]; then
        printf '%s\n' 'FAIL E01 design identity changed during run' >&2
        return 1
    fi
    if [[
        "${vit_e01_verification_post}" != "${vit_e01_verification_pre}"
    ]]; then
        printf '%s\n' 'FAIL E01 verification identity changed during run' >&2
        return 1
    fi
}

vit_e01_obj_dir="${vit_e01_tmp}/obj"
vit_e01_binary="vit_axi_e01_real_rtl_e2e"
vit_e01_verilator_version="$(verilator --version)"
set +e
printf '%s\n' \
    "E01_VERILATOR_VERSION=${vit_e01_verilator_version}" \
    "E01_BUILD_CONFIG mode=${vit_e01_mode} nice=${vit_e01_nice} cflags=${vit_e01_cflags} build_timeout_seconds=${vit_e01_build_timeout}" |
    tee -a "${vit_e01_run_log}"
vit_e01_config_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_config_status[0]}" != "0" ]] ||
   [[ "${vit_e01_config_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 build-config log pipeline' >&2
    exit 1
fi

printf '%s\n' \
    'BUILD production full-dimension E01 real-data AXI test (Verilator)'
set +e
timeout "${vit_e01_build_timeout}s" \
    nice -n "${vit_e01_nice}" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e01_real_rtl \
        --Mdir "${vit_e01_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e01_cflags}" \
        -f sim/end_to_end/vit_phase_e_axi_e01_real_rtl_verilator.f \
        -o "${vit_e01_binary}" \
        2>&1 | tee "${vit_e01_build_log}" | tee -a "${vit_e01_run_log}"
vit_e01_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_build_status[1]}" != "0" ]] ||
   [[ "${vit_e01_build_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 build-log pipeline' >&2
    exit 1
fi

# Re-hash assets and sources even when compilation failed.
vit_e01_verify_post_state
if [[ "${vit_e01_build_status[0]}" != "0" ]]; then
    printf 'FAIL E01 build status=%s\n' \
        "${vit_e01_build_status[0]}" >&2
    exit "${vit_e01_build_status[0]}"
fi

if [[ "${vit_e01_build_only}" == "1" ]]; then
    set +e
    printf '%s\n' \
        "VIT_PHASE_E_AXI_E01_REAL_RTL_BUILD_ONLY_VERIFIED asset_set_sha256=${vit_e01_asset_set_sha256} ${vit_e01_design_pre} ${vit_e01_verification_pre}" |
        tee -a "${vit_e01_run_log}"
    vit_e01_build_only_log_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e01_build_only_log_status[0]}" != "0" ]] ||
       [[ "${vit_e01_build_only_log_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E01 build-only log pipeline' >&2
        exit 1
    fi
    exit 0
fi

vit_e01_sim_argv=(
    "${vit_e01_obj_dir}/${vit_e01_binary}"
    "+E01_PROGRESS_CYCLES=${vit_e01_progress_cycles}"
    "+E01_PROGRESS_READS=${vit_e01_progress_reads}"
    "+E01_PROBE_CYCLES=${vit_e01_probe_cycles}"
)
vit_e01_command_argv_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")))' \
        "${vit_e01_sim_argv[@]}"
)"
vit_e01_configuration_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(dict(x.split("=",1) for x in sys.argv[1:]),sort_keys=True,separators=(",",":")))' \
        "mode=${vit_e01_mode}" \
        "nice=${vit_e01_nice}" \
        "probe_cycles=${vit_e01_probe_cycles}" \
        "progress_cycles=${vit_e01_progress_cycles}" \
        "progress_reads=${vit_e01_progress_reads}" \
        "build_timeout_seconds=${vit_e01_build_timeout}" \
        "run_timeout_seconds=${vit_e01_run_timeout}"
)"
vit_e01_cflags_json="$(
    python3 -c \
        'import json,shlex,sys; print(json.dumps(shlex.split(sys.argv[1]),separators=(",",":")))' \
        "${vit_e01_cflags}"
)"
vit_e01_command_marker="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-command-sha256 \
        --receipt-command-argv-json "${vit_e01_command_argv_json}" \
        --receipt-configuration-json "${vit_e01_configuration_json}" \
        --receipt-cflags-json "${vit_e01_cflags_json}"
)"
if ! [[
    "${vit_e01_command_marker}" =~ ^COMMAND_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed E01 command identity: %s\n' \
        "${vit_e01_command_marker}" >&2
    exit 1
fi
vit_e01_command_sha256="${vit_e01_command_marker#COMMAND_SHA256=}"

set +e
printf '%s\n' \
    "${vit_e01_command_marker}" \
    "E01_RUNNER_CONFIG mode=${vit_e01_mode} nice=${vit_e01_nice} timeout_seconds=${vit_e01_run_timeout} probe_cycles=${vit_e01_probe_cycles} progress_cycles=${vit_e01_progress_cycles} progress_reads=${vit_e01_progress_reads}" |
    tee -a "${vit_e01_run_log}"
vit_e01_run_config_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_run_config_status[0]}" != "0" ]] ||
   [[ "${vit_e01_run_config_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 run-config log pipeline' >&2
    exit 1
fi
printf 'RUN production full-dimension E01 real AXI mode=%s\n' \
    "${vit_e01_mode}"

set +e
timeout "${vit_e01_run_timeout}s" \
    nice -n "${vit_e01_nice}" \
    "${vit_e01_sim_argv[@]}" \
    2>&1 | tee -a "${vit_e01_run_log}"
vit_e01_run_statuses=("${PIPESTATUS[@]}")
set -e
vit_e01_run_status="${vit_e01_run_statuses[0]}"
if [[ "${vit_e01_run_statuses[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 run-log pipeline' >&2
    exit 1
fi

# Always attribute a timeout/failure against the same assets and source state.
vit_e01_verify_post_state

if [[ "${vit_e01_run_status}" == "124" ]]; then
    printf '%s\n' \
        'INCOMPLETE: E01 bounded timeout; neither PASS nor RTL failure.' \
        "Inspect ${vit_e01_run_log} and increase VIT_AXI_E01_REAL_RUN_TIMEOUT_SECONDS."
    exit 124
fi
if [[ "${vit_e01_run_status}" != "0" ]]; then
    printf 'FAIL E01 simulator status=%s\n' \
        "${vit_e01_run_status}" >&2
    exit "${vit_e01_run_status}"
fi

vit_e01_severity_pattern='(^[[:space:]]*(FAIL|ERROR|FATAL)([[:space:]]|:)|^E01_ASSET_VALIDATION_FAIL([[:space:]]|:)|^VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_FAIL([[:space:]]|$)|%Error([-:])|%Fatal([-:])|E01 REAL AXI CHECK FAILED|E01 real AXI watchdog timeout|[Aa]ssertion[[:space:]].*[Ff]ail)'
if grep -Eq "${vit_e01_severity_pattern}" "${vit_e01_run_log}"; then
    printf '%s\n' 'FAIL E01 log contains a severity marker' >&2
    exit 1
fi

vit_e01_run_config_pattern="^E01_REAL_AXI_RUN_CONFIG progress_cycles=${vit_e01_progress_cycles} progress_reads=${vit_e01_progress_reads} probe_cycles=${vit_e01_probe_cycles} plusarg_hits=1/1/1$"
if ((10#${vit_e01_probe_cycles} > 0)); then
    vit_e01_probe_pattern='^VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP cycles=[1-9][0-9]* commands=[0-9]+ checkpoints=[0-9]+ reads=[0-9]+ writes=[0-9]+ model_reads=[0-9]+ input_reads=[0-9]+ scratch_reads=[0-9]+ invalid=0$'
    vit_e01_probe_config_count="$(
        grep -Ec "${vit_e01_run_config_pattern}" \
            "${vit_e01_run_log}" || true
    )"
    vit_e01_probe_config_prefix_count="$(
        grep -Ec '^E01_REAL_AXI_RUN_CONFIG([[:space:]]|$)' \
            "${vit_e01_run_log}" || true
    )"
    vit_e01_probe_count="$(
        grep -Ec "${vit_e01_probe_pattern}" "${vit_e01_run_log}" || true
    )"
    vit_e01_probe_prefix_count="$(
        grep -Ec '^VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP([[:space:]]|$)' \
            "${vit_e01_run_log}" || true
    )"
    if [[ "${vit_e01_probe_config_count}" != "1" ]] ||
       [[ "${vit_e01_probe_config_prefix_count}" != "1" ]] ||
       [[ "${vit_e01_probe_count}" != "1" ]] ||
       [[ "${vit_e01_probe_prefix_count}" != "1" ]]; then
        printf 'FAIL E01 probe config=%s/%s marker=%s/%s\n' \
            "${vit_e01_probe_config_count}" \
            "${vit_e01_probe_config_prefix_count}" \
            "${vit_e01_probe_count}" \
            "${vit_e01_probe_prefix_count}" >&2
        exit 1
    fi
    python3 - \
        "${vit_e01_run_log}" \
        "${vit_e01_probe_cycles}" \
        "${vit_e01_run_config_pattern}" <<'PY'
import re
import sys
from pathlib import Path

prefix = "VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP"
lines = Path(sys.argv[1]).read_text(
    encoding="utf-8", errors="replace"
).splitlines()
probe_hits = [
    (index, line)
    for index, line in enumerate(lines)
    if line.startswith(prefix + " ")
]
config_pattern = re.compile(sys.argv[3])
config_hits = [
    index
    for index, line in enumerate(lines)
    if config_pattern.fullmatch(line)
]
if len(probe_hits) != 1 or len(config_hits) != 1:
    raise SystemExit(
        "FAIL E01 probe/config markers are not unique"
    )
if config_hits[0] >= probe_hits[0][0]:
    raise SystemExit("FAIL E01 probe marker precedes run configuration")
cycle_match = re.search(
    r"(?:^| )cycles=([0-9]+)(?: |$)", probe_hits[0][1]
)
if cycle_match is None:
    raise SystemExit("FAIL E01 probe marker has no canonical cycle count")
reported = int(cycle_match.group(1), 10)
configured = int(sys.argv[2], 10)
if reported not in {configured - 1, configured, configured + 1}:
    raise SystemExit(
        "FAIL E01 probe stopped at an unrelated cycle: "
        f"configured={configured} reported={reported}"
    )
PY
    if grep -Eq '^VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_PASS ' \
        "${vit_e01_run_log}"; then
        printf '%s\n' 'FAIL E01 probe contains terminal E2E PASS' >&2
        exit 1
    fi
    set +e
    printf '%s\n' \
        "VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_VERIFIED asset_set_sha256=${vit_e01_asset_set_sha256} ${vit_e01_design_pre} ${vit_e01_verification_pre}" |
        tee -a "${vit_e01_run_log}"
    vit_e01_probe_log_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e01_probe_log_status[0]}" != "0" ]] ||
       [[ "${vit_e01_probe_log_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E01 probe log pipeline' >&2
        exit 1
    fi
    # Diagnostic only: no receipt and no active sidecar update.
    exit 0
fi

vit_e01_traffic_pattern='^E01_REAL_AXI_TRAFFIC actual_total_r=15350784 expected_total_r=15350784 actual_total_w=453120 expected_total_w=453120 model_r=14898432 expected_model_r=14898432 input_r=150528 expected_input_r=150528 scratch_r=301824 expected_scratch_r=301824 scratch_w=453120 invalid=0$'
vit_e01_numeric_pattern='^E01_REAL_AXI_NUMERIC words=151296 exact_mismatch=[0-9]+ tolerance_failures=0 max_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ mean_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ max_index=[0-9]+ rtl=[0-9a-fA-F]{8} golden=[0-9a-fA-F]{8} tolerance=5\.000000000e-04 hidden_b_modified=0$'
vit_e01_terminal_pattern='^VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_PASS checks=[1-9][0-9]* cycles=[1-9][0-9]* commands=4 reads=15350784 writes=453120 max_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ mean_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+$'

python3 - \
    "${vit_e01_run_log}" \
    "${vit_e01_run_config_pattern}" \
    "${vit_e01_traffic_pattern}" \
    "${vit_e01_numeric_pattern}" \
    "${vit_e01_terminal_pattern}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
patterns = [re.compile(value) for value in sys.argv[2:]]
lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
positions = []
for pattern in patterns:
    hits = [index for index, line in enumerate(lines) if pattern.fullmatch(line)]
    if len(hits) != 1:
        raise SystemExit(
            f"FAIL E01 exact marker {pattern.pattern!r} count={len(hits)}"
        )
    positions.append(hits[0])
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit("FAIL E01 exact terminal markers are out of order")
prefixes = (
    "E01_REAL_AXI_RUN_CONFIG",
    "E01_REAL_AXI_TRAFFIC",
    "E01_REAL_AXI_NUMERIC",
    "VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_PASS",
)
for prefix in prefixes:
    count = sum(
        line == prefix or line.startswith(prefix + " ") for line in lines
    )
    if count != 1:
        raise SystemExit(
            f"FAIL E01 marker prefix {prefix!r} count={count}"
        )
if any(
    line == "VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP"
    or line.startswith("VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP ")
    for line in lines
):
    raise SystemExit("FAIL E01 full log contains a probe marker")
PY

# Freeze the last authority marker before creating the adjacent receipt.
set +e
printf '%s\n' \
    "VIT_PHASE_E_AXI_E01_REAL_RTL_TERMINAL_E2E_VERIFIED asset_set_sha256=${vit_e01_asset_set_sha256}" |
    tee -a "${vit_e01_run_log}"
vit_e01_terminal_log_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e01_terminal_log_status[0]}" != "0" ]] ||
   [[ "${vit_e01_terminal_log_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E01 terminal-log pipeline' >&2
    exit 1
fi

vit_e01_receipt_output="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --create-receipt \
        --receipt-evidence-key e01_real_axi \
        --receipt-log "${vit_e01_run_log}" \
        --receipt-run-id "${vit_e01_run_id}" \
        --receipt-exit-code 0 \
        --receipt-tool-name verilator \
        --receipt-tool-version "${vit_e01_verilator_version}" \
        --receipt-command-argv-json "${vit_e01_command_argv_json}" \
        --receipt-configuration-json "${vit_e01_configuration_json}" \
        --receipt-cflags-json "${vit_e01_cflags_json}" \
        --receipt-command-sha256 "${vit_e01_command_sha256}" \
        --receipt-asset-set-sha256 "${vit_e01_asset_set_sha256}"
)"
vit_e01_expected_receipt="PASS verification receipt: ${vit_e01_receipt_path}"
if [[ "${vit_e01_receipt_output}" != "${vit_e01_expected_receipt}" ]] ||
   [[ ! -s "${vit_e01_receipt_path}" ]]; then
    printf '%s\n' 'FAIL E01 receipt creation/validation' >&2
    exit 1
fi
printf '%s\n' "${vit_e01_receipt_output}"
chmod 0444 "${vit_e01_run_log}" "${vit_e01_receipt_path}"

python3 - \
    "${vit_e01_sidecar}" \
    "${vit_e01_run_id}" \
    "${vit_e01_run_log}" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

sidecar = Path(sys.argv[1])
if sidecar.is_symlink():
    raise SystemExit("ERROR: refusing to replace symlink E01 sidecar")
payload = {
    "schema": "vit-evidence-log-selection-v1",
    "evidence_key": "e01_real_axi",
    "run_id": sys.argv[2],
    "log_path": sys.argv[3],
}
sidecar.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(
    prefix=f".{sidecar.name}.", suffix=".tmp", dir=sidecar.parent
)
try:
    os.fchmod(descriptor, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        descriptor = -1
        stream.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, sidecar)
    directory = os.open(sidecar.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if descriptor >= 0:
        os.close(descriptor)
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
printf 'E01_ACTIVE_LOG_UPDATED run_id=%s log=%s sidecar=%s\n' \
    "${vit_e01_run_id}" "${vit_e01_run_log}" "${vit_e01_sidecar}"
