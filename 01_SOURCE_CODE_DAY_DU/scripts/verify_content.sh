#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
package_root=$(CDPATH= cd -- "${script_dir}/.." && pwd -P)
receipt="${package_root}/immutable/full_vivado_receipt"
checkpoint="${package_root}/immutable/board_candidate_pause_checkpoint"
digilent_embeddedsw="${package_root}/board_support/third_party/digilent_embeddedsw_genesys_zu_22_1"
package_manifest="${package_root}/SOURCE_PACKAGE_SHA256SUMS.txt"
package_pointer="${package_root}/SOURCE_PACKAGE_MANIFEST.sha256"

expected_receipt='060bea427080f8fb8cfb9321f2d95b39a9442de0256051869e33949b1468f437'
expected_snapshot='9cb13a07c059730f36c1e70634657a465e2e7953790e4476da2459d997e4cc29'
expected_development='67c18532e3bb16b24ec6983f99cc54a3ffafb05fe6c02cf0385465c316b31078'
expected_checkpoint='203ed8155541063a7b28b096067fd5936bfb342cb003d9c2eece49e08dda23f2'
expected_pause_tar='898cfee0e08769f203dbb299b4d250eed0adfdb5afb3c60683d8cc5763fdf8c1'
expected_digilent_commit='b218adf07bb98e57d8941b16cbe0eb3dadd0b1b2'
expected_digilent_ddr='16762bf40e86d7ccb839cb1028ba8edfe5218f9fce67aeb32dd3d02b437542ba'

hash_of() {
    sha256sum -- "$1" | awk '{print $1}'
}

require_hash() {
    local path=$1
    local expected=$2
    test -f "$path"
    test ! -L "$path"
    local actual
    actual=$(hash_of "$path")
    if [[ "$actual" != "$expected" ]]; then
        printf 'HASH_MISMATCH path=%s expected=%s actual=%s\n' "$path" "$expected" "$actual" >&2
        exit 1
    fi
}

test -d "$receipt/remote_snapshot/rtl"
test -d "$checkpoint"
test -d "$digilent_embeddedsw/.git"
test -f "$package_manifest"
test -f "$package_pointer"
package_manifest_hash=$(hash_of "$package_manifest")
test "$package_manifest_hash" = "$(awk 'NR == 1 {print $1}' "$package_pointer")"

tmp_manifest=$(mktemp -d /tmp/m8_source_manifest_verify.XXXXXX)
trap 'rm -rf -- "$tmp_manifest"' EXIT
cut -c67- "$package_manifest" | LC_ALL=C sort >"$tmp_manifest/declared"
find "$package_root" -type f -printf '%P\n' \
  | awk '$0 != "SOURCE_PACKAGE_SHA256SUMS.txt" && $0 != "SOURCE_PACKAGE_MANIFEST.sha256"' \
  | LC_ALL=C sort >"$tmp_manifest/current"
cmp "$tmp_manifest/declared" "$tmp_manifest/current"
test "$(wc -l <"$tmp_manifest/declared")" -eq "$(sort -u "$tmp_manifest/declared" | wc -l)"
test "$(find "$package_root" -type l | wc -l)" -eq 0
test "$(find "$package_root" ! -type d ! -type f ! -type l | wc -l)" -eq 0
(
  cd "$package_root"
  sha256sum -c SOURCE_PACKAGE_SHA256SUMS.txt >/dev/null
)

require_hash "$receipt/RECEIPT_SHA256SUMS.txt" "$expected_receipt"
require_hash "$receipt/REMOTE_SNAPSHOT_SHA256SUMS.txt" "$expected_snapshot"
require_hash "$receipt/remote_snapshot/M8_DEVELOPMENT_SHA256SUMS.txt" "$expected_development"
require_hash "$checkpoint/SHA256SUMS.txt" "$expected_checkpoint"
require_hash "$checkpoint/M8_BOARD_CANDIDATE_PACKAGE.tar" "$expected_pause_tar"
require_hash "$digilent_embeddedsw/lib/sw_apps/zynqmp_fsbl/src/xfsbl_ddr_init.c" "$expected_digilent_ddr"
test "$(git -C "$digilent_embeddedsw" rev-parse HEAD)" = "$expected_digilent_commit"
test -z "$(git -C "$digilent_embeddedsw" status --porcelain --untracked-files=all)"

"$receipt/verify_receipt.sh"
"$checkpoint/VERIFY_CHECKPOINT.sh"

printf '%s\n' \
  "M8_OFFLINE_SOURCE_CONTENT_PASS receipt=${expected_receipt} snapshot=${expected_snapshot} development=${expected_development} checkpoint=${expected_checkpoint} digilent_embeddedsw=${expected_digilent_commit} package_manifest=${package_manifest_hash} network_required=0 board_tested=0"
