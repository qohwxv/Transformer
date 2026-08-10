#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="${M8_LN_AB_OUTPUT_DIR:-$(mktemp -d /tmp/m8_layernorm_ab.XXXXXX)}"

mkdir -p "${work_dir}"

check_sha() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "M8_LAYERNORM_PARENT_HASH_FAIL path=${path} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

parent_sources=(
    "${repo_dir}/rtl/leaf/common/vit_u32_mul_iterative_nodsp.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_add_comb.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_mul_comb_nodsp.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_recip_u32_serial.sv"
    "${repo_dir}/sim/m8/reference/vit_layernorm_engine_fp32_parent_v1_12.sv"
)

candidate_sources=(
    "${repo_dir}/rtl/leaf/common/vit_u32_mul_iterative_nodsp.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_add_comb.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_mul_comb_nodsp.sv"
    "${repo_dir}/rtl/leaf/fp32/vit_fp32_recip_u32_serial.sv"
    "${repo_dir}/rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv"
)

check_sha 4b40d6e0b1992fabe0eca28cdbc1cb2956c4085b3410e9bba2d80290e8795d8e "${parent_sources[0]}"
check_sha 3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141 "${parent_sources[1]}"
check_sha 8652521edca10e731633fbe62850b77dc9dc2ad9b52bff1312ef5842bae83c3a "${parent_sources[2]}"
check_sha 26c0ea331183beee53e0bb7f5e9411e510b6d923bfa99fb663e1bc2b158ce1bd "${parent_sources[3]}"
check_sha a61ec7471de9a5641744195dbded3f33202e325e4822da5d113d575346776187 "${parent_sources[4]}"

tb="${repo_dir}/sim/layernorm/tb_vit_layernorm_engine_fp32_m8_ab.sv"
parent_vvp="${work_dir}/m7_parent.vvp"
candidate_vvp="${work_dir}/m8_candidate.vvp"
parent_trace="${work_dir}/m7_parent.trace"
candidate_trace="${work_dir}/m8_candidate.trace"
parent_log="${work_dir}/m7_parent.log"
candidate_log="${work_dir}/m8_candidate.log"

iverilog -g2012 -Wall -DM8_PARENT_BASELINE \
    -s tb_vit_layernorm_engine_fp32_m8_ab \
    -o "${parent_vvp}" "${parent_sources[@]}" "${tb}"
iverilog -g2012 -Wall \
    -s tb_vit_layernorm_engine_fp32_m8_ab \
    -o "${candidate_vvp}" "${candidate_sources[@]}" "${tb}"

vvp "${parent_vvp}" "+TRACE_FILE=${parent_trace}" | tee "${parent_log}"
vvp "${candidate_vvp}" "+TRACE_FILE=${candidate_trace}" | tee "${candidate_log}"

grep -Fq "M8_LAYERNORM_AB_SIM_PASS implementation=M7_PARENT_V1_12" "${parent_log}"
grep -Fq "M8_LAYERNORM_AB_SIM_PASS implementation=M8_LN_BUFFERED" "${candidate_log}"
grep -Fq "name=h1025_t2_fallback tokens=2 hidden=1025 cycles=70830 packets=2050/2050/2050 word_reads=10250" "${parent_log}"
grep -Fq "name=h1025_t2_fallback tokens=2 hidden=1025 cycles=70830 packets=2050/2050/2050 word_reads=10250" "${candidate_log}"
grep -Fq "name=h3072_t1_fallback tokens=1 hidden=3072 cycles=106080 packets=3072/3072/3072 word_reads=15360" "${parent_log}"
grep -Fq "name=h3072_t1_fallback tokens=1 hidden=3072 cycles=106080 packets=3072/3072/3072 word_reads=15360" "${candidate_log}"
grep -Fq "name=production_h768_t197 tokens=197 hidden=768 cycles=5222548 packets=151296/151296/151296 word_reads=756480" "${parent_log}"
grep -Fq "name=production_h768_t197 tokens=197 hidden=768 cycles=3087143 packets=151296/0/768 word_reads=153600" "${candidate_log}"

cmp "${parent_trace}" "${candidate_trace}"
trace_sha="$(sha256sum "${candidate_trace}" | awk '{print $1}')"
trace_lines="$(wc -l < "${candidate_trace}")"
if [[ "${trace_sha}" != "c5dd3e8a10adf71eefe7048ccc943d32228360727d2650728a20ad8338ad0c30" ]]; then
    echo "M8_LAYERNORM_TRACE_HASH_FAIL got=${trace_sha}" >&2
    exit 1
fi
if [[ "${trace_lines}" != "160068" ]]; then
    echo "M8_LAYERNORM_TRACE_COUNT_FAIL got=${trace_lines}" >&2
    exit 1
fi

echo "M8_LAYERNORM_EXACT_PARENT_AB_PASS trace_sha256=${trace_sha} trace_lines=${trace_lines} parent_cycles=5222548 candidate_cycles=3087143 parent_word_reads=756480 candidate_word_reads=153600 output_dir=${work_dir}"
