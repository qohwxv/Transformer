# M8 real E02/E03 simulation

This additive harness qualifies one production execution-mode-3 encoder layer
at a time through the native AXI-128 interface. It does not change production
RTL, package v3, the DSP=0 policy, or receipt-bound E01/E04 files.

The runner builds once with one Verilator worker, executes layers sequentially,
and writes a new immutable-by-convention receipt directory. By default it only
builds and performs one plusarg smoke test. A real simulation must explicitly
set `VIT_M8_MODE3_ENCODER_BUILD_ONLY=0`; it is rejected if less than 16 GiB is
available. Output paths must be new absolute paths inside this workspace.

## Full continuous layer0..11 gate

From the M8 revision root on the high-memory server:

```bash
vit_m8_id="m8-e02-e03-chain-$(date -u +%Y%m%dT%H%M%SZ)"
VIT_M8_MODE3_ENCODER_BUILD_ONLY=0 \
VIT_M8_MODE3_ENCODER_RUN_ID="${vit_m8_id}" \
./sim/end_to_end/run_m8_mode3_encoder_chain_axi_rtl_verilator.sh
```

Layer 0 consumes the pinned T004 embedding checkpoint. Each later layer
consumes the exact preceding RTL dump, and its comparator requires the previous
layer's PASS report and output SHA-256. This is the accumulated E02/E03 gate.
Continuous chains therefore begin at layer 0, or at layer 1 with a separately
receipt-bound E02 seed; later starting layers are rejected at preflight.

## Separate E02 then E03 receipts

```bash
vit_m8_e02_id="m8-e02-$(date -u +%Y%m%dT%H%M%SZ)"
VIT_M8_MODE3_ENCODER_BUILD_ONLY=0 \
VIT_M8_MODE3_ENCODER_RUN_ID="${vit_m8_e02_id}" \
./sim/end_to_end/run_e02_layer0_mode3_real_axi_rtl_verilator.sh

# Copy sha256_manifest from the E02 RECEIPT_COMPLETE marker before E03.
vit_m8_e02_receipt_sha256="<externally-recorded-64-hex-digest>"
vit_m8_e03_id="m8-e03-$(date -u +%Y%m%dT%H%M%SZ)"
VIT_M8_MODE3_ENCODER_BUILD_ONLY=0 \
VIT_M8_MODE3_ENCODER_RUN_ID="${vit_m8_e03_id}" \
VIT_M8_MODE3_ENCODER_CHAIN_SEED_OUTPUT="$(pwd)/build/test_logs/${vit_m8_e02_id}/layers/layer00/outputs/encoder_output_rtl_f32.hex" \
VIT_M8_MODE3_ENCODER_CHAIN_SEED_REPORT="$(pwd)/build/test_logs/${vit_m8_e02_id}/layers/layer00/outputs/t004_comparison.json" \
VIT_M8_MODE3_ENCODER_CHAIN_SEED_RECEIPT_MANIFEST="$(pwd)/build/test_logs/${vit_m8_e02_id}/RUN_SHA256SUMS.txt" \
VIT_M8_MODE3_ENCODER_CHAIN_SEED_RECEIPT_SHA256="${vit_m8_e02_receipt_sha256}" \
./sim/end_to_end/run_e03_layers1_11_mode3_real_axi_rtl_verilator.sh
```

The E03 runner verifies the externally recorded manifest digest, every receipt
member, both source-state snapshots, the E02 sequence marker, canonical staged
assets, and the complete layer-0 comparison contract before it builds or runs
layer 1. For diagnosis, any range can also be run independently against its
own T004 predecessor:

```bash
VIT_M8_MODE3_ENCODER_BUILD_ONLY=0 \
./sim/end_to_end/run_m8_mode3_encoder_real_axi_rtl_verilator.sh \
    --first-layer 1 --last-layer 11 --input-mode independent
```

## Evidence and limits

Every layer stages 16 exact package-v3 tensors, a pinned T004 FP32 input, and a
pinned T004 FP32 golden. The simulator checks structure, AXI traffic/protocol,
status, profile, M5 and M7 exact-stage counters before an external numerical
gate checks all 151,296 output words. The structural receipt also records the
published job-cycle count and verifies it against an independent edge monitor.
Independent T004 runs use fixed
`abs=0.02, rel=0.005`; accumulated-chain runs use fixed
`abs=0.08, rel=0.02`. These predeclared envelopes are qualification gates, not
an accuracy claim.

Until a full run produces its receipt and PASS markers, the harness is only
statically verified. Verilator evidence is simulation evidence, not Vivado
implementation or physical-board evidence. The default per-layer timeout is
24 hours and can be increased with
`VIT_M8_MODE3_ENCODER_RUN_TIMEOUT_SECONDS`; the layers remain sequential.
Schedule-only estimates are roughly 3–10 hours per encoder layer and 1.5–5
days for the continuous twelve-layer chain, based on its share of the 249-step
E05 workload. These are `ESTIMATED`, not simulator measurements.
