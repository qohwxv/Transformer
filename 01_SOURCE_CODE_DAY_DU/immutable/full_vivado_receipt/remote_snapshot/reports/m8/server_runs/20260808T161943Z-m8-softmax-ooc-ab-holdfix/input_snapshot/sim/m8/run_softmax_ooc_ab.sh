#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vivado_bin="${VIVADO_BIN:-/home/qh/Downloads/Vivado/Vivado/2023.2/bin/vivado}"
output_root="${M8_SOFTMAX_OOC_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/vit_m8_softmax_ooc.XXXXXX")}" 

if [[ ! -x "$vivado_bin" ]]; then
    echo "SOFTMAX_OOC_AB_FAIL missing_vivado=$vivado_bin" >&2
    exit 1
fi
mkdir -p "$output_root"
cd "$repo_root"

run_one() {
    local implementation="$1"
    local output_dir="$output_root/$implementation"
    env \
        M8_SOFTMAX_IMPLEMENTATION="$implementation" \
        M8_SOFTMAX_OOC_OUT="$output_dir" \
        "$vivado_bin" \
            -mode batch \
            -nolog \
            -nojournal \
            -notrace \
            -source sim/softmax/run_softmax_buffer_ooc.tcl \
        | tee "$output_root/$implementation.console.log"
    grep -q "SOFTMAX_BUFFER_OOC_PASS implementation=$implementation" \
        "$output_root/$implementation.console.log"
    grep -q '^RESULT=PASS$' "$output_dir/SUMMARY.txt"
}

run_one parent
run_one candidate

sha256sum \
    "$output_root/parent/SUMMARY.txt" \
    "$output_root/candidate/SUMMARY.txt" \
    "$output_root/parent/artifacts/post_route.dcp" \
    "$output_root/candidate/artifacts/post_route.dcp" \
    > "$output_root/SHA256SUMS.txt"

echo "SOFTMAX_OOC_AB_PASS output_root=$output_root"
cat "$output_root/parent/SUMMARY.txt"
cat "$output_root/candidate/SUMMARY.txt"
sha256sum "$output_root/SHA256SUMS.txt"
