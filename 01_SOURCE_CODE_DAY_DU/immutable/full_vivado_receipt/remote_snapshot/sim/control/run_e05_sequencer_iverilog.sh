#!/usr/bin/env bash
set -euo pipefail

vit_seq_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_seq_root}"

for vit_seq_tool in iverilog vvp timeout; do
    if ! command -v "${vit_seq_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_seq_tool}"
        exit 1
    fi
done

vit_seq_tmp="$(mktemp -d /tmp/vit_e05_sequencer.XXXXXX)"
trap 'rm -rf -- "${vit_seq_tmp}"' EXIT

vit_seq_compile_log="${vit_seq_tmp}/compile.log"
if ! timeout 30s iverilog \
        -g2012 \
        -s tb_vit_phase_e_sequencer_e05 \
        -o "${vit_seq_tmp}/tb.vvp" \
        -c sim/control/vit_phase_e_sequencer_e05_iverilog.f \
        >"${vit_seq_compile_log}" 2>&1; then
    printf '%s\n' "FAIL E05 sequencer descriptor regression: compile"
    tail -n 200 "${vit_seq_compile_log}"
    exit 1
fi

timeout 15s vvp "${vit_seq_tmp}/tb.vvp"
