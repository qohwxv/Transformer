#!/usr/bin/env bash
set -euo pipefail

readonly vit_bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${vit_bundle_root}"

readonly vit_parent_manifest_sha="60f7f369902af23a02dd7b7b6451ac73dd29e34adb0623c2fc76fe5279b00571"
readonly vit_m6_source_manifest_sha="72c15f8bbd0683115efa9430c9d20d29e837d5434aa5f0b8cbbe8773ce3d3697"
readonly vit_m7_abi_v19_sha="449170fad38ae14f870f666087a9218b280b76546c70a4809ab4a594ee5af9a3"
readonly vit_m7_abi_v110_sha="c46f9831c7c5d75dc8c3a692dcb98a25247da0e1018426623c0d450e4d35f570"
readonly vit_m7_abi_v111_sha="5f624d90bd1327c3d6f6f026c8a41a21e7cbb3bf5a5aa71fa17399180703150e"
readonly vit_m7_abi_v112_sha="25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35"
readonly vit_python_bin="${VIT_PYTHON_BIN:-/usr/bin/python3}"

if [[ ! -x "${vit_python_bin}" ]]; then
    printf 'ERROR: required system Python is not executable: %s\n' \
        "${vit_python_bin}"
    exit 1
fi

# Vivado exports PYTHONHOME/PYTHONPATH for its bundled Python 3.8 runtime.
# The verifier deliberately uses the system Python, whose standard library is
# incompatible with those inherited paths.  This shell is a child of Vivado,
# so clearing them here cannot modify the parent tool process.
unset PYTHONHOME PYTHONPATH

test "$(sha256sum PARENT_M5_MANIFEST.sha256 | awk '{print $1}')" = \
    "${vit_parent_manifest_sha}"
test "$(sha256sum docs/PERF_PROFILE_ABI_V1_9.json | awk '{print $1}')" = \
    "${vit_m7_abi_v19_sha}"
test "$(sha256sum docs/PERF_PROFILE_ABI_V1_10.json | awk '{print $1}')" = \
    "${vit_m7_abi_v110_sha}"
test "$(sha256sum docs/PERF_PROFILE_ABI_V1_11.json | awk '{print $1}')" = \
    "${vit_m7_abi_v111_sha}"
test "$(sha256sum docs/PERF_PROFILE_ABI_V1_12.json | awk '{print $1}')" = \
    "${vit_m7_abi_v112_sha}"

"${vit_python_bin}" - <<'PY'
import hashlib
import json
import re
from pathlib import Path, PurePosixPath

root = Path(".").resolve()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        raise SystemExit(
            f"ERROR: {label} mismatch: expected {expected!r}, found {actual!r}"
        )


def require_tokens(text: str, tokens: tuple[str, ...], label: str) -> None:
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"ERROR: {label} is missing tokens {missing}: {text!r}")


def require_pattern(text: str, pattern: str, label: str) -> None:
    if re.search(pattern, text, re.MULTILINE) is None:
        raise SystemExit(f"ERROR: source/flow does not implement {label}")


def checked_local_path(relative_text: str, label: str) -> Path:
    relative = PurePosixPath(relative_text)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != relative_text
    ):
        raise SystemExit(f"ERROR: unsafe {label} path: {relative_text}")
    path = root / relative_text
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing/empty {label}: {relative_text}")
    return path


def checked_local_directory(relative_text: str, label: str) -> Path:
    relative = PurePosixPath(relative_text)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != relative_text
    ):
        raise SystemExit(f"ERROR: unsafe {label} directory: {relative_text}")
    path = root / relative_text
    if not path.is_dir():
        raise SystemExit(f"ERROR: missing {label} directory: {relative_text}")
    return path


def verify_sha256_receipt(
    receipt_root: Path,
    expected_manifest_sha256: str,
    expected_entries: int,
    excluded_sidecars: tuple[str, ...] = (),
    manifest_name: str = "SHA256SUMS.txt",
) -> dict[str, str]:
    manifest = receipt_root / manifest_name
    if not manifest.is_file():
        raise SystemExit(f"ERROR: missing receipt manifest: {manifest}")
    require_equal(
        sha256_file(manifest),
        expected_manifest_sha256,
        f"receipt manifest {receipt_root.name}",
    )
    declared: dict[str, str] = {}
    for line_number, line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), 1
    ):
        if len(line) < 67 or line[64:66] != "  ":
            raise SystemExit(
                f"ERROR: malformed receipt record {manifest}:{line_number}"
            )
        digest, relative_text = line[:64], line[66:]
        if any(char not in "0123456789abcdef" for char in digest):
            raise SystemExit(
                f"ERROR: malformed receipt SHA-256 {manifest}:{line_number}"
            )
        relative = PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() != relative_text
            or relative_text in declared
        ):
            raise SystemExit(
                f"ERROR: unsafe/duplicate receipt path {manifest}:{line_number}"
            )
        declared[relative_text] = digest
    require_equal(len(declared), expected_entries, f"receipt entries {receipt_root.name}")
    expected_files = {
        path.relative_to(receipt_root).as_posix()
        for path in receipt_root.rglob("*")
        if path.is_file()
        and path.relative_to(receipt_root).as_posix() != manifest_name
        and path.relative_to(receipt_root).as_posix() not in excluded_sidecars
    }
    require_equal(
        set(declared),
        expected_files,
        f"receipt closure {receipt_root.name}",
    )
    for relative_text, digest in declared.items():
        require_equal(
            sha256_file(receipt_root / relative_text),
            digest,
            f"receipt payload {receipt_root.name}/{relative_text}",
        )
    return declared


def load_bound_receipt(
    relative_text: str,
    expected_manifest_sha256: str,
    expected_entries: int,
    label: str,
) -> tuple[Path, dict]:
    receipt_root = checked_local_directory(relative_text, f"{label} receipt")
    verify_sha256_receipt(
        receipt_root,
        expected_manifest_sha256,
        expected_entries,
        ("RECEIPT_MANIFEST.sha256",),
        "RECEIPT_SHA256SUMS.txt",
    )
    require_equal(
        (receipt_root / "RECEIPT_MANIFEST.sha256")
            .read_text(encoding="utf-8")
            .strip(),
        f"{expected_manifest_sha256}  RECEIPT_SHA256SUMS.txt",
        f"{label} receipt manifest sidecar",
    )
    status = json.loads((receipt_root / "STATUS.json").read_text(encoding="utf-8"))
    if not isinstance(status, dict):
        raise SystemExit(f"ERROR: {label} STATUS is not a JSON object")
    return receipt_root, status


info = json.loads((root / "BUNDLE_INFO.json").read_text(encoding="utf-8"))
fallback = info.get("m7s8_controlled_fallback_local", {})
pre_correction_ooc = info.get("m7s8_pre_correction_ooc_loop_failure", {})
adder_correction = info.get("m7s8_fp32_adder_feedforward_correction_local", {})
place_failure = info.get("m7s8_place_30_487_failure", {})
current = info.get("m7s8_fp16_only_production_local", {})

expected = {
    "bundle_name":
        "vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2",
    "parent_manifest_sha256":
        "60f7f369902af23a02dd7b7b6451ac73dd29e34adb0623c2fc76fe5279b00571",
    "m6_source_manifest_sha256":
        "72c15f8bbd0683115efa9430c9d20d29e837d5434aa5f0b8cbbe8773ce3d3697",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "target_part": "xczu5ev-sfvc784-1-e",
    "vivado_version": "2023.2",
    "source_design_sha256": "PENDING_M7_SEAL",
    "current_development_source_design_sha256":
        "1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888",
    "source_design_file_count": 80,
    "production_rtl_files": 80,
    "ip_version": "0x0001000C",
    "clb_lut_fit_gate":
        "fail_closed_after_ooc_and_board_synthesis_before_implementation",
}
for key, value in expected.items():
    require_equal(info.get(key), value, f"BUNDLE_INFO.{key}")
require_tokens(
    info.get("source_design_hash_scope", ""),
    (
        "future promoted seal",
        "current_development_source_design_sha256",
        "80-source",
        "FP16-only production revision",
    ),
    "BUNDLE_INFO source-design hash scope",
)

require_equal(
    info.get("production_geometry", {}),
    {
        "array_rows": 8,
        "array_cols": 2,
        "pe_lanes": 16,
        "fp16_streams": 8,
        "logical_tile": "R8xC2",
        "physical_fp16_pass": "R8xC1",
    },
    "production S8 geometry",
)

contract = info.get("m7_integration_contract", {})
for key, value in {
    "status":
        "M7S8_FP16_ONLY_PRODUCTION_FULL_VIVADO_E04_E01_SERVER_PASS_BOARD_FULL_E05_PENDING",
    "primary_streams": 8,
    "physical_streams": 8,
    "parent_streams": 16,
    "fallback_streams": 8,
    "logical_output_columns": 2,
    "physical_output_columns_per_pass": 1,
}.items():
    require_equal(contract.get(key), value, f"m7_integration_contract.{key}")
if "zero" not in contract.get("dsp_policy", "").lower():
    raise SystemExit("ERROR: M7 DSP-zero policy is absent")

profile = info.get("perf_counter_abi", {})
for key, value in {
    "m7_capability": "0x01FF0817",
    "m7_register_window": "0x810..0x8E4",
    "m7_counter_count": 23,
    "m7_buffer_config": "0x00080202",
    "machine_readable_map": "docs/PERF_PROFILE_ABI_V1_12.json",
    "machine_readable_map_sha256":
        "25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35",
    "prior_machine_readable_map": "docs/PERF_PROFILE_ABI_V1_11.json",
    "prior_machine_readable_map_sha256":
        "5f624d90bd1327c3d6f6f026c8a41a21e7cbb3bf5a5aa71fa17399180703150e",
}.items():
    require_equal(profile.get(key), value, f"perf_counter_abi.{key}")

expected_fallback = {
    "date": "2026-08-08",
    "evidence_class": "SIM-MEASURED",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "ip_version": "0x0001000B",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "9b4a0e9bdc3f555741096533e5f2e7047cb923e666a49f58999f4f7a1b09df19",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "gate2_integration_log_sha256":
        "01b3ac9c0a21eefe24a5e8019e8e418a4a26b291c56e712b7cf8a80309ebee33",
    "memory_seams_log_sha256":
        "916db066a78c559eaf9aef55c5b6156f134f6de5cd40345ece44c887e7d120ee",
    "compact_mode3_log_sha256":
        "99f47f65317e2c14d4703e6259e6e93ee78a7071a7435b6245f0274f6745074b",
}
for key, value in expected_fallback.items():
    require_equal(fallback.get(key), value, f"m7s8_controlled_fallback_local.{key}")
for key, tokens in {
    "schedule": ("R8xC1 col0", "col1", "K/address rewind", "odd N"),
    "scheduler_gate2": ("checks=66146", "max_fifo=2", "final_depth2_drain=3"),
    "dual_mode": ("checks=21199", "odd N", "K=17/32/33/3072"),
    "memory_seams": ("PASS 6/6", "row-major scratch B K64/K197"),
    "counter_control": ("checks=246", "geometry 0x08100208", "checks=490", "IP 0x0001000B"),
    "compact_mode3": (
        "checks=2081", "job_cycles=488317", "commands=249",
        "reads=39185", "writes=10646", "logical_reads=95449",
        "axi_ar=22670", "axi_r_beats=25973",
        "terms/disabled=184192/124816", "dots/results=1439/1439",
        "panel/FIFO=1175/1175", "max_fifo=2",
        "compute_store_overlap=34047", "logit=0x40e00000",
    ),
    "full_e05_static_model": (
        "DERIVED/ESTIMATED only", "physical K16 passes=139512000",
        "valid/tail=17563828224/293707776", "ideal feed cycles=2232192000",
        "total reads=2409511640", "R beats=805351640", "AR=404311640",
        "no B cache", "not runtime evidence",
    ),
}.items():
    require_tokens(fallback.get(key, ""), tokens, f"initial S8 evidence {key}")

evidence_specs = {
    "gate2_integration_log": (
        "gate2_integration_log_sha256",
        (
            "M7.4_GATE2_FIFO results=7 enq=7 deq=7 max=2",
            "final_drain2=3",
            "PASS M7.4 scheduler ping-pong Gate-2 checks=66146",
            "M7_S8_DUAL_GATE2 results=7 enq=7 deq=7 max=2",
            "PASS M7 dual-mode production GEMM checks=21199",
            "M7_RESULT_FIFO_GATE2_INTEGRATION_PASS",
        ),
    ),
    "memory_seams_log": (
        "memory_seams_log_sha256",
        (
            "PASS M7 packed address context: checks=45",
            "PASS M7 packed memory frontend: checks=350",
            "PASS M7 packed memory seams: 6/6 cases",
        ),
    ),
    "compact_mode3_log": (
        "compact_mode3_log_sha256",
        (
            "M5_COMPACT_COUNTERS logical=95449",
            "M7_COMPACT_COUNTERS mode=3 terms=184192 disabled=124816",
            "fifo_enq=1175 fifo_deq=1175 max_fifo=2",
            "VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 rows=8 cols=2 checks=2081 cycles=495849 job_cycles=488317 commands=249",
            "reads=39185 writes=10646",
        ),
    ),
}
for path_key, (hash_key, tokens) in evidence_specs.items():
    evidence_path = checked_local_path(fallback.get(path_key, ""), path_key)
    require_equal(sha256_file(evidence_path), fallback[hash_key], path_key)
    require_tokens(
        evidence_path.read_text(encoding="utf-8", errors="strict"),
        tokens,
        path_key,
    )

# The first S8 Vivado attempt is an immutable failed identity.  It must remain
# independently replayable after the feed-forward adder correction changes the
# current 80-source stream.
for key, value in {
    "overall_status": "FAILED_OOC_COMBINATIONAL_LOOP",
    "promotion_status": "NOT_PROMOTABLE",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "ip_version": "0x0001000B",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "9b4a0e9bdc3f555741096533e5f2e7047cb923e666a49f58999f4f7a1b09df19",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "development_manifest_sha256":
        "d6839c35131ceb8cc8e9c111676e4d71c06d5a5d13bf9eb254ab4ec3845a9a2e",
    "bundle_info_sha256":
        "0a61c996e843b607f445b64ecbb638a15cb7acb286c78a72a9b6366f8ca9b9dc",
    "receipt_manifest_sha256":
        "43b3e0eac5707a99fb1b082f7d4b692bdef7b6f3f6c71890107b6f722bb3af62",
}.items():
    require_equal(pre_correction_ooc.get(key), value, f"pre-correction OOC.{key}")
require_tokens(
    pre_correction_ooc.get("failure", ""),
    ("exactly one HIGH", "u_stream_array/u_bias_adder", "before OOC DCP"),
    "pre-correction OOC failure",
)
require_tokens(
    pre_correction_ooc.get("not_run", ""),
    ("Block Design", "full-board synthesis", "route", "BIT/XSA", "physical board"),
    "pre-correction OOC non-claims",
)
ooc_status_path = checked_local_path(
    pre_correction_ooc.get("receipt", ""),
    "pre-correction OOC STATUS",
)
ooc_receipt = json.loads(ooc_status_path.read_text(encoding="utf-8"))
verify_sha256_receipt(
    ooc_status_path.parent,
    pre_correction_ooc["receipt_manifest_sha256"],
    38,
)
require_equal(
    ooc_receipt.get("overall_status"),
    "FAILED_OOC_COMBINATIONAL_LOOP",
    "pre-correction OOC receipt status",
)
require_equal(
    ooc_receipt.get("identity", {}).get("ordered_source_sha256"),
    pre_correction_ooc["ordered_source_sha256"],
    "pre-correction OOC receipt source",
)
require_equal(
    ooc_receipt.get("resources", {}).get("ooc_post_synth_raw_report", {}).get("clb_lut_used"),
    109973,
    "pre-correction OOC CLB LUT use",
)
require_equal(
    ooc_receipt.get("resources", {}).get("ooc_post_synth_raw_report", {}).get("dsp_used"),
    0,
    "pre-correction OOC raw DSP use",
)
require_equal(
    ooc_receipt.get("combinational_loop", {}).get("count"),
    1,
    "pre-correction OOC loop count",
)

# Bind the historical feed-forward-adder correction identity, all associated
# simulation-only assets, and its complete local checkpoint receipt.  This
# remains an immutable predecessor of the current FP16-only revision.
for key, value in {
    "date": "2026-08-08",
    "evidence_class": "SIM-MEASURED_AND_VERIFIED_SOURCE",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "ip_version": "0x0001000B",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "7d89768f2b8820bbf3aa13a628a05696b460d2d8f758313e83d104d54b2e5cf5",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "original_adder_sha256":
        "e500b1584794cc33f877b1f17a7cdd317a3ec149fda815713b144a29a4743601",
    "feedforward_adder_sha256":
        "3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141",
    "checkpoint_manifest_sha256":
        "dd77b69a59c7e042a29419fe5556ece59c3feccd4f20a52b9cd4b9839a1552eb",
}.items():
    require_equal(
        adder_correction.get(key), value, f"historical adder correction.{key}"
    )
for key, tokens in {
    "correction_scope": ("feed-forward", "historical FP32 add bit contract"),
    "static_gate": ("continuous_assignments=53", "procedural_blocks=0", "procedural_loops=0"),
    "adder_ab": ("checks=8245", "random=8192", "mismatches=0"),
    "fp32_leaf": ("checks=62002", "mismatches=0"),
    "fp32_special_leaf": ("checks=12031", "mismatches=0"),
    "gate2": ("28592/66146/21199",),
    "production_compile": ("Icarus", "Verilator", "0/0/0"),
    "compact_mode1": ("checks=2086", "job_cycles=900581", "commands=249"),
    "compact_mode3": ("checks=2081", "job_cycles=488317", "commands=249"),
    "boundary": ("local simulation/static/lint only", "mapped Vivado loop gate", "physical-board"),
}.items():
    require_tokens(
        adder_correction.get(key, ""),
        tokens,
        f"historical adder correction {key}",
    )

test_assets = adder_correction.get("test_only_assets", {})
expected_test_assets = {
    "oracle": (
        "sim/reference/vit_fp32_add_package_reference.sv",
        "1a89c8d8352377ee6e0b1bf5368402601e19618d4bbeadc7cf3038545239c9f1",
    ),
    "testbench": (
        "sim/leaf/fp32/tb_vit_fp32_add_feedforward_ab.sv",
        "d93ecc9b8686496a3ba392e4344b8f1997899e1198b84613b256ee089c72ec77",
    ),
    "filelist": (
        "sim/leaf/fp32/vit_fp32_add_feedforward_ab_iverilog.f",
        "21e8e51ff71e6f598462217375f84980f069d70da9db3c3837715b585c192f5c",
    ),
    "runner": (
        "sim/leaf/fp32/run_add_feedforward_ab_iverilog.sh",
        "662244c5e46e8553e2f25e1752a5b4f15f1abed14f7cc7ff7c39f41c433bbd41",
    ),
}
for asset_name, (relative_text, expected_hash) in expected_test_assets.items():
    require_equal(test_assets.get(asset_name), relative_text, f"test asset {asset_name} path")
    require_equal(
        test_assets.get(f"{asset_name}_sha256"),
        expected_hash,
        f"test asset {asset_name} declared hash",
    )
    asset_path = checked_local_path(relative_text, f"test asset {asset_name}")
    require_equal(sha256_file(asset_path), expected_hash, f"test asset {asset_name}")
if "manifest-controlled" not in test_assets.get("production_filelist_policy", ""):
    raise SystemExit("ERROR: test-only manifest/filelist policy is absent")

checkpoint_root = checked_local_directory(
    adder_correction.get("checkpoint", ""),
    "feed-forward-adder checkpoint",
)
verify_sha256_receipt(
    checkpoint_root,
    adder_correction["checkpoint_manifest_sha256"],
    30,
    ("SHA256SUMS.txt.sha256",),
)
require_equal(
    (checkpoint_root / "SHA256SUMS.txt.sha256").read_text(encoding="utf-8").strip(),
    f'{adder_correction["checkpoint_manifest_sha256"]}  SHA256SUMS.txt',
    "feed-forward-adder checkpoint manifest sidecar",
)
gate_status = (checkpoint_root / "GATE_STATUS.txt").read_text(encoding="utf-8")
require_tokens(
    gate_status,
    (
        "fp32_adder_feedforward_static=PASS continuous_assignments=53 procedural_blocks=0 procedural_loops=0",
        "fp32_adder_package_oracle_ab=PASS exit=0 checks=8245",
        "fp32_leaf=PASS exit=0 checks=62002 mismatches=0",
        "fp32_special_leaf=PASS exit=0 checks=12031 mismatches=0",
        "m7_result_fifo_scheduler_dual_gate2=PASS exit=0 fifo_checks=28592 scheduler_checks=66146 dual_checks=21199",
        "compact_mode1=PASS exit=0 checks=2086 job_cycles=900581 commands=249",
        "compact_mode3=PASS exit=0 checks=2081 job_cycles=488317 commands=249",
        "vivado_loop_disposition=PENDING",
    ),
    "feed-forward-adder checkpoint gates",
)
require_equal(
    sha256_file(checkpoint_root / "SOURCE_SHA256SUMS_AFTER.txt"),
    adder_correction["ordered_source_sha256"],
    "checkpoint ordered source stream",
)

# Preserve the exact v1.11 S8 placement failure as an immutable historical
# receipt.  The current FP16-only revision is a distinct source identity and
# must not overwrite or be credited with any of these Vivado observations.
for key, value in {
    "date": "2026-08-08",
    "evidence_class": "SIM-MEASURED_AND_MEASURED_AS_SCOPED",
    "overall_status": "FAILED_PLACE_30_487_CLB_PACKING",
    "promotion_status": "NOT_PROMOTABLE",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "ip_version": "0x0001000B",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "7d89768f2b8820bbf3aa13a628a05696b460d2d8f758313e83d104d54b2e5cf5",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "development_manifest_sha256":
        "7832be523cfee86dc85dbb41638db9d0d0edf3b77f03d8bdb59161dc1c5e2749",
    "bundle_info_sha256":
        "da5b459a418a371edbb1e3d2e29439a057fb3eff84569c62552bbf1245087f2a",
    "receipt_entry_count": 232,
    "remote_snapshot_file_count": 228,
    "remote_local_sha256_compare": "PASS_228_OF_228",
    "receipt_manifest_sha256":
        "e6455349faaf59927c771c664d82ea2b7c1df31c819162a01f69be69bad06a0e",
}.items():
    require_equal(place_failure.get(key), value, f"Place 30-487 failure.{key}")
for key, tokens in {
    "geometry": ("R8/C2/L16/S8", "R8xC1"),
    "xsim": ("PASS 9/9", "mode1 checks=2086", "mode3 checks=2081"),
    "ooc_synthesis": ("loops=0", "DSP=0", "109292/117120", "headroom=7828"),
    "block_design": ("PASS", "R8/C2/L16/S8", "AXI128"),
    "board_synthesis": ("PASS_POST_SYNTH_ONLY", "DSP=0", "111747/117120"),
    "implementation": ("opt_design COMPLETE", "place_design FAIL", "Place 30-487"),
    "failure": ("8797 CLBs available", "9172 required", "deficit 375", "806 control sets"),
    "not_run": ("completed placement", "route", "BIT", "XSA", "physical board"),
}.items():
    require_tokens(place_failure.get(key, ""), tokens, f"Place 30-487 {key}")
place_status_path = checked_local_path(
    place_failure.get("receipt", ""),
    "Place 30-487 STATUS",
)
place_receipt_root = place_status_path.parent
verify_sha256_receipt(
    place_receipt_root,
    place_failure["receipt_manifest_sha256"],
    place_failure["receipt_entry_count"],
    ("RECEIPT_MANIFEST.sha256",),
    "RECEIPT_SHA256SUMS.txt",
)
require_equal(
    (place_receipt_root / "RECEIPT_MANIFEST.sha256")
        .read_text(encoding="utf-8")
        .strip(),
    f'{place_failure["receipt_manifest_sha256"]}  RECEIPT_SHA256SUMS.txt',
    "Place 30-487 receipt manifest sidecar",
)
place_receipt = json.loads(place_status_path.read_text(encoding="utf-8"))
for actual, expected_value, label in (
    (place_receipt.get("overall_status"), "FAILED_PLACE_30_487_CLB_PACKING", "status"),
    (place_receipt.get("ordered_source_sha256"), place_failure["ordered_source_sha256"], "source"),
    (place_receipt.get("remote_local_sha256_compare"), "PASS_228_OF_228", "remote/local compare"),
    (place_receipt.get("snapshot_file_count"), 228, "snapshot count"),
    (place_receipt.get("ooc_synthesis", {}).get("dsp48_dsp58"), 0, "OOC DSP"),
    (place_receipt.get("ooc_synthesis", {}).get("combinational_loops"), 0, "OOC loops"),
    (place_receipt.get("board_synthesis", {}).get("dsp48_dsp58"), 0, "board DSP"),
    (place_receipt.get("implementation", {}).get("place_design"), "FAIL", "place gate"),
    (place_receipt.get("implementation", {}).get("clbs_available_to_place"), 8797, "available CLBs"),
    (place_receipt.get("implementation", {}).get("clbs_required"), 9172, "required CLBs"),
    (place_receipt.get("implementation", {}).get("clb_deficit"), 375, "CLB deficit"),
):
    require_equal(actual, expected_value, f"Place 30-487 receipt {label}")
require_equal(
    place_receipt.get("implementation", {}).get("failure_codes"),
    ["Place 30-487", "Place 30-99", "Common 17-69"],
    "Place 30-487 receipt failure codes",
)
require_equal(
    place_receipt.get("not_run"),
    [
        "completed placement",
        "route",
        "post-route timing and hold",
        "post-route DRC and methodology",
        "post-route loop, blackbox and DSP gates",
        "BIT",
        "XSA",
        "physical board",
    ],
    "Place 30-487 receipt non-claims",
)

# Bind the current v1.12 FP16-only production revision.  The old v1.11 Vivado
# receipt remains historical; the final server section below independently
# binds full Vivado and real E04/E01 receipts to this unchanged source identity.
for key, value in {
    "date": "2026-08-08",
    "evidence_class":
        "SIM-MEASURED_AND_MEASURED_VIVADO_AND_VERIFIED_SOURCE_AS_SCOPED",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "source_design_sha256": "PENDING_M7_SEAL",
    "ip_version": "0x0001000C",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "abi": "docs/PERF_PROFILE_ABI_V1_12.json",
    "abi_sha256":
        "25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35",
}.items():
    require_equal(current.get(key), value, f"current FP16-only.{key}")
for key, tokens in {
    "execution_mode_contract": (
        "mode 3 or mode 5 only", "mode 0", "mode 1", "mode 2", "mode 4",
        "0x80000003", "ERROR_INFO", "before job snapshot",
    ),
    "production_hierarchy": (
        "INCLUDE_LEGACY_GEMM=0", "gen_legacy/gen_no_legacy", "no instantiated u_legacy",
    ),
    "legacy_leaf_regression": ("checks=21199", "INCLUDE_LEGACY_GEMM=1"),
    "fp16_only_leaf": ("checks=66", "INCLUDE_LEGACY_GEMM=0", "mode3/mode5"),
    "fp16_only_hierarchy": ("gen_no_legacy", "no instantiated u_legacy"),
    "axi_wrapper": ("checks=178", "modes 3/5", "0/1/2/4/all-ones"),
    "compact_mode0_reject": ("checks=36", "0x80000003", "0x00000000", "zero accepted"),
    "compact_mode1_reject": ("checks=36", "0x80000003", "0x00000001", "zero accepted"),
    "compact_mode3": (
        "checks=2081", "total_cycles=495849", "job_cycles=488317",
        "commands=249", "blocked_gemm=74", "packed_gemm=74", "fp16_gemm=98",
        "row_major_gemm=24", "reads=39185", "writes=10646",
        "logical_reads=95449", "valid_mac=59376", "tail_mac=124816",
        "class=3", "logit=0x40e00000",
    ),
    "production_compile_lint": ("PASS", "Icarus", "Verilator", "gen_no_legacy"),
    "historical_place_failure_relation": (
        "v1.11 Place 30-487", "7d89768f...e5cf5", "full Vivado 2023.2",
        "1ffe0295...e5888", "BIT/XSA",
    ),
    "boundary": (
        "current-source full Vivado 2023.2", "canonical/repeat real E04",
        "canonical/repeat real E01", "DEVELOPMENT_UNSEALED/PENDING_M7_SEAL",
        "complete E05/full-model", "physical-board",
    ),
}.items():
    require_tokens(current.get(key, ""), tokens, f"current FP16-only {key}")

# Preserve and bind the exact historical S16 Gate2 identity independently of
# the current S8 source identity.
historical = info.get("m7_4c_b_gate2_local", {})
for key, value in {
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "ip_version": "0x0001000A",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "91a2019ccfc60ed7bb3035965beec0df2cda6a026e48b129ca0393241fa45f75",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
}.items():
    require_equal(historical.get(key), value, f"historical Gate2.{key}")
require_tokens(
    historical.get("compact_mode3", ""),
    ("checks=2077", "job_cycles=391629", "reads=28843", "588/588/2"),
    "historical S16 compact evidence",
)

failure = info.get("m7_16stream_server_failure", {})
for key, value in {
    "overall_status": "FAILED_PRE_PLACE_RESOURCE_UTILIZATION",
    "promotion_status": "NOT_PROMOTABLE",
    "ip_version": "0x0001000A",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "91a2019ccfc60ed7bb3035965beec0df2cda6a026e48b129ca0393241fa45f75",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "development_manifest_sha256":
        "53e3202412e4c95c33c2cb1538c35766f2d932f9e43a9f25293daee209a393fa",
    "geometry": "R8/C2/L16/S16",
    "ooc_clb_lut_used_available": "137131/117120",
    "board_clb_lut_used_available": "139437/117120",
    "pre_place_slice_lut_required_available": "137004/117120",
    "receipt_manifest_sha256":
        "f3988be985233ec3ab342f16bdd7e0d87ea44577eec05fe16305d6857654f287",
}.items():
    require_equal(failure.get(key), value, f"S16 failure.{key}")
require_tokens(
    failure.get("not_run", ""),
    ("placement", "route", "BIT/XSA", "physical board"),
    "S16 failure non-claims",
)
receipt_status = (root / failure.get("receipt", "")).resolve()
if not receipt_status.is_file():
    raise SystemExit(f"ERROR: missing S16 failure receipt: {receipt_status}")
receipt = json.loads(receipt_status.read_text(encoding="utf-8"))
require_equal(
    receipt.get("overall_status"),
    "FAILED_PRE_PLACE_RESOURCE_UTILIZATION",
    "S16 receipt status",
)
require_equal(receipt.get("target", {}).get("fp16_streams"), 16, "S16 receipt streams")
require_equal(receipt.get("stages", {}).get("place_design"), "NOT_RUN", "S16 receipt place scope")
require_equal(receipt.get("stages", {}).get("bitstream"), "NOT_GENERATED", "S16 receipt BIT scope")
require_equal(receipt.get("resources", {}).get("ooc_post_synth", {}).get("clb_lut_used"), 137131, "S16 OOC LUT use")
require_equal(receipt.get("resources", {}).get("board_post_synth", {}).get("clb_lut_used"), 139437, "S16 board LUT use")
receipt_manifest = receipt_status.parent / "SHA256SUMS.txt"
require_equal(
    sha256_file(receipt_manifest),
    failure["receipt_manifest_sha256"],
    "S16 receipt manifest",
)

# Recompute the exact ordered current production closure.  The top-level
# source_design_sha256 intentionally remains PENDING_M7_SEAL; only the
# separate development identity may match this unsealed source stream.
filelist = root / "filelists/full_axi.f"
require_equal(sha256_file(filelist), current["filelist_sha256"], "full_axi.f")
sources = []
for raw in filelist.read_text(encoding="utf-8").splitlines():
    relative_text = raw.split("#", 1)[0].strip()
    if not relative_text:
        continue
    relative = PurePosixPath(relative_text)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != relative_text
    ):
        raise SystemExit(f"ERROR: unsafe production source path: {relative_text}")
    sources.append(relative_text)
if len(sources) != 80 or len(set(sources)) != 80:
    raise SystemExit(
        "ERROR: full_axi.f must contain 80/80 ordered unique sources; "
        f"found {len(sources)}/{len(set(sources))}"
    )
for asset_name, (relative_text, _) in expected_test_assets.items():
    if relative_text in sources:
        raise SystemExit(
            f"ERROR: test-only asset entered production full_axi.f: "
            f"{asset_name}={relative_text}"
        )
ordered_records = []
for relative_text in sources:
    source = root / relative_text
    if not source.is_file():
        raise SystemExit(f"ERROR: missing production source: {relative_text}")
    ordered_records.append(f"{sha256_file(source)}  {relative_text}\n")
ordered_sha = hashlib.sha256("".join(ordered_records).encode("utf-8")).hexdigest()
require_equal(ordered_sha, current["ordered_source_sha256"], "ordered 80-source stream")
require_equal(
    ordered_sha,
    info["current_development_source_design_sha256"],
    "current development source identity",
)

# Bind the final server qualification without rewriting history.  In
# particular, the 352-entry manifest/BUNDLE/verifier hashes below are the exact
# inputs consumed by the already-completed Vivado run, not circular claims
# about this post-qualification metadata revision.
final_server = info.get("m7s8_final_server_qualification", {})
for key, value in {
    "date": "2026-08-08",
    "evidence_class":
        "SIM-MEASURED_AND_MEASURED_VIVADO_AND_VERIFIED_IDENTITY_AS_SCOPED",
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "source_design_sha256": "PENDING_M7_SEAL",
    "promotion_status": "NOT_PROMOTED_PENDING_COMPLETE_E05_AND_PHYSICAL_BOARD",
}.items():
    require_equal(final_server.get(key), value, f"final server qualification.{key}")

production_identity = final_server.get("production_identity", {})
for key, value in {
    "ip_version": "0x0001000C",
    "ordered_source_count": 80,
    "ordered_source_sha256":
        "1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888",
    "filelist_sha256":
        "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524",
    "abi_v1_12_sha256":
        "25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35",
    "source_unchanged_across_full_vivado_e04_e01": True,
}.items():
    require_equal(production_identity.get(key), value, f"final production identity.{key}")
require_equal(production_identity["ordered_source_sha256"], ordered_sha, "final ordered source")
require_equal(production_identity["filelist_sha256"], sha256_file(filelist), "final filelist")

historical_input = final_server.get("historical_full_vivado_input_identity", {})
for key, value in {
    "development_manifest_entries": 352,
    "development_manifest_sha256":
        "6b45b2a09ab924619497882507db2bcf5540eeb5eb06ce225174581adaf479b4",
    "bundle_info_sha256":
        "9fc5fa4a44358f60b4df699c4f72d767f028a5976fd718ce59d7bb9f3cf43e0d",
    "development_verifier_sha256":
        "77d061e3a2dfdfa0026ba2f174cb22ffbf0726192dc48c901ffda15b76bb2537",
    "ordered_source_sha256": production_identity["ordered_source_sha256"],
    "filelist_sha256": production_identity["filelist_sha256"],
    "source_design_sha256": "PENDING_M7_SEAL",
}.items():
    require_equal(historical_input.get(key), value, f"historical Vivado input.{key}")
require_tokens(
    historical_input.get("scope", ""),
    ("exact 352-entry", "full Vivado 2023.2", "historical input identity", "post-qualification"),
    "historical Vivado input scope",
)
# The current root manifest is deliberately refreshed after the real E04/E01
# qualification assets are added.  Prove the exact 352-entry manifest consumed
# by the completed Vivado run from that run's immutable receipt snapshot; the
# current 361-entry manifest is checked independently at the final gate below.
historical_manifest = checked_local_path(
    "reports/m7/server_runs/20260808T101823Z-m7s8_fp16only_v112_full_vivado_pass/"
    "remote_snapshot/M7_DEVELOPMENT_SHA256SUMS.txt",
    "historical full-Vivado 352-entry manifest",
)
require_equal(
    sha256_file(historical_manifest),
    historical_input["development_manifest_sha256"],
    "historical 352-entry development manifest bytes",
)
historical_manifest_records = {}
for line_number, line in enumerate(
    historical_manifest.read_text(encoding="utf-8").splitlines(), 1
):
    if len(line) < 67 or line[64:66] != "  ":
        raise SystemExit(f"ERROR: malformed historical manifest line {line_number}")
    digest, relative_text = line[:64], line[66:]
    historical_manifest_records[relative_text] = digest
require_equal(len(historical_manifest_records), 352, "historical manifest entries")
require_equal(
    historical_manifest_records.get("BUNDLE_INFO.json"),
    historical_input["bundle_info_sha256"],
    "historical manifest BUNDLE_INFO identity",
)
require_equal(
    historical_manifest_records.get("run/00_verify_m7_development.sh"),
    historical_input["development_verifier_sha256"],
    "historical manifest verifier identity",
)

full_vivado = final_server.get("full_vivado_2023_2", {})
for key, value in {
    "receipt":
        "reports/m7/server_runs/20260808T101823Z-m7s8_fp16only_v112_full_vivado_pass",
    "receipt_entries": 129,
    "receipt_manifest_sha256":
        "791c31e52c60e8e6af4bcf6c29f55cea6f79553bb89024705b5cc061df305a8d",
    "overall_status": "PASS_FULL_VIVADO_2023_2",
    "vivado": "2023.2 build 4029153",
    "target_clock_hz": 50000000,
    "bit_status": "PASS_GENERATED_NOT_BOARD_TESTED",
    "bit_sha256":
        "09339351720f7aa776755234438cc61a25744dcd69de7f52f7aef625049ee8f3",
    "xsa_status": "PASS_GENERATED_AND_ZIP_VERIFIED_NOT_BOARD_TESTED",
    "xsa_sha256":
        "7e3726ab94d7c4937bb788f193319b62f1feadf69cb25c2c4446e301585e52d8",
    "xsa_external_bit_equal": True,
    "physical_board_evidence": "NONE",
}.items():
    require_equal(full_vivado.get(key), value, f"full Vivado metadata.{key}")
for key, tokens in {
    "ooc_synthesis": ("PASS", "loops=0", "blackboxes=0", "DSP=0", "101927/117120"),
    "board_synthesis": ("PASS", "loops=0", "blackboxes=0", "DSP=0", "104413/117120"),
    "implementation": (
        "PASS_FULLY_ROUTED", "137878/137878", "route_errors=0",
        "setup_WNS_ns=1.273", "hold_WHS_ns=0.010", "DRC=0",
        "methodology=0", "loops=0", "blackboxes=0", "DSP=0", "14594/14640",
    ),
}.items():
    require_tokens(full_vivado.get(key, ""), tokens, f"full Vivado {key}")
full_vivado_root, full_vivado_status = load_bound_receipt(
    full_vivado["receipt"],
    full_vivado["receipt_manifest_sha256"],
    full_vivado["receipt_entries"],
    "full Vivado 2023.2",
)
for key, value in {
    "overall_status": full_vivado["overall_status"],
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "source_design_sha256": "PENDING_M7_SEAL",
    "ordered_source_count": 80,
    "ordered_source_sha256": production_identity["ordered_source_sha256"],
    "development_manifest_entries": historical_input["development_manifest_entries"],
    "development_manifest_sha256": historical_input["development_manifest_sha256"],
    "bundle_info_sha256": historical_input["bundle_info_sha256"],
    "development_verifier_sha256": historical_input["development_verifier_sha256"],
    "filelist_sha256": production_identity["filelist_sha256"],
    "abi_v1_12_sha256": production_identity["abi_v1_12_sha256"],
    "vivado": full_vivado["vivado"],
    "target_clock_hz": 50000000,
}.items():
    require_equal(full_vivado_status.get(key), value, f"full Vivado receipt.{key}")
for section_name, expected_values in {
    "ooc_synthesis": {
        "status": "PASS", "combinational_loops": 0, "blackboxes": 0,
        "dsp48_dsp58": 0, "clb_lut_used": 101927, "clb_lut_available": 117120,
    },
    "board_synthesis": {
        "status": "PASS", "combinational_loops": 0, "blackboxes": 0,
        "dsp48_dsp58": 0, "clb_lut_used": 104413, "clb_lut_available": 117120,
    },
    "implementation": {
        "status": "PASS_FULLY_ROUTED", "place_design": "PASS", "route_design": "PASS",
        "routable_nets": 137878, "fully_routed_nets": 137878, "route_errors": 0,
        "setup_wns_ns": 1.273, "hold_whs_ns": 0.010, "drc_violations": 0,
        "methodology_violations": 0, "combinational_loops": 0, "blackboxes": 0,
        "dsp48_dsp58": 0, "clb_used": 14594, "clb_available": 14640,
    },
}.items():
    actual_section = full_vivado_status.get(section_name, {})
    for key, value in expected_values.items():
        require_equal(actual_section.get(key), value, f"full Vivado receipt {section_name}.{key}")
for key, value in {
    "bit_status": full_vivado["bit_status"],
    "bit_sha256": full_vivado["bit_sha256"],
    "xsa_status": full_vivado["xsa_status"],
    "xsa_sha256": full_vivado["xsa_sha256"],
    "xsa_external_bit_equal": True,
}.items():
    require_equal(full_vivado_status.get("artifacts", {}).get(key), value, f"full Vivado artifact {key}")
require_equal(
    sha256_file(full_vivado_root / "remote_snapshot/VIT_googlebase_rtl/artifacts/vit_system_wrapper.bit"),
    full_vivado["bit_sha256"],
    "full Vivado receipt BIT bytes",
)
require_equal(
    sha256_file(full_vivado_root / "remote_snapshot/VIT_googlebase_rtl/artifacts/vit_system_wrapper.xsa"),
    full_vivado["xsa_sha256"],
    "full Vivado receipt XSA bytes",
)

e04 = final_server.get("real_e04_mode3", {})
for key, value in {
    "canonical_receipt":
        "reports/m7/server_runs/20260808T112044Z-m7s8_mode3_e04_real_pass",
    "canonical_receipt_entries": 55,
    "canonical_receipt_manifest_sha256":
        "2859cb707350057026702f48d3cbabe72e2a8c8575e77d9bef6a43d9811ffa5e",
    "repeat_receipt":
        "reports/m7/server_runs/20260808T113352Z-m7s8_mode3_e04_real_repeat_pass",
    "repeat_receipt_entries": 30,
    "repeat_receipt_manifest_sha256":
        "c23876063b85fed2f014caa3c6a4d1e6dbfda5021bd7bf95597a8cdb2cc5b61f",
    "canonical_status": "PASS_REAL_E04_MODE3_RTL_SIMULATION",
    "repeat_status": "PASS_REAL_E04_MODE3_REPEAT_BYTE_IDENTICAL",
    "structural_checks": 202,
    "reported_total_cycles": 14327394,
    "commands": 5,
    "external_u32_words": 1532014,
    "writes": 154064,
    "class": 879,
    "m6_classifier_exact_mismatches": 0,
    "behavioral_tolerance_failures": 0,
    "repeat_output_report_pairs": "PASS_6_OF_6",
}.items():
    require_equal(e04.get(key), value, f"real E04 metadata.{key}")
require_tokens(
    e04.get("scope_limit", ""),
    ("server Verilator", "not complete E05/full-model", "not physical-board"),
    "real E04 scope",
)
_, e04_canonical_status = load_bound_receipt(
    e04["canonical_receipt"],
    e04["canonical_receipt_manifest_sha256"],
    e04["canonical_receipt_entries"],
    "canonical real E04",
)
_, e04_repeat_status = load_bound_receipt(
    e04["repeat_receipt"],
    e04["repeat_receipt_manifest_sha256"],
    e04["repeat_receipt_entries"],
    "repeat real E04",
)
require_equal(e04_canonical_status.get("overall_status"), e04["canonical_status"], "canonical E04 status")
require_equal(e04_repeat_status.get("overall_status"), e04["repeat_status"], "repeat E04 status")
for key in ("ordered_production_source_count", "ordered_production_source_sha256", "production_filelist_sha256"):
    expected_value = {
        "ordered_production_source_count": 80,
        "ordered_production_source_sha256": production_identity["ordered_source_sha256"],
        "production_filelist_sha256": production_identity["filelist_sha256"],
    }[key]
    require_equal(e04_canonical_status.get("design_identity", {}).get(key), expected_value, f"canonical E04 {key}")
for key in ("structural_checks", "reported_total_cycles", "commands", "external_u32_words", "writes", "class"):
    require_equal(e04_canonical_status.get("runtime", {}).get(key), e04[key], f"canonical E04 runtime {key}")
require_equal(
    e04_canonical_status.get("m6_classifier_oracle", {}).get("exact_mismatches"),
    e04["m6_classifier_exact_mismatches"],
    "canonical E04 M6 exact mismatches",
)
for key in ("final_layernorm_tolerance_failures", "logit_tolerance_failures", "probability_tolerance_failures"):
    require_equal(e04_canonical_status.get("behavioral_golden", {}).get(key), 0, f"canonical E04 {key}")
require_equal(
    e04_repeat_status.get("canonical_first_receipt", {}).get("receipt_manifest_sha256"),
    e04["canonical_receipt_manifest_sha256"],
    "repeat E04 canonical receipt identity",
)
require_equal(
    e04_repeat_status.get("byte_identical_to_canonical", {}).get("status"),
    e04["repeat_output_report_pairs"],
    "repeat E04 byte identity",
)

e01 = final_server.get("real_e01_mode3", {})
traffic_failure = e01.get("traffic_oracle_failure", {})
status_failure = e01.get("status_oracle_failure", {})
for failure_meta, expected_values, label in (
    (
        traffic_failure,
        {
            "receipt": "reports/m7/server_runs/20260808T120951Z-m7s8_mode3_e01_real_traffic_oracle_failure",
            "receipt_entries": 43,
            "receipt_manifest_sha256": "7426c5090ca0b2ec4156399e848f110d19f1a0e59df1d12c48642d98e2313e9e",
            "status": "FAIL_TRAFFIC_ORACLE_ASSERTION_AFTER_ALL_FOUR_RTL_COMMANDS",
            "classification": "HARNESS_EXACT_TRAFFIC_ORACLE_MISMATCH_NOT_A_NUMERICAL_RESULT",
        },
        "traffic-oracle failure",
    ),
    (
        status_failure,
        {
            "receipt": "reports/m7/server_runs/20260808T123843Z-m7s8_mode3_e01_oraclefix_m7_status_failure",
            "receipt_entries": 46,
            "receipt_manifest_sha256": "9d54ff2b30b7b247d258b90dc81f0e703607aa24de266b256d7ca190201dd573",
            "status": "FAIL_STALE_WHOLE_WORD_M7_STATUS_ASSERTION_AFTER_EXACT_TRAFFIC_AND_M5_GATES",
            "classification": "HARNESS_M7_STATUS_BITFIELD_ORACLE_MISMATCH_NOT_A_NUMERICAL_RESULT",
        },
        "M7-status-oracle failure",
    ),
):
    for key, value in expected_values.items():
        require_equal(failure_meta.get(key), value, f"{label}.{key}")
    require_tokens(
        failure_meta.get("disposition", ""),
        ("test-only oracle", "production source unchanged", "no numerical claim"),
        f"{label} disposition",
    )
_, traffic_failure_status = load_bound_receipt(
    traffic_failure["receipt"],
    traffic_failure["receipt_manifest_sha256"],
    traffic_failure["receipt_entries"],
    "traffic-oracle failure",
)
_, status_failure_status = load_bound_receipt(
    status_failure["receipt"],
    status_failure["receipt_manifest_sha256"],
    status_failure["receipt_entries"],
    "M7-status-oracle failure",
)
for failure_meta, failure_receipt, label in (
    (traffic_failure, traffic_failure_status, "traffic-oracle failure"),
    (status_failure, status_failure_status, "M7-status-oracle failure"),
):
    require_equal(failure_receipt.get("overall_status"), failure_meta["status"], f"{label} receipt status")
    require_equal(failure_receipt.get("failure_classification"), failure_meta["classification"], f"{label} classification")
    require_equal(
        failure_receipt.get("design_identity", {}).get("ordered_production_source_sha256"),
        production_identity["ordered_source_sha256"],
        f"{label} production identity",
    )
    require_equal(failure_receipt.get("numerical", {}).get("status"), "NOT_REACHED_NO_CLAIM", f"{label} numerical scope")
    require_equal(failure_receipt.get("numerical", {}).get("embedding_output_files"), 0, f"{label} output count")
require_equal(traffic_failure_status.get("runtime", {}).get("total_read_delta"), 766, "traffic failure read delta")
require_equal(status_failure_status.get("runtime", {}).get("traffic_and_bias_oracles_exact"), True, "status failure traffic gate")
require_equal(status_failure_status.get("runtime", {}).get("failed_m7_status_literal"), "0x00000002", "stale M7 status literal")

for key, value in {
    "canonical_receipt":
        "reports/m7/server_runs/20260808T130525Z-m7s8_mode3_e01_real_pass",
    "canonical_receipt_entries": 58,
    "canonical_receipt_manifest_sha256":
        "280650dafbb5c4c7fae944a3daa59ae6437abbe27df4e290ed9cca4e1e11d235",
    "repeat_receipt":
        "reports/m7/server_runs/20260808T132251Z-m7s8_mode3_e01_real_repeat_pass",
    "repeat_receipt_entries": 58,
    "repeat_receipt_manifest_sha256":
        "3b4d67f6fa884a5df73a076da46d29009da1600151ba60ef6d4cc55499fe6aa7",
    "canonical_status": "PASS_REAL_E01_MODE3_RTL_SIMULATION",
    "repeat_status": "PASS_REAL_E01_MODE3_REPEAT_BYTE_IDENTICAL",
    "runtime_simulator": "Verilator 5.020",
}.items():
    require_equal(e01.get(key), value, f"real E01 metadata.{key}")
e01_canonical_root, e01_canonical_status = load_bound_receipt(
    e01["canonical_receipt"],
    e01["canonical_receipt_manifest_sha256"],
    e01["canonical_receipt_entries"],
    "canonical real E01",
)
e01_repeat_root, e01_repeat_status = load_bound_receipt(
    e01["repeat_receipt"],
    e01["repeat_receipt_manifest_sha256"],
    e01["repeat_receipt_entries"],
    "repeat real E01",
)
require_equal(e01_canonical_status.get("overall_status"), e01["canonical_status"], "canonical E01 status")
require_equal(e01_repeat_status.get("overall_status"), e01["repeat_status"], "repeat E01 status")
for status_object, label in (
    (e01_canonical_status, "canonical E01"),
    (e01_repeat_status, "repeat E01"),
):
    require_equal(status_object.get("manifest_status"), "DEVELOPMENT_UNSEALED", f"{label} manifest status")
    require_equal(status_object.get("physical_board_evidence"), "NONE", f"{label} board scope")

runtime_fields = (
    "structural_checks", "reported_total_cycles", "commands", "external_u32_words",
    "model_reads", "input_reads", "scratch_reads", "writes", "invalid_accesses",
    "ar_transactions", "r_beats", "full_r_beats", "narrow_r_beats", "linefills",
    "line_hits", "max_read_outstanding", "bias_lookups", "bias_hits", "bias_misses",
    "bias_two_pass_refetches", "m7_status_word", "m7_status_running",
    "m7_status_snapshot_valid", "m7_status_overflow", "m7_status_error",
    "m7_status_load_compute", "m7_status_compute_store", "m7_status_three_way",
    "m7_status_both_banks_claimed", "m7_status_claim_mask", "m7_status_bank_max",
    "m7_status_fifo_max", "accepted_terms", "disabled_terms",
    "enabled_terms", "dots", "results", "panel_commits", "panel_claims",
    "panel_releases", "fifo_enqueues", "fifo_dequeues", "load_cycles",
    "compute_cycles", "store_cycles", "stage_union_cycles",
    "load_compute_overlap_cycles", "compute_store_overlap_cycles",
    "load_store_overlap_cycles", "three_way_overlap_cycles",
)
for key in runtime_fields:
    require_equal(e01_canonical_status.get("runtime", {}).get(key), e01.get(key), f"canonical E01 runtime {key}")
repeat_runtime = e01_repeat_status.get("repeat_runtime", {})
for key in (
    "structural_checks", "reported_total_cycles", "commands", "external_u32_words",
    "model_reads", "input_reads", "scratch_reads", "writes", "invalid_accesses",
    "ar_transactions", "r_beats", "full_r_beats", "narrow_r_beats", "linefills",
    "line_hits", "bias_lookups", "bias_hits", "bias_misses", "bias_two_pass_refetches",
    "m7_status_word", "accepted_terms", "disabled_terms", "enabled_terms", "dots",
    "results", "panel_commits", "panel_claims", "panel_releases", "load_cycles",
    "compute_cycles", "store_cycles", "stage_union_cycles",
    "load_compute_overlap_cycles", "compute_store_overlap_cycles",
    "load_store_overlap_cycles", "three_way_overlap_cycles",
):
    require_equal(repeat_runtime.get(key), e01.get(key), f"repeat E01 runtime {key}")

for key in (
    "embedding_words", "embedding_sha256", "embedding_nonfinite", "embedding_sentinel",
    "alternate_hidden_buffer_modified",
):
    require_equal(e01_canonical_status.get("outputs", {}).get(key), e01.get(key), f"canonical E01 output {key}")
require_equal(
    e01_canonical_status.get("m6_current_adder_oracle", {}).get("report_sha256"),
    e01["m6_report_sha256"],
    "canonical E01 M6 report",
)
require_equal(
    e01_canonical_status.get("m6_current_adder_oracle", {}).get("exact_mismatches"),
    e01["m6_exact_mismatches"],
    "canonical E01 M6 mismatches",
)
behavioral_field_map = {
    "behavioral_report_sha256": "report_sha256",
    "behavioral_abs_tolerance": "embedding_abs_tolerance",
    "behavioral_exact_mismatches": "embedding_exact_mismatches",
    "behavioral_tolerance_failures": "embedding_tolerance_failures",
    "behavioral_max_abs": "embedding_max_abs",
    "behavioral_max_abs_index": "embedding_max_abs_index",
    "behavioral_mean_abs": "embedding_mean_abs",
}
for metadata_key, receipt_key in behavioral_field_map.items():
    require_equal(
        e01_canonical_status.get("behavioral_golden", {}).get(receipt_key),
        e01.get(metadata_key),
        f"canonical E01 behavioral {receipt_key}",
    )
repeat_outputs = e01_repeat_status.get("outputs_and_oracles", {})
for metadata_key, repeat_key in {
    "embedding_words": "embedding_words",
    "embedding_sha256": "embedding_sha256",
    "embedding_nonfinite": "embedding_nonfinite",
    "embedding_sentinel": "embedding_sentinel",
    "alternate_hidden_buffer_modified": "alternate_hidden_buffer_modified",
    "m6_report_sha256": "m6_report_sha256",
    "m6_exact_mismatches": "m6_exact_mismatches",
    "behavioral_report_sha256": "behavioral_report_sha256",
    "behavioral_abs_tolerance": "behavioral_tolerance",
    "behavioral_tolerance_failures": "behavioral_tolerance_failures",
    "behavioral_max_abs": "behavioral_max_abs",
    "behavioral_mean_abs": "behavioral_mean_abs",
}.items():
    require_equal(repeat_outputs.get(repeat_key), e01.get(metadata_key), f"repeat E01 {repeat_key}")
require_equal(
    e01_repeat_status.get("canonical_first_receipt", {}).get("receipt_manifest_sha256"),
    e01["canonical_receipt_manifest_sha256"],
    "repeat E01 canonical receipt identity",
)
require_equal(
    e01_repeat_status.get("byte_identical_to_canonical", {}).get("output_report_pairs"),
    e01["repeat_output_report_pairs"],
    "repeat E01 output/report pairs",
)
require_equal(
    e01_repeat_status.get("byte_identical_to_canonical", {}).get("output_report_hash_observations"),
    e01["repeat_output_report_hash_observations"],
    "repeat E01 output/report hash observations",
)

pinned_identities = e01.get("pinned_identities", {})
expected_pinned_identities = {
    "e01_testbench_sha256":
        "128816b3fec273c749be08ea772819e37d6e48cf5755dfee1575dda0a56a1448",
    "e01_verilator_filelist_sha256":
        "8ce965dabef7611c75e8f2e90179670711805e4a48563bb40ac2b82d8e2ce79a",
    "e01_runner_sha256":
        "5ee3a67d3620fcab5bee799980f3fd1b322acce48565ab2c251e8867382aa8d8",
    "stager_sha256":
        "53fa492911285ae1ae3e671f44cd35b280b143227a51388c7cfccec8eba952f9",
    "asset_module_sha256":
        "f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed",
    "asset_tests_sha256":
        "dd59cdfc56d48c63411e6f73f608957845c5f44fdfdc7bbf209edb12852241f7",
    "axi128_ddr_model_sha256":
        "40803b5e7e0407173859e4aad82f1563896fbe9c4f50c477e9607fe2f9f03613",
    "m6_reference_sha256":
        "075d737a2ed94c17ecb37f7a507919d4be5c48c30de3a3c8403b72cd2550ad35",
    "fp32_adder_sha256":
        "3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141",
    "m7_counter_source_sha256":
        "a32aa1541481fd0de18adfadc1f5a596b9eb9579207e24c29d6885bc4550f48e",
    "axi_lite_regs_source_sha256":
        "7ab2cb6211294a7c8e58704bd2e0bb2e0c0f1904d923809d578d6b4a7c838b7c",
    "abi_v1_12_sha256":
        "25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35",
    "behavioral_embedding_golden_sha256":
        "47255d48149ead6a0c74625475e5f3e931c25f1f4c3e41dcc4b2941077d16e18",
}
require_equal(pinned_identities, expected_pinned_identities, "real E01 pinned identities")
canonical_harness = e01_canonical_status.get("harness_identity", {})
for metadata_key, receipt_key in {
    "e01_testbench_sha256": "testbench_sha256",
    "e01_verilator_filelist_sha256": "verilator_filelist_sha256",
    "e01_runner_sha256": "runner_sha256",
    "stager_sha256": "stager_sha256",
    "asset_module_sha256": "asset_module_sha256",
    "asset_tests_sha256": "asset_tests_sha256",
    "axi128_ddr_model_sha256": "axi128_ddr_model_sha256",
    "m6_reference_sha256": "m6_reference_sha256",
    "fp32_adder_sha256": "fp32_adder_sha256",
    "m7_counter_source_sha256": "m7_counter_source_sha256",
    "axi_lite_regs_source_sha256": "axi_lite_regs_source_sha256",
    "abi_v1_12_sha256": "abi_v1_12_sha256",
}.items():
    require_equal(
        canonical_harness.get(receipt_key),
        pinned_identities[metadata_key],
        f"canonical E01 pinned identity {receipt_key}",
    )
for relative_text, metadata_key in {
    "sim/end_to_end/tb_vit_phase_e_axi_e01_mode3_real_rtl.sv": "e01_testbench_sha256",
    "sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f": "e01_verilator_filelist_sha256",
    "sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh": "e01_runner_sha256",
    "sim/end_to_end/stage_m7_mode3_real_assets.py": "stager_sha256",
    "sim/end_to_end/m7_mode3_real_assets.py": "asset_module_sha256",
    "sim/end_to_end/tests/test_m7_mode3_real_assets.py": "asset_tests_sha256",
    "sim/axi/vit_axi_ddr_model_128.sv": "axi128_ddr_model_sha256",
    "rtl/leaf/fp32/vit_fp32_add_comb.sv": "fp32_adder_sha256",
    "rtl/axi/control/vit_phase_e_m7_overlap_counters.sv": "m7_counter_source_sha256",
    "rtl/axi/control/vit_axi_lite_control_regs.sv": "axi_lite_regs_source_sha256",
    "docs/PERF_PROFILE_ABI_V1_12.json": "abi_v1_12_sha256",
}.items():
    require_equal(
        sha256_file(checked_local_path(relative_text, f"pinned identity {metadata_key}")),
        pinned_identities[metadata_key],
        f"live pinned identity {metadata_key}",
    )
for receipt_root, label in (
    (e01_canonical_root, "canonical E01"),
    (e01_repeat_root, "repeat E01"),
):
    require_equal(
        sha256_file(receipt_root / "remote_snapshot/experimental/m6_fp16_nodsp_ooc/reference/m6_fp16_reference.py"),
        pinned_identities["m6_reference_sha256"],
        f"{label} M6 reference bytes",
    )
    require_equal(
        sha256_file(receipt_root / "remote_snapshot/results/embedding_step_06_hidden_states_f32.hex"),
        pinned_identities["behavioral_embedding_golden_sha256"],
        f"{label} behavioral golden bytes",
    )

m5_comparison = e01.get("same_scope_m5_comparison", {})
for key, value in {
    "evidence_class": "DERIVED_FROM_MATCHING_SIM_MEASURED_E01_RUNS",
    "m5_cycles": 424112402,
    "m7_cycles": 83387859,
    "cycles_saved": 340724543,
    "speedup": 5.086020999772,
    "cycle_reduction_percent": 80.338264430192,
    "m5_external_reads": 15350784,
    "external_read_delta_words": 766,
    "external_read_increase_percent": 0.004989973151,
}.items():
    require_equal(m5_comparison.get(key), value, f"same-scope M5 comparison.{key}")
require_equal(m5_comparison["cycles_saved"], m5_comparison["m5_cycles"] - m5_comparison["m7_cycles"], "derived E01 cycles saved")
require_equal(round(m5_comparison["m5_cycles"] / m5_comparison["m7_cycles"], 12), m5_comparison["speedup"], "derived E01 speedup")
require_equal(
    round(100 * m5_comparison["cycles_saved"] / m5_comparison["m5_cycles"], 12),
    m5_comparison["cycle_reduction_percent"],
    "derived E01 cycle reduction",
)
require_equal(e01["external_u32_words"] - m5_comparison["m5_external_reads"], m5_comparison["external_read_delta_words"], "derived E01 read delta")
require_equal(
    round(100 * m5_comparison["external_read_delta_words"] / m5_comparison["m5_external_reads"], 12),
    m5_comparison["external_read_increase_percent"],
    "derived E01 read increase",
)
require_tokens(m5_comparison.get("scope_limit", ""), ("server E01", "not complete E05", "board speed"), "same-scope M5 boundary")
require_tokens(e01.get("scope_limit", ""), ("server Verilator real-E01", "197x768", "not complete E05/full-model", "physical-board"), "real E01 boundary")

test_only = final_server.get("test_only_assets_absent_from_full_axi", {})
require_equal(test_only.get("count"), 9, "final test-only asset count")
require_tokens(
    test_only.get("historical_352_entry_manifest_delta", ""),
    ("exactly these nine", "after the full-Vivado input", "352 to 361", "80-source"),
    "final test-only manifest delta",
)
require_tokens(
    test_only.get("policy", ""),
    ("all nine", "verification-only", "absent", "full_axi.f"),
    "final test-only asset policy",
)
expected_final_test_assets = {
    "shared_asset_module": (
        "sim/end_to_end/m7_mode3_real_assets.py",
        "f064c2f5cc25fc836848b69d140119de0c2e9a22c256421c4eb371f17efa4aed",
    ),
    "shared_stager": (
        "sim/end_to_end/stage_m7_mode3_real_assets.py",
        "53fa492911285ae1ae3e671f44cd35b280b143227a51388c7cfccec8eba952f9",
    ),
    "shared_asset_tests": (
        "sim/end_to_end/tests/test_m7_mode3_real_assets.py",
        "dd59cdfc56d48c63411e6f73f608957845c5f44fdfdc7bbf209edb12852241f7",
    ),
    "e04_testbench": (
        "sim/end_to_end/tb_vit_phase_e_axi_e04_mode3_real_rtl.sv",
        "82ec39d6399ffdd3b24102b7f00a46cc3e98f0e7f97e8d558cd421653dc98888",
    ),
    "e04_verilator_filelist": (
        "sim/end_to_end/vit_phase_e_axi_e04_mode3_real_rtl_verilator.f",
        "ac98cc5a49a53d0f6fb5834639af37d1655244f052564c8b339476d44343d4d6",
    ),
    "e04_runner": (
        "sim/end_to_end/run_e04_mode3_real_axi_rtl_verilator.sh",
        "32f15467392f64b22e00a0a3a97f74b7ab0daec9fe1de76726cd35a77e9936b9",
    ),
    "e01_testbench": (
        "sim/end_to_end/tb_vit_phase_e_axi_e01_mode3_real_rtl.sv",
        "128816b3fec273c749be08ea772819e37d6e48cf5755dfee1575dda0a56a1448",
    ),
    "e01_verilator_filelist": (
        "sim/end_to_end/vit_phase_e_axi_e01_mode3_real_rtl_verilator.f",
        "8ce965dabef7611c75e8f2e90179670711805e4a48563bb40ac2b82d8e2ce79a",
    ),
    "e01_runner": (
        "sim/end_to_end/run_e01_mode3_real_axi_rtl_verilator.sh",
        "5ee3a67d3620fcab5bee799980f3fd1b322acce48565ab2c251e8867382aa8d8",
    ),
}
assets = test_only.get("assets", {})
require_equal(set(assets), set(expected_final_test_assets), "final test-only asset names")
require_equal(len(assets), 9, "final test-only asset identities")
for asset_name, (relative_text, expected_hash) in expected_final_test_assets.items():
    declared = assets.get(asset_name, {})
    require_equal(declared.get("path"), relative_text, f"final test asset {asset_name} path")
    require_equal(declared.get("sha256"), expected_hash, f"final test asset {asset_name} hash")
    if relative_text in sources:
        raise SystemExit(f"ERROR: final test-only asset entered production full_axi.f: {relative_text}")
    require_equal(
        sha256_file(checked_local_path(relative_text, f"final test asset {asset_name}")),
        expected_hash,
        f"final test asset bytes {asset_name}",
    )
e04_harness = e04_canonical_status.get("harness_identity", {})
for asset_name, receipt_key in {
    "e04_testbench": "testbench_sha256",
    "e04_verilator_filelist": "verilator_filelist_sha256",
    "e04_runner": "runner_sha256",
}.items():
    require_equal(
        e04_harness.get(receipt_key),
        assets[asset_name]["sha256"],
        f"canonical E04 test asset {asset_name}",
    )

# Reproduce the development-manifest path policy without writing a manifest.
# The exact closure delta from the Vivado input is these nine test-only files;
# BUNDLE/verifier byte changes alter hashes but do not add paths.
manifest_root_files = {
    ".gitignore", "BUNDLE_INFO.json", "PARENT_M5_MANIFEST.sha256",
    "README_SERVER.md", "import_vit_system_bd.tcl", "run_modelsim.do",
    "vit_phase_e_pure_sv.f",
}
manifest_root_dirs = {
    "docs", "filelists", "rtl", "run", "scripts", "sim", "third_party", "tools",
}
manifest_ignored_parts = {".Xil", "__pycache__", "server_logs"}
manifest_ignored_suffixes = {".pyc", ".vvp"}
current_manifest_paths = set()
for path in root.rglob("*"):
    if not path.is_file():
        continue
    relative = path.relative_to(root)
    relative_text = relative.as_posix()
    if relative_text == "M7_DEVELOPMENT_SHA256SUMS.txt":
        continue
    if any(part in manifest_ignored_parts for part in relative.parts):
        continue
    if path.suffix in manifest_ignored_suffixes:
        continue
    if len(relative.parts) == 1:
        if relative.name in manifest_root_files:
            current_manifest_paths.add(relative_text)
    elif relative.parts[0] in manifest_root_dirs:
        current_manifest_paths.add(relative_text)
expected_manifest_delta = {relative for relative, _ in expected_final_test_assets.values()}
require_equal(len(current_manifest_paths), 361, "final development-manifest path count")
require_equal(
    current_manifest_paths - set(historical_manifest_records),
    expected_manifest_delta,
    "post-Vivado development-manifest path additions",
)
require_equal(
    set(historical_manifest_records) - current_manifest_paths,
    set(),
    "post-Vivado development-manifest path removals",
)

require_equal(info.get("full_real_vit_base_inference_in_bundle"), False, "full real ViT-Base bundle scope")
require_equal(info.get("board_validation_status"), "PENDING_M7_PHYSICAL_FULL_E05", "board validation status")
require_equal(
    info.get("vivado_synthesis_implementation_status"),
    "CURRENT_V1_12_FP16_ONLY_FULL_VIVADO_2023_2_PASS_BIT_XSA_GENERATED_NOT_BOARD_TESTED",
    "current Vivado status",
)
require_tokens(
    final_server.get("boundary", ""),
    ("full Vivado", "real-E04/real-E01", "not bundled or run", "not finally sealed", "not physical-board validated"),
    "final server boundary",
)
require_tokens(
    info.get("migration_scope", ""),
    ("unsealed controlled child", "full Vivado 2023.2", "canonical/repeat real E04", "E01 server receipts", "complete E05", "physical-board"),
    "final migration scope",
)

# Preserve v1.9/v1.10/v1.11 exactly, then bind v1.12's narrowed START
# admission.  v1.12 changes no address, counter index, capability or geometry;
# it specializes the board profile to exact execution modes 3 and 5.
abi19 = json.loads((root / "docs/PERF_PROFILE_ABI_V1_9.json").read_text())
abi110 = json.loads((root / "docs/PERF_PROFILE_ABI_V1_10.json").read_text())
abi111 = json.loads((root / "docs/PERF_PROFILE_ABI_V1_11.json").read_text())
abi112 = json.loads((root / "docs/PERF_PROFILE_ABI_V1_12.json").read_text())
require_equal(abi111.get("schema"), "vit-phase-e-profile-abi-v1.11-m7-s8-two-pass", "ABI v1.11 schema")
require_equal(abi111.get("ip_version"), "0x0001000B", "ABI v1.11 IP")
compatibility = abi111.get("compatibility", {})
for key, value in {
    "base_schema": abi110.get("schema"),
    "base_document": "PERF_PROFILE_ABI_V1_10.json",
    "base_ip_version": "0x0001000A",
    "immutable_range": "0x000..0x8E4",
    "new_range": "none",
}.items():
    require_equal(compatibility.get(key), value, f"ABI v1.11 compatibility.{key}")
m7_abi = abi111.get("m7_overlap", {})
for key, value in {
    "capability_value": "0x01FF0817",
    "geometry_value_for_production_r8_c2_l16_s8": "0x08100208",
    "buffer_config_value_for_current_production": "0x00080202",
    "counter_base": "0x830",
    "counter_last_low_offset": "0x8E0",
    "last_offset": "0x8E4",
    "counter_stride_bytes": 8,
    "counter_count": 23,
    "counter_width_bits": 64,
    "counter_map_document": "PERF_PROFILE_ABI_V1_10.json",
}.items():
    require_equal(m7_abi.get(key), value, f"ABI v1.11 M7.{key}")
require_equal(
    abi111.get("unchanged_v1_10_sections"),
    [
        "capability_bits", "status_bits", "overflow_bits",
        "error_status_bits", "buffer_config_bits", "numeric_config_bits",
        "counters", "register_access_contract",
    ],
    "ABI v1.11 unchanged-section declaration",
)
require_equal(abi110.get("m7_overlap", {}).get("capability_value"), "0x01FF0817", "ABI v1.10 capability")
require_equal(abi110.get("m7_overlap", {}).get("buffer_config_value_for_current_production"), "0x00080202", "ABI v1.10 buffer config")
stable_fields = ("index", "name", "low_offset", "high_offset")
map19 = [tuple(item[field] for field in stable_fields) for item in abi19["counters"]]
map110 = [tuple(item[field] for field in stable_fields) for item in abi110["counters"]]
require_equal(len(map110), 23, "ABI v1.10 counter count")
require_equal(map110, map19, "ABI v1.9-to-v1.10 counter index/address map")

require_equal(
    abi112.get("schema"),
    "vit-phase-e-profile-abi-v1.12-m7-s8-fp16-only",
    "ABI v1.12 schema",
)
require_equal(abi112.get("ip_version"), "0x0001000C", "ABI v1.12 IP")
compatibility112 = abi112.get("compatibility", {})
for key, value in {
    "base_schema": abi111.get("schema"),
    "base_document": "PERF_PROFILE_ABI_V1_11.json",
    "base_ip_version": "0x0001000B",
    "immutable_range": "0x000..0x8E4",
    "new_range": "none",
    "first_unsupported_word_after_new_range": "0x8E8",
}.items():
    require_equal(
        compatibility112.get(key), value, f"ABI v1.12 compatibility.{key}"
    )
require_tokens(
    compatibility112.get("policy", ""),
    ("append-only register-map identity", "clean-idle START", "modes 3 and 5"),
    "ABI v1.12 compatibility policy",
)
mode_contract = abi112.get("execution_mode_contract", {})
for key, value in {
    "register_offset": "0x044",
    "register_access": "RW; every 32-bit value can be written and read back, but legality is checked atomically at START",
    "reset_value": "0x00000000",
    "legal_clean_idle_start_modes": [3, 5],
    "rejected_start_error_code": "0x80000003",
    "rejected_start_error_name": "WRAPPER_ERROR_EXECUTION_MODE",
    "rejected_start_error_info": "the exact rejected 32-bit EXECUTION_MODE value",
}.items():
    require_equal(mode_contract.get(key), value, f"ABI v1.12 mode contract.{key}")
require_tokens(
    mode_contract.get("reset_value_policy", ""),
    ("mode 0", "not executable", "mode 3 or mode 5"),
    "ABI v1.12 reset-mode policy",
)
require_tokens(
    mode_contract.get("rejected_modes", ""),
    ("0, 1, 2", "other than exact 3 or exact 5"),
    "ABI v1.12 rejected modes",
)
require_tokens(
    mode_contract.get("rejected_start_side_effect_contract", ""),
    ("no job snapshot", "performance epoch", "AXI DDR request"),
    "ABI v1.12 rejection side effects",
)
require_equal(
    mode_contract.get("mode_3_job_snapshot"),
    {
        "model_b_blocked_k16_n2": 1,
        "model_b_fp16_packed2": 1,
        "fp16_gemm_compat_enable": 1,
        "model_contract": "package-v3 persistent GEMM-B packed as two FP16 values per u32",
        "model_base_alignment_bytes": 128,
    },
    "ABI v1.12 mode-3 snapshot",
)
require_equal(
    mode_contract.get("mode_5_job_snapshot"),
    {
        "model_b_blocked_k16_n2": 1,
        "model_b_fp16_packed2": 0,
        "fp16_gemm_compat_enable": 1,
        "model_contract": "package-v2 blocked-K16/N2 persistent GEMM-B stored as FP32 and converted for FP16 GEMM compute",
    },
    "ABI v1.12 mode-5 snapshot",
)
m7_abi112 = abi112.get("m7_overlap", {})
for key, value in {
    "capability_value": "0x01FF0817",
    "geometry_value_for_production_r8_c2_l16_s8": "0x08100208",
    "buffer_config_value_for_current_production": "0x00080202",
    "counter_base": "0x830",
    "counter_last_low_offset": "0x8E0",
    "last_offset": "0x8E4",
    "counter_stride_bytes": 8,
    "counter_count": 23,
    "counter_width_bits": 64,
    "counter_map_document": "PERF_PROFILE_ABI_V1_10.json",
}.items():
    require_equal(m7_abi112.get(key), value, f"ABI v1.12 M7.{key}")
require_tokens(
    m7_abi112.get("current_production_contract", ""),
    ("Legal modes 3 and 5", "FP32-compute modes 0 and 1 are absent", "reject at START"),
    "ABI v1.12 production hierarchy",
)
require_equal(
    abi112.get("unchanged_v1_11_sections"),
    [
        "capability_bits", "status_bits", "overflow_bits",
        "error_status_bits", "geometry_bits", "buffer_config_bits",
        "numeric_config_bits", "counters",
        "register_access_contract_except_start_admission",
    ],
    "ABI v1.12 unchanged-section declaration",
)

source_paths = {
    "top": "rtl/top/vit_phase_e_axi_bd_wrapper.v",
    "wrapper": "rtl/axi/vit_phase_e_axi_wrapper.sv",
    "npu": "rtl/core/vit_phase_e_npu.sv",
    "engine": "rtl/core/vit_phase_e_engine_top.sv",
    "dual": "rtl/blocks/gemm/vit_gemm_dual_mode_array.sv",
    "scheduler": "rtl/blocks/gemm/vit_gemm_fp16_parallel_scheduler.sv",
    "address": "rtl/core/vit_gemm_memory_address_context.sv",
    "frontend": "rtl/core/vit_phase_e_memory_frontend.sv",
    "counter": "rtl/axi/control/vit_phase_e_m7_overlap_counters.sv",
    "control": "rtl/axi/control/vit_axi_lite_control_regs.sv",
    "adder": "rtl/leaf/fp32/vit_fp32_add_comb.sv",
    "bd": "scripts/vivado/create_vit_system_bd.tcl",
    "stage20": "scripts/server/20_run_ooc_synth.tcl",
    "stage30": "scripts/server/30_create_clean_project_and_bd.tcl",
    "stage40": "scripts/server/40_run_board_synth.tcl",
    "stage50": "scripts/server/50_run_board_impl.tcl",
    "common": "scripts/server/vivado_server_common.tcl",
    "collector": "run/90_collect_results.sh",
    "run_all": "run/run_all.sh",
    "xsim": "run/10_xsim_axi_smoke.sh",
    "dual_runner": "sim/m7/run_m7_dual_mode_iverilog.sh",
    "dual_fp16_tb": "sim/m7/tb_vit_gemm_dual_mode_array_fp16_only.sv",
    "wrapper_runner": "sim/axi/run_axi_wrapper_fp16_only_iverilog.sh",
    "wrapper_tb": "sim/axi/tb_vit_phase_e_axi_wrapper.sv",
    "compact_tb": "sim/end_to_end/tb_vit_phase_e_axi_e05_compact_rtl.sv",
}
text = {
    name: checked_local_path(path, name).read_text(encoding="utf-8")
    for name, path in source_paths.items()
}

for name in ("top", "wrapper", "npu", "engine", "dual", "scheduler"):
    require_pattern(
        text[name],
        r"parameter\s+integer\s+FP16_STREAMS\s*=\s*8",
        f"{name} FP16_STREAMS=8 default",
    )
for name in ("top", "wrapper", "npu", "engine", "dual"):
    require_pattern(
        text[name],
        r"\.FP16_STREAMS\s*\(\s*FP16_STREAMS\s*\)",
        f"{name} FP16 stream propagation",
    )
for pattern, label in (
    (r"\.STREAMS\s*\(\s*FP16_STREAMS\s*\)", "counter stream propagation"),
    (r"\.RESULT_FIFO_DEPTH\s*\(\s*2\s*\)", "counter result FIFO depth 2"),
    (r"\.GENERATION_BITS\s*\(\s*8\s*\)", "counter generation width 8"),
):
    require_pattern(text["wrapper"], pattern, label)
require_pattern(text["control"], r"IP_VERSION_VALUE\s*=\s*32'h0001_000c", "IP v1.12")
require_pattern(text["counter"], r"32'h013f_0817", "M7 capability base")
require_pattern(text["counter"], r"assign\s+geometry_o\s*=\s*\{\s*8'\(STREAMS\)", "M7 geometry stream field")

# The reusable selector retains both generate branches for leaf regression,
# while the only production engine instance binds parameter zero.  The
# focused parameter-zero elaboration script must also inspect its hierarchy
# and reject any instantiated u_legacy scope.
require_pattern(
    text["dual"],
    r"parameter\s+integer\s+INCLUDE_LEGACY_GEMM\s*=\s*1",
    "parameterized legacy GEMM selector",
)
require_pattern(
    text["dual"],
    r"generate\s+if\s*\(\s*INCLUDE_LEGACY_GEMM\s*!=\s*0\s*\)\s*begin\s*:\s*gen_legacy(?s:.*?)vit_gemm_tree_array\s*#(?s:.*?)\)\s*u_legacy\s*\(",
    "dual selector legacy generate branch",
)
require_pattern(
    text["dual"],
    r"end\s+else\s+begin\s*:\s*gen_no_legacy(?s:.*?)assign\s+legacy_busy\s*=\s*1'b0(?s:.*?)end\s+endgenerate",
    "dual selector no-legacy generate branch",
)
require_equal(
    len(re.findall(r"\bvit_gemm_tree_array\s*#", text["dual"])),
    1,
    "dual selector legacy-instance source count",
)
require_pattern(
    text["engine"],
    r"vit_gemm_dual_mode_array\s*#\s*\((?s:.*?)\.INCLUDE_LEGACY_GEMM\s*\(\s*0\s*\)(?s:.*?)\)\s*u_gemm\s*\(",
    "production engine INCLUDE_LEGACY_GEMM=0 binding",
)
require_pattern(
    text["dual_fp16_tb"],
    r"\.INCLUDE_LEGACY_GEMM\s*\(\s*0\s*\)",
    "focused no-legacy test binding",
)
require_tokens(
    text["dual_runner"],
    (
        "tb_vit_gemm_dual_mode_array_fp16_only",
        "grep -q 'gen_no_legacy'",
        "grep -q '\\.scope module, \"u_legacy\"'",
        "ERROR: FP16-only elaboration retained u_legacy",
        "PASS M7 FP16-only GEMM checks=",
    ),
    "focused no-legacy elaboration gate",
)
require_tokens(
    text["dual_fp16_tb"],
    (
        "PASS M7 FP16-only GEMM checks=%0d",
        'reject_non_fp16(1\'b0)',
        'reject_non_fp16(1\'b1)',
        'run_fp16_mode(1\'b1, "mode3 packed FP16-only")',
        'run_fp16_mode(1\'b0, "mode5 compatibility FP16-only")',
    ),
    "focused no-legacy exact result",
)

# Exact clean-idle START admission: only modes 3 and 5.  Rejected encodings
# preserve their full value in ERROR_INFO and cannot start a performance epoch
# or NPU/DDR activity.
require_pattern(
    text["wrapper"],
    r"assign\s+execution_mode_legal\s*=\s*\(\s*execution_mode\s*==\s*32'd3\s*\)\s*\|\|\s*\(\s*execution_mode\s*==\s*32'd5\s*\)\s*;",
    "exact mode-3/mode-5 START admission",
)
require_tokens(
    text["wrapper"],
    (
        "WRAPPER_ERROR_EXECUTION_MODE",
        "else if (!execution_mode_legal)",
        "error_code_sticky <= WRAPPER_ERROR_EXECUTION_MODE",
        "error_info_sticky <= execution_mode",
        "execution_mode_legal && packed_model_alignment_legal",
    ),
    "fail-closed execution-mode rejection",
)
require_tokens(
    text["wrapper_tb"],
    (
        'expect_execution_mode_reject(32\'d0, "mode 0")',
        'expect_execution_mode_reject(32\'d1, "mode 1")',
        'expect_execution_mode_reject(32\'d2, "mode 2")',
        'expect_execution_mode_reject(32\'d4, "reserved mode 4")',
        'expect_execution_mode_reject(32\'hffff_ffff, "reserved all-ones mode")',
        '"mode 3 START accepted"',
        '"mode 5 START accepted"',
        "VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=%0d",
    ),
    "wrapper legal/rejected-mode regression",
)
require_tokens(
    text["wrapper_runner"],
    ("^VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=178$",),
    "focused wrapper exact marker",
)
require_equal(
    sha256_file(root / source_paths["adder"]),
    adder_correction["feedforward_adder_sha256"],
    "current feed-forward FP32 adder",
)
require_equal(
    len(re.findall(r"^\s*assign\s+", text["adder"], re.MULTILINE)),
    53,
    "feed-forward FP32 adder continuous-assignment count",
)
if re.search(r"\balways(?:_comb|_ff|_latch)?\b", text["adder"]):
    raise SystemExit("ERROR: feed-forward FP32 adder contains a procedural block")
if re.search(r"\b(?:for|while|repeat|forever)\s*\(", text["adder"]):
    raise SystemExit("ERROR: feed-forward FP32 adder contains a procedural loop")
require_tokens(
    text["adder"],
    ("strictly feed-forward", "single continuous assignment", "assign result ="),
    "feed-forward FP32 adder contract",
)
runner_path = root / expected_test_assets["runner"][0]
if not (runner_path.stat().st_mode & 0o111):
    raise SystemExit("ERROR: feed-forward A/B runner is not executable")

for pattern, label in (
    (r"FP16_TWO_PASS\s*=\s*\(FP16_STREAMS\s*==\s*ARRAY_ROWS\)", "S8 two-pass selection"),
    (r"fallback_column_q", "S8 fallback-column state"),
    (r"second_column_valid", "S8 odd-N column gate"),
    (r"k_base\s*<=\s*32'd0", "S8 K rewind"),
    (r"\.GENERATION_BITS\s*\(\s*8\s*\)", "scheduler generation width 8"),
    (r"\.DEPTH\s*\(\s*2\s*\)", "scheduler result FIFO depth 2"),
):
    require_pattern(text["scheduler"], pattern, label)
require_pattern(text["address"], r"k_base\s*<\s*previous_k_base", "address-context rewind comparison")
require_pattern(text["address"], r"activation_address_base\s*<=\s*activation_token_base", "address-context A restore")
require_pattern(text["address"], r"weight_address_base\s*<=\s*weight_output_base", "address-context B restore")
require_tokens(
    text["frontend"],
    ("There is deliberately no B cache", "profile_b_bypass_o"),
    "explicit no-B-cache/bypass source",
)

require_pattern(text["bd"], r"variable\s+fp16_streams\s+8", "BD S8 variable")
require_pattern(
    text["bd"],
    r"proc\s+verify_design\s+\{\}\s+\{(?s:.*?)variable\s+fp16_streams(?s:.*?)require_property\s+\$accelerator_cell\s+CONFIG\.FP16_STREAMS\s+\$fp16_streams",
    "BD verify_design FP16_STREAMS namespace import",
)
require_tokens(
    text["bd"],
    ("CONFIG.FP16_STREAMS $fp16_streams", "require_property $accelerator_cell CONFIG.FP16_STREAMS $fp16_streams"),
    "BD S8 set/readback contract",
)
require_tokens(
    text["stage30"],
    ("CONFIG.FP16_STREAMS", "vit_system_geometry.rpt"),
    "stage-30 geometry receipt",
)

# The two early capacity checks must be exact and must execute before any
# implementation launch.  Stage 50 repeats both checks to fail closed when it
# is invoked directly; the collector also refuses a complete receipt without
# both PASS files and exact arithmetic.
require_tokens(
    text["common"],
    ("proc require_clb_lut_fit", "CLB LUTs\\*", "M7S8_CLB_LUT_FIT", "headroom"),
    "common CLB-LUT fit parser",
)
for stage_name in ("stage20", "stage40"):
    require_tokens(
        text[stage_name],
        ("require_clb_lut_fit", "write_checkpoint"),
        f"{stage_name} CLB-LUT gate",
    )
    if text[stage_name].index("require_clb_lut_fit") > text[stage_name].index("write_checkpoint"):
        raise SystemExit(f"ERROR: {stage_name} CLB-LUT gate occurs after checkpoint")
require_tokens(
    text["stage50"],
    ("rtl_ooc_post_synth", "board_post_synth", "require_clb_lut_fit", "launch_runs"),
    "stage-50 prerequisite fit gates",
)
if text["stage50"].rindex("require_clb_lut_fit") > text["stage50"].index("launch_runs"):
    raise SystemExit("ERROR: implementation can launch before both CLB-LUT gates")
require_tokens(
    text["run_all"],
    ("VIT_RUN_IMPLEMENTATION=1 requires VIT_RUN_OOC_SYNTH=1", "run/00_verify_m7_development.sh"),
    "run_all safe implementation prerequisites",
)
for token in (
    "rtl_ooc_post_synth_lut_fit_gate.rpt",
    "board_post_synth_lut_fit_gate.rpt",
    "M7S8_CLB_LUT_FIT",
    "vit_collect_fit_used > vit_collect_fit_available",
    "CONFIG.FP16_STREAMS 8",
):
    require_tokens(text["collector"], (token,), "collector S8/fit closure")

# A complete receipt must bind exactly the two fail-closed compact logs and the
# one legal cycle-exact mode-3 log.  This prevents an inherited mode-1 success
# log or a generic compact filename from satisfying the FP16-only flow.
collector_compact_modes = set(
    re.findall(
        r"server_logs/10_tb_vit_phase_e_axi_e05_compact_rtl_mode([0-9]+)\.log",
        text["collector"],
    )
)
require_equal(
    collector_compact_modes,
    {"0", "1", "3"},
    "collector exact FP16-only compact-log modes",
)
require_tokens(
    text["xsim"],
    (
        '"tb_vit_phase_e_axi_wrapper|^VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=178$"',
        "for vit_xsim_compact_mode in 0 1 3; do",
        '^VIT_PHASE_E_AXI_E05_COMPACT_RTL_MODE_REJECT_PASS mode=${vit_xsim_compact_mode} checks=36 error=80000003 info=0000000${vit_xsim_compact_mode}$',
        "PASS: production AXI/engine/profile/M7 smoke plus compact mode0/mode1 rejection and exact mode3 E05 XSim completed",
    ),
    "exact FP16-only XSim cases and markers",
)
require_tokens(
    text["compact_tb"],
    (
        "VIT_PHASE_E_AXI_E05_COMPACT_RTL_MODE_REJECT_PASS mode=%0d checks=%0d error=80000003 info=%08x",
        "rejected FP32 mode opens no performance epoch",
        "rejected FP32 mode accepts no production command",
        "rejected FP32 mode performs no modeled DDR transaction",
    ),
    "compact fail-closed side-effect gate",
)

expected_compact_marker = (
    "VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 rows=8 cols=2 "
    "checks=2081 cycles=495849 job_cycles=488317 commands=249 "
    "blocked_gemm=74 packed_gemm=74 fp16_gemm=98 row_major_gemm=24 "
    "packed_tiles=1175 nonpacked_tiles=264 reads=39185 writes=10646 "
    "axi_stalls=3849 model_reads=22429 input_reads=32 scratch_reads=16724 "
    "cmd_active=487340 logical_reads=95449 cache_hits=55080 "
    "valid_mac=59376 tail_mac=124816 class=3 logit=40e00000"
)
require_tokens(text["xsim"], (expected_compact_marker,), "exact S8 XSim compact marker")

print(
    "M7S8_FINAL_SERVER_QUALIFICATION_PASS "
    "vivado_receipt=791c31e52c60e8e6af4bcf6c29f55cea6f79553bb89024705b5cc061df305a8d "
    "e04_canonical=2859cb707350057026702f48d3cbabe72e2a8c8575e77d9bef6a43d9811ffa5e "
    "e04_repeat=c23876063b85fed2f014caa3c6a4d1e6dbfda5021bd7bf95597a8cdb2cc5b61f "
    "e01_canonical=280650dafbb5c4c7fae944a3daa59ae6437abbe27df4e290ed9cca4e1e11d235 "
    "e01_repeat=3b4d67f6fa884a5df73a076da46d29009da1600151ba60ef6d4cc55499fe6aa7 "
    "cycles=83387859 embedding=e06079ecc3bcd16678fafeec44c52535ac955876569bd96449b15f01978b7df9 "
    "post_vivado_test_assets=9 final_manifest_paths=361 board=NONE full_e05=PENDING"
)
print(
    "M7S8_FP16_ONLY_BUNDLE_INFO_PASS "
    f"sources={len(sources)} ordered_sha256={ordered_sha} "
    "seal=PENDING_M7_SEAL ip=0x0001000C capability=0x01FF0817 "
    "geometry=0x08100208 buffer=0x00080202 streams=8 "
    "legal_modes=3,5 legacy_production=0 "
    "place30_487_receipt=e6455349faaf59927c771c664d82ea2b7c1df31c819162a01f69be69bad06a0e"
)
PY

# This is intentionally the final source-closure gate.  Generate the manifest
# only after every source/doc/flow edit is quiescent; any later mutation makes
# this verifier fail before Vivado can open or create a production project.
"${vit_python_bin}" tools/m7/m7_development_manifest.py check

printf 'M7S8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M7_SEAL parent=%s m6=%s\n' \
    "${vit_parent_manifest_sha}" "${vit_m6_source_manifest_sha}"
