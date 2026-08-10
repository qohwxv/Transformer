#!/usr/bin/env bash
set -euo pipefail

vit_bundle_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
cd "${vit_bundle_root}"

for vit_bundle_tool in \
    sha256sum awk cmp find grep python3 readlink sort wc; do
    if ! command -v "${vit_bundle_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_bundle_tool}"
        exit 1
    fi
done

if [[ ! -s MANIFEST.sha256 ]]; then
    printf '%s\n' 'ERROR: MANIFEST.sha256 is missing or empty'
    exit 1
fi
LC_ALL=C sha256sum --check --strict MANIFEST.sha256

# A copied parent manifest can validate all old paths while omitting every M5
# input. Require one manifest entry for each M5 contract/flow source and later
# require every ordered production source as well.
vit_bundle_m5_required=(
    BUNDLE_INFO.json
    README_SERVER.md
    docs/M5_AXI128_CONTRACT.md
    docs/PERF_PROFILE_ABI_V1_2.json
    docs/PERF_PROFILE_ABI_V1_6.json
    docs/PHASE_E_AXI_WRAPPER.md
    filelists/full_axi.f
    filelists/vit_phase_e_axi_wrapper_synth.f
    run/00_verify_bundle.sh
    run/10_xsim_axi_smoke.sh
    run/90_collect_results.sh
    run/run_all.sh
    scripts/server/00_preflight.tcl
    scripts/server/20_run_ooc_synth.tcl
    scripts/server/30_create_clean_project_and_bd.tcl
    scripts/server/40_run_board_synth.tcl
    scripts/server/50_run_board_impl.tcl
    scripts/server/vivado_server_common.tcl
    scripts/vivado/create_vit_system_bd.tcl
    scripts/vivado/vit_project_common.tcl
    rtl/axi/control/vit_phase_e_m5_axi_counters.sv
    rtl/axi/control/vit_phase_e_profile_counters.sv
    rtl/axi/control/vit_axi_lite_control_regs.sv
    rtl/axi/memory/vit_phase_e_axi_mem_adapter.sv
    rtl/axi/vit_phase_e_axi_wrapper.sv
    rtl/core/vit_phase_e_memory_frontend.sv
    rtl/core/vit_phase_e_engine_top.sv
    rtl/core/vit_phase_e_npu.sv
    rtl/core/vit_phase_e_read_address_router.sv
    rtl/top/vit_phase_e_axi_bd_wrapper.v
    sim/axi/vit_axi_ddr_model_128.sv
    sim/axi/tb_vit_phase_e_axi_mem_adapter.sv
    sim/axi/tb_vit_phase_e_axi_wrapper.sv
    sim/axi/tb_vit_phase_e_engine_axi.sv
    sim/control/tb_vit_phase_e_profile_counters.sv
    sim/control/tb_vit_axi_lite_control_regs.sv
    sim/end_to_end/tb_vit_phase_e_axi_e01_real_rtl.sv
    sim/end_to_end/tb_vit_phase_e_axi_e04_real_rtl.sv
    sim/end_to_end/tb_vit_phase_e_axi_e05_compact_rtl.sv
    sim/gemm/tb_vit_phase_e_read_address_router_blocked_b.sv
    sim/m5/run_iverilog.sh
    sim/m5/run_m5_counter_regression.sh
    sim/m5/run_axi128_ddr_model_seed_sweep.sh
    sim/m5/tb_vit_phase_e_axi_mem_adapter_m5.sv
    sim/m5/tb_vit_axi_ddr_model_128.sv
    sim/m5/tb_m5_axi_counter_bank.sv
    sim/m5/tb_m5_profile_burst_queue.sv
    tools/m4/vit_m4_reuse_model.py
    evidence/m4_r8_2026-08-06/README.md
    evidence/m4_r8_2026-08-06/SHA256SUMS
    evidence/m5_axi128_2026-08-06/README.md
    evidence/m5_axi128_2026-08-06/SOURCE_PROVENANCE.md
    evidence/m5_axi128_2026-08-06/SHA256SUMS
)

vit_bundle_require_manifest_path() {
    local required_path="$1"
    local entry_count
    entry_count="$(
        awk -v required_path="${required_path}" '
            $2 == required_path { count++ }
            END { print count + 0 }
        ' MANIFEST.sha256
    )"
    if [[ "${entry_count}" != "1" ]]; then
        printf 'ERROR: manifest contains %s entries for required M5 input: %s\n' \
            "${entry_count}" "${required_path}"
        exit 1
    fi
}

for vit_bundle_m5_path in "${vit_bundle_m5_required[@]}"; do
    vit_bundle_require_manifest_path "${vit_bundle_m5_path}"
done

while read -r vit_bundle_evidence_digest vit_bundle_evidence_path; do
    if [[ ! "${vit_bundle_evidence_digest}" =~ ^[0-9a-f]{64}$ ]]; then
        printf 'ERROR: malformed M5 evidence digest: %s\n' \
            "${vit_bundle_evidence_digest}"
        exit 1
    fi
    vit_bundle_evidence_path="${vit_bundle_evidence_path#./}"
    vit_bundle_require_manifest_path \
        "evidence/m5_axi128_2026-08-06/${vit_bundle_evidence_path}"
done < evidence/m5_axi128_2026-08-06/SHA256SUMS

vit_bundle_source_count="$(
    awk '
        {
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) != 0) count++
        }
        END { print count + 0 }
    ' filelists/full_axi.f
)"
if [[ "${vit_bundle_source_count}" != "68" ]]; then
    printf 'ERROR: full_axi.f has %s sources; expected 68\n' \
        "${vit_bundle_source_count}"
    exit 1
fi

while IFS= read -r vit_bundle_source; do
    if [[ ! -f "${vit_bundle_source}" ]]; then
        printf 'ERROR: missing production source: %s\n' "${vit_bundle_source}"
        exit 1
    fi
    vit_bundle_require_manifest_path "${vit_bundle_source}"
done < <(
    awk '
        {
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) != 0) print
        }
    ' filelists/full_axi.f
)

# Retained M4-R8 data proves ancestry only; it never satisfies an M5 gate.
(
    cd evidence/m4_r8_2026-08-06
    sha256sum --check --strict SHA256SUMS
)
(
    cd evidence/m5_axi128_2026-08-06
    sha256sum --check --strict SHA256SUMS
)
python3 tools/m4/vit_m4_reuse_model.py --self-check

python3 - <<'PY'
import hashlib
import json
import re
from pathlib import Path

root = Path(".")
bundle = json.loads((root / "BUNDLE_INFO.json").read_text(encoding="utf-8"))
abi12 = json.loads(
    (root / "docs/PERF_PROFILE_ABI_V1_2.json").read_text(encoding="utf-8")
)
abi16 = json.loads(
    (root / "docs/PERF_PROFILE_ABI_V1_6.json").read_text(encoding="utf-8")
)

expected_parent_hash = (
    "c310266a85500069dfa20e9b72d2cd9d8bb7b0db1e858cda603ba78070fab828"
)
if bundle.get("bundle_name") != \
        "vivado_server_307_perf_v1_m5_axi128_burst_fp32_2023_2":
    raise SystemExit("ERROR: BUNDLE_INFO bundle_name is not exact M5")
if bundle.get("parent_bundle_name") != \
        "vivado_server_307_perf_v1_m4_r8_reuse_fp32_2023_2":
    raise SystemExit("ERROR: BUNDLE_INFO parent is not sealed M4-R8")
if bundle.get("parent_manifest_sha256") != expected_parent_hash:
    raise SystemExit("ERROR: BUNDLE_INFO parent manifest is not sealed M4-R8")
if bundle.get("manifest_status") != "SEALED":
    raise SystemExit(
        "ERROR: M5 metadata is deliberately unsealed; root must set "
        "manifest_status=SEALED only when regenerating MANIFEST.sha256"
    )
if bundle.get("vivado_version") != "2023.2":
    raise SystemExit("ERROR: M5 requires Vivado 2023.2")
if bundle.get("target_part") != "xczu5ev-sfvc784-1-e":
    raise SystemExit("ERROR: wrong M5 target part")
if bundle.get("production_pl_clock_hz") != 50_000_000 or \
        bundle.get("production_pl_clock_period_ns") != 20.0:
    raise SystemExit("ERROR: M5 production clock is not exactly 50 MHz")
if bundle.get("source_design_file_count") != 68 or \
        bundle.get("production_rtl_files") != 68:
    raise SystemExit("ERROR: BUNDLE_INFO does not bind the 68-source closure")
if bundle.get("ip_version") != "0x00010006":
    raise SystemExit("ERROR: BUNDLE_INFO IP version is not v1.6/M5")
if bundle.get("production_geometry") != {
    "array_rows": 8,
    "array_cols": 2,
    "pe_lanes": 16,
}:
    raise SystemExit("ERROR: M5 geometry is not exact R8/C2/L16")

axi = bundle.get("native_axi_contract", {})
expected_axi = {
    "control_data_width_bits": 32,
    "memory_data_width_bits": 128,
    "memory_addr_width_bits": 40,
    "memory_id_width_bits": 1,
    "supports_narrow_burst": True,
    "burst_type": "INCR",
    "maximum_burst_beats": 4,
    "maximum_read_outstanding": 2,
    "maximum_write_outstanding": 1,
    "logical_request_fifo_depth": 2,
    "logical_response_fifo_depth": 2,
}
for key, value in expected_axi.items():
    if axi.get(key) != value:
        raise SystemExit(
            f"ERROR: native_axi_contract.{key}={axi.get(key)!r}; expected {value!r}"
        )
if "only proven-contiguous blocked K16/N2 MODEL-B reads" not in \
        axi.get("burst_scope", ""):
    raise SystemExit("ERROR: M5 burst scope is not fail-closed to blocked MODEL-B")
if "writes and all other reads remain narrow" not in \
        axi.get("fallback_scope", ""):
    raise SystemExit("ERROR: M5 narrow fallback scope is missing")
for text_key, required in {
    "structural_error_policy": ("ordered errors", "poison", "reset"),
    "structural_error_limit": ("no watchdog", "no guarantee", "drained"),
}.items():
    text = axi.get(text_key, "").lower()
    if any(token not in text for token in required):
        raise SystemExit(f"ERROR: incomplete {text_key}: {text!r}")
if axi.get("bd_contract_marker") != "M5_AXI128_CONTRACT PASS":
    raise SystemExit("ERROR: BUNDLE_INFO lacks exact M5 BD marker")

profile = bundle.get("perf_counter_abi", {})
if profile.get("machine_readable_map") != "docs/PERF_PROFILE_ABI_V1_6.json":
    raise SystemExit("ERROR: BUNDLE_INFO does not bind profile ABI v1.6")
actual_abi16_hash = hashlib.sha256(
    (root / "docs/PERF_PROFILE_ABI_V1_6.json").read_bytes()
).hexdigest()
if profile.get("machine_readable_map_sha256") != actual_abi16_hash:
    raise SystemExit(
        "ERROR: BUNDLE_INFO does not bind the exact byte identity of "
        "PERF_PROFILE_ABI_V1_6.json"
    )
if profile.get("m5_capability") != "0x01F21008" or \
        profile.get("m5_register_window") != "0x7C0..0x80C" or \
        profile.get("m5_counter_count") != 8:
    raise SystemExit("ERROR: BUNDLE_INFO M5 counter bank is wrong")
if abi16.get("schema") != "vit-phase-e-profile-abi-v1.6-m5-axi128" or \
        abi16.get("ip_version") != "0x00010006":
    raise SystemExit("ERROR: child profile ABI is not exact v1.6/M5")
if abi16.get("compatibility", {}).get("base_schema") != abi12.get("schema"):
    raise SystemExit("ERROR: profile ABI v1.6 does not bind the v1.2 schema")
m5_abi = abi16.get("m5_native_axi", {})
if m5_abi.get("capability_value") != "0x01F21008" or \
        m5_abi.get("counter_count") != 8 or \
        m5_abi.get("last_offset") != "0x80C":
    raise SystemExit("ERROR: profile ABI v1.6 M5 bank is inconsistent")
expected_counter_names = [
    "full_r_beats",
    "narrow_r_beats",
    "linefill_starts",
    "linefill_hits",
    "four_k_splits",
    "max_read_outstanding",
    "protocol_errors",
    "prefetched_words_discarded",
]
if [counter.get("name") for counter in m5_abi.get("counters", [])] != \
        expected_counter_names:
    raise SystemExit("ERROR: profile ABI v1.6 M5 counter ordering changed")

verification = bundle.get("local_verification", {})
verification_files = {
    "final_e01_run_log_sha256":
        "evidence/m5_axi128_2026-08-06/real_axi/"
        "e01_final_fallthrough_server.run.log",
    "final_e01_build_log_sha256":
        "evidence/m5_axi128_2026-08-06/real_axi/"
        "e01_final_fallthrough_server.build.log",
    "final_e01_pre_identity_sha256":
        "evidence/m5_axi128_2026-08-06/real_axi/"
        "e01_final_fallthrough_server.pre.sha256",
    "final_e01_asset_hash_list_sha256":
        "evidence/m5_axi128_2026-08-06/real_axi/e01_asset_sha256.txt",
    "final_e04_log_sha256":
        "evidence/m5_axi128_2026-08-06/real_axi/"
        "e04_post_fallthrough.run.log",
    "final_compact_xsim_log_sha256":
        "evidence/m5_axi128_2026-08-06/local_xsim/"
        "10_tb_vit_phase_e_axi_e05_compact_rtl.log",
    "curated_local_evidence_sha256s_sha256":
        "evidence/m5_axi128_2026-08-06/SHA256SUMS",
}
for key, path in verification_files.items():
    actual = hashlib.sha256((root / path).read_bytes()).hexdigest()
    if verification.get(key) != actual:
        raise SystemExit(
            f"ERROR: local_verification.{key} does not bind {path}"
        )
e01_log = (root / verification_files["final_e01_run_log_sha256"]).read_text(
    encoding="utf-8"
)
required_e01_markers = (
    "VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_PASS checks=159 "
    "cycles=424112402 commands=4 reads=15350784 writes=453120",
    "E01_REAL_AXI128_TRAFFIC useful_fp32_words=15350784 ar=1526784 "
    "r_beats=4291584 full_r_beats=3686400 narrow_r_beats=605184 "
    "linefills=460800 line_hits=14284800 writes=453120",
    "E01_REAL_AXI_NUMERIC words=151296 exact_mismatch=132151 "
    "tolerance_failures=0 max_abs=1.788139343e-06 "
    "mean_abs=1.016216337e-07",
)
for marker in required_e01_markers:
    if e01_log.count(marker) != 1:
        raise SystemExit(f"ERROR: exact final-source E01 marker missing: {marker}")

oracle = bundle.get("m5_full_e05_counter_oracle", {})
exact_oracle = {
    "commands": 249,
    "logical_reads": 11_079_900_104,
    "logical_writes": 59_130_368,
    "linefill_starts": 66_840_000,
    "linefill_hits": 2_072_040_000,
    "full_r_beats": 534_720_000,
    "narrow_r_beats": 180_084_440,
    "axi_ar": 313_764_440,
    "axi_r_beats": 714_804_440,
    "axi_aw_w_b": 59_130_368,
    "max_read_outstanding": 2,
    "four_k_splits": 0,
    "protocol_errors": 0,
    "prefetched_words_discarded": 0,
    "counter_tolerance": 0,
}
for key, value in exact_oracle.items():
    if oracle.get(key) != value:
        raise SystemExit(
            f"ERROR: full-E05 M5 oracle {key}={oracle.get(key)!r}; expected {value}"
        )
if oracle.get("evidence_class") != "ESTIMATED":
    raise SystemExit("ERROR: pre-board M5 oracle must remain ESTIMATED")
if oracle["axi_r_beats"] != oracle["full_r_beats"] + oracle["narrow_r_beats"]:
    raise SystemExit("ERROR: M5 R-beat partition is inconsistent")
if oracle["axi_ar"] != oracle["narrow_r_beats"] + 2 * oracle["linefill_starts"]:
    raise SystemExit("ERROR: M5 AR partition is inconsistent")
if 4 * oracle["full_r_beats"] != \
        oracle["linefill_starts"] + oracle["linefill_hits"] + \
        oracle["prefetched_words_discarded"]:
    raise SystemExit("ERROR: M5 full-beat payload partition is inconsistent")

paths = []
for raw in (root / "filelists/full_axi.f").read_text(encoding="utf-8").splitlines():
    path = raw.split("#", 1)[0].strip()
    if path:
        paths.append(path)
if len(paths) != 68 or len(set(paths)) != 68:
    raise SystemExit("ERROR: full_axi.f is not 68 unique production paths")
aggregate = hashlib.sha256()
for path in paths:
    digest = hashlib.sha256((root / path).read_bytes()).hexdigest()
    aggregate.update(f"{digest}  {path}\n".encode("utf-8"))
actual_source_hash = aggregate.hexdigest()
expected_source_hash = bundle.get("source_design_sha256", "")
if not re.fullmatch(r"[0-9a-f]{64}", expected_source_hash):
    raise SystemExit("ERROR: M5 ordered source hash is not sealed")
if actual_source_hash != expected_source_hash:
    raise SystemExit(
        f"ERROR: ordered production source hash is {actual_source_hash}; "
        f"expected {expected_source_hash}"
    )

wrapper = (root / "rtl/axi/vit_phase_e_axi_wrapper.sv").read_text()
shim = (root / "rtl/top/vit_phase_e_axi_bd_wrapper.v").read_text()
for source_name, source_text in (("wrapper", wrapper), ("shim", shim)):
    for token in (
        "DATA_WIDTH 128",
        "MAX_BURST_LENGTH 4",
        "NUM_READ_OUTSTANDING 2",
        "NUM_WRITE_OUTSTANDING 1",
    ):
        if token not in source_text:
            raise SystemExit(f"ERROR: {source_name} AXI metadata lacks {token}")
control = (root / "rtl/axi/control/vit_axi_lite_control_regs.sv").read_text()
if "32'h0001_0006" not in control:
    raise SystemExit("ERROR: RTL IP_VERSION is not v1.6")
bd = (root / "scripts/vivado/create_vit_system_bd.tcl").read_text()
for token in (
    "variable m_axi_data_width 128",
    "variable m_axi_max_burst_length 4",
    "variable m_axi_read_outstanding 2",
    "variable m_axi_write_outstanding 1",
    "M5_AXI128_CONTRACT PASS",
):
    if token not in bd:
        raise SystemExit(f"ERROR: BD Tcl lacks exact M5 contract token: {token}")

print(f"PASS: ordered M5 production source identity {actual_source_hash}")
print("PASS: M5 bundle metadata, ABI, AXI contract and full-E05 oracle are exact")
PY

vit_bundle_input_symlink="$(
    find rtl filelists scripts third_party sim docs evidence tools \
        -type l -print -quit
)"
if [[ -n "${vit_bundle_input_symlink}" ]]; then
    printf 'ERROR: bundle input must not be a symlink: %s\n' \
        "${vit_bundle_input_symlink}"
    exit 1
fi

for vit_bundle_forbidden in parameters preprocessed baseline results build; do
    if [[ -e "${vit_bundle_forbidden}" ]]; then
        printf 'ERROR: heavyweight/non-signoff path is present: %s\n' \
            "${vit_bundle_forbidden}"
        exit 1
    fi
done

printf '%s\n' \
    'PASS: M5 native-AXI128 bundle checksum and 68-source production closure are valid'
