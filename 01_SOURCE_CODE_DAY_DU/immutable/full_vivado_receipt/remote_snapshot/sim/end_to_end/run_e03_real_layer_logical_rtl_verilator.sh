#!/usr/bin/env bash
set -euo pipefail

# Production-RTL E03 single-layer runner. A bounded probe proves startup,
# all twenty descriptors and logical-memory protocol activity, but it is never
# accepted as terminal numerical evidence. A full PASS is authoritative only
# after exact marker, asset, design and verification-identity checks and receipt
# creation. The evidence-v3 receipt schema currently supports layer 1 only.
vit_e03_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_e03_root}"

for vit_e03_tool in \
    verilator timeout nice tee python3 grep sed date mktemp mkdir dirname rm; do
    if ! command -v "${vit_e03_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_e03_tool}"
        exit 1
    fi
done

if (($# != 0)); then
    printf '%s\n' \
        'ERROR: do not pass a positional layer index.' \
        'Use exactly one VIT_E03_LAYER=<1..11> environment setting.'
    exit 1
fi

vit_e03_is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

vit_e03_layer="${VIT_E03_LAYER:-}"
if ! [[ "${vit_e03_layer}" =~ ^([1-9]|1[01])$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E03_LAYER is required and must be an integer from 1 to 11'
    exit 1
fi
vit_e03_layer_padded="$(printf '%02d' "${vit_e03_layer}")"

vit_e03_nice="${VIT_E03_LOGICAL_NICE:-15}"
if ! [[ "${vit_e03_nice}" =~ ^([0-9]|1[0-9])$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E03_LOGICAL_NICE must be an integer from 0 to 19'
    exit 1
fi

vit_e03_build_only="${VIT_E03_LOGICAL_BUILD_ONLY:-0}"
if ! [[ "${vit_e03_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E03_LOGICAL_BUILD_ONLY must be exactly 0 or 1'
    exit 1
fi

vit_e03_probe_cycles="${VIT_E03_LOGICAL_PROBE_CYCLES:-0}"
if ! [[ "${vit_e03_probe_cycles}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
        'ERROR: VIT_E03_LOGICAL_PROBE_CYCLES must be a non-negative integer'
    exit 1
fi
if [[ "${vit_e03_build_only}" == "1" ]] &&
   ((10#${vit_e03_probe_cycles} != 0)); then
    printf '%s\n' \
        'ERROR: BUILD_ONLY and a nonzero probe cycle limit are mutually exclusive'
    exit 1
fi

vit_e03_progress_cycles="${VIT_E03_LOGICAL_PROGRESS_CYCLES:-50000000}"
vit_e03_progress_transactions="${VIT_E03_LOGICAL_PROGRESS_TRANSACTIONS:-10000000}"
vit_e03_build_timeout="${VIT_E03_LOGICAL_BUILD_TIMEOUT_SECONDS:-1200}"
vit_e03_run_timeout="${VIT_E03_LOGICAL_RUN_TIMEOUT_SECONDS:-18000}"
for vit_e03_numeric_setting in \
    "${vit_e03_progress_cycles}" \
    "${vit_e03_progress_transactions}" \
    "${vit_e03_build_timeout}" \
    "${vit_e03_run_timeout}"; do
    if ! vit_e03_is_positive_integer "${vit_e03_numeric_setting}"; then
        printf '%s\n' \
            'ERROR: progress intervals and build/run timeouts must be positive integers'
        exit 1
    fi
done

vit_e03_cflags="${VIT_E03_CFLAGS:-${VIT_VERILATOR_CFLAGS:--O3}}"
if [[ -z "${vit_e03_cflags}" ]]; then
    printf '%s\n' 'ERROR: VIT_E03_CFLAGS must not be empty'
    exit 1
fi

vit_e03_run_id="${VIT_E03_EVIDENCE_RUN_ID:-e03-l${vit_e03_layer_padded}-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[
    "${vit_e03_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
]]; then
    printf '%s\n' \
        'ERROR: VIT_E03_EVIDENCE_RUN_ID has an invalid evidence-ID format'
    exit 1
fi

vit_e03_mode="full"
if [[ "${vit_e03_build_only}" == "1" ]]; then
    vit_e03_mode="build_only"
elif ((10#${vit_e03_probe_cycles} > 0)); then
    vit_e03_mode="probe"
fi
vit_e03_evidence_key=""
vit_e03_selection_sidecar=""
if [[ "${vit_e03_layer}" == "1" ]]; then
    if [[ "${vit_e03_mode}" == "probe" ]]; then
        vit_e03_evidence_key="e03_layer1_real_logical_probe"
        if [[ -n "${VIT_E03_LOGICAL_PROBE_SIDECAR+x}" ]]; then
            vit_e03_selection_sidecar="${VIT_E03_LOGICAL_PROBE_SIDECAR}"
        else
            vit_e03_selection_sidecar="build/test_logs/vit_e03_layer01_real_logical_rtl_probe.active.json"
        fi
    elif [[ "${vit_e03_mode}" == "full" ]]; then
        vit_e03_evidence_key="e03_layer1_real_logical_full"
        if [[ -n "${VIT_E03_LOGICAL_FULL_SIDECAR+x}" ]]; then
            vit_e03_selection_sidecar="${VIT_E03_LOGICAL_FULL_SIDECAR}"
        else
            vit_e03_selection_sidecar="build/test_logs/vit_e03_layer01_real_logical_rtl_e2e.active.json"
        fi
    fi
fi

# Defaults are unique and mode-specific. In particular, neither a probe nor a
# new full run silently overwrites the historical canonical E03 evidence paths.
if [[ -n "${VIT_E03_LOGICAL_LOG+x}" ]]; then
    vit_e03_run_log="${VIT_E03_LOGICAL_LOG}"
else
    vit_e03_run_log="build/test_logs/vit_e03_layer${vit_e03_layer_padded}_real_logical_rtl_${vit_e03_mode}_${vit_e03_run_id}.log"
fi
if [[ -n "${VIT_E03_LOGICAL_BUILD_LOG+x}" ]]; then
    vit_e03_build_log="${VIT_E03_LOGICAL_BUILD_LOG}"
else
    vit_e03_build_log="build/test_logs/vit_e03_layer${vit_e03_layer_padded}_real_logical_rtl_${vit_e03_mode}_${vit_e03_run_id}.build.log"
fi
vit_e03_receipt_path="${vit_e03_run_log}.receipt.json"

# Refuse absolute/traversing paths and any existing symlink component before
# tee/mkdir can touch a log. Existing outputs are also rejected: a receipt-bound
# log is immutable, and an accidental run-ID collision must never overwrite it.
python3 - \
    "${vit_e03_root}" \
    "${vit_e03_run_log}" \
    "${vit_e03_build_log}" \
    "${vit_e03_receipt_path}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
values = sys.argv[2:]
if len(set(values)) != len(values):
    raise SystemExit("ERROR: E03 run/build/receipt output paths must be distinct")
for value in values:
    relative = Path(value)
    if (
        not value
        or relative.is_absolute()
        or relative.as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise SystemExit(
            f"ERROR: E03 output path must be normalized repository-relative: {value!r}"
        )
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(
                f"ERROR: E03 output path contains symlink component: {value}"
            )
        if not current.exists():
            break
    try:
        (root / relative).resolve(strict=False).relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"ERROR: E03 output path escapes repository root: {value}"
        ) from exc
    if (root / relative).exists():
        raise SystemExit(
            f"ERROR: refusing to overwrite existing E03 output: {value}"
        )
PY

if [[ -n "${vit_e03_selection_sidecar}" ]]; then
    python3 - \
        "${vit_e03_root}" \
        "${vit_e03_selection_sidecar}" \
        "${vit_e03_run_log}" \
        "${vit_e03_build_log}" \
        "${vit_e03_receipt_path}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
sidecar_value = sys.argv[2]
other_values = sys.argv[3:]
relative = Path(sidecar_value)
if (
    not sidecar_value
    or relative.is_absolute()
    or relative.as_posix() != sidecar_value
    or any(part in {"", ".", ".."} for part in relative.parts)
):
    raise SystemExit(
        "ERROR: E03 selection sidecar must be normalized repository-relative"
    )
if sidecar_value in other_values:
    raise SystemExit("ERROR: E03 selection sidecar must be distinct from logs")
current = root
for part in relative.parts:
    current = current / part
    if current.is_symlink():
        raise SystemExit(
            "ERROR: E03 selection sidecar contains a symlink component"
        )
    if not current.exists():
        break
try:
    (root / relative).resolve(strict=False).relative_to(root)
except (OSError, ValueError) as exc:
    raise SystemExit("ERROR: E03 selection sidecar escapes repository") from exc
if (root / relative).exists() and not (root / relative).is_file():
    raise SystemExit("ERROR: E03 selection sidecar is not a regular file")
PY
fi

mkdir -p \
    "$(dirname "${vit_e03_run_log}")" \
    "$(dirname "${vit_e03_build_log}")"
if [[ -n "${vit_e03_selection_sidecar}" ]]; then
    mkdir -p "$(dirname "${vit_e03_selection_sidecar}")"
fi

vit_e03_design_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-design-sha256
)"
vit_e03_verification_pre="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-verification-sha256
)"
if ! [[ "${vit_e03_design_pre}" =~ ^DESIGN_SHA256=[0-9a-f]{64}$ ]]; then
    printf 'ERROR: malformed design identity: %s\n' "${vit_e03_design_pre}"
    exit 1
fi
if ! [[
    "${vit_e03_verification_pre}" =~ ^VERIFICATION_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed verification identity: %s\n' \
        "${vit_e03_verification_pre}"
    exit 1
fi

# Receipt authority requires these to be exactly the first three non-empty
# lines. tee without -a deliberately starts a fresh, unique run log.
set +e
printf '%s\n' \
    "VIT_EVIDENCE_RUN_ID=${vit_e03_run_id}" \
    "${vit_e03_design_pre}" \
    "${vit_e03_verification_pre}" |
    tee "${vit_e03_run_log}"
vit_e03_provenance_pipe_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e03_provenance_pipe_status[0]}" != "0" ]] ||
   [[ "${vit_e03_provenance_pipe_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E03 provenance-log pipeline'
    exit 1
fi

vit_e03_tmp="$(mktemp -d /tmp/vit_e03_real_layer_logical.XXXXXX)"
trap 'rm -rf -- "${vit_e03_tmp}"' EXIT
vit_e03_asset_pre_log="${vit_e03_tmp}/asset-pre.log"
vit_e03_asset_post_log="${vit_e03_tmp}/asset-post.log"

set +e
nice -n "${vit_e03_nice}" \
    python3 sim/end_to_end/validate_e03_real_assets.py \
        --layer "${vit_e03_layer}" \
    2>&1 | tee "${vit_e03_asset_pre_log}" | tee -a "${vit_e03_run_log}"
vit_e03_asset_pipe_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e03_asset_pipe_status[0]}" != "0" ]] ||
   [[ "${vit_e03_asset_pipe_status[1]}" != "0" ]] ||
   [[ "${vit_e03_asset_pipe_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E03 immutable-asset validation before build'
    exit 1
fi

vit_e03_asset_marker_pattern="^E03_ASSET_VALIDATION_PASS layer=${vit_e03_layer} parameters=16 parameter_words=7087872 checkpoints=2 checkpoint_words=302592 model_table_sha256=bdcee496df4036b4b49a7b69f37751f10d1ef112d6529bc09bb260cfc2bac038 baseline_manifest_sha256=d0d7cadd558a0d7434cc1dfe8efe8452624f8aafa2450a5e3733ce45db68393b asset_set_sha256=[0-9a-f]{64}$"
vit_e03_asset_marker_count="$(
    grep -Ec "${vit_e03_asset_marker_pattern}" "${vit_e03_asset_pre_log}" || true
)"
vit_e03_asset_prefix_count="$(
    grep -Ec '^E03_ASSET_VALIDATION_PASS([[:space:]]|$)' \
        "${vit_e03_asset_pre_log}" || true
)"
if [[ "${vit_e03_asset_marker_count}" != "1" ]] ||
   [[ "${vit_e03_asset_prefix_count}" != "1" ]]; then
    printf '%s\n' \
        "FAIL E03 asset validation: exact=${vit_e03_asset_marker_count} prefix=${vit_e03_asset_prefix_count}"
    exit 1
fi
vit_e03_asset_marker="$(
    grep -E "${vit_e03_asset_marker_pattern}" "${vit_e03_asset_pre_log}"
)"
vit_e03_asset_set_sha256="$(
    sed -n \
        's/.* asset_set_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
        "${vit_e03_asset_pre_log}"
)"
if ! [[ "${vit_e03_asset_set_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'FAIL E03 asset validation: malformed asset-set identity'
    exit 1
fi

vit_e03_obj_dir="${vit_e03_tmp}/obj"
vit_e03_binary="vit_e03_real_layer_logical_rtl_e2e"
vit_e03_verilator_version="$(verilator --version)"
printf '%s\n' \
    "E03_VERILATOR_VERSION=${vit_e03_verilator_version}" \
    "E03_BUILD_CONFIG layer=${vit_e03_layer} nice=${vit_e03_nice} cflags=${vit_e03_cflags} build_timeout_seconds=${vit_e03_build_timeout}" \
    | tee -a "${vit_e03_run_log}"

printf '%s\n' \
    "BUILD production full-dimension E03 real layer-${vit_e03_layer_padded} logical-memory test"
set +e
timeout "${vit_e03_build_timeout}s" \
    nice -n "${vit_e03_nice}" \
    verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_npu_e03_real_layer_rtl \
        --Mdir "${vit_e03_obj_dir}" \
        -j 1 \
        -CFLAGS "${vit_e03_cflags}" \
        -f sim/end_to_end/vit_phase_e_npu_e03_real_layer_rtl_verilator.f \
        -o "${vit_e03_binary}" \
        2>&1 | tee "${vit_e03_build_log}" | tee -a "${vit_e03_run_log}"
vit_e03_build_pipe_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_e03_build_pipe_status[1]}" != "0" ]] ||
   [[ "${vit_e03_build_pipe_status[2]}" != "0" ]]; then
    printf '%s\n' 'FAIL E03 build-log pipeline'
    exit 1
fi
if [[ "${vit_e03_build_pipe_status[0]}" != "0" ]]; then
    printf 'FAIL E03 production build: status=%s\n' \
        "${vit_e03_build_pipe_status[0]}"
    exit "${vit_e03_build_pipe_status[0]}"
fi

vit_e03_verify_post_state() {
    local vit_e03_design_post
    local vit_e03_verification_post
    local vit_e03_post_marker
    local vit_e03_post_marker_count
    local vit_e03_post_prefix_count
    local -a vit_e03_post_pipe_status

    set +e
    nice -n "${vit_e03_nice}" \
        python3 sim/end_to_end/validate_e03_real_assets.py \
            --layer "${vit_e03_layer}" \
        2>&1 | tee "${vit_e03_asset_post_log}"
    vit_e03_post_pipe_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_e03_post_pipe_status[0]}" != "0" ]] ||
       [[ "${vit_e03_post_pipe_status[1]}" != "0" ]]; then
        printf '%s\n' 'FAIL E03 immutable-asset validation after execution'
        return 1
    fi
    vit_e03_post_marker_count="$(
        grep -Ec \
            "${vit_e03_asset_marker_pattern}" \
            "${vit_e03_asset_post_log}" || true
    )"
    vit_e03_post_prefix_count="$(
        grep -Ec '^E03_ASSET_VALIDATION_PASS([[:space:]]|$)' \
            "${vit_e03_asset_post_log}" || true
    )"
    if [[ "${vit_e03_post_marker_count}" != "1" ]] ||
       [[ "${vit_e03_post_prefix_count}" != "1" ]]; then
        printf '%s\n' \
            'FAIL E03 post-execution asset validation marker is not unique/exact'
        return 1
    fi
    vit_e03_post_marker="$(
        grep -E "${vit_e03_asset_marker_pattern}" "${vit_e03_asset_post_log}"
    )"
    if [[ "${vit_e03_post_marker}" != "${vit_e03_asset_marker}" ]]; then
        printf '%s\n' 'FAIL E03 immutable assets changed during execution'
        return 1
    fi

    vit_e03_design_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-design-sha256
    )"
    vit_e03_verification_post="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --emit-verification-sha256
    )"
    if [[ "${vit_e03_design_post}" != "${vit_e03_design_pre}" ]]; then
        printf '%s\n' 'FAIL E03 production design identity changed during run'
        return 1
    fi
    if [[
        "${vit_e03_verification_post}" != "${vit_e03_verification_pre}"
    ]]; then
        printf '%s\n' \
            'FAIL E03 verification identity changed during run'
        return 1
    fi
}

if [[ "${vit_e03_build_only}" == "1" ]]; then
    vit_e03_verify_post_state
    printf '%s\n' \
        "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_BUILD_ONLY_VERIFIED layer=${vit_e03_layer} asset_set_sha256=${vit_e03_asset_set_sha256} ${vit_e03_design_pre} ${vit_e03_verification_pre}" \
        | tee -a "${vit_e03_run_log}"
    exit 0
fi

vit_e03_sim_argv=(
    "${vit_e03_obj_dir}/${vit_e03_binary}"
    "+E03_ENCODER_LAYER=${vit_e03_layer}"
    "+E03_LOGICAL_PROGRESS_CYCLES=${vit_e03_progress_cycles}"
    "+E03_LOGICAL_PROGRESS_TRANSACTIONS=${vit_e03_progress_transactions}"
    "+E03_LOGICAL_PROBE_CYCLES=${vit_e03_probe_cycles}"
)
vit_e03_command_argv_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(sys.argv[1:], separators=(",",":")))' \
        "${vit_e03_sim_argv[@]}"
)"
vit_e03_configuration_json="$(
    python3 -c \
        'import json,sys; print(json.dumps(dict(x.split("=",1) for x in sys.argv[1:]), sort_keys=True, separators=(",",":")))' \
        "layer=${vit_e03_layer}" \
        "mode=${vit_e03_mode}" \
        "nice=${vit_e03_nice}" \
        "probe_cycles=${vit_e03_probe_cycles}" \
        "progress_cycles=${vit_e03_progress_cycles}" \
        "progress_transactions=${vit_e03_progress_transactions}" \
        "build_timeout_seconds=${vit_e03_build_timeout}" \
        "run_timeout_seconds=${vit_e03_run_timeout}"
)"
vit_e03_cflags_json="$(
    python3 -c \
        'import json,shlex,sys; print(json.dumps(shlex.split(sys.argv[1]), separators=(",",":")))' \
        "${vit_e03_cflags}"
)"
vit_e03_command_marker="$(
    python3 tools/generate_rtl_evidence_manifest.py \
        --emit-command-sha256 \
        --receipt-command-argv-json "${vit_e03_command_argv_json}" \
        --receipt-configuration-json "${vit_e03_configuration_json}" \
        --receipt-cflags-json "${vit_e03_cflags_json}"
)"
if ! [[
    "${vit_e03_command_marker}" =~ ^COMMAND_SHA256=[0-9a-f]{64}$
]]; then
    printf 'ERROR: malformed command identity: %s\n' \
        "${vit_e03_command_marker}"
    exit 1
fi
vit_e03_command_sha256="${vit_e03_command_marker#COMMAND_SHA256=}"

vit_e03_publish_selection_sidecar() {
    local vit_e03_publish_output
    local vit_e03_expected_publish_output

    if [[ -z "${vit_e03_selection_sidecar}" ]]; then
        return 0
    fi
    vit_e03_publish_output="$(
        python3 - \
            "${vit_e03_root}" \
            "${vit_e03_selection_sidecar}" \
            "${vit_e03_evidence_key}" \
            "${vit_e03_run_id}" \
            "${vit_e03_run_log}" \
            "${vit_e03_receipt_path}" <<'PY'
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
sidecar_value, evidence_key, run_id, log_value, receipt_value = sys.argv[2:]


def safe_relative(value: str, description: str) -> tuple[Path, Path]:
    relative = Path(value)
    if (
        not value
        or relative.is_absolute()
        or relative.as_posix() != value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise SystemExit(
            f"ERROR: {description} must be normalized repository-relative"
        )
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit(
                f"ERROR: {description} contains a symlink component"
            )
        if not current.exists():
            break
    candidate = root / relative
    try:
        candidate.resolve(strict=False).relative_to(root)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"ERROR: {description} escapes repository") from exc
    return relative, candidate


sidecar_relative, sidecar = safe_relative(
    sidecar_value,
    "E03 selection sidecar",
)
log_relative, log = safe_relative(log_value, "E03 selected log")
receipt_relative, receipt = safe_relative(
    receipt_value,
    "E03 selected receipt",
)
if receipt_relative.as_posix() != log_relative.as_posix() + ".receipt.json":
    raise SystemExit("ERROR: E03 receipt path is not adjacent to selected log")
if not log.is_file() or not receipt.is_file():
    raise SystemExit("ERROR: E03 selected log/receipt is missing")
log_snapshot = log.read_bytes()


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


try:
    receipt_payload = json.loads(
        receipt.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicate_keys,
    )
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
    raise SystemExit("ERROR: E03 selected receipt is unreadable") from exc
expected_receipt = {
    "schema": "vit-verification-receipt-v1",
    "evidence_key": evidence_key,
    "run_id": run_id,
    "log_path": log_relative.as_posix(),
    "log_size_bytes": len(log_snapshot),
    "log_sha256": hashlib.sha256(log_snapshot).hexdigest(),
}
if not isinstance(receipt_payload, dict) or any(
    receipt_payload.get(key) != value
    for key, value in expected_receipt.items()
):
    raise SystemExit(
        "ERROR: E03 receipt does not bind key/run-id/path/size/hash"
    )
os.chmod(log, 0o444)
os.chmod(receipt, 0o444)

payload = {
    "schema": "vit-evidence-log-selection-v1",
    "evidence_key": evidence_key,
    "run_id": run_id,
    "log_path": log_relative.as_posix(),
}
sidecar.parent.mkdir(parents=True, exist_ok=True)
if sidecar.is_symlink() or (sidecar.exists() and not sidecar.is_file()):
    raise SystemExit("ERROR: refusing unsafe E03 selection sidecar target")
descriptor = (
    json.dumps(payload, indent=2, sort_keys=True) + "\n"
).encode("utf-8")
file_descriptor, temporary_value = tempfile.mkstemp(
    prefix=f".{sidecar.name}.",
    suffix=".tmp",
    dir=sidecar.parent,
)
temporary = Path(temporary_value)
try:
    with os.fdopen(file_descriptor, "wb") as stream:
        stream.write(descriptor)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o644)
    if sidecar.is_symlink():
        raise SystemExit(
            "ERROR: E03 selection sidecar became a symlink before publish"
        )
    os.replace(temporary, sidecar)
    directory_descriptor = os.open(
        sidecar.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
finally:
    if temporary.exists():
        temporary.unlink()

print(f"PASS E03 selection sidecar: {sidecar_relative.as_posix()}")
PY
    )"
    vit_e03_expected_publish_output="$(
        printf 'PASS E03 selection sidecar: %s' \
            "${vit_e03_selection_sidecar}"
    )"
    if [[
        "${vit_e03_publish_output}" != "${vit_e03_expected_publish_output}"
    ]] || [[ ! -s "${vit_e03_selection_sidecar}" ]]; then
        printf '%s\n' \
            'FAIL E03 selection sidecar helper returned an unexpected result'
        return 1
    fi
    printf '%s\n' "${vit_e03_publish_output}"
}

vit_e03_create_receipt_if_supported() {
    local vit_e03_receipt_output
    local vit_e03_expected_receipt_output

    if [[ "${vit_e03_layer}" != "1" ]]; then
        printf '%s\n' \
            "E03_RECEIPT_SKIPPED layer=${vit_e03_layer} reason=evidence-v3-schema-supports-layer1-only"
        return 0
    fi
    if [[ -z "${vit_e03_evidence_key}" ]]; then
        printf '%s\n' 'FAIL E03 layer-1 evidence key was not configured'
        return 1
    fi
    if [[ -e "${vit_e03_receipt_path}" || -L "${vit_e03_receipt_path}" ]]; then
        printf '%s\n' \
            "FAIL E03 refusing to replace receipt: ${vit_e03_receipt_path}"
        return 1
    fi

    vit_e03_receipt_output="$(
        python3 tools/generate_rtl_evidence_manifest.py \
            --create-receipt \
            --receipt-evidence-key "${vit_e03_evidence_key}" \
            --receipt-log "${vit_e03_run_log}" \
            --receipt-run-id "${vit_e03_run_id}" \
            --receipt-exit-code 0 \
            --receipt-tool-name verilator \
            --receipt-tool-version "${vit_e03_verilator_version}" \
            --receipt-command-argv-json "${vit_e03_command_argv_json}" \
            --receipt-configuration-json "${vit_e03_configuration_json}" \
            --receipt-cflags-json "${vit_e03_cflags_json}" \
            --receipt-command-sha256 "${vit_e03_command_sha256}" \
            --receipt-asset-set-sha256 "${vit_e03_asset_set_sha256}"
    )"
    vit_e03_expected_receipt_output="PASS verification receipt: ${vit_e03_receipt_path}"
    if [[
        "${vit_e03_receipt_output}" != "${vit_e03_expected_receipt_output}"
    ]] || [[ ! -s "${vit_e03_receipt_path}" ]]; then
        printf '%s\n' \
            'FAIL E03 receipt helper returned an unexpected result or empty receipt'
        return 1
    fi
    # Deliberately do not append after this receipt freezes the run-log hash.
    printf '%s\n' "${vit_e03_receipt_output}"
    vit_e03_publish_selection_sidecar
}

printf '%s\n' \
    "${vit_e03_command_marker}" \
    "E03_RUN_CONFIG layer=${vit_e03_layer} mode=${vit_e03_mode} nice=${vit_e03_nice} timeout_seconds=${vit_e03_run_timeout} probe_cycles=${vit_e03_probe_cycles} progress_cycles=${vit_e03_progress_cycles} progress_transactions=${vit_e03_progress_transactions}" \
    | tee -a "${vit_e03_run_log}"
printf '%s\n' \
    "RUN production full-dimension E03 real layer-${vit_e03_layer_padded} mode=${vit_e03_mode}"

set +e
timeout "${vit_e03_run_timeout}s" \
    nice -n "${vit_e03_nice}" \
    "${vit_e03_sim_argv[@]}" \
    2>&1 | tee -a "${vit_e03_run_log}"
vit_e03_run_pipe_status=("${PIPESTATUS[@]}")
set -e
vit_e03_run_status="${vit_e03_run_pipe_status[0]}"
if [[ "${vit_e03_run_pipe_status[1]}" != "0" ]]; then
    printf '%s\n' 'FAIL E03 run-log pipeline'
    exit 1
fi

# Drift is checked even for a timeout or simulator failure so a long-run failure
# cannot be misattributed to files changing underneath it.
vit_e03_verify_post_state

if [[ "${vit_e03_run_status}" == "124" ]]; then
    printf '%s\n' \
        'INCOMPLETE: bounded timeout reached; this is neither PASS nor RTL failure.' \
        "Inspect ${vit_e03_run_log} and increase VIT_E03_LOGICAL_RUN_TIMEOUT_SECONDS."
    exit 124
fi
if [[ "${vit_e03_run_status}" != "0" ]]; then
    printf 'FAIL E03 simulator exited with status=%s\n' \
        "${vit_e03_run_status}"
    exit "${vit_e03_run_status}"
fi

vit_e03_severity_pattern='(^[[:space:]]*(FAIL|ERROR|FATAL)([[:space:]]|:)|^E03_ASSET_VALIDATION_FAIL([[:space:]]|:)|^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_(E2E_FAIL|PROBE_FAIL) |%Error([-:])|%Fatal([-:])|[Aa]ssertion[[:space:]].*[Ff]ail|[Aa]borted)'
if grep -Eq "${vit_e03_severity_pattern}" "${vit_e03_run_log}"; then
    printf '%s\n' \
        'FAIL E03 log contains an error/fatal/assertion severity marker'
    exit 1
fi

if ((10#${vit_e03_probe_cycles} > 0)); then
    vit_e03_probe_pattern="^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_PROBE_PASS layer=${vit_e03_layer} cycles=[1-9][0-9]* commands=[1-9][0-9]* checkpoints=[0-9]+ layer_requests=1 parameter_requests=[1-9][0-9]* reads=[1-9][0-9]* writes=[1-9][0-9]* parameter_reads=[1-9][0-9]* scratch_reads=[1-9][0-9]* requests=[1-9][0-9]* responses=[0-9]+ outstanding=[01] invalid=0 backpressure_cycles=[1-9][0-9]* checks=[1-9][0-9]* failures=0$"
    vit_e03_probe_markers="$(
        grep -Ec "${vit_e03_probe_pattern}" "${vit_e03_run_log}" || true
    )"
    vit_e03_probe_prefix_markers="$(
        grep -Ec \
            '^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_PROBE_PASS([[:space:]]|$)' \
            "${vit_e03_run_log}" || true
    )"
    if [[ "${vit_e03_probe_markers}" != "1" ]] ||
       [[ "${vit_e03_probe_prefix_markers}" != "1" ]]; then
        printf '%s\n' \
            "FAIL E03 layer-${vit_e03_layer_padded} probe: exact=${vit_e03_probe_markers} prefix=${vit_e03_probe_prefix_markers}"
        exit 1
    fi
    vit_e03_probe_line="$(
        grep -E "${vit_e03_probe_pattern}" "${vit_e03_run_log}"
    )"
    vit_e03_reported_probe_cycles="$(
        sed -n 's/.* cycles=\([0-9][0-9]*\) commands=.*/\1/p' \
            <<<"${vit_e03_probe_line}"
    )"
    vit_e03_previous_probe_cycle="$((10#${vit_e03_probe_cycles} - 1))"
    if [[
        "${vit_e03_reported_probe_cycles}" != "${vit_e03_probe_cycles}" &&
        "${vit_e03_reported_probe_cycles}" != "${vit_e03_previous_probe_cycle}"
    ]]; then
        printf '%s\n' \
            "FAIL E03 probe cycle mismatch: configured=${vit_e03_probe_cycles} reported=${vit_e03_reported_probe_cycles}"
        exit 1
    fi
    if grep -Eq \
        '^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_E2E_PASS([[:space:]]|$)' \
        "${vit_e03_run_log}"; then
        printf '%s\n' \
            "FAIL E03 layer-${vit_e03_layer_padded} probe: probe log must not claim terminal E2E_PASS"
        exit 1
    fi
    printf '%s\n' \
        "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_PROBE_VERIFIED layer=${vit_e03_layer} asset_set_sha256=${vit_e03_asset_set_sha256} ${vit_e03_design_pre} ${vit_e03_verification_pre}" \
        | tee -a "${vit_e03_run_log}"
    vit_e03_create_receipt_if_supported
    exit 0
fi

vit_e03_e2e_pattern="^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_E2E_PASS layer=${vit_e03_layer} checks=[1-9][0-9]* failures=0 cycles=[1-9][0-9]* commands=20 reads=737995740 writes=4876932 parameter_reads=701323008 scratch_reads=36672732 input_reads=0 invalid=0 requests=742872672 responses=742872672 outstanding=0 tolerance_failures=0 nonfinite=0 unknown=0 exact_mismatch=[0-9]+ max_abs=[-+0-9.]+[eE][-+][0-9]+ mean_abs=[-+0-9.]+[eE][-+][0-9]+$"
vit_e03_e2e_markers="$(
    grep -Ec "${vit_e03_e2e_pattern}" "${vit_e03_run_log}" || true
)"
vit_e03_e2e_prefix_markers="$(
    grep -Ec \
        '^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_E2E_PASS([[:space:]]|$)' \
        "${vit_e03_run_log}" || true
)"
if [[ "${vit_e03_e2e_markers}" != "1" ]] ||
   [[ "${vit_e03_e2e_prefix_markers}" != "1" ]]; then
    printf '%s\n' \
        "FAIL E03 layer-${vit_e03_layer_padded} full run: exact=${vit_e03_e2e_markers} prefix=${vit_e03_e2e_prefix_markers}"
    exit 1
fi
if grep -Eq \
    '^VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_(PROBE_PASS|PROBE_VERIFIED)([[:space:]]|$)' \
    "${vit_e03_run_log}"; then
    printf '%s\n' \
        "FAIL E03 layer-${vit_e03_layer_padded} full run: conflicting probe marker"
    exit 1
fi

# This is the last line appended before a supported receipt freezes the log.
printf '%s\n' \
    "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_TERMINAL_E2E_VERIFIED layer=${vit_e03_layer} asset_set_sha256=${vit_e03_asset_set_sha256}" \
    | tee -a "${vit_e03_run_log}"
vit_e03_create_receipt_if_supported
