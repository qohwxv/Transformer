#!/usr/bin/env bash
set -euo pipefail

# Separate package-v3 / execution-mode-3 real E04 gate.  BUILD_ONLY defaults
# to one so preparing this harness cannot accidentally launch the heavy
# full-dimension simulation.  A full structural run emits raw final-LN,
# logits, probability and class-result dumps.  Independent behavioral-golden
# qualification and the separately labelled exact M6 classifier oracle must
# both pass.
vit_m7_e04_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vit_m7_workspace_root="$(cd "${vit_m7_e04_root}/.." && pwd)"
cd "${vit_m7_e04_root}"

if (($# != 0)); then
    printf '%s\n' 'ERROR: mode-3 E04 runner accepts environment settings only' >&2
    exit 2
fi

for vit_m7_e04_tool in verilator timeout nice python3 tee grep mktemp mkdir date; do
    if ! command -v "${vit_m7_e04_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_m7_e04_tool}" >&2
        exit 2
    fi
done

vit_m7_e04_build_only="${VIT_M7_MODE3_E04_BUILD_ONLY:-1}"
if ! [[ "${vit_m7_e04_build_only}" =~ ^[01]$ ]]; then
    printf '%s\n' 'ERROR: VIT_M7_MODE3_E04_BUILD_ONLY must be exactly 0 or 1' >&2
    exit 2
fi
vit_m7_e04_nice="${VIT_M7_MODE3_E04_NICE:-15}"
if [[ "${vit_m7_e04_nice}" != "15" ]]; then
    printf '%s\n' 'ERROR: this low-resource gate requires nice level 15' >&2
    exit 2
fi
vit_m7_e04_build_timeout="${VIT_M7_MODE3_E04_BUILD_TIMEOUT_SECONDS:-1800}"
vit_m7_e04_run_timeout="${VIT_M7_MODE3_E04_RUN_TIMEOUT_SECONDS:-10800}"
for vit_m7_e04_value in \
    "${vit_m7_e04_build_timeout}" "${vit_m7_e04_run_timeout}"; do
    if ! [[ "${vit_m7_e04_value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' 'ERROR: mode-3 E04 timeouts must be positive integers' >&2
        exit 2
    fi
done

vit_m7_e04_run_id="${VIT_M7_MODE3_E04_RUN_ID:-m7-mode3-e04-$(
    date -u +%Y%m%dT%H%M%SZ
)-$$}"
if ! [[ "${vit_m7_e04_run_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s\n' 'ERROR: invalid VIT_M7_MODE3_E04_RUN_ID' >&2
    exit 2
fi

vit_m7_e04_default_run_root="${vit_m7_e04_root}/build/test_logs/${vit_m7_e04_run_id}"
vit_m7_e04_run_root="${VIT_M7_MODE3_E04_OUTPUT_DIR:-${vit_m7_e04_default_run_root}}"
vit_m7_e04_activation="${VIT_M7_MODE3_E04_ACTIVATION_HEX:-${vit_m7_workspace_root}/results/encoder_layer_11_step_20_layer_output_f32.hex}"

python3 - \
    "${vit_m7_workspace_root}" \
    "${vit_m7_e04_run_root}" \
    "${vit_m7_e04_activation}" <<'PY'
import hashlib
import sys
from pathlib import Path

workspace = Path(sys.argv[1]).resolve(strict=True)
run_root = Path(sys.argv[2])
activation = Path(sys.argv[3])
if not run_root.is_absolute() or not activation.is_absolute():
    raise SystemExit("ERROR: run-root and activation paths must be absolute")
try:
    run_root.resolve(strict=False).relative_to(workspace)
    activation.resolve(strict=True).relative_to(workspace)
except (OSError, ValueError) as exc:
    raise SystemExit("ERROR: mode-3 E04 paths must stay inside the workspace") from exc
if run_root.exists() or run_root.is_symlink():
    raise SystemExit(f"ERROR: refusing to reuse output directory: {run_root}")
if not activation.is_file() or activation.is_symlink():
    raise SystemExit("ERROR: activation must be a non-symlink regular file")
data = activation.read_bytes()
if hashlib.sha256(data).hexdigest() != "5cf34a472d907125dd6bdb0c7bfc5d4b5e353571978aa8ef73b9a8b17bc93359":
    raise SystemExit("ERROR: real encoder-11 activation SHA-256 mismatch")
lines = data.splitlines()
if len(lines) != 151296 or any(
    len(line) != 8 or any(chr(value) not in "0123456789abcdefABCDEF" for value in line)
    for line in lines
):
    raise SystemExit("ERROR: activation is not 151296 canonical u32 hex words")
PY

mkdir -p "${vit_m7_e04_run_root}"
vit_m7_e04_asset_dir="${vit_m7_e04_run_root}/assets"
vit_m7_e04_output_dir="${vit_m7_e04_run_root}/outputs"
vit_m7_e04_build_log="${vit_m7_e04_run_root}/build.log"
vit_m7_e04_run_log="${vit_m7_e04_run_root}/run.log"
vit_m7_e04_stage_log="${vit_m7_e04_run_root}/asset_stage.log"
vit_m7_e04_source_pre="${vit_m7_e04_run_root}/SOURCE_STATE_BEFORE.txt"
vit_m7_e04_source_post="${vit_m7_e04_run_root}/SOURCE_STATE_AFTER.txt"
vit_m7_e04_stager="${vit_m7_e04_root}/sim/end_to_end/stage_m7_mode3_real_assets.py"
if [[ ! -f "${vit_m7_e04_stager}" || -L "${vit_m7_e04_stager}" ]]; then
    printf 'ERROR: missing non-symlink mode-3 asset stager: %s\n' \
        "${vit_m7_e04_stager}" >&2
    exit 2
fi

set +e
nice -n 15 python3 "${vit_m7_e04_stager}" \
    --phase e04 \
    --output-dir "${vit_m7_e04_asset_dir}" \
    2>&1 | tee "${vit_m7_e04_stage_log}"
vit_m7_e04_stage_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e04_stage_status[0]}" != 0 || \
      "${vit_m7_e04_stage_status[1]}" != 0 ]]; then
    printf '%s\n' 'FAIL: package-v3 E04 asset staging failed' >&2
    exit 1
fi

vit_m7_e04_gamma="${vit_m7_e04_asset_dir}/final_ln_gamma_f32.hex"
vit_m7_e04_beta="${vit_m7_e04_asset_dir}/final_ln_beta_f32.hex"
vit_m7_e04_weight="${vit_m7_e04_asset_dir}/classifier_weight_packed_fp16_u32.hex"
vit_m7_e04_bias="${vit_m7_e04_asset_dir}/classifier_bias_f32.hex"
vit_m7_e04_asset_evidence="${vit_m7_e04_asset_dir}/asset_evidence.json"

python3 - \
    "${vit_m7_e04_asset_evidence}" \
    "${vit_m7_e04_gamma}" 768 \
    "${vit_m7_e04_beta}" 768 \
    "${vit_m7_e04_weight}" 384000 \
    "${vit_m7_e04_bias}" 1000 <<'PY'
import json
import sys
from pathlib import Path

evidence = Path(sys.argv[1])
if not evidence.is_file() or evidence.is_symlink():
    raise SystemExit("ERROR: asset evidence JSON is missing or a symlink")
payload = json.loads(evidence.read_text(encoding="utf-8"))
if payload.get("schema") != "vit-m7-mode3-real-assets-v2" or payload.get("phase") != "e04":
    raise SystemExit("ERROR: staged asset evidence schema/phase mismatch")
goldens = payload.get("behavioral_goldens")
if not isinstance(goldens, dict) or set(goldens) != {
    "final_layernorm", "logits", "probabilities"
}:
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
    "M7_MODE3_E04_ASSET_CONTRACT_PASS files=4 words=386536 "
    "golden_files=3 golden_words=153296"
)
PY

vit_m7_e04_source_state() {
    python3 - \
        "${vit_m7_e04_root}" \
        "${vit_m7_e04_activation}" <<'PY'
import hashlib
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve(strict=True)
workspace = root.parent.resolve(strict=True)
activation = Path(sys.argv[2]).resolve(strict=True)
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
    "tb": root / "sim/end_to_end/tb_vit_phase_e_axi_e04_mode3_real_rtl.sv",
    "filelist": root / "sim/end_to_end/vit_phase_e_axi_e04_mode3_real_rtl_verilator.f",
    "runner": root / "sim/end_to_end/run_e04_mode3_real_axi_rtl_verilator.sh",
    "stager": root / "sim/end_to_end/stage_m7_mode3_real_assets.py",
    "asset_module": root / "sim/end_to_end/m7_mode3_real_assets.py",
    "ddr_model": root / "sim/axi/vit_axi_ddr_model_128.sv",
}
goldens = {
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
for name, (path, expected) in goldens.items():
    if not path.is_file() or path.is_symlink() or digest(path) != expected:
        raise SystemExit(f"ERROR: {name} canonical pin mismatch")
print(
    "M7_MODE3_E04_SOURCE_STATE "
    f"production_sources=80 full_axi_sha256={filelist_sha} "
    f"ordered_source_sha256={ordered} "
    + " ".join(f"{name}_sha256={digest(path)}" for name, path in verification.items())
    + " " + " ".join(f"{name}_sha256={expected}" for name, (_, expected) in goldens.items())
    + f" activation_sha256={digest(activation)}"
)
PY
}

vit_m7_e04_state_before="$(vit_m7_e04_source_state)"
printf '%s\n' "${vit_m7_e04_state_before}" | tee "${vit_m7_e04_source_pre}"
printf '%s\n' \
    "M7_MODE3_E04_BUILD_CONFIG build_only=${vit_m7_e04_build_only} jobs=1 nice=15 build_timeout_seconds=${vit_m7_e04_build_timeout} run_timeout_seconds=${vit_m7_e04_run_timeout}" \
    | tee -a "${vit_m7_e04_run_log}"

vit_m7_e04_tmp="$(mktemp -d /tmp/vit_m7_mode3_e04.XXXXXX)"
trap 'rm -rf -- "${vit_m7_e04_tmp}"' EXIT
vit_m7_e04_obj="${vit_m7_e04_tmp}/obj"
vit_m7_e04_binary="vit_m7_mode3_e04_real_rtl"

set +e
timeout "${vit_m7_e04_build_timeout}s" \
    nice -n 15 verilator \
        --binary \
        --timing \
        -Wno-fatal \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        --top-module tb_vit_phase_e_axi_e04_mode3_real_rtl \
        --Mdir "${vit_m7_e04_obj}" \
        -j 1 \
        -CFLAGS "-O3" \
        -f sim/end_to_end/vit_phase_e_axi_e04_mode3_real_rtl_verilator.f \
        -o "${vit_m7_e04_binary}" \
        2>&1 | tee "${vit_m7_e04_build_log}" | tee -a "${vit_m7_e04_run_log}"
vit_m7_e04_build_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e04_build_status[0]}" != 0 || \
      "${vit_m7_e04_build_status[1]}" != 0 || \
      "${vit_m7_e04_build_status[2]}" != 0 ]]; then
    printf 'FAIL: mode-3 E04 Verilator build statuses=%s,%s,%s\n' \
        "${vit_m7_e04_build_status[@]}" >&2
    exit 1
fi
if grep -Eq '%Error([-:])|%Fatal([-:])|(^|[[:space:]])Error:' \
        "${vit_m7_e04_build_log}"; then
    printf '%s\n' 'FAIL: mode-3 E04 build log contains a severe marker' >&2
    exit 1
fi

vit_m7_e04_state_after="$(vit_m7_e04_source_state)"
printf '%s\n' "${vit_m7_e04_state_after}" | tee "${vit_m7_e04_source_post}"
if [[ "${vit_m7_e04_state_after}" != "${vit_m7_e04_state_before}" ]]; then
    printf '%s\n' 'FAIL: mode-3 E04 source/activation state changed during build' >&2
    exit 1
fi

mkdir -p "${vit_m7_e04_output_dir}"
vit_m7_e04_final_ln_dump="${vit_m7_e04_output_dir}/final_layernorm_rtl_f32.hex"
vit_m7_e04_logits_dump="${vit_m7_e04_output_dir}/logits_rtl_f32.hex"
vit_m7_e04_probabilities_dump="${vit_m7_e04_output_dir}/probabilities_rtl_f32.hex"
vit_m7_e04_class_result_dump="${vit_m7_e04_output_dir}/class_result_rtl_u32.hex"
vit_m7_e04_argv=(
    "${vit_m7_e04_obj}/${vit_m7_e04_binary}"
    "+M7_MODE3_ACTIVATION_HEX=${vit_m7_e04_activation}"
    "+M7_MODE3_FINAL_LN_GAMMA_HEX=${vit_m7_e04_gamma}"
    "+M7_MODE3_FINAL_LN_BETA_HEX=${vit_m7_e04_beta}"
    "+M7_MODE3_CLASSIFIER_WEIGHT_HEX=${vit_m7_e04_weight}"
    "+M7_MODE3_CLASSIFIER_BIAS_HEX=${vit_m7_e04_bias}"
    "+M7_MODE3_ASSET_EVIDENCE_JSON=${vit_m7_e04_asset_evidence}"
    "+M7_MODE3_FINAL_LN_DUMP=${vit_m7_e04_final_ln_dump}"
    "+M7_MODE3_LOGITS_DUMP=${vit_m7_e04_logits_dump}"
    "+M7_MODE3_PROBABILITIES_DUMP=${vit_m7_e04_probabilities_dump}"
    "+M7_MODE3_CLASS_RESULT_DUMP=${vit_m7_e04_class_result_dump}"
)

if [[ "${vit_m7_e04_build_only}" == 1 ]]; then
    set +e
    timeout 120s nice -n 15 \
        "${vit_m7_e04_argv[@]}" +M7_MODE3_PLUSARG_SMOKE_ONLY \
        2>&1 | tee -a "${vit_m7_e04_run_log}"
    vit_m7_e04_smoke_status=("${PIPESTATUS[@]}")
    set -e
    if [[ "${vit_m7_e04_smoke_status[0]}" != 0 || \
          "${vit_m7_e04_smoke_status[1]}" != 0 ]]; then
        printf 'FAIL: mode-3 E04 plusarg-smoke statuses=%s,%s\n' \
            "${vit_m7_e04_smoke_status[@]}" >&2
        exit 1
    fi
    if [[ "$(grep -Ec '^M7_MODE3_E04_PLUSARG_SMOKE_PASS checks=[1-9][0-9]* model_words=43421440 backing_words=834280 packed_classifier_words=384000 mode=3 ip=0001000d geometry=R8C2L16S8$' "${vit_m7_e04_run_log}" || true)" != 1 ]]; then
        printf '%s\n' 'FAIL: missing/nonunique exact mode-3 plusarg-smoke marker' >&2
        exit 1
    fi
    vit_m7_e04_state_smoke="$(vit_m7_e04_source_state)"
    if [[ "${vit_m7_e04_state_smoke}" != "${vit_m7_e04_state_before}" ]]; then
        printf '%s\n' 'FAIL: source/activation state changed during plusarg smoke' >&2
        exit 1
    fi
    printf 'M7_MODE3_E04_BUILD_ONLY_PASS jobs=1 nice=15 plusarg_smoke=PASS run_root=%s\n' \
        "${vit_m7_e04_run_root}" | tee -a "${vit_m7_e04_run_log}"
    exit 0
fi

printf '%s\n' 'M7_MODE3_E04_FULL_RUN_BEGIN numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES' \
    | tee -a "${vit_m7_e04_run_log}"
set +e
timeout "${vit_m7_e04_run_timeout}s" \
    nice -n 15 "${vit_m7_e04_argv[@]}" \
    2>&1 | tee -a "${vit_m7_e04_run_log}"
vit_m7_e04_run_status=("${PIPESTATUS[@]}")
set -e
if [[ "${vit_m7_e04_run_status[0]}" == 124 ]]; then
    printf '%s\n' 'INCOMPLETE: bounded mode-3 E04 full run timed out' >&2
    exit 124
fi
if [[ "${vit_m7_e04_run_status[0]}" != 0 || \
      "${vit_m7_e04_run_status[1]}" != 0 ]]; then
    printf 'FAIL: mode-3 E04 run statuses=%s,%s\n' \
        "${vit_m7_e04_run_status[@]}" >&2
    exit 1
fi

python3 - \
    "${vit_m7_e04_run_log}" \
    "${vit_m7_e04_final_ln_dump}" 151296 \
    "${vit_m7_e04_logits_dump}" 1000 \
    "${vit_m7_e04_probabilities_dump}" 1000 \
    "${vit_m7_e04_class_result_dump}" 2 <<'PY'
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
patterns = [
    r"M7_MODE3_E04_OUTPUT_STRUCTURE final_ln_words=151296 final_ln_nonfinite=0 final_ln_sentinel=0 layout_mismatch=0 logits_words=1000 logits_nonfinite=0 logits_sentinel=0 probabilities_words=1000 probabilities_nonfinite=0 probabilities_sentinel=0",
    r"M7_MODE3_E04_OUTPUT_DUMPS final_ln_words=151296 logits_words=1000 probabilities_words=1000 class_result_words=2 .+",
    r"M7_MODE3_E04_RESULT class=879 logit=[0-9a-fA-F]{8} logit_real=[-+]?[0-9]+\.[0-9]+ numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES",
    r"M7_MODE3_E04_TRAFFIC cycles=[1-9][0-9]* logical_reads=[1-9][0-9]* cache_hits=[0-9]+ external_u32=[1-9][0-9]* ar=[1-9][0-9]* r_beats=[1-9][0-9]* full_r_beats=[1-9][0-9]* narrow_r_beats=[0-9]+ linefills=[1-9][0-9]* line_hits=[0-9]+ writes=154064",
    r"VIT_PHASE_E_AXI_E04_MODE3_REAL_RTL_STRUCTURAL_PASS checks=[1-9][0-9]* cycles=[1-9][0-9]* commands=5 external_u32=[1-9][0-9]* writes=154064 model_reads=[1-9][0-9]* scratch_reads=[1-9][0-9]* class=879 logit=[0-9a-fA-F]{8} numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES",
]
positions = []
for text in patterns:
    pattern = re.compile(text)
    hits = [index for index, line in enumerate(log) if pattern.fullmatch(line)]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: mode-3 E04 marker count={len(hits)} pattern={text}")
    positions.append(hits[0])
if positions != sorted(positions):
    raise SystemExit("FAIL: mode-3 E04 terminal markers are out of order")
if any(re.search(r"(%Error|%Fatal|STRUCTURAL_FAIL|CHECK FAILED|watchdog timeout)", line) for line in log):
    raise SystemExit("FAIL: mode-3 E04 log contains a severity marker")
for index in range(2, len(sys.argv), 2):
    path = Path(sys.argv[index])
    expected = int(sys.argv[index + 1])
    words = [line.strip() for line in path.read_text(encoding="ascii").splitlines()
             if line.strip() and not line.lstrip().startswith("//")]
    if len(words) != expected or any(not re.fullmatch(r"[0-9a-fA-F]{8}", word) for word in words):
        raise SystemExit(f"FAIL: malformed RTL output dump: {path}")
print("M7_MODE3_E04_RAW_OUTPUT_GATE_PASS final_ln_words=151296 logits_words=1000 probabilities_words=1000 class_result_words=2 class=879 numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES")
PY

vit_m7_e04_behavioral_report="${vit_m7_e04_output_dir}/m7_mode3_e04_behavioral_golden_comparison.json"
vit_m7_e04_behavioral_log="${vit_m7_e04_run_root}/behavioral_golden_compare.log"
set +e
nice -n 15 python3 "${vit_m7_e04_stager}" \
    --compare-e04-behavioral-golden \
    --asset-dir "${vit_m7_e04_asset_dir}" \
    --final-ln-dump "${vit_m7_e04_final_ln_dump}" \
    --logits-dump "${vit_m7_e04_logits_dump}" \
    --probabilities-dump "${vit_m7_e04_probabilities_dump}" \
    --class-result-dump "${vit_m7_e04_class_result_dump}" \
    --report "${vit_m7_e04_behavioral_report}" \
    2>&1 | tee "${vit_m7_e04_behavioral_log}" | tee -a "${vit_m7_e04_run_log}"
vit_m7_e04_behavioral_status=("${PIPESTATUS[@]}")
set -e

vit_m7_e04_m6_report="${vit_m7_e04_output_dir}/m7_mode3_e04_m6_classifier_oracle_comparison.json"
vit_m7_e04_m6_log="${vit_m7_e04_run_root}/m6_classifier_oracle_compare.log"
set +e
nice -n 15 python3 "${vit_m7_e04_stager}" \
    --compare-e04-m6-classifier-oracle \
    --asset-dir "${vit_m7_e04_asset_dir}" \
    --final-ln-dump "${vit_m7_e04_final_ln_dump}" \
    --logits-dump "${vit_m7_e04_logits_dump}" \
    --report "${vit_m7_e04_m6_report}" \
    --abs-tolerance 0 \
    --rel-tolerance 0 \
    2>&1 | tee "${vit_m7_e04_m6_log}" | tee -a "${vit_m7_e04_run_log}"
vit_m7_e04_m6_status=("${PIPESTATUS[@]}")
set -e

vit_m7_e04_state_final="$(vit_m7_e04_source_state)"
if [[ "${vit_m7_e04_state_final}" != "${vit_m7_e04_state_before}" ]]; then
    printf '%s\n' 'FAIL: mode-3 E04 source/activation/golden state changed during full run' >&2
    exit 1
fi
if [[ "${vit_m7_e04_behavioral_status[0]}" != 0 || \
      "${vit_m7_e04_behavioral_status[1]}" != 0 || \
      "${vit_m7_e04_behavioral_status[2]}" != 0 || \
      "${vit_m7_e04_m6_status[0]}" != 0 || \
      "${vit_m7_e04_m6_status[1]}" != 0 || \
      "${vit_m7_e04_m6_status[2]}" != 0 ]]; then
    printf 'FAIL: behavioral statuses=%s,%s,%s M6 statuses=%s,%s,%s\n' \
        "${vit_m7_e04_behavioral_status[@]}" \
        "${vit_m7_e04_m6_status[@]}" >&2
    exit 1
fi

python3 - \
    "${vit_m7_e04_behavioral_log}" \
    "${vit_m7_e04_behavioral_report}" \
    "${vit_m7_e04_m6_log}" \
    "${vit_m7_e04_m6_report}" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

behavioral_log = Path(sys.argv[1])
behavioral_report = Path(sys.argv[2])
m6_log = Path(sys.argv[3])
m6_report = Path(sys.argv[4])
float_re = r"[-+]?[0-9]+\.[0-9]+[eE][-+][0-9]+"
behavioral_pattern = re.compile(
    r"M7_MODE3_E04_BEHAVIORAL_GOLDEN_COMPARE_PASS "
    r"final_ln=151296 final_ln_exact_mismatch=[0-9]+ "
    r"final_ln_tolerance_failures=0 final_ln_max_abs=" + float_re +
    r" logits=1000 logits_exact_mismatch=[0-9]+ "
    r"logits_tolerance_failures=0 logits_max_abs=" + float_re +
    r" probabilities=1000 probabilities_exact_mismatch=[0-9]+ "
    r"probabilities_tolerance_failures=0 probabilities_max_abs=" + float_re +
    r" expected_top1=879 logits_top1_actual=879 logits_top1_golden=879 "
    r"probabilities_top1_actual=879 probabilities_top1_golden=879 "
    r"class_result=879 class_logit_matches_dump=1 "
    r"report_sha256=([0-9a-f]{64})"
)
m6_pattern = re.compile(
    r"M7_MODE3_E04_M6_CLASSIFIER_ORACLE_COMPARE_PASS "
    r"logits=1000 exact_mismatch=0 "
    r"tolerance_failures=0 abs_tolerance=0\.000000000e\+00 "
    r"rel_tolerance=0\.000000000e\+00 max_abs=0\.000000000e\+00 "
    r"mean_abs=0\.000000000e\+00 top1_actual=879 "
    r"top1_oracle=879 report_sha256=([0-9a-f]{64})"
)
def unique(pattern: re.Pattern[str], path: Path, description: str):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    hits = [match for line in lines if (match := pattern.fullmatch(line))]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: missing/nonunique {description} PASS marker")
    return hits[0]

behavioral_hit = unique(
    behavioral_pattern, behavioral_log, "behavioral-golden"
)
behavioral = json.loads(behavioral_report.read_text(encoding="utf-8"))
top1 = behavioral.get("top1_and_class", {})
if (
    behavioral.get("schema") !=
        "vit-m7-mode3-e04-behavioral-golden-comparison-v1"
    or behavioral.get("decision") != "PASS"
    or behavioral.get("final_layernorm", {}).get("words") != 151296
    or behavioral.get("final_layernorm", {}).get("tolerance_failures") != 0
    or behavioral.get("logits", {}).get("words") != 1000
    or behavioral.get("logits", {}).get("tolerance_failures") != 0
    or behavioral.get("probabilities", {}).get("words") != 1000
    or behavioral.get("probabilities", {}).get("tolerance_failures") != 0
    or any(top1.get(name) != 879 for name in (
        "expected", "actual_logits", "golden_logits",
        "actual_probabilities", "golden_probabilities", "class_result",
    ))
    or top1.get("class_result_logit_matches_dump") is not True
):
    raise SystemExit("FAIL: behavioral-golden report contract mismatch")
behavioral_sha = hashlib.sha256(behavioral_report.read_bytes()).hexdigest()
if behavioral_sha != behavioral_hit.group(1):
    raise SystemExit("FAIL: behavioral marker/report SHA-256 mismatch")

m6_hit = unique(m6_pattern, m6_log, "M6 classifier-oracle")
m6 = json.loads(m6_report.read_text(encoding="utf-8"))
comparison = m6.get("comparison", {})
if (
    m6.get("schema") !=
        "vit-m7-mode3-e04-m6-classifier-oracle-comparison-v1"
    or m6.get("decision") != "PASS"
    or comparison.get("words") != 1000
    or comparison.get("exact_mismatches") != 0
    or comparison.get("tolerance_failures") != 0
    or comparison.get("actual_top1") != 879
    or comparison.get("oracle_top1") != 879
):
    raise SystemExit("FAIL: M6 classifier-oracle report contract mismatch")
m6_sha = hashlib.sha256(m6_report.read_bytes()).hexdigest()
if m6_sha != m6_hit.group(1):
    raise SystemExit("FAIL: M6 oracle marker/report SHA-256 mismatch")
print(
    "M7_MODE3_E04_BEHAVIORAL_REPORT_PASS final_ln=151296 logits=1000 "
    "probabilities=1000 top1=879 class=879 "
    f"report_sha256={behavioral_sha}"
)
print(
    "M7_MODE3_E04_M6_CLASSIFIER_ORACLE_REPORT_PASS logits=1000 "
    f"exact_mismatch=0 top1=879 report_sha256={m6_sha}"
)
PY

printf 'M7_MODE3_E04_NUMERICAL_RUN_PASS run_root=%s behavioral_report=%s m6_classifier_report=%s final_ln_tolerance_failures=0 logits_tolerance_failures=0 probabilities_tolerance_failures=0 top1=879 class=879 m6_logits_exact=1000\n' \
    "${vit_m7_e04_run_root}" "${vit_m7_e04_behavioral_report}" \
    "${vit_m7_e04_m6_report}" \
    | tee -a "${vit_m7_e04_run_log}"
