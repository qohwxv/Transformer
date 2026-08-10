#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
package_root=$(CDPATH= cd -- "${script_dir}/.." && pwd -P)
snapshot="${package_root}/immutable/full_vivado_receipt/remote_snapshot"

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /absolute/or/relative/fresh_worktree\n' "$0" >&2
    exit 2
fi

destination=$1
if [[ -z "$destination" || "$destination" == / || "$destination" == . ]]; then
    printf 'UNSAFE_DESTINATION %s\n' "$destination" >&2
    exit 2
fi
if [[ -e "$destination" ]]; then
    printf 'DESTINATION_ALREADY_EXISTS %s\n' "$destination" >&2
    exit 2
fi

"${script_dir}/verify_content.sh"

parent=$(dirname -- "$destination")
mkdir -p -- "$parent"
cp -a --reflink=auto -- "$snapshot" "$destination"

# Chỉ worktree mới được mở quyền ghi; cây immutable không đổi.
chmod -R u+w -- "$destination"

(
    cd "$destination"
    ./run/00_verify_m8_development.sh
)

test "$(find "$destination" -type l | wc -l)" -eq 0
printf 'M8_WRITABLE_WORKTREE_PREPARE_PASS destination=%s\n' "$(CDPATH= cd -- "$destination" && pwd -P)"
