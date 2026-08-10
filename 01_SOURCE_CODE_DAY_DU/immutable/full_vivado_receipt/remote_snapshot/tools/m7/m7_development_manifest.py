#!/usr/bin/env python3
"""Generate or verify the deterministic, explicitly unsealed M7 work manifest."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath


SCRIPT = Path(__file__).resolve()
BUNDLE_ROOT = SCRIPT.parents[2]
DEFAULT_MANIFEST = BUNDLE_ROOT / "M7_DEVELOPMENT_SHA256SUMS.txt"

ROOT_FILES = {
    ".gitignore",
    "BUNDLE_INFO.json",
    "PARENT_M5_MANIFEST.sha256",
    "README_SERVER.md",
    "import_vit_system_bd.tcl",
    "run_modelsim.do",
    "vit_phase_e_pure_sv.f",
}
ROOT_DIRS = {
    "docs",
    "filelists",
    "rtl",
    "run",
    "scripts",
    "sim",
    "third_party",
    "tools",
}
IGNORED_PARTS = {
    ".Xil",
    "__pycache__",
    "server_logs",
}
IGNORED_SUFFIXES = {".pyc", ".vvp"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_source_file(path: Path) -> bool:
    relative = path.relative_to(BUNDLE_ROOT)
    if relative.as_posix() == DEFAULT_MANIFEST.name:
        return False
    if any(part in IGNORED_PARTS for part in relative.parts):
        return False
    if path.suffix in IGNORED_SUFFIXES:
        return False
    if len(relative.parts) == 1:
        return relative.name in ROOT_FILES
    return relative.parts[0] in ROOT_DIRS


def source_paths() -> list[Path]:
    return sorted(
        (path for path in BUNDLE_ROOT.rglob("*") if path.is_file() and is_source_file(path)),
        key=lambda path: path.relative_to(BUNDLE_ROOT).as_posix(),
    )


def generate(manifest: Path) -> None:
    paths = source_paths()
    if not paths:
        raise SystemExit("ERROR: M7 development manifest source set is empty")
    lines = [
        f"{sha256_file(path)}  {path.relative_to(BUNDLE_ROOT).as_posix()}"
        for path in paths
    ]
    manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"M7_DEVELOPMENT_MANIFEST_GENERATED entries={len(lines)}")
    print(f"M7_DEVELOPMENT_MANIFEST_SHA256={sha256_file(manifest)}")


def parse_line(line: str, line_number: int) -> tuple[str, str]:
    if len(line) < 67 or line[64:66] != "  ":
        raise ValueError(f"line {line_number}: malformed sha256sum record")
    digest, relative_text = line[:64], line[66:]
    if any(char not in "0123456789abcdef" for char in digest):
        raise ValueError(f"line {line_number}: malformed SHA-256")
    relative = PurePosixPath(relative_text)
    if relative.is_absolute() or ".." in relative.parts or relative_text != relative.as_posix():
        raise ValueError(f"line {line_number}: unsafe path")
    return digest, relative_text


def check(manifest: Path) -> None:
    declared: dict[str, str] = {}
    for line_number, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        digest, relative = parse_line(line, line_number)
        if relative in declared:
            raise ValueError(f"line {line_number}: duplicate path {relative}")
        declared[relative] = digest

    expected_paths = {
        path.relative_to(BUNDLE_ROOT).as_posix(): path for path in source_paths()
    }
    if set(declared) != set(expected_paths):
        missing = sorted(set(expected_paths) - set(declared))
        extra = sorted(set(declared) - set(expected_paths))
        raise ValueError(f"manifest closure mismatch: missing={missing} extra={extra}")
    for relative, path in expected_paths.items():
        actual = sha256_file(path)
        if actual != declared[relative]:
            raise ValueError(f"checksum mismatch: {relative}")
    print(f"M7_DEVELOPMENT_MANIFEST_PASS entries={len(declared)}")
    print(f"M7_DEVELOPMENT_MANIFEST_SHA256={sha256_file(manifest)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("generate", "check"))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    manifest = args.manifest.resolve()
    if manifest.parent != BUNDLE_ROOT:
        raise SystemExit("ERROR: manifest must be located at the M7 bundle root")
    if args.action == "generate":
        generate(manifest)
    else:
        check(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
