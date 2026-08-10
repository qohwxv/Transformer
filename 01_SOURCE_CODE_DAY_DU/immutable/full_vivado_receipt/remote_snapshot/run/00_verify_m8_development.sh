#!/usr/bin/env bash
set -euo pipefail

vit_m8_verify_root="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
cd "${vit_m8_verify_root}"

vit_m8_verify_mode="${1:-full}"
if [[ "${vit_m8_verify_mode}" != "full" &&
      "${vit_m8_verify_mode}" != "--metadata-only" ]]; then
    printf 'ERROR: usage: %s [--metadata-only]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
fi

if [[ -n "${VIT_SYSTEM_PYTHON+x}" ]]; then
    printf '%s\n' \
        'ERROR: VIT_SYSTEM_PYTHON overrides are forbidden; strict M8 verification is pinned to /usr/bin/python3' >&2
    exit 1
fi
readonly vit_m8_python="/usr/bin/python3"
vit_m8_python_resolved="$(readlink -f -- "${vit_m8_python}" 2>/dev/null || true)"
if [[ ! "${vit_m8_python_resolved}" =~ ^/usr/bin/python3\.[0-9]+$ ||
      -L "${vit_m8_python_resolved}" ||
      ! -f "${vit_m8_python_resolved}" ||
      ! -x "${vit_m8_python_resolved}" ]]; then
    printf 'ERROR: /usr/bin/python3 must resolve to a regular executable named /usr/bin/python3.N; found: %s\n' \
        "${vit_m8_python_resolved:-UNRESOLVED}" >&2
    exit 1
fi
readonly vit_m8_python_resolved

# Vivado exports PYTHONHOME/PYTHONPATH for its bundled runtime. The verifier
# deliberately uses the system Python; clearing these variables affects only
# this child process.
env -u PYTHONHOME -u PYTHONPATH \
    "${vit_m8_python_resolved}" - "${vit_m8_verify_root}" "${vit_m8_verify_mode}" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath


root = Path(sys.argv[1]).resolve()
verify_mode = sys.argv[2]
replay_receipt_payloads = verify_mode == "full"


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_path(relative_text: str, label: str) -> Path:
    relative = PurePosixPath(relative_text)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != relative_text
    ):
        fail(f"unsafe {label} path: {relative_text}")
    path = root / relative_text
    if path.is_symlink():
        fail(f"{label} must not be a symlink: {relative_text}")
    if not path.is_file() or path.stat().st_size == 0:
        fail(f"missing or empty {label}: {relative_text}")
    return path


def load_json(relative_text: str, label: str) -> dict:
    path = checked_path(relative_text, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def checked_directory(relative_text: str, label: str) -> Path:
    relative = PurePosixPath(relative_text)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != relative_text
    ):
        fail(f"unsafe {label} directory: {relative_text}")
    path = root / relative_text
    cursor = root
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            fail(f"symlinked component in {label} directory: {cursor}")
    if not path.is_dir():
        fail(f"missing or symlinked {label} directory: {relative_text}")
    return path


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        fail(f"{label} mismatch: expected {expected!r}, found {actual!r}")


def require_tokens(relative_text: str, tokens: tuple[str, ...], label: str) -> None:
    text = checked_path(relative_text, label).read_text(encoding="utf-8")
    missing = [token for token in tokens if token not in text]
    if missing:
        fail(f"{label} is missing tokens: {missing}")


def require_regex(relative_text: str, pattern: str, label: str) -> None:
    text = checked_path(relative_text, label).read_text(encoding="utf-8")
    if re.search(pattern, text, flags=re.MULTILINE) is None:
        fail(f"{label} does not match {pattern!r}")


def canonical_receipt_path(relative_text: str, manifest: Path, line_number: int) -> str:
    # Several preserved receipts were produced by `find .` and intentionally
    # store one leading "./". Accept that documented spelling while binding a
    # single canonical path and rejecting all other ambiguous forms.
    canonical_text = relative_text[2:] if relative_text.startswith("./") else relative_text
    relative = PurePosixPath(canonical_text)
    if (
        not canonical_text
        or relative.is_absolute()
        or ".." in relative.parts
        or relative.as_posix() != canonical_text
        or relative_text.startswith(".//")
    ):
        fail(f"unsafe receipt path {manifest}:{line_number}: {relative_text!r}")
    return canonical_text


def verify_receipt_closure(
    relative_root: str,
    manifest_name: str,
    expected_manifest_sha256: str,
    expected_entries: int,
    expected_sidecars: dict[str, str],
) -> int:
    receipt_root = checked_directory(relative_root, "M8 receipt")
    manifest = receipt_root / manifest_name
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size == 0:
        fail(f"missing, empty or symlinked receipt manifest: {manifest}")
    require_equal(
        sha256_file(manifest),
        expected_manifest_sha256,
        f"receipt manifest {relative_root}",
    )

    declared: dict[str, str] = {}
    for line_number, line in enumerate(
        manifest.read_text(encoding="utf-8").splitlines(), 1
    ):
        if len(line) < 67 or line[64:66] != "  ":
            fail(f"malformed receipt record {manifest}:{line_number}")
        digest, relative_text = line[:64], line[66:]
        if any(character not in "0123456789abcdef" for character in digest):
            fail(f"malformed receipt SHA-256 {manifest}:{line_number}")
        canonical_text = canonical_receipt_path(relative_text, manifest, line_number)
        if canonical_text in declared:
            fail(f"duplicate canonical receipt path {manifest}:{line_number}")
        declared[canonical_text] = digest
    require_equal(len(declared), expected_entries, f"receipt entries {relative_root}")

    all_paths = sorted(receipt_root.rglob("*"))
    symlinks = [
        path.relative_to(receipt_root).as_posix()
        for path in all_paths
        if path.is_symlink()
    ]
    if symlinks:
        fail(f"receipt contains symlinks {relative_root}: {symlinks}")
    excluded = {manifest_name, *expected_sidecars}
    current_files = {
        path.relative_to(receipt_root).as_posix()
        for path in all_paths
        if path.is_file()
        and path.relative_to(receipt_root).as_posix() not in excluded
    }
    if set(declared) != current_files:
        missing = sorted(current_files - set(declared))
        extra = sorted(set(declared) - current_files)
        fail(f"receipt closure mismatch {relative_root}: missing={missing} extra={extra}")

    for sidecar_name, expected_sidecar_sha256 in expected_sidecars.items():
        sidecar = receipt_root / sidecar_name
        if sidecar.is_symlink() or not sidecar.is_file() or sidecar.stat().st_size == 0:
            fail(f"missing, empty or symlinked receipt sidecar: {sidecar}")
        require_equal(
            sha256_file(sidecar),
            expected_sidecar_sha256,
            f"receipt sidecar {relative_root}/{sidecar_name}",
        )
        require_equal(
            sidecar.read_text(encoding="utf-8"),
            f"{expected_manifest_sha256}  {manifest_name}\n",
            f"receipt sidecar content {relative_root}/{sidecar_name}",
        )

    if replay_receipt_payloads:
        for canonical_text, expected_digest in declared.items():
            require_equal(
                sha256_file(receipt_root / canonical_text),
                expected_digest,
                f"receipt payload {relative_root}/{canonical_text}",
            )
    return len(declared)


expected_source = "db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e"
expected_parent_source = "1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888"
expected_filelist = "88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524"
expected_parent_manifest = "0fd289058fbcfb2eff5a63664d14232f39b2b9e30e3023c890e8f6ddc901f838"
expected_abi = "b15765c858edb0785c34ea75fa50fa5df873f1d22cd53ed2bc0b898db13d8e90"

info = load_json("BUNDLE_INFO.json", "M8 bundle metadata")
for key, expected in {
    "schema": "vit-vivado-server-bundle-v1",
    "bundle_name": "vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2",
    "created_date": "2026-08-09",
    "parent_bundle_name": "vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2",
    "parent_manifest_sha256": expected_parent_manifest,
    "parent_source_design_sha256": expected_parent_source,
    "manifest_status": "DEVELOPMENT_UNSEALED",
    "source_design_sha256": "PENDING_M8_SEAL",
    "current_development_source_design_sha256": expected_source,
    "source_design_file_count": 80,
    "production_rtl_files": 80,
    "vivado_version": "2023.2",
    "target_part": "xczu5ev-sfvc784-1-e",
    "target_board": "digilentinc.com:gzu_5ev:part0:1.1",
    "production_pl_clock_hz": 50000000,
    "production_pl_clock_period_ns": 20.0,
    "synthesis_flatten_hierarchy": "none",
    "ip_version": "0x0001000D",
    "vivado_synthesis_implementation_status": "M8_FULL_DESIGN_VIVADO_NOT_RUN",
    "board_validation_status": "PENDING_M8_FULL_VIVADO_BIT_XSA_COMPLETE_E05_AND_PHYSICAL_BOARD",
}.items():
    require_equal(info.get(key), expected, f"BUNDLE_INFO.{key}")

if "ordered sha256sum-record stream" not in info.get("source_design_hash_scope", ""):
    fail("BUNDLE_INFO source hash scope does not define the ordered-record identity")
if "DSP48/DSP58" not in info.get("dsp_policy", "") or "zero" not in info.get("dsp_policy", ""):
    fail("BUNDLE_INFO hard DSP-zero policy is absent")

geometry = info.get("production_geometry", {})
for key, expected in {
    "array_rows": 8,
    "array_cols": 2,
    "pe_lanes": 16,
    "fp16_streams": 8,
    "logical_tile": "R8xC2",
    "physical_fp16_pass": "R8xC1",
}.items():
    require_equal(geometry.get(key), expected, f"production_geometry.{key}")

axi = info.get("native_axi_contract", {})
for key, expected in {
    "control_data_width_bits": 32,
    "memory_data_width_bits": 128,
    "memory_addr_width_bits": 40,
    "memory_id_width_bits": 1,
    "maximum_burst_beats": 4,
    "maximum_read_outstanding": 2,
    "maximum_write_outstanding": 1,
}.items():
    require_equal(axi.get(key), expected, f"native_axi_contract.{key}")

perf = info.get("perf_counter_abi", {})
for key, expected in {
    "m7_capability": "0x01FF0817",
    "m7_buffer_config": "0x00080202",
    "m7_counter_count": 23,
    "machine_readable_map": "docs/PERF_PROFILE_ABI_V1_13.json",
    "machine_readable_map_sha256": expected_abi,
    "prior_machine_readable_map": "docs/PERF_PROFILE_ABI_V1_12.json",
    "prior_machine_readable_map_sha256": "25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35",
}.items():
    require_equal(perf.get(key), expected, f"perf_counter_abi.{key}")

parent = info.get("parent_m7s8_provenance", {})
for key, expected in {
    "provenance_file_sha256": "221b32f46dcdd6e5afbfa20fb0ef48d955cb3bcb639e3c82809c10923dab8b54",
    "development_manifest_entries": 361,
    "development_manifest_sha256": expected_parent_manifest,
    "ordered_source_count": 80,
    "ordered_source_sha256": expected_parent_source,
    "filelist_sha256": expected_filelist,
    "artifact_boundary": "M7_FULL_VIVADO_BIT_XSA_AND_BOARD_EVIDENCE_ARE_PARENT_ONLY_NOT_M8_ARTIFACTS",
}.items():
    require_equal(parent.get(key), expected, f"parent_m7s8_provenance.{key}")
if "parent" not in parent.get("scope", "") or "no M7" not in parent.get("scope", ""):
    fail("direct-parent artifact boundary is incomplete")

require_equal(
    sha256_file(checked_path("PARENT_M7S8_PROVENANCE.txt", "M7-S8 provenance")),
    parent["provenance_file_sha256"],
    "PARENT_M7S8_PROVENANCE.txt SHA-256",
)
require_equal(
    sha256_file(checked_path("M7_DEVELOPMENT_SHA256SUMS.txt", "historical M7 manifest")),
    expected_parent_manifest,
    "historical M7 manifest SHA-256",
)
require_tokens(
    "PARENT_M7S8_PROVENANCE.txt",
    (
        "Parent ordered 80-source stream SHA256: " + expected_parent_source,
        "Parent filelists/full_axi.f SHA256: " + expected_filelist,
        "Historical M7 BIT/XSA and server receipts are parent evidence only",
    ),
    "M7-S8 provenance",
)

m8 = info.get("m8_integration_contract", {})
for key, expected in {
    "status": "M8_SIMULATION_QUALIFIED_FULL_DESIGN_VIVADO_PENDING",
    "ip_version": "0x0001000D",
    "ordered_source_count": 80,
    "ordered_source_sha256": expected_source,
    "filelist_sha256": expected_filelist,
    "parent_unchanged_source_count": 74,
    "changed_source_count": 6,
}.items():
    require_equal(m8.get(key), expected, f"m8_integration_contract.{key}")

expected_changed = {
    "rtl/blocks/vector/vit_vector_engine_fp32.sv": "c71542773318964a538384d81bf9b842361678e81132986d5a31ad0b1ec96df2",
    "rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv": "f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f",
    "rtl/blocks/softmax/vit_softmax_engine_fp32.sv": "9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9",
    "rtl/core/vit_phase_e_read_address_router.sv": "4dcd75977601711b9324e431f7582b9791b69dd17720f4fd5e7184df8bb12219",
    "rtl/core/vit_phase_e_engine_top.sv": "0056ebc96dfd23a0de2fd2ad25d3acd53ad2985ee69bebdab5253946609fe512",
    "rtl/axi/control/vit_axi_lite_control_regs.sv": "00eceb2222ea89eb1d4d0149baf4185047be8c72047a0958e0a18dbdc54426b6",
}
require_equal(m8.get("changed_sources"), expected_changed, "six exact M8 changed sources")
for relative_text, expected_hash in expected_changed.items():
    require_equal(
        sha256_file(checked_path(relative_text, "M8 production source")),
        expected_hash,
        f"production source {relative_text}",
    )

expected_ram = {
    "total_ramb36": 41,
    "activation_cache": 32,
    "bias_cache": 4,
    "layernorm": 3,
    "softmax": 1,
    "layer_param_table": 1,
    "ramb18": 0,
    "uram": 0,
    "new_layernorm_softmax_buffer_lutram": 0,
}
require_equal(m8.get("full_design_ram_hierarchy"), expected_ram, "M8 RAM hierarchy")
for name, expected_ramb36 in (("layernorm_row_affine_buffer", 3), ("softmax_row_exp_buffer", 1)):
    value = m8.get(name, {})
    require_equal(value.get("production_enable"), 1, f"{name} enable")
    require_equal(value.get("production_depth_words"), 1024, f"{name} depth")
    require_equal(value.get("expected_ramb36"), expected_ramb36, f"{name} RAMB36")
    require_equal(value.get("forbidden_lutram"), True, f"{name} LUTRAM policy")

full_flow = info.get("m8_full_vivado_gate_contract", {})
require_equal(full_flow.get("status"), "PENDING_NOT_RUN", "M8 full Vivado status")
require_equal(full_flow.get("bit_status"), "NOT_GENERATED", "M8 BIT status")
require_equal(full_flow.get("xsa_status"), "NOT_GENERATED", "M8 XSA status")
for key, required_tokens in {
    "receipt_identity_gate": ("six bound M8", "658", "full SHA-256 payload replay"),
    "terminal_source_identity_gate": ("initial M8 manifest hash", "strict terminal verifier", "collection reruns"),
    "clean_project_gate": ("VIT_REUSE_PROJECT=0", "reuse=1 is rejected"),
    "xsim_thread_gate": ("defaults to 2", "auto", "off", "integer >=2", "value 1"),
    "python_gate": ("/usr/bin/python3", "VIT_SYSTEM_PYTHON", "forbidden"),
    "artifact_gate": (
        "exactly one BIT",
        "exactly three HWH",
        "vit_system.hwh",
        "vit_system_smartconnect_control_0.hwh",
        "vit_system_smartconnect_ddr_0.hwh",
        "byte-for-byte",
    ),
}.items():
    value = full_flow.get(key, "")
    for token in required_tokens:
        if token not in value:
            fail(f"M8 full-flow {key} is missing {token!r}")
for required in (
    "blackboxes=0",
    "latches=0",
    "combinational loops=0",
    "DSP48/DSP58=0",
    "RAMB36 hierarchy=32+4+3+1+1=41",
    "LayerNorm/Softmax buffer LUTRAM=0",
):
    if required not in full_flow.get("required_post_synth_gates", []):
        fail(f"missing post-synthesis gate: {required}")
for required in (
    "fully routed and route errors=0",
    "setup WNS>=0",
    "hold WHS>=0",
    "internal constraint coverage clean",
    "total DRC violations=0",
    "total methodology violations=0",
):
    if required not in full_flow.get("required_post_route_gates", []):
        fail(f"missing post-route gate: {required}")

abi = load_json("docs/PERF_PROFILE_ABI_V1_13.json", "ABI v1.13")
require_equal(sha256_file(root / "docs/PERF_PROFILE_ABI_V1_13.json"), expected_abi, "ABI v1.13 SHA-256")
for key, expected in {
    "schema": "vit-phase-e-profile-abi-v1.13-m8-nongemm-nodsp",
    "ip_version": "0x0001000D",
    "profile": "m8_nongemm_nodsp_board_development",
    "axi_lite_address_width": 12,
}.items():
    require_equal(abi.get(key), expected, f"ABI v1.13 {key}")
compatibility = abi.get("compatibility", {})
for key, expected in {
    "base_schema": "vit-phase-e-profile-abi-v1.12-m7-s8-fp16-only",
    "base_document": "PERF_PROFILE_ABI_V1_12.json",
    "base_ip_version": "0x0001000C",
    "immutable_range": "0x000..0x8E4",
    "new_range": "none",
}.items():
    require_equal(compatibility.get(key), expected, f"ABI compatibility.{key}")
require_equal(abi.get("changed_production_sources"), [
    {"path": path, "sha256": digest} for path, digest in expected_changed.items()
], "ABI changed production sources")
require_equal(
    abi.get("m8_non_gemm_acceleration", {}).get("full_design_ram_gate"),
    {
        "total_ramb36": 41,
        "activation_cache_ramb36": 32,
        "bias_cache_ramb36": 4,
        "layernorm_ramb36": 3,
        "softmax_ramb36": 1,
        "layer_param_table_ramb36": 1,
        "ramb18": 0,
        "uram": 0,
        "new_layernorm_softmax_buffer_lutram": 0,
        "scope_note": "inherited distributed RAM elsewhere in the design is not relabelled as an M8 buffer and is not required to be globally zero",
    },
    "ABI full-design RAM gate",
)

filelist = checked_path("filelists/full_axi.f", "production filelist")
require_equal(sha256_file(filelist), expected_filelist, "full_axi.f SHA-256")
sources: list[str] = []
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
        fail(f"unsafe production source path: {relative_text}")
    sources.append(relative_text)
if len(sources) != 80 or len(set(sources)) != 80:
    fail(f"full_axi.f must contain 80/80 ordered unique sources; found {len(sources)}/{len(set(sources))}")
records: list[str] = []
for relative_text in sources:
    source = checked_path(relative_text, "production source")
    records.append(f"{sha256_file(source)}  {relative_text}\n")
ordered_sha = hashlib.sha256("".join(records).encode("utf-8")).hexdigest()
require_equal(ordered_sha, expected_source, "ordered 80-source stream")

require_regex(
    "rtl/axi/control/vit_axi_lite_control_regs.sv",
    r"IP_VERSION_VALUE\s*=\s*32'h0001_000d",
    "production IP literal",
)
require_regex(
    "rtl/core/vit_phase_e_engine_top.sv",
    r"\.ENABLE_ROW_AFFINE_BUFFER\s*\(\s*1\s*\)[\s\S]*?\.ROW_AFFINE_BUFFER_DEPTH\s*\(\s*1024\s*\)",
    "explicit production LayerNorm buffer binding",
)
require_regex(
    "rtl/core/vit_phase_e_engine_top.sv",
    r"\.ENABLE_ROW_EXP_BUFFER\s*\(\s*1\s*\)[\s\S]*?\.ROW_EXP_BUFFER_DEPTH\s*\(\s*1024\s*\)",
    "explicit production Softmax buffer binding",
)
for relative_text, pattern, label in (
    ("sim/axi/tb_vit_phase_e_axi_wrapper.sv", r"32'h0001_000d", "wrapper IP oracle"),
    ("sim/control/tb_vit_axi_lite_control_regs.sv", r"32'h0001_000d", "control IP oracle"),
    ("sim/m5/tb_m5_axi_counter_bank.sv", r"32'h0001_000d", "M5-bank IP oracle"),
    ("sim/end_to_end/tb_vit_phase_e_axi_e05_compact_rtl.sv", r"32'h0001_000d", "compact IP oracle"),
):
    require_regex(relative_text, pattern, label)

# Current RTL and simulation files contain several independent IP-version
# oracles and runner markers.  Bind all detected literals, including harnesses
# added after the original four mandatory seams above, and reject any stale
# v1.12-or-earlier current-tree literal before a manifest can be accepted.
ip_literal_patterns = (
    re.compile(r"32\s*'\s*h\s*0001_000([0-9a-f])", flags=re.IGNORECASE),
    re.compile(r"(?<![0-9a-f])(?:0x)?0001000([0-9a-f])(?![0-9a-f])", flags=re.IGNORECASE),
)
ip_text_suffixes = {".f", ".md", ".py", ".sh", ".sv", ".svh", ".tcl", ".v", ".vh"}
ip_literal_count = 0
for source_root_name in ("rtl", "sim"):
    source_root = root / source_root_name
    for path in sorted(source_root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in ip_text_suffixes:
            continue
        if path.is_symlink():
            fail(f"IP-literal scan input must not be a symlink: {path.relative_to(root)}")
        text = path.read_text(encoding="utf-8")
        for pattern in ip_literal_patterns:
            for match in pattern.finditer(text):
                ip_literal_count += 1
                if match.group(1).lower() != "d":
                    line_number = text.count("\n", 0, match.start()) + 1
                    fail(
                        "stale current-tree IP literal "
                        f"{match.group(0)!r} at {path.relative_to(root)}:{line_number}"
                    )
if ip_literal_count == 0:
    fail("current RTL/simulation tree contains no detectable v1.13 IP literal")

require_tokens(
    "rtl/axi/vit_phase_e_axi_wrapper.sv",
    ("MAX_BURST_LENGTH 4", "NUM_READ_OUTSTANDING 2", "NUM_WRITE_OUTSTANDING 1"),
    "native AXI interface metadata",
)

qualification = info.get("m8_simulation_qualification", {})
expected_receipt_closure = {
    "simulation_checkpoint": {
        "root": "reports/m8/checkpoints/20260808T182708Z-m8_simulation_qualification",
        "manifest": "SHA256SUMS.txt",
        "manifest_sha256": "a73adcf2e6597ef81e733dcdccbf9e6d95938b5edad0581617412133c446da3f",
        "entries": 3,
        "sidecars": {
            "RECEIPT_MANIFEST.sha256": "3f315e28afc6145e16da98eba022ab0e14528f4a29e44fe998e971f0db0a07e5"
        },
    },
    "softmax_leaf_ooc": {
        "root": "reports/m8/server_runs/20260808T161943Z-m8-softmax-ooc-ab-holdfix",
        "manifest": "RECEIPT_SHA256SUMS.txt",
        "manifest_sha256": "e5aa7485c96bf9789dcfca76af29b4580bfc0a767d4608ea662ab3caea5f3174",
        "entries": 94,
        "sidecars": {
            "RECEIPT_MANIFEST.sha256": "5d6182862397d42590efcdf036647c93a80dc342d30f5867a8c8a2d54d2ab454"
        },
    },
    "layernorm_leaf_ooc": {
        "root": "reports/m8/server_runs/20260808T164100Z-m8-layernorm-ooc-ab-generate-fix",
        "manifest": "RECEIPT_SHA256SUMS.txt",
        "manifest_sha256": "a1f7e6c42eea1ba71f0768cb17c2b3f407d739424047b6bd0ee6f92ab0fb0f09",
        "entries": 71,
        "sidecars": {
            "RECEIPT_MANIFEST.sha256": "dfa291f9a03430dcc41370be72ad4ca247a5ca3ffc6405c0d48a96d20aef66aa"
        },
    },
    "xsim_exact_10of10": {
        "root": "reports/m8/server_runs/20260808T171800Z-m8-xsim-exact-10of10-receipt",
        "manifest": "RECEIPT_SHA256SUMS.txt",
        "manifest_sha256": "83c88bf0458cd8ac29a0e8cd76014ad49c97507c0513d538cf3be78da3f8c059",
        "entries": 143,
        "sidecars": {},
    },
    "real_e04_repeat": {
        "root": "reports/m8/server_runs/20260808T173000Z-m8-e04-mode3-pass-repeat-receipt",
        "manifest": "RECEIPT_SHA256SUMS.txt",
        "manifest_sha256": "8d2d448aefc24ac386ea4bc80087584a85c357179686396b85016158535f85cf",
        "entries": 162,
        "sidecars": {},
    },
    "real_e01_threepass": {
        "root": "reports/m8/server_runs/20260808T181104Z-m8-e01-mode3-threepass-receipt",
        "manifest": "RECEIPT_SHA256SUMS.txt",
        "manifest_sha256": "05df7fff6d1b714b5b8c5f519325f5a416f27c0c1c33c1f6c7b0cfaebcf9a3e0",
        "entries": 185,
        "sidecars": {},
    },
}
require_equal(
    qualification.get("receipt_closure"),
    expected_receipt_closure,
    "M8 receipt closure metadata",
)
receipt_entry_total = 0
for receipt_name, receipt_spec in expected_receipt_closure.items():
    receipt_entry_total += verify_receipt_closure(
        receipt_spec["root"],
        receipt_spec["manifest"],
        receipt_spec["manifest_sha256"],
        receipt_spec["entries"],
        receipt_spec["sidecars"],
    )
require_equal(receipt_entry_total, 658, "total M8 receipt payload entries")
for qualification_key, receipt_name in {
    "checkpoint_sha256sums_sha256": "simulation_checkpoint",
    "softmax_leaf_ooc_receipt_manifest_sha256": "softmax_leaf_ooc",
    "layernorm_leaf_ooc_receipt_manifest_sha256": "layernorm_leaf_ooc",
    "xsim_10of10_receipt_manifest_sha256": "xsim_exact_10of10",
    "real_e04_receipt_manifest_sha256": "real_e04_repeat",
    "real_e01_receipt_manifest_sha256": "real_e01_threepass",
}.items():
    require_equal(
        qualification.get(qualification_key),
        expected_receipt_closure[receipt_name]["manifest_sha256"],
        f"qualification receipt anchor {qualification_key}",
    )
require_equal(
    qualification.get("checkpoint_receipt_manifest_sha256"),
    expected_receipt_closure["simulation_checkpoint"]["sidecars"]
        ["RECEIPT_MANIFEST.sha256"],
    "qualification checkpoint sidecar anchor",
)
print(
    "M8_RECEIPT_CLOSURE_PASS receipts=6 entries=658 sidecars=3 "
    f"payload_replay={'FULL' if replay_receipt_payloads else 'SKIPPED_METADATA_ONLY'}"
)

checkpoint = load_json(
    "reports/m8/checkpoints/20260808T182708Z-m8_simulation_qualification/STATUS.json",
    "M8 simulation checkpoint status",
)
require_equal(checkpoint.get("m8_production", {}).get("ordered_source_sha256"), expected_source, "checkpoint source")
require_equal(checkpoint.get("m8_production", {}).get("changed_source_count"), 6, "checkpoint changed-source count")
require_equal(checkpoint.get("full_design_and_board_boundary", {}).get("full_design_vivado"), "NOT_RUN", "checkpoint full-Vivado boundary")
require_equal(checkpoint.get("full_design_and_board_boundary", {}).get("m8_bit"), "NOT_GENERATED", "checkpoint BIT boundary")
require_equal(checkpoint.get("full_design_and_board_boundary", {}).get("m8_xsa"), "NOT_GENERATED", "checkpoint XSA boundary")

# Static full-flow closure: these tokens are requirements, not Vivado results.
require_tokens(
    "run/00_verify_m8_development.sh",
    (
        'readonly vit_m8_python="/usr/bin/python3"',
        "VIT_SYSTEM_PYTHON overrides are forbidden",
        '^/usr/bin/python3\\.[0-9]+$',
        'readonly vit_m8_python_resolved',
    ),
    "strict M8 Python pin",
)
require_tokens(
    "tools/m8/m8_development_manifest.py",
    (
        '"PARENT_M7S8_PROVENANCE.txt"',
        '"M7_DEVELOPMENT_SHA256SUMS.txt"',
        'DEFAULT_MANIFEST = BUNDLE_ROOT / "M8_DEVELOPMENT_SHA256SUMS.txt"',
        "ROOT_DIRS = {",
        '"tools",',
    ),
    "M8 manifest generator",
)
require_tokens(
    "run/run_all.sh",
    (
        "run/00_verify_m8_development.sh",
        "M8_DEVELOPMENT_SHA256SUMS.txt",
        "M8_ORDERED_SOURCE_SHA256",
        "90_terminal_m8_verifier.log",
        "TERMINAL_M8_VERIFIER_SHA256",
        "PENDING_COLLECTION",
        "M8 sign-off requires VIT_REUSE_PROJECT=0",
        "hwh_entries=3",
        "vit_system_smartconnect_control_0.hwh",
        "vit_system_smartconnect_ddr_0.hwh",
        expected_source,
    ),
    "M8 full-flow runner",
)
run_all_text = checked_path("run/run_all.sh", "M8 full-flow runner").read_text(
    encoding="utf-8"
)
for forbidden in (
    'VIT_REUSE_PROJECT must be 0' + ' or 1',
    'if [[ "${vit_run_reuse_project}" '
    + '== "0" ]]',
):
    if forbidden in run_all_text:
        fail(f"M8 full-flow runner retains forbidden project-reuse path: {forbidden}")
require_tokens(
    "run/10_xsim_axi_smoke.sh",
    (
        'vit_xsim_threads="${VIT_XSIM_THREADS:-2}"',
        'VIT_XSIM_THREADS=1 is invalid for xelab --mt',
        '"${vit_xsim_threads}" != "auto"',
        '"${vit_xsim_threads}" != "off"',
        '^([2-9]|[1-9][0-9]+)$',
        '--mt "${vit_xsim_threads}"',
    ),
    "M8 XSim thread gate",
)
xsim_runner_text = checked_path(
    "run/10_xsim_axi_smoke.sh", "M8 XSim thread gate"
).read_text(encoding="utf-8")
if "VIT_XSIM_THREADS must be a positive" + " integer" in xsim_runner_text:
    fail("M8 XSim runner retains the invalid positive-integer thread gate")
require_tokens(
    "scripts/server/vivado_server_common.tcl",
    (
        "proc require_m8_development_manifest",
        "M8_CLB_LUT_FIT",
        "proc require_no_blackboxes",
        "M8_BLACKBOX_GATE",
        "proc require_no_latches",
        "M8_LATCH_GATE",
        "proc require_m8_ram_mapping",
        "M8_RAM_HIERARCHY",
        "[llength $all_ramb36] != 41",
        "activation=32",
        "bias=4",
        "layernorm=3",
        "softmax=1",
        "layer_param=1",
        "proc require_no_drc_violations",
        "M8_DRC_GATE",
        "total=[llength $violations]",
        "proc require_no_methodology_violations",
        "M8_METHODOLOGY_GATE",
        "M8_XSA_CONTENT_GATE",
        "[llength $hwh_entries] == 3",
        "hwh_set_equal",
        "vit_system.hwh",
        "vit_system_smartconnect_control_0.hwh",
        "vit_system_smartconnect_ddr_0.hwh",
        "embedded_bit_equal",
    ),
    "M8 server gate library",
)
for relative_text, tokens in {
    "scripts/server/20_run_ooc_synth.tcl": (
        "require_no_blackboxes",
        "require_no_latches",
        "require_m8_ram_mapping",
        "require_no_dsp",
        "require_no_combinational_loops",
    ),
    "scripts/server/40_run_board_synth.tcl": (
        "require_no_blackboxes",
        "require_no_latches",
        "require_m8_ram_mapping",
        "require_no_dsp",
        "require_no_combinational_loops",
    ),
    "scripts/server/50_run_board_impl.tcl": (
        "require_no_blackboxes",
        "require_no_latches",
        "require_m8_ram_mapping",
        "require_no_dsp",
        "require_no_combinational_loops",
        "require_route_complete",
        "write_timing_gate",
        "write_constraint_coverage_gate",
        "require_no_drc_violations",
        "require_no_methodology_violations",
        "write_bitstream",
        "write_hw_platform",
        "validate_xsa_contents",
    ),
    "scripts/server/55_export_current_impl_xsa.tcl": (
        "require_no_blackboxes",
        "require_no_latches",
        "require_m8_ram_mapping",
        "require_no_dsp",
        "require_no_combinational_loops",
        "require_route_complete",
        "write_timing_gate",
        "write_constraint_coverage_gate",
        "require_no_drc_violations",
        "require_no_methodology_violations",
        "write_hw_platform",
        "validate_xsa_contents",
    ),
}.items():
    require_tokens(relative_text, tokens, relative_text)
require_tokens(
    "scripts/vivado/vit_project_common.tcl",
    ("M8_COMBINATIONAL_LOOP_GATE", "FLATTEN_HIERARCHY"),
    "Vivado common gate library",
)
require_tokens(
    "run/90_collect_results.sh",
    (
        "M8_ORDERED_SOURCE_SHA256",
        expected_source,
        "M8_CLB_LUT_FIT",
        "M8_BLACKBOX_GATE PASS",
        "M8_LATCH_GATE PASS",
        "M8_RAM_HIERARCHY PASS",
        "DSP48/DSP58 primitive count: 0",
        "M8_COMBINATIONAL_LOOP_GATE PASS",
        "M8_DRC_GATE PASS",
        "M8_METHODOLOGY_GATE PASS",
        "total=0 severe=0",
        "TERMINAL_M8_VERIFIER_RESULT PASS",
        "COLLECTOR_M8_VERIFIER_RESULT PASS",
        "M8_OUTPUT_COLLECTION_PASS",
        "COLLECTOR_XSA_CONTENT_GATE PASS",
        "M8_XSA_CONTENT_GATE PASS",
        "VIT_REUSE_PROJECT 0",
        "embedded_bit_equal=1",
        "setup_wns",
        "hold_whs",
        "ROUTED_FULLY 1",
        "ERRORS_IN_ROUTES 0",
        "exactly one BIT",
        "exactly three HWH",
        "vit_system_smartconnect_control_0.hwh",
        "vit_system_smartconnect_ddr_0.hwh",
    ),
    "M8 output collector",
)

print(
    "M8_METADATA_PREFLIGHT_PASS "
    f"sources=80 ordered={ordered_sha} filelist={expected_filelist} "
    "ip=0x0001000D abi=v1.13 parent=M7S8 receipts=BOUND "
    "full_vivado=PENDING bit_xsa=NOT_GENERATED"
)
PY

if [[ "${vit_m8_verify_mode}" == "full" ]]; then
    env -u PYTHONHOME -u PYTHONPATH \
        "${vit_m8_python_resolved}" tools/m8/m8_development_manifest.py check
    printf '%s\n' \
        'M8_DEVELOPMENT_PREFLIGHT_PASS status=DEVELOPMENT_UNSEALED seal=PENDING_M8_SEAL'
else
    printf '%s\n' \
        'M8_METADATA_ONLY_PASS manifest=DELIBERATELY_NOT_CHECKED_OR_GENERATED'
fi
