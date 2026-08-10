#!/usr/bin/env python3
"""Verify the externally sealed M8 real-E05 launch source set.

The expected hashes live in a separate data-only manifest so the runner can
be one of the objects being authenticated.  This verifier fixes the required
roles and canonical paths; a manifest cannot silently omit or redirect one.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Mapping


SCHEMA = "vit-m8-mode3-e05-launch-manifest-v1"
REVISION = "vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# Keep the seven originally audited E05 files first, followed by every
# external helper that participates in launch or post-run qualification.
EXPECTED_PATHS: tuple[tuple[str, str], ...] = (
    (
        "e05_testbench",
        f"{REVISION}/sim/end_to_end/"
        "tb_vit_phase_e_axi_e05_mode3_real_rtl.sv",
    ),
    (
        "e05_simulation_filelist",
        f"{REVISION}/sim/end_to_end/"
        "vit_phase_e_axi_e05_mode3_real_rtl_verilator.f",
    ),
    (
        "e05_asset_module",
        f"{REVISION}/sim/end_to_end/m8_mode3_e05_real_assets.py",
    ),
    (
        "e05_stager",
        f"{REVISION}/sim/end_to_end/stage_m8_mode3_e05_real_assets.py",
    ),
    (
        "e05_runner",
        f"{REVISION}/sim/end_to_end/"
        "run_e05_mode3_real_axi_rtl_verilator.sh",
    ),
    (
        "e05_asset_tests",
        f"{REVISION}/sim/end_to_end/tests/"
        "test_m8_mode3_e05_real_assets.py",
    ),
    (
        "e05_harness_document",
        f"{REVISION}/sim/end_to_end/M8_REAL_E05_HARNESS.md",
    ),
    (
        "qualified_common_helper",
        f"{REVISION}/sim/end_to_end/m7_mode3_real_assets.py",
    ),
    (
        "ddr_model",
        f"{REVISION}/sim/axi/vit_axi_ddr_model_128.sv",
    ),
    (
        "m6_reference",
        "experimental/m6_fp16_nodsp_ooc/reference/m6_fp16_reference.py",
    ),
    (
        "current_fp32_adder_oracle_rtl",
        "vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2/"
        "rtl/leaf/fp32/vit_fp32_add_comb.sv",
    ),
    (
        "launch_manifest_verifier",
        f"{REVISION}/sim/end_to_end/verify_m8_e05_launch_manifest.py",
    ),
    (
        "run_evidence_helper",
        f"{REVISION}/sim/end_to_end/m8_e05_run_evidence.py",
    ),
)


class LaunchManifestError(RuntimeError):
    """The launch manifest or one of its bound files failed closed."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _absolute_normalized(path: Path, description: str) -> Path:
    if not path.is_absolute() or Path(os.path.abspath(os.fspath(path))) != path:
        raise LaunchManifestError(f"{description} must be absolute and normalized")
    return path


def _regular_without_symlinks(path: Path, description: str) -> Path:
    path = _absolute_normalized(path, description)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise LaunchManifestError(f"{description} contains a symlink: {current}")
    if not path.is_file():
        raise LaunchManifestError(f"{description} is missing/nonregular: {path}")
    return path


def _canonical_relative(text: object) -> str:
    if not isinstance(text, str):
        raise LaunchManifestError("manifest path is not a string")
    value = PurePosixPath(text)
    if (
        not text
        or value.is_absolute()
        or ".." in value.parts
        or value.as_posix() != text
        or any(part in {"", "."} for part in value.parts)
    ):
        raise LaunchManifestError(f"manifest path is not canonical: {text!r}")
    return text


def verify_launch_manifest(
    workspace_root: Path, manifest_path: Path
) -> Mapping[str, object]:
    """Verify the exact role/path/hash/size closure and return its receipt."""

    workspace_root = _absolute_normalized(workspace_root, "workspace root")
    if workspace_root.is_symlink() or not workspace_root.is_dir():
        raise LaunchManifestError("workspace root is missing, non-directory, or symlinked")
    manifest_path = _regular_without_symlinks(manifest_path, "launch manifest")
    try:
        manifest_path.relative_to(workspace_root)
    except ValueError as exc:
        raise LaunchManifestError("launch manifest escapes the workspace") from exc

    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LaunchManifestError(f"cannot parse launch manifest: {exc}") from exc
    if not isinstance(value, dict) or set(value) != {
        "schema",
        "revision",
        "entries",
    }:
        raise LaunchManifestError("launch manifest top-level contract mismatch")
    if value["schema"] != SCHEMA or value["revision"] != REVISION:
        raise LaunchManifestError("launch manifest schema/revision mismatch")
    entries = value["entries"]
    if not isinstance(entries, list) or len(entries) != len(EXPECTED_PATHS):
        raise LaunchManifestError("launch manifest entry count mismatch")

    aggregate = hashlib.sha256()
    observed: dict[str, str] = {}
    for index, ((required_role, required_path), row) in enumerate(
        zip(EXPECTED_PATHS, entries, strict=True)
    ):
        if not isinstance(row, dict) or set(row) != {
            "role",
            "path",
            "bytes",
            "sha256",
        }:
            raise LaunchManifestError(f"manifest entry {index} contract mismatch")
        relative = _canonical_relative(row["path"])
        if row["role"] != required_role or relative != required_path:
            raise LaunchManifestError(
                f"manifest entry {index} role/path mismatch: {row.get('role')!r}"
            )
        if (
            not isinstance(row["bytes"], int)
            or isinstance(row["bytes"], bool)
            or row["bytes"] < 1
            or not isinstance(row["sha256"], str)
            or not SHA256_RE.fullmatch(row["sha256"])
        ):
            raise LaunchManifestError(f"manifest entry {index} size/hash is invalid")
        path = _regular_without_symlinks(
            workspace_root / relative, f"manifest entry {required_role}"
        )
        actual_size = path.stat().st_size
        actual_sha256 = _sha256(path)
        if actual_size != row["bytes"] or actual_sha256 != row["sha256"]:
            raise LaunchManifestError(
                f"launch input changed: role={required_role} path={relative} "
                f"expected_bytes={row['bytes']} actual_bytes={actual_size} "
                f"expected_sha256={row['sha256']} actual_sha256={actual_sha256}"
            )
        record = f"{required_role}\0{relative}\0{actual_size}\0{actual_sha256}\n"
        aggregate.update(record.encode("utf-8"))
        observed[required_role] = actual_sha256

    return {
        "schema": SCHEMA,
        "revision": REVISION,
        "entries": len(entries),
        "manifest_sha256": _sha256(manifest_path),
        "aggregate_sha256": aggregate.hexdigest(),
        "runner_sha256": observed["e05_runner"],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        receipt = verify_launch_manifest(args.workspace_root, args.manifest)
    except (LaunchManifestError, OSError, ValueError) as exc:
        print(f"ERROR: M8 E05 launch manifest rejected: {exc}", file=sys.stderr)
        return 2
    print(
        "M8_MODE3_E05_LAUNCH_MANIFEST_PASS "
        f"entries={receipt['entries']} "
        f"manifest_sha256={receipt['manifest_sha256']} "
        f"aggregate_sha256={receipt['aggregate_sha256']} "
        f"runner_sha256={receipt['runner_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

