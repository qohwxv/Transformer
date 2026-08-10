#!/usr/bin/env bash
set -euo pipefail

# Full-dimension production-RTL E04 through AXI-Lite + M_AXI.  A run becomes
# evidence only after immutable assets, source identities, exact terminal
# markers, simulator status and the adjacent receipt all agree.
vit_e04_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e04_root}"

for vit_e04_tool in \
    verilator timeout nice tee python3 grep sed date mktemp mkdir dirname rm \
    chmod; do
    if ! command -v "${vit_e04_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e04_tool}" >&2
        exit 1
    fi
done
if (($# != 0)); then
    printf '%s\n' \
        'ERROR: E04 runner accepts environment settings, not arguments' >&2
    exit 1
fi

vit_e04_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

vit_e04_nice="${VIT_AXI_E04_REAL_NICE:-15}"
if ! [[ "${vit_e04_nice}" =~ ^([0-9]|1[0-9])$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E04_REAL_NICE must be an integer from 0 to 19' >&2
    exit 1
fi
vit_e04_build_only="${VIT_AXI_E04_REAL_BUILD_ONLY:-0}"
if ! [[ "${vit_e04_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E04_REAL_BUILD_ONLY must be exactly 0 or 1' >&2
    exit 1
fi

vit_e04_build_timeout="${VIT_AXI_E04_REAL_BUILD_TIMEOUT_SECONDS:-900}"
vit_e04_run_timeout="${VIT_AXI_E04_REAL_RUN_TIMEOUT_SECONDS:-1800}"
for vit_e04_number in "${vit_e04_build_timeout}" "${vit_e04_run_timeout}"; do
    if ! vit_e04_positive_integer "${vit_e04_number}"; then
        printf '%s\n' \
            'ERROR: E04 build/run timeouts must be positive integers' >&2
        exit 1
    fi
done

vit_e04_cflags="${VIT_AXI_E04_REAL_CFLAGS:-${VIT_VERILATOR_CFLAGS:--O3}}"
if [[ -z "${vit_e04_cflags}" ]]; then
    printf '%s\n' 'ERROR: E04 Verilator CFLAGS must not be empty' >&2
    exit 1
fi

vit_e04_run_id="${VIT_AXI_E04_REAL_EVIDENCE_RUN_ID:-e04-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[
    "${vit_e04_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
]]; then
    printf '%s\n' \
        'ERROR: VIT_AXI_E04_REAL_EVIDENCE_RUN_ID is invalid' >&2
    exit 1
fi

vit_e04_mode="full"
if [[ "${vit_e04_build_only}" == "1" ]]; then
    vit_e04_mode="build_only"
fi
if [[ -n "${VIT_AXI_E04_REAL_LOG+x}" ]]; then
    vit_e04_run_log="${VIT_AXI_E04_REAL_LOG}"
else
    vit_e04_run_log="build/test_logs/vit_axi_e04_real_rtl_${vit_e04_mode}_${vit_e04_run_id}.log"
fi
if [[ -n "${VIT_AXI_E04_REAL_BUILD_LOG+x}" ]]; then
    vit_e04_build_log="${VIT_AXI_E04_REAL_BUILD_LOG}"
else
    vit_e04_build_log="build/test_logs/vit_axi_e04_real_rtl_${vit_e04_mode}_${vit_e04_run_id}.build.log"
fi
vit_e04_receipt_path="${vit_e04_run_log}.receipt.json"
vit_e04_sidecar="build/test_logs/vit_axi_e04_real_rtl_e2e.active.json"

# Logs and receipts are immutable per run.  The generic selection sidecar is
# the sole replaceable output and is updated atomically only after a receipt.
python3 - \
    "${vit_e04_root}" \
    "${vit_e04_run_log}" \
    "${vit_e04_build_log}" \
    "${vit_e04_receipt_path}" \
    "${vit_e04_sidecar}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
outputs = sys.argv[2:5]
sidecar_value = sys.argv[5]
values = outputs + [sidecar_value]
if len(set(values)) != len(values):
    raise SystemExit("ERROR: E04 output paths must be distinct")
for value in values:
    relative = Path(value)
    if (
        not value
        or relative.is_absolute()
        or relative.as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise SystemExit(
            f"ERROR: E04 output must be normalized repository-relative: {value!r}"
        )
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(
                f"ERROR: E04 output path contains symlink component: {value}"
            )
        if not current.exists():
            break
    try:
        (root / relative).resolve(strict=False).relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"ERROR: E04 output escapes repository root: {value}"
        ) from exc
for value in outputs:
    if (root / value).exists() or (root / value).is_symlink():
        raise SystemExit(
            f"ERROR: refusing to overwrite existing E04 output: {value}"
        )
sidecar = root / sidecar_value
if sidecar.exists() and not sidecar.is_file():
    raise SystemExit(
        f"ERROR: E04 selection sidecar is not a regular file: {sidecar_value}"
    )
PY

mkdir -p \
    "$(dirname "${vit_e04_run_log}")" \
    "$(dirname "${vit_e04_build_log}")"

vit_e04_design_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py --emit-design-sha256
)"
vit_e04_verification_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-verification-sha256
)"
if ! [[ "${vit_e04_design_pre}" =~ ^DESIGN_SHA256=[0-9a-f]{64}$ ]]; then
    printf 'ERROR: malformed E04 design identity: %s\n' \
        "${vit_e04_design_pre}" >&2
    exit 1
fi
if ! [[
    "${vit_e04_verification_pre}" =~ ^VERIFICATION_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed E04 verification identity: %s\n' \
        "${vit_e04_verification_pre}" >&2
    exit 1
fi

# Receipt authority requires these to be the first three non-empty lines.
set +e
printf '%s\n' \
    "VIT_EVIDENCE_RUN_ID=${vit_e04_run_id}" \
    "${vit_e04_design_pre}" \
    "${vit_e04_verification_pre}" |
    tee "${vit_e04_run_log}"
vit_e04_provenance_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_provenance_status[0]}" != "0" ]] ||
   [[ "${vit_e04_provenance_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 provenance-log pipeline' >&2
    exit 1
fi

vit_e04_tmp="$(mktemp -d /tmp/vit_axi_e04_real.XXXXXX)"
trap 'rm -rf -- "${vit_e04_tmp}"' EXIT
vit_e04_asset_pre_log="${vit_e04_tmp}/asset-pre.log"
vit_e04_asset_post_log="${vit_e04_tmp}/asset-post.log"

set +e
nice -n "${vit_e04_nice}" \
    python3 sim/end_to_end/validate_e01_e04_real_axi_assets.py \
        --phase e04 \
    2>&1 | tee "${vit_e04_asset_pre_log}" | tee -a "${vit_e04_run_log}"
vit_e04_asset_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_asset_status[0]}" != "0" ]] ||
   [[ "${vit_e04_asset_status[1]}" != "0" ]] ||
   [[ "${vit_e04_asset_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 immutable-asset validation before build' >&2
    exit 1
fi

vit_e04_asset_pattern='^E04_ASSET_VALIDATION_PASS files=8 parameter_words=770536 activation_words=151296 golden_words=153296 model_table_sha256=bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038 modelsim_manifest_sha256=d225e16ed2be3c3868c5d71c39860386e3180e0b82671ae4ddc47e9203cac45d modelsim_hash_list_sha256=d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b preprocess_manifest_sha256=08c001878e342779412f991653fe3899c9bc1753fdc9dbc0d893d6c315d735e7 asset_set_sha256=964fdd1a63d3c92be498316e7dcb20e2a2dc99664c9080fb492ffab50d257019$'
vit_e04_asset_count="$(
    grep -Ec "${vit_e04_asset_pattern}" "${vit_e04_asset_pre_log}" || true
)"
vit_e04_asset_prefix_count="$(
    grep -Ec '^E04_ASSET_VALIDATION_PASS([[:space:]]|$)' \
        "${vit_e04_asset_pre_log}" || true
)"
if [[ "${vit_e04_asset_count}" != "1" ]] ||
   [[ "${vit_e04_asset_prefix_count}" != "1" ]]; then
    printf 'FAIL E04 asset marker exact=%s prefix=%s\n' \
        "${vit_e04_asset_count}" "${vit_e04_asset_prefix_count}" >&2
    exit 1
fi
vit_e04_asset_marker="$(
    grep -E "${vit_e04_asset_pattern}" "${vit_e04_asset_pre_log}"
)"
vit_e04_asset_set_sha256="$(
    sed -n \
        's/.* asset_set_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
        "${vit_e04_asset_pre_log}"
)"
if [[
    "${vit_e04_asset_set_sha256}" != \
    "964fdd1a63d3c92be498316e7dcb20e2a2dc99664c9080fb492ffab50d257019"
]]; then
    printf '%s\n' 'FAIL E04 malformed/untrusted asset-set identity' >&2
    exit 1
fi

vit_e04_verify_post_state() {
    local vit_e04_design_post
    local vit_e04_verification_post
    local vit_e04_post_marker
    local vit_e04_post_count
    local vit_e04_post_prefix_count
    local -a vit_e04_post_status

    set +e
    nice -n "${vit_e04_nice}" \
        python3 sim/end_to_end/validate_e01_e04_real_axi_assets.py \
            --phase e04 \
        2>&1 | tee "${vit_e04_asset_post_log}"
    vit_e04_post_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e04_post_status[0]}" != "0" ]] ||
       [[ "${vit_e04_post_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E04 post-run immutable-asset validation' >&2
        return 1
    fi
    vit_e04_post_count="$(
        grep -Ec "${vit_e04_asset_pattern}" \
            "${vit_e04_asset_post_log}" || true
    )"
    vit_e04_post_prefix_count="$(
        grep -Ec '^E04_ASSET_VALIDATION_PASS([[:space:]]|$)' \
            "${vit_e04_asset_post_log}" || true
    )"
    if [[ "${vit_e04_post_count}" != "1" ]] ||
       [[ "${vit_e04_post_prefix_count}" != "1" ]]; then
        printf '%s\n' 'FAIL E04 post-run asset marker is not unique/exact' >&2
        return 1
    fi
    vit_e04_post_marker="$(
        grep -E "${vit_e04_asset_pattern}" "${vit_e04_asset_post_log}"
    )"
    if [[ "${vit_e04_post_marker}" != "${vit_e04_asset_marker}" ]]; then
        printf '%s\n' 'FAIL E04 immutable assets changed during run' >&2
        return 1
    fi
    vit_e04_design_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-design-sha256
    )"
    vit_e04_verification_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-verification-sha256
    )"
    if [[ "${vit_e04_design_post}" != "${vit_e04_design_pre}" ]]; then
        printf '%s\n' 'FAIL E04 design identity changed during run' >&2
        return 1
    fi
    if [[
        "${vit_e04_verification_post}" != "${vit_e04_verification_pre}"
    ]]; then
        printf '%s\n' 'FAIL E04 verification identity changed during run' >&2
        return 1
    fi
}

vit_e04_obj_dir="${vit_e04_tmp}/obj"
vit_e04_binary="vit_axi_e04_real_rtl_e2e"
vit_e04_verilator_version="$(verilator --version)"
set +e
printf '%s\n' \
    "E04_VERILATOR_VERSION=${vit_e04_verilator_version}" \
    "E04_BUILD_CONFIG mode=${vit_e04_mode} nice=${vit_e04_nice} cflags=${vit_e04_cflags} build_timeout_seconds=${vit_e04_build_timeout}" |
    tee -a "${vit_e04_run_log}"
vit_e04_config_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_config_status[0]}" != "0" ]] ||
   [[ "${vit_e04_config_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 build-config log pipeline' >&2
    exit 1
fi

printf '%s\n' \
    'BUILD production full-dimension E04 real-data AXI test (Verilator)'
set +e
timeout "${vit_e04_build_timeout}s" \
    nice -n "${vit_e04_nice}" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e04_real_rtl \
        --Mdir "${vit_e04_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e04_cflags}" \
        -f sim/end_to_end/vit_phase_e_axi_e04_real_rtl_verilator.f \
        -o "${vit_e04_binary}" \
        2>&1 | tee "${vit_e04_build_log}" | tee -a "${vit_e04_run_log}"
vit_e04_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_build_status[1]}" != "0" ]] ||
   [[ "${vit_e04_build_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 build-log pipeline' >&2
    exit 1
fi

# Re-hash assets and sources even when compilation failed.
vit_e04_verify_post_state
if [[ "${vit_e04_build_status[0]}" != "0" ]]; then
    printf 'FAIL E04 build status=%s\n' \
        "${vit_e04_build_status[0]}" >&2
    exit "${vit_e04_build_status[0]}"
fi

if [[ "${vit_e04_build_only}" == "1" ]]; then
    set +e
    printf '%s\n' \
        "VIT_PHASE_E_AXI_E04_REAL_RTL_BUILD_ONLY_VERIFIED asset_set_sha256=${vit_e04_asset_set_sha256} ${vit_e04_design_pre} ${vit_e04_verification_pre}" |
        tee -a "${vit_e04_run_log}"
    vit_e04_build_only_log_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e04_build_only_log_status[0]}" != "0" ]] ||
       [[ "${vit_e04_build_only_log_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E04 build-only log pipeline' >&2
        exit 1
    fi
    exit 0
fi

vit_e04_sim_argv=("${vit_e04_obj_dir}/${vit_e04_binary}")
vit_e04_command_argv_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(sys.argv[1:],separators=(",",":")))' \
        "${vit_e04_sim_argv[@]}"
)"
vit_e04_configuration_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(dict(x.split("=",1) for x in sys.argv[1:]),sort_keys=True,separators=(",",":")))' \
        "mode=${vit_e04_mode}" \
        "nice=${vit_e04_nice}" \
        "build_timeout_seconds=${vit_e04_build_timeout}" \
        "run_timeout_seconds=${vit_e04_run_timeout}"
)"
vit_e04_cflags_json="$(
    python3 -c \
        'import json,shlex,sys; print(json.dumps(shlex.split(sys.argv[1]),separators=(",",":")))' \
        "${vit_e04_cflags}"
)"
vit_e04_command_marker="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-command-sha256 \
        --receipt-command-argv-json "${vit_e04_command_argv_json}" \
        --receipt-configuration-json "${vit_e04_configuration_json}" \
        --receipt-cflags-json "${vit_e04_cflags_json}"
)"
if ! [[
    "${vit_e04_command_marker}" =~ ^COMMAND_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed E04 command identity: %s\n' \
        "${vit_e04_command_marker}" >&2
    exit 1
fi
vit_e04_command_sha256="${vit_e04_command_marker#COMMAND_SHA256=}"

set +e
printf '%s\n' \
    "${vit_e04_command_marker}" \
    "E04_RUNNER_CONFIG mode=${vit_e04_mode} nice=${vit_e04_nice} timeout_seconds=${vit_e04_run_timeout}" |
    tee -a "${vit_e04_run_log}"
vit_e04_run_config_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_run_config_status[0]}" != "0" ]] ||
   [[ "${vit_e04_run_config_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 run-config log pipeline' >&2
    exit 1
fi
printf '%s\n' 'RUN production full-dimension E04 real AXI'

set +e
timeout "${vit_e04_run_timeout}s" \
    nice -n "${vit_e04_nice}" \
    "${vit_e04_sim_argv[@]}" \
    2>&1 | tee -a "${vit_e04_run_log}"
vit_e04_run_statuses=("${PIPESTATUS[@]}")
set -e
vit_e04_run_status="${vit_e04_run_statuses[0]}"
if [[ "${vit_e04_run_statuses[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 run-log pipeline' >&2
    exit 1
fi

# Attribute timeout/failure against an unchanged source and asset state.
vit_e04_verify_post_state

if [[ "${vit_e04_run_status}" == "124" ]]; then
    printf '%s\n' \
        'INCOMPLETE: E04 bounded timeout; neither PASS nor RTL failure.' \
        "Inspect ${vit_e04_run_log} and increase VIT_AXI_E04_REAL_RUN_TIMEOUT_SECONDS."
    exit 124
fi
if [[ "${vit_e04_run_status}" != "0" ]]; then
    printf 'FAIL E04 simulator status=%s\n' \
        "${vit_e04_run_status}" >&2
    exit "${vit_e04_run_status}"
fi

vit_e04_severity_pattern='(^[[:space:]]*(FAIL|ERROR|FATAL)([[:space:]]|:)|^E04_ASSET_VALIDATION_FAIL([[:space:]]|:)|^VIT_PHASE_E_AXI_E04_REAL_RTL_E2E_FAIL([[:space:]]|$)|%Error([-:])|%Fatal([-:])|E04 REAL AXI CHECK FAILED|E04 real-data AXI watchdog timeout|[Aa]ssertion[[:space:]].*[Ff]ail)'
if grep -Eq "${vit_e04_severity_pattern}" "${vit_e04_run_log}"; then
    printf '%s\n' 'FAIL E04 log contains a severity marker' >&2
    exit 1
fi

vit_e04_logit_pattern='^E04_REAL_AXI_LOGIT rtl_word=414887b9 golden_word=414887b7 raw_word_delta=2 rtl=[-+]?[0-9]+\.[0-9]+ golden=[-+]?[0-9]+\.[0-9]+ numeric_delta=[-+]?[0-9]+\.[0-9]+$'
vit_e04_numeric_pattern='^E04_REAL_AXI_NUMERIC final_ln_exact_mismatch=[0-9]+ final_ln_max_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ final_ln_max_index=[0-9]+ logits_exact_mismatch=[0-9]+ logits_max_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ logits_max_index=[0-9]+ probabilities_exact_mismatch=[0-9]+ probabilities_max_abs=[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+ probabilities_max_index=[0-9]+$'
vit_e04_terminal_pattern='^VIT_PHASE_E_AXI_E04_REAL_RTL_E2E_PASS checks=[1-9][0-9]* cycles=[1-9][0-9]* commands=5 reads=1531016 writes=154064 model_reads=1071592 scratch_reads=459424 class=879 logit=414887b9 golden=414887b7 raw_delta=2$'

python3 - \
    "${vit_e04_run_log}" \
    "${vit_e04_logit_pattern}" \
    "${vit_e04_numeric_pattern}" \
    "${vit_e04_terminal_pattern}" <<'PY'
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
            f"FAIL E04 exact marker {pattern.pattern!r} count={len(hits)}"
        )
    positions.append(hits[0])
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit("FAIL E04 exact terminal markers are out of order")
prefixes = (
    "E04_REAL_AXI_LOGIT",
    "E04_REAL_AXI_NUMERIC",
    "VIT_PHASE_E_AXI_E04_REAL_RTL_E2E_PASS",
)
for prefix in prefixes:
    count = sum(
        line == prefix or line.startswith(prefix + " ") for line in lines
    )
    if count != 1:
        raise SystemExit(
            f"FAIL E04 marker prefix {prefix!r} count={count}"
        )
PY

# Freeze the last authority marker before creating the adjacent receipt.
set +e
printf '%s\n' \
    "VIT_PHASE_E_AXI_E04_REAL_RTL_TERMINAL_E2E_VERIFIED asset_set_sha256=${vit_e04_asset_set_sha256}" |
    tee -a "${vit_e04_run_log}"
vit_e04_terminal_log_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e04_terminal_log_status[0]}" != "0" ]] ||
   [[ "${vit_e04_terminal_log_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E04 terminal-log pipeline' >&2
    exit 1
fi

vit_e04_receipt_output="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --create-receipt \
        --receipt-evidence-key e04_real_axi \
        --receipt-log "${vit_e04_run_log}" \
        --receipt-run-id "${vit_e04_run_id}" \
        --receipt-exit-code 0 \
        --receipt-tool-name verilator \
        --receipt-tool-version "${vit_e04_verilator_version}" \
        --receipt-command-argv-json "${vit_e04_command_argv_json}" \
        --receipt-configuration-json "${vit_e04_configuration_json}" \
        --receipt-cflags-json "${vit_e04_cflags_json}" \
        --receipt-command-sha256 "${vit_e04_command_sha256}" \
        --receipt-asset-set-sha256 "${vit_e04_asset_set_sha256}"
)"
vit_e04_expected_receipt="PASS verification receipt: ${vit_e04_receipt_path}"
if [[ "${vit_e04_receipt_output}" != "${vit_e04_expected_receipt}" ]] ||
   [[ ! -s "${vit_e04_receipt_path}" ]]; then
    printf '%s\n' 'FAIL E04 receipt creation/validation' >&2
    exit 1
fi
printf '%s\n' "${vit_e04_receipt_output}"
chmod 0444 "${vit_e04_run_log}" "${vit_e04_receipt_path}"

python3 - \
    "${vit_e04_sidecar}" \
    "${vit_e04_run_id}" \
    "${vit_e04_run_log}" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

sidecar = Path(sys.argv[1])
if sidecar.is_symlink():
    raise SystemExit("ERROR: refusing to replace symlink E04 sidecar")
payload = {
    "schema": "vit-evidence-log-selection-v1",
    "evidence_key": "e04_real_axi",
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
printf 'E04_ACTIVE_LOG_UPDATED run_id=%s log=%s sidecar=%s\n' \
    "${vit_e04_run_id}" "${vit_e04_run_log}" "${vit_e04_sidecar}"
