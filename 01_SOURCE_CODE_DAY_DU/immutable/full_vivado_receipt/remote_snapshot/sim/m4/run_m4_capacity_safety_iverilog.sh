#!/usr/bin/env bash
set -euo pipefail

vit_m4_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${vit_m4_root}"

for vit_m4_tool in iverilog vvp; do
    if ! command -v "${vit_m4_tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool is missing: %s\n' "${vit_m4_tool}"
        exit 1
    fi
done

vit_m4_tmp="$(mktemp -d /tmp/vit_m4_capacity_safety.XXXXXX)"
trap 'rm -rf -- "${vit_m4_tmp}"' EXIT

vit_m4_tests=(
    "cache_capacity m4_cache_capacity_iverilog.f tb_m4_cache_capacity"
    "frontend_boundary m4_frontend_cache_boundary_iverilog.f tb_m4_frontend_cache_boundary"
    "tail_sentinel m4_tail_output_sentinel_iverilog.f tb_m4_tail_output_sentinel"
)

for vit_m4_rows in 4 8; do
    for vit_m4_test in "${vit_m4_tests[@]}"; do
        read -r vit_m4_name vit_m4_filelist vit_m4_top <<<"${vit_m4_test}"
        vit_m4_image="${vit_m4_tmp}/${vit_m4_name}_r${vit_m4_rows}.vvp"
        vit_m4_compile_log="${vit_m4_tmp}/${vit_m4_name}_r${vit_m4_rows}.compile.log"

        printf 'RUN  M4 %-18s R=%s\n' "${vit_m4_name}" "${vit_m4_rows}"
        if ! iverilog \
            -g2012 \
            -Wall \
            -s "${vit_m4_top}" \
            -P"${vit_m4_top}.ARRAY_ROWS=${vit_m4_rows}" \
            -o "${vit_m4_image}" \
            -c "sim/m4/${vit_m4_filelist}" \
            >"${vit_m4_compile_log}" 2>&1; then
            tail -n 200 "${vit_m4_compile_log}"
            exit 1
        fi
        vvp "${vit_m4_image}"
    done
done

printf '%s\n' 'PASS M4 capacity/banking/tail safety suite (R4 then R8)'
