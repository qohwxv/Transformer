#!/usr/bin/env bash
set -euo pipefail

receipt_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$receipt_root"

fail() {
    printf 'M8_SOFTMAX_RECEIPT_FAIL %s\n' "$*" >&2
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
cmp -s REMOTE_RUN_SHA256SUMS.txt LOCAL_RUN_SHA256SUMS.txt || fail remote_local_run_hash_set
cmp -s REMOTE_INITIAL_FAILURE_SHA256SUMS.txt LOCAL_INITIAL_FAILURE_SHA256SUMS.txt || fail remote_local_initial_failure_hash_set

(cd input_snapshot && sha256sum -c ../remote_run/INPUT_SHA256SUMS.txt >/dev/null)
(cd initial_parent_hold_failure && sha256sum -c FAILURE_PAYLOAD_SHA256SUMS.txt >/dev/null)
test "$(sha256sum initial_parent_hold_failure/FAILURE_PAYLOAD_SHA256SUMS.txt | awk '{print $1}')" = \
    e217074da4d12b2b2dd7c7d1fa9251b05e7e39eb66cb0a14b130cb4d866b3072 || fail initial_failure_manifest_identity

parent=remote_run/parent/SUMMARY.txt
candidate=remote_run/candidate/SUMMARY.txt
for summary in "$parent" "$candidate"; do
    expect "$summary" RESULT PASS
    expect "$summary" EVIDENCE_SCOPE standalone_softmax_ooc
    expect "$summary" VIVADO 2023.2
    expect "$summary" PART xczu5ev-sfvc784-1-e
    expect "$summary" CLOCK_MHZ 50
    positive "$summary" WNS_NS
    positive "$summary" WHS_NS
    expect "$summary" DSP48_DSP58 0
    expect "$summary" RAMB18E2 0
    expect "$summary" URAM288 0
    expect "$summary" LUTRAM_PRIMITIVES 0
    expect "$summary" BLACKBOX 0
    expect "$summary" LATCH 0
    expect "$summary" COMBINATIONAL_LOOPS 0
    expect "$summary" ROUTING_ERRORS 0
    test "$(value "$summary" ROUTABLE_NETS)" = "$(value "$summary" FULLY_ROUTED_NETS)" || fail "${summary}:not_fully_routed"
done

expect "$parent" IMPLEMENTATION parent
expect "$parent" SOURCE_SHA256 4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da
expect "$parent" WNS_NS 4.567
expect "$parent" WHS_NS 0.023
expect "$parent" RAMB36E2 0

expect "$candidate" IMPLEMENTATION candidate
expect "$candidate" SOURCE_SHA256 9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9
expect "$candidate" WNS_NS 4.472
expect "$candidate" WHS_NS 0.033
expect "$candidate" RAMB36E2 1

grep -Fq 'SOFTMAX_BUFFER_OOC_PASS implementation=parent source_sha=4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da' remote_run/parent.console.log || fail parent_terminal_marker
grep -Fq 'SOFTMAX_BUFFER_OOC_PASS implementation=candidate source_sha=9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9' remote_run/candidate.console.log || fail candidate_terminal_marker
grep -Fq 'SOFTMAX_OOC_AB_PASS output_root=' remote_run/REMOTE_RUNNER.log || fail ab_terminal_marker
grep -Fq 'SOFTMAX_BUFFER_GATE_PASS stage=post_route severe_methodology=0' remote_run/parent.console.log || fail parent_methodology_gate
grep -Fq 'SOFTMAX_BUFFER_GATE_PASS stage=post_route severe_methodology=0' remote_run/candidate.console.log || fail candidate_methodology_gate
grep -Fq 'SOFTMAX_BUFFER_GATE_PASS stage=post_route severe_drc=0' remote_run/parent.console.log || fail parent_drc_gate
grep -Fq 'SOFTMAX_BUFFER_GATE_PASS stage=post_route severe_drc=0' remote_run/candidate.console.log || fail candidate_drc_gate

grep -Fq 'SOFTMAX_BUFFER_OOC_FAIL post_route timing WNS=2.776 WHS=-0.020' initial_parent_hold_failure/parent.console.log || fail initial_failure_marker
test -s remote_run/parent/artifacts/post_synth.dcp || fail missing_parent_post_synth_dcp
test -s remote_run/parent/artifacts/post_route.dcp || fail missing_parent_post_route_dcp
test -s remote_run/candidate/artifacts/post_synth.dcp || fail missing_candidate_post_synth_dcp
test -s remote_run/candidate/artifacts/post_route.dcp || fail missing_candidate_post_route_dcp

printf 'M8_SOFTMAX_RECEIPT_PASS manifest_sha256=%s\n' "$(sha256sum RECEIPT_SHA256SUMS.txt | awk '{print $1}')"
