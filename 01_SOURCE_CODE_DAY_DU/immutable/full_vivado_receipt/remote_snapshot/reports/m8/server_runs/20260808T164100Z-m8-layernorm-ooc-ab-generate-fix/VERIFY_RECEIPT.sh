#!/usr/bin/env bash
set -euo pipefail

receipt_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$receipt_root"

fail() {
    printf 'M8_LAYERNORM_RECEIPT_FAIL %s\n' "$*" >&2
    exit 1
}

value() {
    local file=$1
    local key=$2
    awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); found=1 } END { if (!found) exit 1 }' "$file"
}

expect() {
    local file=$1
    local key=$2
    local expected=$3
    local actual
    actual=$(value "$file" "$key") || fail "missing_${key}_in_${file}"
    test "$actual" = "$expected" || fail "${file}:${key} expected=${expected} actual=${actual}"
}

positive() {
    local file=$1
    local key=$2
    local actual
    actual=$(value "$file" "$key") || fail "missing_${key}_in_${file}"
    awk -v v="$actual" 'BEGIN { exit !(v + 0.0 > 0.0) }' || fail "${file}:${key} not_positive=${actual}"
}

sha256sum -c RECEIPT_MANIFEST.sha256 >/dev/null
sha256sum -c RECEIPT_SHA256SUMS.txt >/dev/null

cmp -s REMOTE_INITIAL_RUN_SHA256SUMS.before.txt REMOTE_INITIAL_RUN_SHA256SUMS.after.txt || fail initial_remote_changed_during_capture
cmp -s REMOTE_INITIAL_RUN_SHA256SUMS.before.txt LOCAL_INITIAL_RUN_SHA256SUMS.txt || fail initial_remote_local_hash_set
cmp -s REMOTE_PASS_RUN_SHA256SUMS.before.txt REMOTE_PASS_RUN_SHA256SUMS.after.txt || fail corrected_remote_changed_during_capture
cmp -s REMOTE_PASS_RUN_SHA256SUMS.before.txt LOCAL_PASS_RUN_SHA256SUMS.txt || fail corrected_remote_local_hash_set
test "$(wc -l < REMOTE_INITIAL_RUN_SHA256SUMS.before.txt)" -eq 4 || fail initial_file_count
test "$(wc -l < REMOTE_PASS_RUN_SHA256SUMS.before.txt)" -eq 35 || fail corrected_file_count

(cd initial_disabled_ram_failure/input_snapshot && sha256sum -c INPUT_SHA256SUMS.txt >/dev/null)
(cd corrected_full_pass/input_snapshot && sha256sum -c INPUT_SHA256SUMS.txt >/dev/null)
cmp -s <(tail -n +2 initial_disabled_ram_failure/input_snapshot/INPUT_SHA256SUMS.txt) \
    initial_disabled_ram_failure/remote_run/INPUT_SHA256SUMS.txt || fail initial_run_input_manifest
cmp -s <(tail -n +2 corrected_full_pass/input_snapshot/INPUT_SHA256SUMS.txt) \
    corrected_full_pass/remote_run/INPUT_SHA256SUMS.txt || fail corrected_run_input_manifest
cmp -s corrected_full_pass/remote_run/INPUT_SHA256SUMS.txt \
    corrected_full_pass/remote_run/INPUT_SHA256SUMS_AFTER.txt || fail corrected_input_changed_during_run
cmp -s initial_disabled_ram_failure/input_snapshot/PARENT_M7S8_PROVENANCE.txt \
    corrected_full_pass/input_snapshot/PARENT_M7S8_PROVENANCE.txt || fail parent_provenance_changed
cmp -s <(grep -v 'rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv' initial_disabled_ram_failure/input_snapshot/INPUT_SHA256SUMS.txt) \
    <(grep -v 'rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv' corrected_full_pass/input_snapshot/INPUT_SHA256SUMS.txt) || fail more_than_layernorm_source_changed

old_source=initial_disabled_ram_failure/input_snapshot/rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv
new_source=corrected_full_pass/input_snapshot/rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv
local_source=local_final_source/rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv
test "$(sha256sum "$old_source" | awk '{print $1}')" = c1f1342722104584e41ae753208f6295d3bae219927eae768ccff41d4c8a71b3 || fail old_source_identity
test "$(sha256sum "$new_source" | awk '{print $1}')" = f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f || fail corrected_source_identity
test "$(sha256sum "$local_source" | awk '{print $1}')" = f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f || fail local_final_source_identity
cmp -s "$new_source" "$local_source" || fail corrected_remote_vs_local_final

failure_log=initial_disabled_ram_failure/remote_run/disabled.console.log
cmp -s "$failure_log" initial_disabled_ram_failure/remote_run/REMOTE_RUNNER.log || fail initial_tee_log_mismatch
grep -Fq 'M8_LAYERNORM_OOC_FAIL post_synth enable=0 DSP=0 RAMB36=3 RAMB18=0 URAM=0 LUTRAM=0 blackbox=0 latch=0 expected_RAM36=0 and all others zero' "$failure_log" || fail initial_failure_marker
test -z "$(find initial_disabled_ram_failure/remote_run -type f \( -name '*.dcp' -o -name '*.rpt' -o -name 'SUMMARY.txt' \) -print -quit)" || fail initial_failure_has_reconstructed_artifacts

disabled=corrected_full_pass/remote_run/disabled/SUMMARY.txt
candidate=corrected_full_pass/remote_run/candidate/SUMMARY.txt
for summary in "$disabled" "$candidate"; do
    expect "$summary" RESULT PASS
    expect "$summary" SCOPE STANDALONE_M8_LAYERNORM_BUFFER_OOC
    expect "$summary" VIVADO 2023.2
    expect "$summary" PART xczu5ev-sfvc784-1-e
    expect "$summary" CLOCK_PERIOD_NS 20.000
    expect "$summary" ROW_AFFINE_BUFFER_DEPTH 1024
    expect "$summary" POST_ROUTE_RAMB18 0
    expect "$summary" POST_ROUTE_URAM 0
    expect "$summary" POST_ROUTE_LUTRAM 0
    expect "$summary" POST_ROUTE_DSP48_DSP58 0
    expect "$summary" BLACKBOX 0
    expect "$summary" LATCH 0
    expect "$summary" COMBINATIONAL_LOOPS 0
    expect "$summary" ROUTING_ERRORS 0
    expect "$summary" EXPLICIT_OOC_GAPS 1
    expect "$summary" DRC_SEVERE 0
    expect "$summary" METHODOLOGY_SEVERE 0
    expect "$summary" FULL_CHIP_TIMING_SIGNOFF 0
    positive "$summary" WNS_NS
    positive "$summary" WHS_NS
    test "$(value "$summary" ROUTABLE_NETS)" = "$(value "$summary" FULLY_ROUTED_NETS)" || fail "${summary}:not_fully_routed"
done

expect "$disabled" BUFFER_ENABLE 0
expect "$disabled" POST_SYNTH_RAMB36 0
expect "$disabled" POST_ROUTE_RAMB36 0
expect "$disabled" WNS_NS 10.037
expect "$disabled" WHS_NS 0.012
expect "$disabled" ROUTABLE_NETS 1951

expect "$candidate" BUFFER_ENABLE 1
expect "$candidate" POST_SYNTH_RAMB36 3
expect "$candidate" POST_ROUTE_RAMB36 3
expect "$candidate" WNS_NS 10.964
expect "$candidate" WHS_NS 0.019
expect "$candidate" ROUTABLE_NETS 1983

grep -Fq 'M8_LAYERNORM_OOC_PASS enable=0 ramb36=0 ramb18=0 uram=0 lutram=0 dsp=0 loops=0 blackbox=0 latch=0 WNS=10.037 WHS=0.012' corrected_full_pass/remote_run/disabled.console.log || fail disabled_terminal_marker
grep -Fq 'M8_LAYERNORM_OOC_PASS enable=1 ramb36=3 ramb18=0 uram=0 lutram=0 dsp=0 loops=0 blackbox=0 latch=0 WNS=10.964 WHS=0.019' corrected_full_pass/remote_run/candidate.console.log || fail candidate_terminal_marker
grep -Fq 'M8_LAYERNORM_OOC_AB_PASS output_root=' corrected_full_pass/remote_run/REMOTE_RUNNER.log || fail ab_terminal_marker

for case_name in disabled candidate; do
    test -s "corrected_full_pass/remote_run/${case_name}/artifacts/post_synth.dcp" || fail "missing_${case_name}_post_synth_dcp"
    test -s "corrected_full_pass/remote_run/${case_name}/artifacts/post_route.dcp" || fail "missing_${case_name}_post_route_dcp"
    test "$(find "corrected_full_pass/remote_run/${case_name}/reports" -type f | wc -l)" -eq 11 || fail "${case_name}_report_count"
done

run_id=20260808T164100Z-m8-layernorm-ooc-ab-generate-fix
while read -r expected remote_path; do
    relative=${remote_path#*"/${run_id}/"}
    test "$relative" != "$remote_path" || fail output_manifest_path
    actual=$(sha256sum "corrected_full_pass/remote_run/${relative}" | awk '{print $1}')
    test "$actual" = "$expected" || fail "output_manifest_hash_${relative}"
done < corrected_full_pass/remote_run/OUTPUT_SHA256SUMS.txt

grep -Eq '^\| vit_layernorm_engine_fp32 +\| +\(top\) \| +1391 \| +1391 \| +0 \| +0 \| +1247 \| +0 \| +0 \| +0 \| +0 \|' corrected_full_pass/remote_run/disabled/reports/post_route_utilization.rpt || fail disabled_utilization_row
grep -Eq '^\| vit_layernorm_engine_fp32 +\| +\(top\) \| +1345 \| +1345 \| +0 \| +0 \| +1245 \| +3 \| +0 \| +0 \| +0 \|' corrected_full_pass/remote_run/candidate/reports/post_route_utilization.rpt || fail candidate_utilization_row

printf 'M8_LAYERNORM_RECEIPT_PASS manifest_sha256=%s\n' "$(sha256sum RECEIPT_SHA256SUMS.txt | awk '{print $1}')"
