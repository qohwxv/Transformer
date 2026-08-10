#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
python_bin=/usr/bin/python3

test -f "$root/SHA256SUMS.txt"
test -f "$root/CHECKPOINT_MANIFEST.sha256"
test -f "$root/M8_BOARD_CANDIDATE_PACKAGE.tar"
test -x "$root/VERIFY_CHECKPOINT.sh"

(cd "$root" && sha256sum -c SHA256SUMS.txt)

expected_manifest='PENDING_CHECKPOINT_MANIFEST_SHA256'
actual_manifest=$(sha256sum "$root/SHA256SUMS.txt" | awk '{print $1}')
pointer_manifest=$(awk 'NR == 1 {print $1}' "$root/CHECKPOINT_MANIFEST.sha256")
test "$actual_manifest" = "$pointer_manifest"
if [ "$expected_manifest" != PENDING_CHECKPOINT_MANIFEST_SHA256 ]; then
  test "$actual_manifest" = "$expected_manifest"
fi

"$python_bin" - "$root/STATUS.json" <<'PY'
import json
import pathlib
import sys

status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["status"] == "M8_BOARD_CANDIDATE_PAUSE_SAFE_NOT_BOARD_TESTED"
assert status["m8_safe_nonboard_complete"] is False
assert status["physical_board_tested"] is False
assert status["vivado_board_candidate"]["dsp48"] == 0
assert status["vivado_board_candidate"]["dsp58"] == 0
assert status["vivado_board_candidate"]["ramb36"] == 41
assert status["vivado_board_candidate"]["wns_ns"] >= 0
assert status["vivado_board_candidate"]["whs_ns"] >= 0
assert status["simulation"]["e02_layer0"] == "INTERRUPTED_PARTIAL_NOT_PASS"
assert status["simulation"]["e03"] == "NOT_RUN"
assert status["simulation"]["full_e05"] == "NOT_RUN"
assert status["boot"]["boot_receipt"] == "ABSENT"
PY

tmp=$(mktemp -d /tmp/m8_pause_verify.XXXXXX)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf -- "$tmp"' EXIT
tar -xf "$root/M8_BOARD_CANDIDATE_PACKAGE.tar" -C "$tmp"

test "$(find "$tmp" -type f | wc -l)" -eq 78
test "$(wc -l < "$tmp/PAYLOAD_SHA256SUMS.txt")" -eq 77
test "$(find "$tmp" -type l | wc -l)" -eq 0
(cd "$tmp" && sha256sum -c PAYLOAD_SHA256SUMS.txt >/dev/null)

test "$(sha256sum "$tmp/artifacts/vit_system_wrapper.bit" | awk '{print $1}')" = \
  462d78a91d9fb35b2cb5832ab222c39952a1052d3ff6766d94e37405f887a275
test "$(sha256sum "$tmp/artifacts/vit_system_wrapper.xsa" | awk '{print $1}')" = \
  47e764324d9eaedcc343b3cdf66190dbb90635cf8e51b4f6e65b4746c43680ee
test "$(sha256sum "$tmp/model/vit_model.bin" | awk '{print $1}')" = \
  d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5
test "$(sha256sum "$tmp/model/vit_model_table.bin" | awk '{print $1}')" = \
  10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a
test "$(sha256sum "$tmp/model/prepared_input.bin" | awk '{print $1}')" = \
  3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54
test "$(sha256sum "$tmp/board/m8_v3_mode3_50mhz.identity" | awk '{print $1}')" = \
  e53104c4154f7b39a77a70ceace7a2065bf3bb4f822d2081705f3a1e904af308
test "$(sha256sum "$tmp/simulation/interrupted_layer0_receipt/PAYLOAD_SHA256SUMS.txt" | awk '{print $1}')" = \
  068eea24b27c7f6b124d89885995397c5db312460026e07fffb28321c48169ff

echo "M8_BOARD_CANDIDATE_PAUSE_CHECKPOINT_PASS manifest_sha256=$actual_manifest package_sha256=898cfee0e08769f203dbb299b4d250eed0adfdb5afb3c60683d8cc5763fdf8c1"
