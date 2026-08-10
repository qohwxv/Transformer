#!/usr/bin/env bash
set -euo pipefail

# Sequential real E02/E03 package-v3 qualification.  This runner builds the
# common AXI-128 harness once, then executes each requested encoder layer.  In
# chain mode every layer after the first consumes the preceding M8 RTL dump,
# and the Python comparator requires the preceding PASS report to bind it.

vit_m8_encoder_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vit_m8_workspace_root="$(cd "${vit_m8_encoder_root}/.." && pwd)"
cd "${vit_m8_encoder_root}"

vit_m8_first_layer=""
vit_m8_last_layer=""
vit_m8_input_mode=""
while (($#)); do
    case "$1" in
        --first-layer)
            [[ $# -ge 2 ]] || { printf '%s\n' 'ERROR: --first-layer needs a value' >&2; exit 2; }
            vit_m8_first_layer="$2"
            shift 2
            ;;
        --last-layer)
            [[ $# -ge 2 ]] || { printf '%s\n' 'ERROR: --last-layer needs a value' >&2; exit 2; }
            vit_m8_last_layer="$2"
            shift 2
            ;;
        --input-mode)
            [[ $# -ge 2 ]] || { printf '%s\n' 'ERROR: --input-mode needs a value' >&2; exit 2; }
            vit_m8_input_mode="$2"
            shift 2
            ;;
        *)
            printf 'ERROR: unsupported M8 encoder runner argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

for vit_m8_value in "${vit_m8_first_layer}" "${vit_m8_last_layer}"; do
    [[ "${vit_m8_value}" =~ ^([0-9]|1[01])$ ]] || {
        printf '%s\n' 'ERROR: first/last layer must be decimal 0..11' >&2
        exit 2
    }
done
if ((vit_m8_first_layer > vit_m8_last_layer)); then
    printf '%s\n' 'ERROR: first layer must not exceed last layer' >&2
    exit 2
fi
if [[ "${vit_m8_input_mode}" != "independent" && "${vit_m8_input_mode}" != "chain" ]]; then
    printf '%s\n' 'ERROR: --input-mode must be independent or chain' >&2
    exit 2
fi
if [[ "${vit_m8_input_mode}" == chain &&
      "${vit_m8_first_layer}" != 0 && "${vit_m8_first_layer}" != 1 ]]; then
    printf '%s\n' 'ERROR: a continuous chain must begin at layer 0 or receipt-bound layer 1' >&2
    exit 2
fi

for vit_m8_tool in verilator timeout nice python3 tee grep mktemp mkdir date sha256sum find sort awk xargs; do
    command -v "${vit_m8_tool}" >/dev/null 2>&1 || {
        printf 'ERROR: required tool is missing: %s\n' "${vit_m8_tool}" >&2
        exit 2
    }
done

vit_m8_build_only="${VIT_M8_MODE3_ENCODER_BUILD_ONLY:-1}"
[[ "${vit_m8_build_only}" =~ ^[01]$ ]] || {
    printf '%s\n' 'ERROR: VIT_M8_MODE3_ENCODER_BUILD_ONLY must be 0 or 1' >&2
    exit 2
}
vit_m8_build_timeout="${VIT_M8_MODE3_ENCODER_BUILD_TIMEOUT_SECONDS:-3600}"
vit_m8_run_timeout="${VIT_M8_MODE3_ENCODER_RUN_TIMEOUT_SECONDS:-86400}"
for vit_m8_value in "${vit_m8_build_timeout}" "${vit_m8_run_timeout}"; do
    [[ "${vit_m8_value}" =~ ^[1-9][0-9]*$ ]] || {
        printf '%s\n' 'ERROR: build/run timeouts must be positive integers' >&2
        exit 2
    }
done
vit_m8_nice="${VIT_M8_MODE3_ENCODER_NICE:-15}"
[[ "${vit_m8_nice}" == 15 ]] || {
    printf '%s\n' 'ERROR: real encoder qualification requires nice level 15' >&2
    exit 2
}

# Avoid an accidental full-size run on the owner's RAM-limited laptop.  The
# threshold may only be lowered explicitly for a build-only diagnostic.
vit_m8_min_available_kib="${VIT_M8_MODE3_ENCODER_MIN_AVAILABLE_KIB:-16777216}"
[[ "${vit_m8_min_available_kib}" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' 'ERROR: minimum available KiB must be a positive integer' >&2
    exit 2
}
if [[ "${vit_m8_build_only}" == 0 ]] && ((vit_m8_min_available_kib < 16777216)); then
    printf '%s\n' 'ERROR: a full M8 encoder run cannot lower the 16 GiB RAM gate' >&2
    exit 2
fi
vit_m8_require_memory() {
    local vit_m8_resource_stage="$1"
    local vit_m8_available_kib
    local vit_m8_load_average
    vit_m8_available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    vit_m8_load_average="$(awk '{print $1 "," $2 "," $3}' /proc/loadavg)"
    if ((vit_m8_available_kib < vit_m8_min_available_kib)); then
        printf 'ERROR: stage=%s only %s KiB available; M8 encoder gate requires at least %s KiB\n' \
            "${vit_m8_resource_stage}" "${vit_m8_available_kib}" \
            "${vit_m8_min_available_kib}" >&2
        return 2
    fi
    printf 'M8_MODE3_ENCODER_RESOURCE_OK stage=%s available_kib=%s minimum_kib=%s loadavg=%s nice=15 jobs=1\n' \
        "${vit_m8_resource_stage}" "${vit_m8_available_kib}" \
        "${vit_m8_min_available_kib}" "${vit_m8_load_average}"
}
vit_m8_require_memory preflight

vit_m8_run_id="${VIT_M8_MODE3_ENCODER_RUN_ID:-m8-mode3-encoder-$((vit_m8_first_layer))-$((vit_m8_last_layer))-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "${vit_m8_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
    printf '%s\n' 'ERROR: invalid VIT_M8_MODE3_ENCODER_RUN_ID' >&2
    exit 2
}
vit_m8_default_output="${vit_m8_encoder_root}/build/test_logs/${vit_m8_run_id}"
vit_m8_output_root="${VIT_M8_MODE3_ENCODER_OUTPUT_DIR:-${vit_m8_default_output}}"

python3 - "${vit_m8_workspace_root}" "${vit_m8_output_root}" <<'PY'
import sys
from pathlib import Path

workspace = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2])
if not output.is_absolute():
    raise SystemExit("ERROR: M8 encoder output directory must be absolute")
try:
    output.resolve(strict=False).relative_to(workspace)
except (OSError, ValueError) as exc:
    raise SystemExit("ERROR: M8 encoder output must stay inside workspace") from exc
if output.exists() or output.is_symlink():
    raise SystemExit(f"ERROR: refusing existing M8 encoder output: {output}")
PY
mkdir -p "${vit_m8_output_root}/layers"

vit_m8_stager="${vit_m8_encoder_root}/sim/end_to_end/stage_m8_mode3_encoder_real_assets.py"
vit_m8_filelist="sim/end_to_end/vit_phase_e_axi_m8_mode3_encoder_real_rtl_verilator.f"
vit_m8_top="tb_vit_phase_e_axi_m8_mode3_encoder_real_rtl"
vit_m8_build_log="${vit_m8_output_root}/build.log"
vit_m8_source_before="${vit_m8_output_root}/SOURCE_STATE_BEFORE.txt"
vit_m8_source_after="${vit_m8_output_root}/SOURCE_STATE_AFTER.txt"
vit_m8_summary="${vit_m8_output_root}/summary.log"

vit_m8_source_state() {
    python3 - "${vit_m8_encoder_root}" <<'PY'
import hashlib
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve(strict=True)
def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

filelist = root / "filelists/full_axi.f"
sources = []
for raw in filelist.read_text(encoding="utf-8").splitlines():
    text = raw.split("#", 1)[0].strip()
    if not text:
        continue
    relative = PurePosixPath(text)
    if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != text:
        raise SystemExit(f"ERROR: unsafe production path: {text}")
    sources.append(text)
if len(sources) != 80 or len(set(sources)) != 80:
    raise SystemExit("ERROR: production closure is not exactly 80/80 unique")
records = []
for relative in sources:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"ERROR: missing/nonregular production source: {relative}")
    records.append(f"{digest(path)}  {relative}\n")
ordered = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
filelist_sha = digest(filelist)
if filelist_sha != "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524":
    raise SystemExit("ERROR: full_axi.f identity changed")
if ordered != "db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e":
    raise SystemExit("ERROR: M8 production ordered-source identity changed")
protected = {
    "sim/end_to_end/m7_mode3_real_assets.py": "f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed",
    "sim/end_to_end/stage_m7_mode3_real_assets.py": "53fa492911285ae1ae3e671f44cd35b280b143227a51388c7cfccec8eba952f9",
    "sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh": "0f376c03632d9fa5148b1939004d992ebecf4b88e71cd977ff0573b1c1ab98f6",
    "sim/end_to_end/tb_vit_phase_e_axi_e01_mode3_real_rtl.sv": "f4ab571dc7a0dcce158ba1a9448ae62220be95272e4127248ad0e4458b18bd2f",
    "sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f": "8ce965dabef7611c75e8f2e90179670711805e4a48563bb40ac2b82d8e2ce79a",
    "sim/end_to_end/run_e04_mode3_real_axi_rtl_verilator.sh": "74d7b8e5c737bbb9ef201a378e918eb23cadab9a6272adaed323025499c3ce9f",
    "sim/end_to_end/tb_vit_phase_e_axi_e04_mode3_real_rtl.sv": "56ef0ed5910f152ac4c00744b331eee1b261c01d2569c1a67d040134a4e4e1c6",
    "sim/end_to_end/vit_phase_e_axi_e04_mode3_real_rtl_verilator.f": "ac98cc5a49a53d0f6fb5834639af37d1655244f052564c8b339476d44343d4d6",
}
for relative, expected in protected.items():
    path = root / relative
    if not path.is_file() or path.is_symlink() or digest(path) != expected:
        raise SystemExit(f"ERROR: protected E01/E04 receipt file changed: {relative}")
support = {
    "sim/axi/vit_axi_ddr_model_128.sv": "40803b5e7e0407173859e4aad82f1563896fbe9c4f50c477e9607fe2f9f03613",
}
for relative, expected in support.items():
    path = root / relative
    if not path.is_file() or path.is_symlink() or digest(path) != expected:
        raise SystemExit(f"ERROR: pinned M8 simulation support changed: {relative}")
verification = (
    "sim/end_to_end/m8_mode3_encoder_real_assets.py",
    "sim/end_to_end/stage_m8_mode3_encoder_real_assets.py",
    "sim/end_to_end/tb_vit_phase_e_axi_m8_mode3_encoder_real_rtl.sv",
    "sim/end_to_end/vit_phase_e_axi_m8_mode3_encoder_real_rtl_verilator.f",
    "sim/end_to_end/run_m8_mode3_encoder_real_axi_rtl_verilator.sh",
    "sim/end_to_end/run_e02_layer0_mode3_real_axi_rtl_verilator.sh",
    "sim/end_to_end/run_e03_layers1_11_mode3_real_axi_rtl_verilator.sh",
    "sim/end_to_end/run_m8_mode3_encoder_chain_axi_rtl_verilator.sh",
    "sim/end_to_end/tests/test_m8_mode3_encoder_real_assets.py",
    "sim/end_to_end/M8_MODE3_ENCODER_REAL_SIMULATION.md",
)
rows = []
for relative in verification:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"ERROR: missing/nonregular M8 verification file: {relative}")
    rows.append(f"{relative}={digest(path)}")
print(
    "M8_MODE3_ENCODER_SOURCE_STATE production_sources=80 "
    f"full_axi_sha256={filelist_sha} ordered_source_sha256={ordered} "
    f"protected_e01_e04_files={len(protected)} support_files={len(support)} "
    + " ".join(rows)
)
PY
}

vit_m8_state_before="$(vit_m8_source_state)"
printf '%s\n' "${vit_m8_state_before}" | tee "${vit_m8_source_before}" "${vit_m8_summary}"

vit_m8_previous_output=""
vit_m8_previous_report=""
if [[ "${vit_m8_input_mode}" == chain && "${vit_m8_first_layer}" != 0 ]]; then
    vit_m8_previous_output="${VIT_M8_MODE3_ENCODER_CHAIN_SEED_OUTPUT:-}"
    vit_m8_previous_report="${VIT_M8_MODE3_ENCODER_CHAIN_SEED_REPORT:-}"
    vit_m8_seed_manifest="${VIT_M8_MODE3_ENCODER_CHAIN_SEED_RECEIPT_MANIFEST:-}"
    vit_m8_seed_manifest_sha256="${VIT_M8_MODE3_ENCODER_CHAIN_SEED_RECEIPT_SHA256:-}"
    [[ -n "${vit_m8_previous_output}" && -n "${vit_m8_previous_report}" &&
       -n "${vit_m8_seed_manifest}" && -n "${vit_m8_seed_manifest_sha256}" ]] || {
        printf '%s\n' 'ERROR: a chain beginning after layer 0 needs receipt-bound E02 seed output/report/manifest/SHA-256' >&2
        exit 2
    }
    set +e
    nice -n 15 python3 "${vit_m8_stager}" --verify-seed \
        --seed-output "${vit_m8_previous_output}" \
        --seed-report "${vit_m8_previous_report}" \
        --receipt-manifest "${vit_m8_seed_manifest}" \
        --receipt-manifest-sha256 "${vit_m8_seed_manifest_sha256}" \
        --expected-source-state-file "${vit_m8_source_before}" \
        2>&1 | tee "${vit_m8_output_root}/seed_receipt_validation.log" \
        | tee -a "${vit_m8_summary}"
    vit_m8_seed_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_seed_status[0]}" != 0 || "${vit_m8_seed_status[1]}" != 0 ||
          "${vit_m8_seed_status[2]}" != 0 ]]; then
        printf 'FAIL: M8 E02 seed-receipt validation statuses=%s,%s,%s\n' \
            "${vit_m8_seed_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec '^M8_MODE3_ENCODER_E02_SEED_RECEIPT_PASS files=[1-9][0-9]* manifest_sha256=[0-9a-f]{64} output_sha256=[0-9a-f]{64} report_sha256=[0-9a-f]{64}$' "${vit_m8_output_root}/seed_receipt_validation.log" || true)" != 1 ]]; then
        printf '%s\n' 'FAIL: missing exact E02 seed-receipt PASS marker' >&2
        exit 1
    fi
fi

vit_m8_tmp="$(mktemp -d /tmp/vit_m8_mode3_encoder.XXXXXX)"
trap 'rm -rf -- "${vit_m8_tmp}"' EXIT
vit_m8_obj="${vit_m8_tmp}/obj"
vit_m8_binary="vit_m8_mode3_encoder_real_rtl"

set +e
timeout "${vit_m8_build_timeout}s" nice -n 15 \
    verilator --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    --top-module "${vit_m8_top}" --Mdir "${vit_m8_obj}" -j 1 \
    -CFLAGS "-O3" -f "${vit_m8_filelist}" -o "${vit_m8_binary}" \
    2>&1 | tee "${vit_m8_build_log}" | tee -a "${vit_m8_summary}"
vit_m8_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m8_build_status[0]}" == 124 ]]; then
    printf '%s\n' 'M8_MODE3_ENCODER_BUILD_INCOMPLETE reason=TIMEOUT' | tee -a "${vit_m8_summary}" >&2
    exit 124
fi
if [[ "${vit_m8_build_status[0]}" != 0 || "${vit_m8_build_status[1]}" != 0 || "${vit_m8_build_status[2]}" != 0 ]]; then
    printf 'FAIL: M8 encoder build pipeline statuses=%s,%s,%s\n' "${vit_m8_build_status[@]}" >&2
    exit 1
fi
if grep -Eq '%Error([-:])|%Fatal([-:])|(^|[[:space:]])Error:' "${vit_m8_build_log}"; then
    printf '%s\n' 'FAIL: M8 encoder build log contains a severe marker' >&2
    exit 1
fi

for ((vit_m8_layer=vit_m8_first_layer; vit_m8_layer<=vit_m8_last_layer; vit_m8_layer++)); do
    vit_m8_require_memory "layer-${vit_m8_layer}" | tee -a "${vit_m8_summary}"
    vit_m8_layer_name="$(printf 'layer%02d' "${vit_m8_layer}")"
    vit_m8_layer_dir="${vit_m8_output_root}/layers/${vit_m8_layer_name}"
    vit_m8_asset_dir="${vit_m8_layer_dir}/assets"
    vit_m8_output_dir="${vit_m8_layer_dir}/outputs"
    vit_m8_run_log="${vit_m8_layer_dir}/run.log"
    vit_m8_stage_log="${vit_m8_layer_dir}/asset_stage.log"
    vit_m8_output_dump="${vit_m8_output_dir}/encoder_output_rtl_f32.hex"
    vit_m8_report="${vit_m8_output_dir}/t004_comparison.json"
    mkdir -p "${vit_m8_layer_dir}" "${vit_m8_output_dir}"

    set +e
    nice -n 15 python3 "${vit_m8_stager}" --stage --layer "${vit_m8_layer}" \
        --output-dir "${vit_m8_asset_dir}" \
        2>&1 | tee "${vit_m8_stage_log}" | tee -a "${vit_m8_summary}"
    vit_m8_stage_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_stage_status[0]}" != 0 || "${vit_m8_stage_status[1]}" != 0 || "${vit_m8_stage_status[2]}" != 0 ]]; then
        printf 'FAIL: M8 encoder layer %s asset staging statuses=%s,%s,%s\n' \
            "${vit_m8_layer}" "${vit_m8_stage_status[@]}" >&2
        exit 1
    fi

    vit_m8_runtime_input="${vit_m8_asset_dir}/input_t004_f32.hex"
    vit_m8_origin="t004"
    vit_m8_previous_args=()
    if [[ "${vit_m8_input_mode}" == chain && "${vit_m8_layer}" != 0 ]]; then
        vit_m8_runtime_input="${vit_m8_previous_output}"
        vit_m8_origin="m8-chain"
        vit_m8_previous_args=(--previous-report "${vit_m8_previous_report}")
    fi
    vit_m8_asset_evidence="${vit_m8_asset_dir}/asset_evidence.json"
    vit_m8_argv=(
        "${vit_m8_obj}/${vit_m8_binary}"
        "+M8_MODE3_ENCODER_LAYER=${vit_m8_layer}"
        "+M8_MODE3_ENCODER_ASSET_DIR=${vit_m8_asset_dir}"
        "+M8_MODE3_ENCODER_INPUT_HEX=${vit_m8_runtime_input}"
        "+M8_MODE3_ENCODER_ASSET_EVIDENCE_JSON=${vit_m8_asset_evidence}"
        "+M8_MODE3_ENCODER_OUTPUT_DUMP=${vit_m8_output_dump}"
    )

    if [[ "${vit_m8_build_only}" == 1 ]]; then
        set +e
        timeout 300s nice -n 15 "${vit_m8_argv[@]}" \
            +M8_MODE3_ENCODER_PLUSARG_SMOKE_ONLY \
            2>&1 | tee "${vit_m8_run_log}" | tee -a "${vit_m8_summary}"
        vit_m8_smoke_status=("${PIPESTATUS[@]}")
        set -e
        if [[ "${vit_m8_smoke_status[0]}" != 0 || "${vit_m8_smoke_status[1]}" != 0 || "${vit_m8_smoke_status[2]}" != 0 ]]; then
            printf 'FAIL: M8 encoder plusarg smoke statuses=%s,%s,%s\n' "${vit_m8_smoke_status[@]}" >&2
            exit 1
        fi
        grep -Eq "^M8_MODE3_ENCODER_PLUSARG_SMOKE_PASS checks=[1-9][0-9]* layer=${vit_m8_layer} phase=[23] files=18 package_words=43421440 layer_words=3548928 mode=3 ip=0001000d geometry=R8C2L16S8$" "${vit_m8_run_log}" || {
            printf '%s\n' 'FAIL: missing exact M8 encoder plusarg-smoke marker' >&2
            exit 1
        }
        set +e
        timeout 300s nice -n 15 "${vit_m8_argv[@]}" \
            +M8_MODE3_ENCODER_LAYER_REQUEST_SMOKE_ONLY \
            2>&1 | tee -a "${vit_m8_run_log}" | tee -a "${vit_m8_summary}"
        vit_m8_request_smoke_status=("${PIPESTATUS[@]}")
        set -e
        if [[ "${vit_m8_request_smoke_status[0]}" != 0 || "${vit_m8_request_smoke_status[1]}" != 0 || "${vit_m8_request_smoke_status[2]}" != 0 ]]; then
            printf 'FAIL: M8 encoder layer-request smoke statuses=%s,%s,%s\n' \
                "${vit_m8_request_smoke_status[@]}" >&2
            exit 1
        fi
        grep -Eq "^M8_MODE3_ENCODER_LAYER_REQUEST_SMOKE_PASS checks=[1-9][0-9]* layer=${vit_m8_layer} phase=[23] completions=1 high_cycles=([2-9]|[1-9][0-9]+)$" "${vit_m8_run_log}" || {
            printf '%s\n' 'FAIL: missing exact M8 encoder layer-request smoke marker' >&2
            exit 1
        }
        break
    fi

    set +e
    timeout "${vit_m8_run_timeout}s" nice -n 15 "${vit_m8_argv[@]}" \
        2>&1 | tee "${vit_m8_run_log}" | tee -a "${vit_m8_summary}"
    vit_m8_run_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_run_status[0]}" == 124 ]]; then
        printf 'M8_MODE3_ENCODER_RUN_INCOMPLETE layer=%s reason=TIMEOUT\n' "${vit_m8_layer}" | tee -a "${vit_m8_summary}" >&2
        exit 124
    fi
    if [[ "${vit_m8_run_status[0]}" != 0 || "${vit_m8_run_status[1]}" != 0 || "${vit_m8_run_status[2]}" != 0 ]]; then
        printf 'FAIL: M8 encoder layer %s run statuses=%s,%s,%s\n' \
            "${vit_m8_layer}" "${vit_m8_run_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec "^VIT_PHASE_E_AXI_M8_MODE3_ENCODER_REAL_RTL_STRUCTURAL_PASS .*layer=${vit_m8_layer} .*numerical_status=PENDING_EXTERNAL_T004_GATE$" "${vit_m8_run_log}" || true)" != 1 ]]; then
        printf 'FAIL: layer %s lacks one exact structural PASS marker\n' "${vit_m8_layer}" >&2
        exit 1
    fi

    set +e
    nice -n 15 python3 "${vit_m8_stager}" --compare \
        --asset-dir "${vit_m8_asset_dir}" \
        --runtime-input "${vit_m8_runtime_input}" \
        --output-dump "${vit_m8_output_dump}" \
        --report "${vit_m8_report}" \
        --input-origin "${vit_m8_origin}" \
        "${vit_m8_previous_args[@]}" \
        2>&1 | tee -a "${vit_m8_run_log}" | tee -a "${vit_m8_summary}"
    vit_m8_compare_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_compare_status[0]}" != 0 || "${vit_m8_compare_status[1]}" != 0 || "${vit_m8_compare_status[2]}" != 0 ]]; then
        printf 'FAIL: M8 encoder layer %s T004 compare statuses=%s,%s,%s\n' \
            "${vit_m8_layer}" "${vit_m8_compare_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec "^M8_MODE3_ENCODER_T004_COMPARE_PASS layer=${vit_m8_layer} .*tolerance_failures=0 actual_nonfinite=0 .*report_sha256=[0-9a-f]{64}$" "${vit_m8_run_log}" || true)" != 1 ]]; then
        printf 'FAIL: layer %s lacks one exact T004 comparison PASS marker\n' "${vit_m8_layer}" >&2
        exit 1
    fi
    printf 'M8_MODE3_ENCODER_LAYER_PASS layer=%s input_origin=%s output=%s report=%s\n' \
        "${vit_m8_layer}" "${vit_m8_origin}" "${vit_m8_output_dump}" "${vit_m8_report}" \
        | tee -a "${vit_m8_summary}"
    vit_m8_previous_output="${vit_m8_output_dump}"
    vit_m8_previous_report="${vit_m8_report}"
done

vit_m8_state_after="$(vit_m8_source_state)"
printf '%s\n' "${vit_m8_state_after}" \
    | tee "${vit_m8_source_after}" \
    | tee -a "${vit_m8_summary}"
if [[ "${vit_m8_state_after}" != "${vit_m8_state_before}" ]]; then
    printf '%s\n' 'FAIL: M8 production/harness source state changed during run' >&2
    exit 1
fi

if [[ "${vit_m8_build_only}" == 1 ]]; then
    printf 'M8_MODE3_ENCODER_BUILD_ONLY_PASS smoke_layer=%s layers_smoked=1 requested_first_layer=%s requested_last_layer=%s input_mode=%s source_stable=1\n' \
        "${vit_m8_first_layer}" "${vit_m8_first_layer}" \
        "${vit_m8_last_layer}" "${vit_m8_input_mode}" \
        | tee -a "${vit_m8_summary}"
else
    printf 'M8_MODE3_ENCODER_SEQUENCE_PASS first_layer=%s last_layer=%s input_mode=%s layers=%s source_stable=1\n' \
        "${vit_m8_first_layer}" "${vit_m8_last_layer}" "${vit_m8_input_mode}" \
        "$((vit_m8_last_layer - vit_m8_first_layer + 1))" \
        | tee -a "${vit_m8_summary}"
fi

(
    cd "${vit_m8_output_root}"
    find . -type f ! -name RUN_SHA256SUMS.txt -print0 \
        | sort -z \
        | xargs -0 sha256sum > RUN_SHA256SUMS.txt
)
printf 'M8_MODE3_ENCODER_RECEIPT_COMPLETE root=%s sha256_manifest=%s\n' \
    "${vit_m8_output_root}" \
    "$(sha256sum "${vit_m8_output_root}/RUN_SHA256SUMS.txt" | awk '{print $1}')"
