#!/usr/bin/env bash
set -euo pipefail
umask 077

# Continuous package-v3, execution-mode-3, full-size E05 gate for M8 v1.13.
# BUILD_ONLY defaults to one so an ordinary invocation cannot accidentally
# start a multi-day simulation.  The full path is observation-first: exact
# schedule/protocol/status/counter algebra and pinned numerical oracles gate
# PASS, while previously unmeasured cycle/read totals are recorded only.
vit_m8_e05_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vit_m8_e05_workspace_root="$(cd "${vit_m8_e05_root}/.." && pwd)"
cd "${vit_m8_e05_root}"

if (($# != 0)); then
    printf '%s\n' 'ERROR: M8 real-E05 runner accepts environment settings only' >&2
    exit 2
fi

for vit_m8_e05_tool in \
    verilator c++ timeout nice python3 tee grep mktemp mkdir date sha256sum; do
    if ! command -v "${vit_m8_e05_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_m8_e05_tool}" >&2
        exit 2
    fi
done

vit_m8_e05_build_only="${VIT_M8_MODE3_E05_BUILD_ONLY:-1}"
if ! [[ "${vit_m8_e05_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' 'ERROR: VIT_M8_MODE3_E05_BUILD_ONLY must be 0 or 1' >&2
    exit 2
fi
vit_m8_e05_probe_cycles="${VIT_M8_MODE3_E05_PROBE_STOP_CYCLES:-0}"
if ! [[ "${vit_m8_e05_probe_cycles}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'ERROR: VIT_M8_MODE3_E05_PROBE_STOP_CYCLES must be an integer' >&2
    exit 2
fi
if ((vit_m8_e05_probe_cycles != 0)) && \
   ((vit_m8_e05_probe_cycles < 1000000 || vit_m8_e05_probe_cycles > 10000000)); then
    printf '%s\n' 'ERROR: probe stop must be zero or in 1,000,000..10,000,000' >&2
    exit 2
fi
if [[ "${vit_m8_e05_build_only}" == 1 && "${vit_m8_e05_probe_cycles}" != 0 ]]; then
    printf '%s\n' 'ERROR: build-only and bounded probe are mutually exclusive' >&2
    exit 2
fi
vit_m8_e05_nice="${VIT_M8_MODE3_E05_NICE:-15}"
if [[ "${vit_m8_e05_nice}" != 15 ]]; then
    printf '%s\n' 'ERROR: M8 real-E05 gate requires nice level 15' >&2
    exit 2
fi
vit_m8_e05_build_timeout="${VIT_M8_MODE3_E05_BUILD_TIMEOUT_SECONDS:-2400}"
vit_m8_e05_run_timeout="${VIT_M8_MODE3_E05_RUN_TIMEOUT_SECONDS:-604800}"
for vit_m8_e05_timeout in \
    "${vit_m8_e05_build_timeout}" "${vit_m8_e05_run_timeout}"; do
    if ! [[ "${vit_m8_e05_timeout}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' 'ERROR: M8 real-E05 timeouts must be positive integers' >&2
        exit 2
    fi
done

vit_m8_e05_run_id="${VIT_M8_MODE3_E05_RUN_ID:-m8-mode3-e05-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
if ! [[ "${vit_m8_e05_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s\n' 'ERROR: invalid VIT_M8_MODE3_E05_RUN_ID' >&2
    exit 2
fi
vit_m8_e05_default_run_root="${vit_m8_e05_root}/build/test_logs/${vit_m8_e05_run_id}"
vit_m8_e05_run_root="${VIT_M8_MODE3_E05_OUTPUT_DIR:-${vit_m8_e05_default_run_root}}"
vit_m8_e05_launch_manifest="${vit_m8_e05_root}/sim/end_to_end/m8_e05_launch_manifest.json"
vit_m8_e05_launch_verifier="${vit_m8_e05_root}/sim/end_to_end/verify_m8_e05_launch_manifest.py"
vit_m8_e05_run_evidence_helper="${vit_m8_e05_root}/sim/end_to_end/m8_e05_run_evidence.py"

python3 - "${vit_m8_e05_workspace_root}" "${vit_m8_e05_run_root}" <<'PY'
import sys
from pathlib import Path

workspace = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2])
if not output.is_absolute() or output != Path(str(output.resolve(strict=False))):
    raise SystemExit("ERROR: run root must be an absolute normalized path")
try:
    output.relative_to(workspace)
except ValueError as exc:
    raise SystemExit("ERROR: run root must stay inside the workspace") from exc
if output.exists() or output.is_symlink():
    raise SystemExit(f"ERROR: refusing to reuse run root: {output}")
PY

# This external, data-only seal includes the runner itself.  Keep it before
# run-root creation, asset staging and compilation so a changed harness cannot
# consume a long-run directory or server time.
vit_m8_e05_launch_receipt="$(python3 "${vit_m8_e05_launch_verifier}" \
    --workspace-root "${vit_m8_e05_workspace_root}" \
    --manifest "${vit_m8_e05_launch_manifest}")"

vit_m8_e05_verify_launch_seal() {
    local vit_m8_e05_phase="$1" vit_m8_e05_current_receipt
    vit_m8_e05_current_receipt="$(python3 "${vit_m8_e05_launch_verifier}" \
        --workspace-root "${vit_m8_e05_workspace_root}" \
        --manifest "${vit_m8_e05_launch_manifest}")"
    if [[ "${vit_m8_e05_current_receipt}" != "${vit_m8_e05_launch_receipt}" ]]; then
        printf 'FAIL: E05 launch seal changed at phase=%s\n' \
            "${vit_m8_e05_phase}" >&2
        return 1
    fi
    printf 'M8_MODE3_E05_LAUNCH_SEAL_RECHECK_PASS phase=%s\n' \
        "${vit_m8_e05_phase}" | tee -a "${vit_m8_e05_run_log}"
}

mkdir -p "${vit_m8_e05_run_root}"
vit_m8_e05_asset_dir="${vit_m8_e05_run_root}/assets"
vit_m8_e05_output_dir="${vit_m8_e05_run_root}/outputs"
vit_m8_e05_build_log="${vit_m8_e05_run_root}/build.log"
vit_m8_e05_run_log="${vit_m8_e05_run_root}/run.log"
vit_m8_e05_stage_log="${vit_m8_e05_run_root}/asset_stage.log"
vit_m8_e05_endpoint_log="${vit_m8_e05_run_root}/endpoint_compare.log"
vit_m8_e05_behavioral_log="${vit_m8_e05_run_root}/behavioral_compare.log"
vit_m8_e05_source_pre="${vit_m8_e05_run_root}/SOURCE_STATE_BEFORE.txt"
vit_m8_e05_source_post="${vit_m8_e05_run_root}/SOURCE_STATE_AFTER.txt"
vit_m8_e05_toolchain_receipt="${vit_m8_e05_run_root}/TOOLCHAIN.json"
vit_m8_e05_status_receipt="${vit_m8_e05_run_root}/RUN_STATUS.txt"
vit_m8_e05_stager="${vit_m8_e05_root}/sim/end_to_end/stage_m8_mode3_e05_real_assets.py"
vit_m8_e05_model="${vit_m8_e05_workspace_root}/build/model_package/v3_blocked_b_fp16_mixed/vit_model.bin"
vit_m8_e05_tmp=""
vit_m8_e05_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

vit_m8_e05_finish() {
    local vit_m8_e05_exit_status="$1"
    local vit_m8_e05_finish_utc vit_m8_e05_result vit_m8_e05_mode
    set +e
    vit_m8_e05_finish_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${vit_m8_e05_build_only}" == 1 ]]; then
        vit_m8_e05_mode="BUILD_ONLY"
    elif [[ "${vit_m8_e05_probe_cycles}" != 0 ]]; then
        vit_m8_e05_mode="BOUNDED_PROBE"
    else
        vit_m8_e05_mode="FULL"
    fi
    if [[ "${vit_m8_e05_exit_status}" == 0 ]]; then
        vit_m8_e05_result="PASS"
    elif [[ "${vit_m8_e05_exit_status}" == 124 ]]; then
        vit_m8_e05_result="INCOMPLETE_TIMEOUT"
    else
        vit_m8_e05_result="FAIL"
    fi
    printf 'schema=vit-m8-mode3-e05-run-status-v1\nmode=%s\nresult=%s\nexit_code=%s\nstart_utc=%s\nend_utc=%s\nrun_id=%s\n' \
        "${vit_m8_e05_mode}" "${vit_m8_e05_result}" \
        "${vit_m8_e05_exit_status}" "${vit_m8_e05_start_utc}" \
        "${vit_m8_e05_finish_utc}" "${vit_m8_e05_run_id}" \
        >"${vit_m8_e05_status_receipt}"
    printf 'M8_MODE3_E05_RUN_STATUS mode=%s result=%s exit_code=%s start_utc=%s end_utc=%s receipt=%s\n' \
        "${vit_m8_e05_mode}" "${vit_m8_e05_result}" \
        "${vit_m8_e05_exit_status}" "${vit_m8_e05_start_utc}" \
        "${vit_m8_e05_finish_utc}" "${vit_m8_e05_status_receipt}" \
        | tee -a "${vit_m8_e05_run_log}"
    if [[ -n "${vit_m8_e05_tmp}" && -d "${vit_m8_e05_tmp}" ]]; then
        rm -rf -- "${vit_m8_e05_tmp}"
    fi
    trap - EXIT
    exit "${vit_m8_e05_exit_status}"
}
trap 'vit_m8_e05_finish "$?"' EXIT

printf '%s\n' "${vit_m8_e05_launch_receipt}" | tee -a "${vit_m8_e05_run_log}"
python3 - "${vit_m8_e05_toolchain_receipt}" "${vit_m8_e05_start_utc}" \
    <<'PY' | tee -a "${vit_m8_e05_run_log}"
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

receipt = Path(sys.argv[1])
start_utc = sys.argv[2]
tools = {}
for name, version_args in (
    ("verilator", ("--version",)),
    ("c++", ("--version",)),
    ("python3", ("--version",)),
):
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"ERROR: receipt tool disappeared: {name}")
    completed = subprocess.run(
        (path, *version_args), check=True, capture_output=True, text=True
    )
    version_lines = (completed.stdout + completed.stderr).splitlines()
    tools[name] = {
        "path": path,
        "version": version_lines[0] if version_lines else "UNKNOWN",
    }
value = {
    "schema": "vit-m8-mode3-e05-toolchain-v1",
    "start_utc": start_utc,
    "host": platform.node(),
    "platform": platform.platform(),
    "tools": tools,
}
payload = json.dumps(
    value, indent=2, sort_keys=True, separators=(",", ": ")
).encode("utf-8") + b"\n"
with receipt.open("xb") as stream:
    stream.write(payload)
print(
    "M8_MODE3_E05_TOOLCHAIN_RECEIPT "
    f"start_utc={start_utc} host={value['host']} "
    f"verilator={tools['verilator']['version'].replace(' ', '_')} "
    f"compiler={tools['c++']['version'].replace(' ', '_')} "
    f"sha256={hashlib.sha256(payload).hexdigest()} path={receipt}"
)
PY

set +e
nice -n 15 python3 "${vit_m8_e05_stager}" \
    --stage --output-dir "${vit_m8_e05_asset_dir}" \
    2>&1 | tee "${vit_m8_e05_stage_log}" | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_stage_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m8_e05_stage_status[0]}" != 0 || \
      "${vit_m8_e05_stage_status[1]}" != 0 || \
      "${vit_m8_e05_stage_status[2]}" != 0 ]]; then
    printf 'FAIL: E05 asset-stage statuses=%s,%s,%s\n' \
        "${vit_m8_e05_stage_status[@]}" >&2
    exit 1
fi
if [[ "$(grep -Ec '^M8_MODE3_E05_ASSET_STAGE_PASS files=18 checkpoints=13 runtime_offsets=200 model_words=43421440 input_words=150528 scratch_words=1990656 evidence=.+ evidence_sha256=[0-9a-f]{64}$' "${vit_m8_e05_stage_log}" || true)" != 1 ]]; then
    printf '%s\n' 'FAIL: missing/nonunique exact E05 asset-stage marker' >&2
    exit 1
fi

vit_m8_e05_prepared="${vit_m8_e05_asset_dir}/prepared_input_f32.hex"
vit_m8_e05_offsets="${vit_m8_e05_asset_dir}/runtime_offsets_u32.hex"
vit_m8_e05_evidence="${vit_m8_e05_asset_dir}/asset_evidence.json"

vit_m8_e05_source_state() {
    python3 - \
        "${vit_m8_e05_root}" \
        "${vit_m8_e05_workspace_root}" <<'PY'
import hashlib
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve(strict=True)
workspace = Path(sys.argv[2]).resolve(strict=True)

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
    raise SystemExit("ERROR: production closure is not 80/80 unique sources")
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
    raise SystemExit("ERROR: M8 ordered production-source identity changed")

verification = {
    "tb": root / "sim/end_to_end/tb_vit_phase_e_axi_e05_mode3_real_rtl.sv",
    "simulation_filelist": root / "sim/end_to_end/vit_phase_e_axi_e05_mode3_real_rtl_verilator.f",
    "runner": root / "sim/end_to_end/run_e05_mode3_real_axi_rtl_verilator.sh",
    "stager": root / "sim/end_to_end/stage_m8_mode3_e05_real_assets.py",
    "e05_asset_module": root / "sim/end_to_end/m8_mode3_e05_real_assets.py",
    "qualified_common_helper": root / "sim/end_to_end/m7_mode3_real_assets.py",
    "ddr_model": root / "sim/axi/vit_axi_ddr_model_128.sv",
}
pins = {
    "model": (
        workspace / "build/model_package/v3_blocked_b_fp16_mixed/vit_model.bin",
        "d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5",
    ),
    "table": (
        workspace / "build/model_package/v3_blocked_b_fp16_mixed/vit_model_table.bin",
        "10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a",
    ),
    "input": (
        workspace / "build/model_package/v3_blocked_b_fp16_mixed/prepared_input.bin",
        "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54",
    ),
    "runtime": (
        workspace / "build/model_package/v3_blocked_b_fp16_mixed/vit_runtime_config.json",
        "20ee65ab28d8aa32cbd3a0f5f04f99975fe29aae2d4ae66d1c790e94b7ca704d",
    ),
    "golden_embedding": (
        workspace / "results/embedding_step_06_hidden_states_f32.hex",
        "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18",
    ),
    "golden_final_ln": (
        workspace / "results/post_encoder_step_30_final_layernorm_f32.hex",
        "d8ac11b3b8c244c4c525da8f2a56352595256290f0673c607944d5581835167d",
    ),
    "golden_logits": (
        workspace / "results/post_encoder_step_32_logits_f32.hex",
        "fef8118492356377612d95f0b02120d6fde728ff47bef9b4b8c87cf52c4c7143",
    ),
    "golden_probabilities": (
        workspace / "results/post_encoder_step_33p_probabilities_f32.hex",
        "870497897b0b0453c8dc1335c3db8881e9ffdbf81bf66eba3d40c8c1b169491b",
    ),
}
layer_hashes = (
    "e95ccf94deebc9f85acb7f905e5052f2d1ef56e3ad1ed6449f05884e5fecb552",
    "a36b4ff1a042bd24ecf601cbb8accfaeeeec1deb0384530867212a6f5a7a7619",
    "1e06c65f2ada90bb172f49917cfa414c25ca4f1911da3e058f57376c65a41297",
    "0f1bca089c1d55366c52544e68766f877c73d47fc2e4a22e376d8a9062459d77",
    "b34420f5b7026c31553bf167be8fd5eb9d8c4459604bd9155857163e30815ffd",
    "2bf04acf166f51b22bcb39a38c9bf2db461254c3366388a3ecf0c312f641f6f6",
    "2263736bd4f13997f6ccf275c8084cd106d633d762aa81d1dd30bcd96069666d",
    "76e1462cb92dcf2807386f2c2b16a302ca00132b4f11b06194de1ef2c6500b99",
    "70e666024df1cb7d1bfa01c53c01ceacfe14d931cc2ceaa82f55f882bf522551",
    "8e9a6b28061f7c460248eb6636ec0f69a048c7a80f0db04b8242dcb1460b0480",
    "b10a1815d25f973e5ec794034f124f189db5c40c4fb884885251290d75ba07ef",
    "5cf34a472d907125dd6bdb0c7bfc5d4b5e353571978aa8ef73b9a8b17bc93359",
)
for layer, expected in enumerate(layer_hashes):
    pins[f"golden_layer_{layer:02d}"] = (
        workspace / f"results/encoder_layer_{layer:02d}_step_20_layer_output_f32.hex",
        expected,
    )
for name, path in verification.items():
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"ERROR: missing/nonregular verification input: {name}")
for name, (path, expected) in pins.items():
    if not path.is_file() or path.is_symlink() or digest(path) != expected:
        raise SystemExit(f"ERROR: pinned E05 input changed: {name}")
print(
    "M8_MODE3_E05_SOURCE_STATE "
    f"production_sources=80 full_axi_sha256={filelist_sha} "
    f"ordered_source_sha256={ordered} "
    + " ".join(f"{name}_sha256={digest(path)}" for name, path in verification.items())
    + " "
    + " ".join(f"{name}_sha256={expected}" for name, (_, expected) in pins.items())
)
PY
}

vit_m8_e05_state_before="$(vit_m8_e05_source_state)"
printf '%s\n' "${vit_m8_e05_state_before}" | tee "${vit_m8_e05_source_pre}"
printf 'M8_MODE3_E05_BUILD_CONFIG build_only=%s probe_stop_cycles=%s jobs=1 nice=15 build_timeout_seconds=%s run_timeout_seconds=%s observation_first=1\n' \
    "${vit_m8_e05_build_only}" "${vit_m8_e05_probe_cycles}" \
    "${vit_m8_e05_build_timeout}" "${vit_m8_e05_run_timeout}" \
    | tee -a "${vit_m8_e05_run_log}"

vit_m8_e05_tmp="$(mktemp -d /tmp/vit_m8_mode3_e05.XXXXXX)"
vit_m8_e05_obj="${vit_m8_e05_tmp}/obj"
vit_m8_e05_binary="vit_m8_mode3_e05_real_rtl"

set +e
timeout "${vit_m8_e05_build_timeout}s" \
    nice -n 15 verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e05_mode3_real_rtl \
        --Mdir "${vit_m8_e05_obj}" \
        -j 1 \
        -CFLAGS "-O3" \
        -f sim/end_to_end/vit_phase_e_axi_e05_mode3_real_rtl_verilator.f \
        -o "${vit_m8_e05_binary}" \
        2>&1 | tee "${vit_m8_e05_build_log}" | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m8_e05_build_status[0]}" != 0 || \
      "${vit_m8_e05_build_status[1]}" != 0 || \
      "${vit_m8_e05_build_status[2]}" != 0 ]]; then
    printf 'FAIL: E05 build statuses=%s,%s,%s\n' \
        "${vit_m8_e05_build_status[@]}" >&2
    exit 1
fi
if grep -Eq '%Error([-:])|%Fatal([-:])|(^|[[:space:]])Error:' \
        "${vit_m8_e05_build_log}"; then
    printf '%s\n' 'FAIL: E05 build log contains a severe marker' >&2
    exit 1
fi
read -r vit_m8_e05_binary_sha256 _ \
    < <(sha256sum "${vit_m8_e05_obj}/${vit_m8_e05_binary}")
printf 'M8_MODE3_E05_EXECUTABLE_RECEIPT sha256=%s build_end_utc=%s path=%s\n' \
    "${vit_m8_e05_binary_sha256}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${vit_m8_e05_obj}/${vit_m8_e05_binary}" \
    | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_verify_launch_seal POST_BUILD

vit_m8_e05_state_after_build="$(vit_m8_e05_source_state)"
if [[ "${vit_m8_e05_state_after_build}" != "${vit_m8_e05_state_before}" ]]; then
    printf '%s\n' 'FAIL: E05 source/package/golden state changed during build' >&2
    exit 1
fi

mkdir -p "${vit_m8_e05_output_dir}"
vit_m8_e05_argv=(
    "${vit_m8_e05_obj}/${vit_m8_e05_binary}"
    "+M8_MODE3_E05_MODEL_BIN=${vit_m8_e05_model}"
    "+M8_MODE3_E05_PREPARED_INPUT_HEX=${vit_m8_e05_prepared}"
    "+M8_MODE3_E05_RUNTIME_OFFSETS_HEX=${vit_m8_e05_offsets}"
    "+M8_MODE3_E05_ASSET_EVIDENCE_JSON=${vit_m8_e05_evidence}"
    "+M8_MODE3_E05_OUTPUT_DIR=${vit_m8_e05_output_dir}"
)

if [[ "${vit_m8_e05_build_only}" == 1 ]]; then
    set +e
    timeout 180s nice -n 15 \
        "${vit_m8_e05_argv[@]}" +M8_MODE3_E05_PLUSARG_SMOKE_ONLY \
        2>&1 | tee -a "${vit_m8_e05_run_log}"
    vit_m8_e05_smoke_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_e05_smoke_status[0]}" != 0 || \
          "${vit_m8_e05_smoke_status[1]}" != 0 ]]; then
        printf 'FAIL: E05 plusarg-smoke statuses=%s,%s\n' \
            "${vit_m8_e05_smoke_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec '^M8_MODE3_E05_PLUSARG_SMOKE_PASS checks=[1-9][0-9]* staged_files=18 runtime_offset_words=200 global_offset_words=8 layer_aperture_words=192 package_tensor_entries=200 model_bytes=173685760 model_words=43421440 input_words=150528 scratch_words=1990656 checkpoints=13 mode=3 job_config=00101d85 ip=0001000d geometry=R8C2L16S8 loader_probe=PASS$' "${vit_m8_e05_run_log}" || true)" != 1 ]]; then
        printf '%s\n' 'FAIL: missing/nonunique exact E05 smoke marker' >&2
        exit 1
    fi
    vit_m8_e05_state_smoke="$(vit_m8_e05_source_state)"
    printf '%s\n' "${vit_m8_e05_state_smoke}" | tee "${vit_m8_e05_source_post}"
    if [[ "${vit_m8_e05_state_smoke}" != "${vit_m8_e05_state_before}" ]]; then
        printf '%s\n' 'FAIL: E05 source/package/golden state changed during smoke' >&2
        exit 1
    fi
    vit_m8_e05_verify_launch_seal POST_SMOKE
    printf 'M8_MODE3_E05_BUILD_ONLY_PASS jobs=1 nice=15 plusarg_smoke=PASS run_root=%s\n' \
        "${vit_m8_e05_run_root}" | tee -a "${vit_m8_e05_run_log}"
    exit 0
fi

vit_m8_e05_start_epoch="$(date -u +%s)"
if [[ "${vit_m8_e05_probe_cycles}" != 0 ]]; then
    printf 'M8_MODE3_E05_PROBE_BEGIN stop_cycles=%s numerical_status=INCOMPLETE_NO_ACCURACY_CLAIM\n' \
        "${vit_m8_e05_probe_cycles}" | tee -a "${vit_m8_e05_run_log}"
    set +e
    timeout "${vit_m8_e05_run_timeout}s" nice -n 15 \
        "${vit_m8_e05_argv[@]}" \
        "+M8_MODE3_E05_PROBE_STOP_CYCLES=${vit_m8_e05_probe_cycles}" \
        2>&1 | tee -a "${vit_m8_e05_run_log}"
    vit_m8_e05_probe_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m8_e05_probe_status[0]}" != 0 || \
          "${vit_m8_e05_probe_status[1]}" != 0 ]]; then
        printf 'FAIL: E05 probe statuses=%s,%s\n' \
            "${vit_m8_e05_probe_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec "^M8_MODE3_E05_INCOMPLETE_PROBE_PASS stop_cycles=${vit_m8_e05_probe_cycles} sample_cycles=[1-9][0-9]* commands_sample=[0-9]+ commands_stop=[1-9][0-9]* checkpoints_sample=[0-9]+ checkpoints_stop=[0-9]+ reads_sample=[0-9]+ reads_stop=[1-9][0-9]* writes_stop=[0-9]+ numerical_status=INCOMPLETE_NO_ACCURACY_CLAIM$" "${vit_m8_e05_run_log}" || true)" != 1 ]]; then
        printf '%s\n' 'FAIL: missing/nonunique bounded E05 probe marker' >&2
        exit 1
    fi
    vit_m8_e05_state_probe="$(vit_m8_e05_source_state)"
    printf '%s\n' "${vit_m8_e05_state_probe}" | tee "${vit_m8_e05_source_post}"
    if [[ "${vit_m8_e05_state_probe}" != "${vit_m8_e05_state_before}" ]]; then
        printf '%s\n' 'FAIL: E05 source/package/golden state changed during probe' >&2
        exit 1
    fi
    vit_m8_e05_verify_launch_seal POST_PROBE
    printf 'M8_MODE3_E05_BOUNDED_PROBE_PASS stop_cycles=%s numerical_status=INCOMPLETE_NO_ACCURACY_CLAIM run_root=%s\n' \
        "${vit_m8_e05_probe_cycles}" "${vit_m8_e05_run_root}" \
        | tee -a "${vit_m8_e05_run_log}"
    exit 0
fi

printf '%s\n' 'M8_MODE3_E05_FULL_RUN_BEGIN commands=249 checkpoints=13 numerical_status=PENDING_EXTERNAL_ARITHMETIC_AND_FP32_ORACLES' \
    | tee -a "${vit_m8_e05_run_log}"
set +e
timeout "${vit_m8_e05_run_timeout}s" nice -n 15 \
    "${vit_m8_e05_argv[@]}" \
    2>&1 | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_run_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m8_e05_run_status[0]}" == 124 ]]; then
    printf 'INCOMPLETE: full E05 timed out after %s seconds; preserved run_root=%s\n' \
        "${vit_m8_e05_run_timeout}" "${vit_m8_e05_run_root}" >&2
    exit 124
fi
if [[ "${vit_m8_e05_run_status[1]}" != 0 ]]; then
    printf 'FAIL: full E05 log pipeline statuses=%s,%s\n' \
        "${vit_m8_e05_run_status[@]}" >&2
    exit 1
fi
vit_m8_e05_verify_launch_seal POST_SIMULATION
vit_m8_e05_salvage=0
if [[ "${vit_m8_e05_run_status[0]}" != 0 ]]; then
    vit_m8_e05_salvage=1
    printf 'M8_MODE3_E05_LATE_STRUCTURAL_FAILURE_CANDIDATE simulator_status=%s action=VALIDATE_COMPLETE_DUMPS_BEFORE_NUMERICAL_SALVAGE overall_status=FAIL\n' \
        "${vit_m8_e05_run_status[0]}" | tee -a "${vit_m8_e05_run_log}"
fi
set +e
python3 "${vit_m8_e05_run_evidence_helper}" \
    --run-log "${vit_m8_e05_run_log}" \
    --output-dir "${vit_m8_e05_output_dir}" \
    --simulator-status "${vit_m8_e05_run_status[0]}" \
    --tee-status "${vit_m8_e05_run_status[1]}" \
    2>&1 | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_raw_gate_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m8_e05_raw_gate_status[0]}" != 0 || \
      "${vit_m8_e05_raw_gate_status[1]}" != 0 ]]; then
    printf 'FAIL: full E05 raw-evidence statuses=%s,%s simulator_status=%s\n' \
        "${vit_m8_e05_raw_gate_status[@]}" \
        "${vit_m8_e05_run_status[0]}" >&2
    exit 1
fi

vit_m8_e05_checkpoints=(
    "${vit_m8_e05_output_dir}/checkpoint_00_embedding_rtl_f32.hex"
)
for vit_m8_e05_layer in {0..11}; do
    printf -v vit_m8_e05_checkpoint \
        '%s/checkpoint_%02d_encoder_layer_%02d_step_20_rtl_f32.hex' \
        "${vit_m8_e05_output_dir}" "$((vit_m8_e05_layer + 1))" \
        "${vit_m8_e05_layer}"
    vit_m8_e05_checkpoints+=("${vit_m8_e05_checkpoint}")
done
vit_m8_e05_final_ln="${vit_m8_e05_output_dir}/final_layernorm_rtl_f32.hex"
vit_m8_e05_logits="${vit_m8_e05_output_dir}/logits_rtl_f32.hex"
vit_m8_e05_probabilities="${vit_m8_e05_output_dir}/probabilities_rtl_f32.hex"
vit_m8_e05_class="${vit_m8_e05_output_dir}/class_result_rtl_u32.hex"
vit_m8_e05_endpoint_report="${vit_m8_e05_output_dir}/m8_mode3_e05_endpoint_arithmetic_comparison.json"
vit_m8_e05_behavioral_report="${vit_m8_e05_output_dir}/m8_mode3_e05_behavioral_golden_comparison.json"

set +e
nice -n 15 python3 "${vit_m8_e05_stager}" \
    --compare-endpoint \
    --asset-dir "${vit_m8_e05_asset_dir}" \
    --embedding-dump "${vit_m8_e05_checkpoints[0]}" \
    --final-ln-dump "${vit_m8_e05_final_ln}" \
    --logits-dump "${vit_m8_e05_logits}" \
    --report "${vit_m8_e05_endpoint_report}" \
    2>&1 | tee "${vit_m8_e05_endpoint_log}" | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_endpoint_status=("${PIPESTATUS[@]}")
set -e
printf 'M8_MODE3_E05_ENDPOINT_ORACLE_STATUS statuses=%s,%s,%s action=CONTINUE_TO_BEHAVIORAL\n' \
    "${vit_m8_e05_endpoint_status[@]}" | tee -a "${vit_m8_e05_run_log}"

vit_m8_e05_behavioral_args=(
    --compare-behavioral
    --asset-dir "${vit_m8_e05_asset_dir}"
)
for vit_m8_e05_checkpoint in "${vit_m8_e05_checkpoints[@]}"; do
    vit_m8_e05_behavioral_args+=(--checkpoint-dump "${vit_m8_e05_checkpoint}")
done
vit_m8_e05_behavioral_args+=(
    --final-ln-dump "${vit_m8_e05_final_ln}"
    --logits-dump "${vit_m8_e05_logits}"
    --probabilities-dump "${vit_m8_e05_probabilities}"
    --class-result-dump "${vit_m8_e05_class}"
    --report "${vit_m8_e05_behavioral_report}"
)
set +e
nice -n 15 python3 "${vit_m8_e05_stager}" \
    "${vit_m8_e05_behavioral_args[@]}" \
    2>&1 | tee "${vit_m8_e05_behavioral_log}" | tee -a "${vit_m8_e05_run_log}"
vit_m8_e05_behavioral_status=("${PIPESTATUS[@]}")
set -e
printf 'M8_MODE3_E05_BEHAVIORAL_ORACLE_STATUS statuses=%s,%s,%s action=VERIFY_BOTH_REPORTS\n' \
    "${vit_m8_e05_behavioral_status[@]}" | tee -a "${vit_m8_e05_run_log}"

set +e
python3 - \
    "${vit_m8_e05_endpoint_log}" "${vit_m8_e05_endpoint_report}" \
    "${vit_m8_e05_behavioral_log}" "${vit_m8_e05_behavioral_report}" \
    <<'PY' 2>&1 | tee -a "${vit_m8_e05_run_log}"
import hashlib
import json
import re
import sys
from pathlib import Path

endpoint_log, endpoint_report, behavioral_log, behavioral_report = map(Path, sys.argv[1:])
endpoint_pattern = re.compile(
    r"M8_MODE3_E05_ENDPOINT_COMPARE_(PASS|FAIL) embedding_words=151296 "
    r"embedding_exact_mismatch=([0-9]+) classifier_words=1000 "
    r"classifier_exact_mismatch=([0-9]+) top1_actual=([0-9]+) "
    r"top1_oracle=([0-9]+) "
    r"report_sha256=([0-9a-f]{64})"
)
behavioral_pattern = re.compile(
    r"M8_MODE3_E05_BEHAVIORAL_COMPARE_(PASS|FAIL) checkpoints=13 "
    r"checkpoint_failures=([0-9]+) final_vectors=3 final_failures=([0-9]+) "
    r"top1=([0-9]+) "
    r"probability_sum_abs_error=[0-9]\.[0-9]{9}e[+-][0-9]{2} "
    r"report_sha256=([0-9a-f]{64})"
)

def unique(path: Path, pattern: re.Pattern[str], name: str) -> re.Match[str]:
    hits = [
        match
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if (match := pattern.fullmatch(line))
    ]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: missing/nonunique {name} marker")
    return hits[0]

endpoint_hit = unique(endpoint_log, endpoint_pattern, "endpoint-oracle")
behavioral_hit = unique(behavioral_log, behavioral_pattern, "behavioral-oracle")
endpoint = json.loads(endpoint_report.read_text(encoding="utf-8"))
behavioral = json.loads(behavioral_report.read_text(encoding="utf-8"))
endpoint_sha = hashlib.sha256(endpoint_report.read_bytes()).hexdigest()
behavioral_sha = hashlib.sha256(behavioral_report.read_bytes()).hexdigest()
if endpoint_sha != endpoint_hit.group(6) or behavioral_sha != behavioral_hit.group(5):
    raise SystemExit("FAIL: E05 numerical marker/report SHA-256 mismatch")
if endpoint.get("decision") != endpoint_hit.group(1):
    raise SystemExit("FAIL: endpoint marker/report decision mismatch")
if behavioral.get("decision") != behavioral_hit.group(1):
    raise SystemExit("FAIL: behavioral marker/report decision mismatch")
contract_ok = (
    endpoint.get("schema") == "vit-m8-mode3-e05-endpoint-arithmetic-comparison-v1"
    and behavioral.get("schema")
        == "vit-m8-mode3-e05-behavioral-golden-comparison-v1"
    and len(behavioral.get("checkpoints", [])) == 13
    and set(behavioral.get("final_outputs", {}))
        == {"final_layernorm", "logits", "probabilities"}
)
if not contract_ok:
    raise SystemExit("FAIL: E05 numerical-report contract mismatch")
strict_pass = (
    endpoint.get("decision") == "PASS"
    and endpoint.get("embedding", {}).get("exact_mismatches") == 0
    and endpoint.get("classifier", {}).get("exact_mismatches") == 0
    and endpoint.get("classifier", {}).get("actual_top1") == 879
    and behavioral.get("decision") == "PASS"
    and all(row.get("decision") == "PASS" for row in behavioral["checkpoints"])
    and all(
        row.get("decision") == "PASS"
        for row in behavioral["final_outputs"].values()
    )
    and behavioral.get("top1_and_class", {}).get("decision") == "PASS"
)
decision = "PASS" if strict_pass else "FAIL"
print(
    f"M8_MODE3_E05_NUMERICAL_REPORTS_{decision} checkpoints=13 final_vectors=3 "
    f"embedding_exact_mismatch={endpoint['embedding']['exact_mismatches']} "
    f"classifier_exact_mismatch={endpoint['classifier']['exact_mismatches']} "
    f"top1={behavioral['top1_and_class']['class_result']} "
    f"endpoint_report_sha256={endpoint_sha} behavioral_report_sha256={behavioral_sha}"
)
raise SystemExit(0 if strict_pass else 1)
PY
vit_m8_e05_report_status=("${PIPESTATUS[@]}")
set -e

vit_m8_e05_state_final="$(vit_m8_e05_source_state)"
printf '%s\n' "${vit_m8_e05_state_final}" | tee "${vit_m8_e05_source_post}"
if [[ "${vit_m8_e05_state_final}" != "${vit_m8_e05_state_before}" ]]; then
    printf '%s\n' 'FAIL: E05 source/package/golden state changed during full run' >&2
    exit 1
fi
vit_m8_e05_verify_launch_seal POST_NUMERICAL_ORACLES
vit_m8_e05_end_epoch="$(date -u +%s)"
vit_m8_e05_elapsed="$((vit_m8_e05_end_epoch - vit_m8_e05_start_epoch))"
vit_m8_e05_numerical_status="PASS"
for vit_m8_e05_status in \
    "${vit_m8_e05_endpoint_status[@]}" \
    "${vit_m8_e05_behavioral_status[@]}" \
    "${vit_m8_e05_report_status[@]}"; do
    if [[ "${vit_m8_e05_status}" != 0 ]]; then
        vit_m8_e05_numerical_status="FAIL"
    fi
done
if [[ "${vit_m8_e05_salvage}" == 1 ]]; then
    printf 'M8_MODE3_E05_SALVAGED_NUMERICAL_REPORTS_%s simulator_status=%s structural_status=FAIL overall_status=FAIL elapsed_seconds=%s run_root=%s\n' \
        "${vit_m8_e05_numerical_status}" "${vit_m8_e05_run_status[0]}" \
        "${vit_m8_e05_elapsed}" "${vit_m8_e05_run_root}" \
        | tee -a "${vit_m8_e05_run_log}"
    exit 1
fi
if [[ "${vit_m8_e05_numerical_status}" != PASS ]]; then
    printf 'FAIL: E05 numerical gates failed endpoint=%s,%s,%s behavioral=%s,%s,%s report=%s,%s\n' \
        "${vit_m8_e05_endpoint_status[@]}" \
        "${vit_m8_e05_behavioral_status[@]}" \
        "${vit_m8_e05_report_status[@]}" >&2
    exit 1
fi
printf 'M8_MODE3_E05_CONTINUOUS_NUMERICAL_RUN_PASS commands=249 checkpoints=13 top1=879 endpoint_exact=PASS behavioral=PASS elapsed_seconds=%s run_root=%s\n' \
    "${vit_m8_e05_elapsed}" "${vit_m8_e05_run_root}" \
    | tee -a "${vit_m8_e05_run_log}"
