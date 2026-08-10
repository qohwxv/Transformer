#!/usr/bin/env bash
set -euo pipefail

# Separate package-v3 / execution-mode-3 real E01 gate.  BUILD_ONLY defaults
# to one so preparing this harness cannot accidentally launch the heavy
# full-dimension simulation.  A full structural run emits one raw 197x768
# embedding dump.  Independent FP32-quality and exact M6/current-adder gates
# must both pass before the runner emits its terminal numerical PASS.
vit_m7_e01_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vit_m7_workspace_root="$(cd "${vit_m7_e01_root}/.." && pwd)"
cd "${vit_m7_e01_root}"

if (($# != 0)); then
    printf '%s\n' 'ERROR: mode-3 E01 runner accepts environment settings only' >&2
    exit 2
fi

for vit_m7_e01_tool in verilator timeout nice python3 tee grep mktemp mkdir date; do
    if ! command -v "${vit_m7_e01_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_m7_e01_tool}" >&2
        exit 2
    fi
done

vit_m7_e01_build_only="${VIT_M7_MODE3_E01_BUILD_ONLY:-1}"
if ! [[ "${vit_m7_e01_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' 'ERROR: VIT_M7_MODE3_E01_BUILD_ONLY must be exactly 0 or 1' >&2
    exit 2
fi
vit_m7_e01_nice="${VIT_M7_MODE3_E01_NICE:-15}"
if [[ "${vit_m7_e01_nice}" != "15" ]]; then
    printf '%s\n' 'ERROR: this low-resource gate requires nice level 15' >&2
    exit 2
fi
vit_m7_e01_build_timeout="${VIT_M7_MODE3_E01_BUILD_TIMEOUT_SECONDS:-1800}"
vit_m7_e01_run_timeout="${VIT_M7_MODE3_E01_RUN_TIMEOUT_SECONDS:-28800}"
vit_m7_e01_oracle_timeout="${VIT_M7_MODE3_E01_ORACLE_TIMEOUT_SECONDS:-7200}"
for vit_m7_e01_value in \
    "${vit_m7_e01_build_timeout}" "${vit_m7_e01_run_timeout}" \
    "${vit_m7_e01_oracle_timeout}"; do
    if ! [[ "${vit_m7_e01_value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' 'ERROR: mode-3 E01 timeouts must be positive integers' >&2
        exit 2
    fi
done

vit_m7_e01_run_id="${VIT_M7_MODE3_E01_RUN_ID:-m7-mode3-e01-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[ "${vit_m7_e01_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s\n' 'ERROR: invalid VIT_M7_MODE3_E01_RUN_ID' >&2
    exit 2
fi

vit_m7_e01_default_run_root="${vit_m7_e01_root}/build/test_logs/${vit_m7_e01_run_id}"
vit_m7_e01_run_root="${VIT_M7_MODE3_E01_OUTPUT_DIR:-${vit_m7_e01_default_run_root}}"

python3 - \
    "${vit_m7_workspace_root}" \
    "${vit_m7_e01_run_root}" <<'PY'
import sys
from pathlib import Path

workspace = Path(sys.argv[1]).resolve(strict=True)
run_root = Path(sys.argv[2])
if not run_root.is_absolute():
    raise SystemExit("ERROR: run-root path must be absolute")
try:
    run_root.resolve(strict=False).relative_to(workspace)
except (OSError, ValueError) as exc:
    raise SystemExit("ERROR: mode-3 E01 run root must stay inside the workspace") from exc
if run_root.exists() or run_root.is_symlink():
    raise SystemExit(f"ERROR: refusing to reuse output directory: {run_root}")
PY

mkdir -p "${vit_m7_e01_run_root}"
vit_m7_e01_asset_dir="${vit_m7_e01_run_root}/assets"
vit_m7_e01_output_dir="${vit_m7_e01_run_root}/outputs"
vit_m7_e01_build_log="${vit_m7_e01_run_root}/build.log"
vit_m7_e01_run_log="${vit_m7_e01_run_root}/run.log"
vit_m7_e01_stage_log="${vit_m7_e01_run_root}/asset_stage.log"
vit_m7_e01_source_pre="${vit_m7_e01_run_root}/SOURCE_STATE_BEFORE.txt"
vit_m7_e01_source_post="${vit_m7_e01_run_root}/SOURCE_STATE_AFTER.txt"
vit_m7_e01_source_final="${vit_m7_e01_run_root}/SOURCE_STATE_FINAL.txt"
vit_m7_e01_stager="${vit_m7_e01_root}/sim/end_to_end/stage_m7_mode3_real_assets.py"
if [[ ! -f "${vit_m7_e01_stager}" || -L "${vit_m7_e01_stager}" ]]; then
    printf 'ERROR: missing non-symlink mode-3 asset stager: %s\n' \
        "${vit_m7_e01_stager}" >&2
    exit 2
fi

set +e
nice -n 15 python3 "${vit_m7_e01_stager}" \
    --phase e01 \
    --output-dir "${vit_m7_e01_asset_dir}" \
    2>&1 | tee "${vit_m7_e01_stage_log}"
vit_m7_e01_stage_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e01_stage_status[0]}" != 0 || \
      "${vit_m7_e01_stage_status[1]}" != 0 ]]; then
    printf '%s\n' 'FAIL: package-v3 E01 asset staging failed' >&2
    exit 1
fi

vit_m7_e01_input="${vit_m7_e01_asset_dir}/prepared_input_f32.hex"
vit_m7_e01_weight="${vit_m7_e01_asset_dir}/patch_weight_packed_fp16_u32.hex"
vit_m7_e01_bias="${vit_m7_e01_asset_dir}/patch_bias_f32.hex"
vit_m7_e01_cls="${vit_m7_e01_asset_dir}/cls_token_f32.hex"
vit_m7_e01_position="${vit_m7_e01_asset_dir}/position_f32.hex"
vit_m7_e01_golden="${vit_m7_e01_asset_dir}/embedding_golden_f32.hex"
vit_m7_e01_asset_evidence="${vit_m7_e01_asset_dir}/asset_evidence.json"

python3 - \
    "${vit_m7_e01_asset_evidence}" \
    "${vit_m7_e01_weight}" 294912 \
    "${vit_m7_e01_bias}" 768 \
    "${vit_m7_e01_cls}" 768 \
    "${vit_m7_e01_position}" 151296 \
    "${vit_m7_e01_input}" 150528 \
    "${vit_m7_e01_golden}" 151296 <<'PY'
import json
import sys
from pathlib import Path

evidence = Path(sys.argv[1])
if not evidence.is_file() or evidence.is_symlink():
    raise SystemExit("ERROR: asset evidence JSON is missing or a symlink")
payload = json.loads(evidence.read_text(encoding="utf-8"))
if payload.get("schema") != "vit-m7-mode3-real-assets-v2" or payload.get("phase") != "e01":
    raise SystemExit("ERROR: staged asset evidence schema/phase mismatch")
goldens = payload.get("behavioral_goldens")
if not isinstance(goldens, dict) or set(goldens) != {"embedding"}:
    raise SystemExit("ERROR: staged evidence lacks exact behavioral-golden pins")
for index in range(2, len(sys.argv), 2):
    path = Path(sys.argv[index])
    expected = int(sys.argv[index + 1])
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"ERROR: staged asset is missing or a symlink: {path}")
    lines = path.read_bytes().splitlines()
    if len(lines) != expected or any(
        len(line) != 8 or any(chr(value) not in "0123456789abcdef" for value in line)
        for line in lines
    ):
        raise SystemExit(f"ERROR: noncanonical staged asset: {path}")
print(
    "M7_MODE3_E01_ASSET_CONTRACT_PASS files=6 words=749568 "
    "model_words=447744 input_words=150528 golden_words=151296"
)
PY

vit_m7_e01_source_state() {
    python3 - \
        "${vit_m7_e01_root}" <<'PY'
import hashlib
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve(strict=True)
workspace = root.parent.resolve(strict=True)
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
        raise SystemExit(f"ERROR: unsafe production source path: {text}")
    sources.append(text)
if len(sources) != 80 or len(set(sources)) != 80:
    raise SystemExit("ERROR: production closure is not exactly 80/80 unique sources")
records = []
for relative in sources:
    path = root / relative
    if not path.is_file():
        raise SystemExit(f"ERROR: missing production source: {relative}")
    records.append(f"{digest(path)}  {relative}\n")
ordered = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
filelist_sha = digest(filelist)
if filelist_sha != "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524":
    raise SystemExit("ERROR: full_axi.f identity changed")
if ordered != "db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e":
    raise SystemExit("ERROR: production ordered-source identity changed")
verification = {
    "tb": root / "sim/end_to_end/tb_vit_phase_e_axi_e01_mode3_real_rtl.sv",
    "filelist": root / "sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f",
    "runner": root / "sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh",
    "stager": root / "sim/end_to_end/stage_m7_mode3_real_assets.py",
    "asset_module": root / "sim/end_to_end/m7_mode3_real_assets.py",
    "asset_tests": root / "sim/end_to_end/tests/test_m7_mode3_real_assets.py",
    "ddr_model": root / "sim/axi/vit_axi_ddr_model_128.sv",
}
pins = {
    "prepared_input": (
        workspace / "build/model_package/v3_blocked_b_fp16_mixed/prepared_input.bin",
        "3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54",
    ),
    "golden_embedding": (
        workspace / "results/embedding_step_06_hidden_states_f32.hex",
        "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18",
    ),
}
for name, (path, expected) in pins.items():
    if not path.is_file() or path.is_symlink() or digest(path) != expected:
        raise SystemExit(f"ERROR: {name} canonical pin mismatch")
print(
    "M7_MODE3_E01_SOURCE_STATE "
    f"production_sources=80 full_axi_sha256={filelist_sha} "
    f"ordered_source_sha256={ordered} "
    + " ".join(f"{name}_sha256={digest(path)}" for name, path in verification.items())
    + " " + " ".join(f"{name}_sha256={expected}" for name, (_, expected) in pins.items())
)
PY
}

vit_m7_e01_state_before="$(vit_m7_e01_source_state)"
printf '%s\n' "${vit_m7_e01_state_before}" | tee "${vit_m7_e01_source_pre}"

vit_m7_e01_verify_final_state() {
    local vit_m7_e01_live_state
    vit_m7_e01_live_state="$(vit_m7_e01_source_state)"
    printf '%s\n' "${vit_m7_e01_live_state}" \
        | tee "${vit_m7_e01_source_final}"
    if [[ "${vit_m7_e01_live_state}" != "${vit_m7_e01_state_before}" ]]; then
        printf '%s\n' \
            'FAIL: mode-3 E01 source/pinned-asset final state changed' >&2
        return 1
    fi
}
printf '%s\n' \
    "M7_MODE3_E01_BUILD_CONFIG build_only=${vit_m7_e01_build_only} jobs=1 nice=15 build_timeout_seconds=${vit_m7_e01_build_timeout} run_timeout_seconds=${vit_m7_e01_run_timeout} oracle_timeout_seconds=${vit_m7_e01_oracle_timeout}" \
    | tee -a "${vit_m7_e01_run_log}"

vit_m7_e01_tmp="$(mktemp -d /tmp/vit_m7_mode3_e01.XXXXXX)"
trap 'rm -rf -- "${vit_m7_e01_tmp}"' EXIT
vit_m7_e01_obj="${vit_m7_e01_tmp}/obj"
vit_m7_e01_binary="vit_m7_mode3_e01_real_rtl"

set +e
timeout "${vit_m7_e01_build_timeout}s" \
    nice -n 15 verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e01_mode3_real_rtl \
        --Mdir "${vit_m7_e01_obj}" \
        -j 1 \
        -CFLAGS "-O3" \
        -f sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f \
        -o "${vit_m7_e01_binary}" \
        2>&1 | tee "${vit_m7_e01_build_log}" | tee -a "${vit_m7_e01_run_log}"
vit_m7_e01_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e01_build_status[0]}" == 124 ]]; then
    vit_m7_e01_verify_final_state
    printf '%s\n' \
        'M7_MODE3_E01_BUILD_INCOMPLETE reason=VERILATOR_BUILD_TIMEOUT' \
        | tee -a "${vit_m7_e01_run_log}" >&2
    exit 124
fi
if [[ "${vit_m7_e01_build_status[0]}" != 0 || \
      "${vit_m7_e01_build_status[1]}" != 0 || \
      "${vit_m7_e01_build_status[2]}" != 0 ]]; then
    printf 'FAIL: mode-3 E01 Verilator build statuses=%s,%s,%s\n' \
        "${vit_m7_e01_build_status[@]}" >&2
    exit 1
fi
if grep -Eq '%Error([-:])|%Fatal([-:])|(^|[[:space:]])Error:' \
        "${vit_m7_e01_build_log}"; then
    printf '%s\n' 'FAIL: mode-3 E01 build log contains a severe marker' >&2
    exit 1
fi

vit_m7_e01_state_after="$(vit_m7_e01_source_state)"
printf '%s\n' "${vit_m7_e01_state_after}" | tee "${vit_m7_e01_source_post}"
if [[ "${vit_m7_e01_state_after}" != "${vit_m7_e01_state_before}" ]]; then
    printf '%s\n' 'FAIL: mode-3 E01 source/pinned-asset state changed during build' >&2
    exit 1
fi

mkdir -p "${vit_m7_e01_output_dir}"
vit_m7_e01_embedding_dump="${vit_m7_e01_output_dir}/embedding_rtl_f32.hex"
vit_m7_e01_argv=(
    "${vit_m7_e01_obj}/${vit_m7_e01_binary}"
    "+M7_MODE3_E01_PREPARED_INPUT_HEX=${vit_m7_e01_input}"
    "+M7_MODE3_E01_PATCH_WEIGHT_HEX=${vit_m7_e01_weight}"
    "+M7_MODE3_E01_PATCH_BIAS_HEX=${vit_m7_e01_bias}"
    "+M7_MODE3_E01_CLS_HEX=${vit_m7_e01_cls}"
    "+M7_MODE3_E01_POSITION_HEX=${vit_m7_e01_position}"
    "+M7_MODE3_E01_EMBEDDING_GOLDEN_HEX=${vit_m7_e01_golden}"
    "+M7_MODE3_E01_ASSET_EVIDENCE_JSON=${vit_m7_e01_asset_evidence}"
    "+M7_MODE3_E01_EMBEDDING_DUMP=${vit_m7_e01_embedding_dump}"
)

if [[ "${vit_m7_e01_build_only}" == 1 ]]; then
    set +e
    timeout 120s nice -n 15 \
        "${vit_m7_e01_argv[@]}" +M7_MODE3_E01_PLUSARG_SMOKE_ONLY \
        2>&1 | tee -a "${vit_m7_e01_run_log}"
    vit_m7_e01_smoke_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m7_e01_smoke_status[0]}" != 0 || \
          "${vit_m7_e01_smoke_status[1]}" != 0 ]]; then
        printf 'FAIL: mode-3 E01 plusarg-smoke statuses=%s,%s\n' \
            "${vit_m7_e01_smoke_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec '^M7_MODE3_E01_PLUSARG_SMOKE_PASS checks=[1-9][0-9]* staged_files=6 staged_words=749568 model_words=43421440 backing_words=447744 packed_patch_words=294912 input_words=150528 golden_words=151296 mode=3 job_config=00041001 ip=0001000d geometry=R8C2L16S8$' "${vit_m7_e01_run_log}" || true)" != 1 ]]; then
        printf '%s\n' 'FAIL: missing/nonunique exact mode-3 plusarg-smoke marker' >&2
        exit 1
    fi
    vit_m7_e01_state_smoke="$(vit_m7_e01_source_state)"
    if [[ "${vit_m7_e01_state_smoke}" != "${vit_m7_e01_state_before}" ]]; then
        printf '%s\n' 'FAIL: source/pinned-asset state changed during plusarg smoke' >&2
        exit 1
    fi
    vit_m7_e01_verify_final_state
    printf 'M7_MODE3_E01_BUILD_ONLY_PASS jobs=1 nice=15 plusarg_smoke=PASS run_root=%s\n' \
        "${vit_m7_e01_run_root}" | tee -a "${vit_m7_e01_run_log}"
    exit 0
fi

printf '%s\n' 'M7_MODE3_E01_FULL_RUN_BEGIN numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES' \
    | tee -a "${vit_m7_e01_run_log}"
set +e
timeout "${vit_m7_e01_run_timeout}s" \
    nice -n 15 "${vit_m7_e01_argv[@]}" \
    2>&1 | tee -a "${vit_m7_e01_run_log}"
vit_m7_e01_run_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e01_run_status[0]}" == 124 ]]; then
    vit_m7_e01_verify_final_state
    printf '%s\n' \
        'M7_MODE3_E01_FULL_RUN_INCOMPLETE reason=RTL_SIMULATION_TIMEOUT numerical_status=INCOMPLETE' \
        | tee -a "${vit_m7_e01_run_log}" >&2
    exit 124
fi
if [[ "${vit_m7_e01_run_status[0]}" != 0 || \
      "${vit_m7_e01_run_status[1]}" != 0 ]]; then
    printf 'FAIL: mode-3 E01 run statuses=%s,%s\n' \
        "${vit_m7_e01_run_status[@]}" >&2
    exit 1
fi

python3 - \
    "${vit_m7_e01_run_log}" \
    "${vit_m7_e01_embedding_dump}" <<'PY'
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
patterns = [
    r"M7_MODE3_E01_BIAS_CACHE lookups=38400 hits=36866 misses=1534 two_pass_refetch=766",
    r"M7_MODE3_E01_TRAFFIC external_u32=15351550 model_reads=14899198 input_reads=150528 scratch_reads=301824 ar=1243870 r_beats=4065406 full_r_beats=3762048 narrow_r_beats=303358 linefills=940512 line_hits=14107680 writes=453120 maxout=1",
    r"M7_MODE3_E01_M7_STATUS raw=00071bf2 running=0 snapshot=1 overflow=0 error=0 lc=1 cs=1 three=1 both_claimed=1 claim_mask=3 bank_max=2 fifo_max=1 feeder_wait=1 result_bp=1 empty_wait=1 full_wait=0",
    r"M7_MODE3_E01_M7_COUNTERS terms=117964800 disabled=2359296 enabled=115605504 dots=19200 results=19200 commits=921600 claims=921600 releases=921600 bank_max=2 fifo_enqueue=19200 fifo_dequeue=19200 fifo_max=1 load=75268889 compute=15033600 store=1380096 union=75864134 load_compute=14438400 compute_store=307184 load_store=1380051 three_way=307184",
    r"M7_MODE3_E01_OUTPUT_STRUCTURE embedding_words=151296 embedding_nonfinite=0 embedding_sentinel=0 hidden_b_modified=0",
    r"M7_MODE3_E01_OUTPUT_DUMP embedding_words=151296 embedding=.+ numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES",
    r"VIT_PHASE_E_AXI_E01_MODE3_REAL_RTL_STRUCTURAL_PASS checks=266 cycles=82215315 commands=4 external_u32=15351550 writes=453120 model_reads=14899198 input_reads=150528 scratch_reads=301824 numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES",
]
positions = []
for text in patterns:
    pattern = re.compile(text)
    hits = [index for index, line in enumerate(log) if pattern.fullmatch(line)]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: mode-3 E01 marker count={len(hits)} pattern={text}")
    positions.append(hits[0])
if positions != sorted(positions):
    raise SystemExit("FAIL: mode-3 E01 structural markers are out of order")
if any(re.search(
    r"(%Error|%Fatal|STRUCTURAL_FAIL|CHECK FAILED|watchdog timeout)", line
) for line in log):
    raise SystemExit("FAIL: mode-3 E01 log contains a severity marker")
path = Path(sys.argv[2])
words = [
    line.strip()
    for line in path.read_text(encoding="ascii").splitlines()
    if line.strip() and not line.lstrip().startswith("//")
]
if len(words) != 151296 or any(
    not re.fullmatch(r"[0-9a-fA-F]{8}", word) for word in words
):
    raise SystemExit(f"FAIL: malformed E01 RTL embedding dump: {path}")
print(
    "M7_MODE3_E01_RAW_OUTPUT_GATE_PASS embedding_words=151296 "
    "commands=4 external_u32=15351550 writes=453120 "
    "numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES"
)
PY

vit_m7_e01_m6_report="${vit_m7_e01_output_dir}/m7_mode3_e01_m6_current_adder_oracle_comparison.json"
vit_m7_e01_m6_log="${vit_m7_e01_run_root}/m6_current_adder_oracle_compare.log"
set +e
timeout "${vit_m7_e01_oracle_timeout}s" nice -n 15 \
    python3 "${vit_m7_e01_stager}" \
    --compare-e01-m6-current-adder-oracle \
    --asset-dir "${vit_m7_e01_asset_dir}" \
    --embedding-dump "${vit_m7_e01_embedding_dump}" \
    --report "${vit_m7_e01_m6_report}" \
    2>&1 | tee "${vit_m7_e01_m6_log}" | tee -a "${vit_m7_e01_run_log}"
vit_m7_e01_m6_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e01_m6_status[0]}" == 124 ]]; then
    vit_m7_e01_verify_final_state
    printf '%s\n' \
        'M7_MODE3_E01_FULL_RUN_INCOMPLETE reason=M6_CURRENT_ADDER_ORACLE_TIMEOUT numerical_status=INCOMPLETE' \
        | tee -a "${vit_m7_e01_run_log}" >&2
    exit 124
fi
if [[ "${vit_m7_e01_m6_status[0]}" != 0 || \
      "${vit_m7_e01_m6_status[1]}" != 0 || \
      "${vit_m7_e01_m6_status[2]}" != 0 ]]; then
    printf 'FAIL: E01 M6/current-adder statuses=%s,%s,%s\n' \
        "${vit_m7_e01_m6_status[@]}" >&2
    exit 1
fi

vit_m7_e01_behavioral_report="${vit_m7_e01_output_dir}/m7_mode3_e01_behavioral_golden_comparison.json"
vit_m7_e01_behavioral_log="${vit_m7_e01_run_root}/behavioral_golden_compare.log"
set +e
timeout "${vit_m7_e01_oracle_timeout}s" nice -n 15 \
    python3 "${vit_m7_e01_stager}" \
    --compare-e01-behavioral-golden \
    --asset-dir "${vit_m7_e01_asset_dir}" \
    --embedding-dump "${vit_m7_e01_embedding_dump}" \
    --report "${vit_m7_e01_behavioral_report}" \
    2>&1 | tee "${vit_m7_e01_behavioral_log}" | tee -a "${vit_m7_e01_run_log}"
vit_m7_e01_behavioral_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e01_behavioral_status[0]}" == 124 ]]; then
    vit_m7_e01_verify_final_state
    printf '%s\n' \
        'M7_MODE3_E01_FULL_RUN_INCOMPLETE reason=BEHAVIORAL_ORACLE_TIMEOUT numerical_status=INCOMPLETE' \
        | tee -a "${vit_m7_e01_run_log}" >&2
    exit 124
fi
if [[ "${vit_m7_e01_behavioral_status[0]}" != 0 || \
      "${vit_m7_e01_behavioral_status[1]}" != 0 || \
      "${vit_m7_e01_behavioral_status[2]}" != 0 ]]; then
    printf 'FAIL: E01 behavioral-golden statuses=%s,%s,%s\n' \
        "${vit_m7_e01_behavioral_status[@]}" >&2
    exit 1
fi

vit_m7_e01_verify_final_state

python3 - \
    "${vit_m7_e01_m6_log}" \
    "${vit_m7_e01_m6_report}" \
    "${vit_m7_e01_behavioral_log}" \
    "${vit_m7_e01_behavioral_report}" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

m6_log = Path(sys.argv[1])
m6_report = Path(sys.argv[2])
behavioral_log = Path(sys.argv[3])
behavioral_report = Path(sys.argv[4])
float_re = r"[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+"
m6_pattern = re.compile(
    r"M7_MODE3_E01_M6_CURRENT_ADDER_ORACLE_COMPARE_PASS "
    r"embedding=151296 exact_mismatch=0 actual_nonfinite=0 "
    r"oracle_nonfinite=0 oracle_sha256=([0-9a-f]{64}) "
    r"report_sha256=([0-9a-f]{64})"
)
behavioral_pattern = re.compile(
    r"M7_MODE3_E01_BEHAVIORAL_GOLDEN_COMPARE_PASS "
    r"embedding=151296 exact_mismatch=[0-9]+ tolerance_failures=0 "
    r"abs_tolerance=5\.000000000e-03 max_abs=" + float_re +
    r" mean_abs=" + float_re + r" report_sha256=([0-9a-f]{64})"
)

def unique(pattern: re.Pattern[str], path: Path, description: str):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    hits = [match for line in lines if (match := pattern.fullmatch(line))]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: missing/nonunique {description} PASS marker")
    return hits[0]

m6_hit = unique(m6_pattern, m6_log, "M6/current-adder")
m6 = json.loads(m6_report.read_text(encoding="utf-8"))
m6_comparison = m6.get("comparison", {})
if (
    m6.get("schema") !=
        "vit-m7-mode3-e01-m6-current-adder-oracle-comparison-v1"
    or m6.get("decision") != "PASS"
    or m6_comparison.get("words") != 151296
    or m6_comparison.get("exact_mismatches") != 0
    or m6_comparison.get("actual_nonfinite") != 0
    or m6_comparison.get("oracle_nonfinite") != 0
    or m6_comparison.get("oracle_readmemh_sha256") != m6_hit.group(1)
):
    raise SystemExit("FAIL: E01 M6/current-adder report contract mismatch")
m6_sha = hashlib.sha256(m6_report.read_bytes()).hexdigest()
if m6_sha != m6_hit.group(2):
    raise SystemExit("FAIL: E01 M6 marker/report SHA-256 mismatch")

behavioral_hit = unique(
    behavioral_pattern, behavioral_log, "behavioral-golden"
)
behavioral = json.loads(behavioral_report.read_text(encoding="utf-8"))
quality = behavioral.get("embedding", {})
if (
    behavioral.get("schema") !=
        "vit-m7-mode3-e01-behavioral-golden-comparison-v1"
    or behavioral.get("decision") != "PASS"
    or quality.get("words") != 151296
    or quality.get("tolerance_failures") != 0
    or quality.get("actual_nonfinite") != 0
    or quality.get("golden_nonfinite") != 0
    or quality.get("abs_tolerance") != 0.005
):
    raise SystemExit("FAIL: E01 behavioral-golden report contract mismatch")
behavioral_sha = hashlib.sha256(behavioral_report.read_bytes()).hexdigest()
if behavioral_sha != behavioral_hit.group(1):
    raise SystemExit("FAIL: E01 behavioral marker/report SHA-256 mismatch")
print(
    "M7_MODE3_E01_M6_CURRENT_ADDER_REPORT_PASS embedding=151296 "
    f"exact_mismatch=0 oracle_sha256={m6_hit.group(1)} "
    f"report_sha256={m6_sha}"
)
print(
    "M7_MODE3_E01_BEHAVIORAL_REPORT_PASS embedding=151296 "
    "tolerance_failures=0 abs_tolerance=5.000000000e-03 "
    f"report_sha256={behavioral_sha}"
)
PY

printf 'M7_MODE3_E01_NUMERICAL_RUN_PASS run_root=%s m6_current_adder_report=%s behavioral_report=%s m6_current_adder_exact=151296 behavioral_tolerance_failures=0 behavioral_abs_tolerance=5.000000000e-03\n' \
    "${vit_m7_e01_run_root}" "${vit_m7_e01_m6_report}" \
    "${vit_m7_e01_behavioral_report}" \
    | tee -a "${vit_m7_e01_run_log}"
