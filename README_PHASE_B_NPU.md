# Runtime-configurable Phase-B/C batched GEMM NPU

This is the implemented, lint-clean GEMM RTL candidate for `test_1` through
`test_12`. One compiled design accepts runtime batch-count/M/K/N values instead
of requiring a different RTL build for projections, MLP, classifier, QKᵀ, and
P×V shapes. The new generic core has not yet been numerically verified in
ModelSim; only the older Q-only baseline has a recorded passing result.

## Architecture

```text
file-backed memory model in testbench
        |
        | data_request / data_valid
        | packed A-row and B-column chunks
        v
vit_gemm_tree_array
    |-- runtime job registers: batch_count, M, K, N, bias_enable
    |-- GEMM controller FSM
    |-- batch/head loop and result metadata
    |-- M/N boundary masks
    |-- K-tail lane mask
    `-- 2x2 output-stationary array
         `-- four 16-lane FP32 tree PEs
        |
        | result_valid / result_ready
        v
testbench output collector -> npu_output_f32.hex
```

This remains a row/column-broadcast tree-PE array, not a classic systolic array
with values moving from PE to PE. The testbench still owns A/B/bias/output
memory. There are no physical NPU SRAM buffers, AXI ports, or DMA yet.

## What changed from the Q-only engine

- M, K, and N are runtime inputs latched when `start` is accepted.
- `cfg_batch_count` repeats a GEMM shape over contiguous tensor sets. Phase B
  uses count 1; C02/C04 map this generic index to 12 attention heads.
- `cfg_bias_enable` supports future no-bias attention GEMMs.
- K no longer has to be divisible by 16. Invalid lanes are suppressed inside
  each PE before the multiplier is called.
- `result_ready` adds real output backpressure. Result data and coordinates
  remain stable while the consumer stalls.
- The generic testbench uses runtime batch/head strides and automatically
  selects the correct tensor sizes and timeout for `test_1` through `test_12`.
- Optional deterministic input/output stalls can exercise both handshakes.
- C03/C04 inject poison into invalid K-tail lanes, and all Phase-C tests inject
  poison on the disabled bias bus, so their future runs can prove PE lane
  masking and bias bypass.

The original `vit_q_tree_array` and `tb_vit_q_tree_array` remain available as
the previously proven Q-only baseline.

## Files

| File | Purpose |
|---|---|
| `vit_fp32_pkg.sv` | Current combinational FP32 add/multiply functions |
| `vit_tree_pe_fp32.sv` | 16-lane tree PE with internal K-lane validity mask |
| `vit_gemm_tree_array.sv` | Runtime GEMM controller and 2x2 PE array |
| `tb_vit_gemm_tree_array.sv` | File-backed, runtime-size Phase-B/C testbench |
| `vit_gemm_tree_array.f` | Generic ModelSim compilation order |

## Supported package table

| TEST_ID | Folder | Checklist/operation | Count | M | K | N | Estimated zero-stall cycles |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `test_1` | B01 Q | 1 | 197 | 768 | 768 | 1,938,816 |
| 2 | `test_2` | B02 K | 1 | 197 | 768 | 768 | 1,938,816 |
| 3 | `test_3` | B03 V | 1 | 197 | 768 | 768 | 1,938,816 |
| 4 | `test_4` | B04 O | 1 | 197 | 768 | 768 | 1,938,816 |
| 5 | `test_5` | B05 patch GEMM | 1 | 196 | 768 | 768 | 1,919,232 |
| 6 | `test_6` | B06 FC1 | 1 | 197 | 768 | 3072 | 7,755,264 |
| 7 | `test_7` | B07 FC2 | 1 | 197 | 3072 | 768 | 7,413,120 |
| 8 | `test_8` | B08 classifier | 1 | 1 | 768 | 1000 | 25,500 |
| 9 | `test_9` | C01 QKᵀ head 0 | 1 | 197 | 64 | 197 | 68,607 |
| 10 | `test_10` | C02 QKᵀ all heads | 12 | 197 | 64 | 197 | 823,284 |
| 11 | `test_11` | C03 P×V head 0 | 1 | 197 | 197 | 64 | 50,688 |
| 12 | `test_12` | C04 P×V all heads | 12 | 197 | 197 | 64 | 608,256 |

The testbench adds a 25% timeout margin automatically, or a conservative 3x
margin when deterministic stalls are enabled. These cycle estimates describe
the current unpipelined, zero-memory-latency functional model; they are not
performance estimates for a synthesized implementation.

## ModelSim usage

Compile once from the repository root:

```tcl
vlib work
vlog -sv -f compute_engine/vit_gemm_tree_array.f
```

Run one package, for example K projection:

```tcl
vsim work.tb_vit_gemm_tree_array +TEST_ID=2
run -all
```

Then compare it:

```bash
.venv/bin/python prepare_phase_b_tests.py \
  --compare test_2 test_2/npu_output_f32.hex \
  --atol 5e-5 --rtol 1e-4
```

For Q (`TEST_ID=1`), use `prepare_test_1.py` as before.

For a Phase-C test, use its Phase-C comparator:

```bash
.venv/bin/python prepare_phase_c_tests.py \
  --compare test_11 test_11/npu_output_f32.hex \
  --atol 5e-5 --rtol 1e-4
```

## Plusargs

| Plusarg | Meaning |
|---|---|
| `+TEST_ID=1..12` | Select package and default batch/M/K/N/path |
| `+BATCH_COUNT=` | Override number of contiguous GEMMs in one job |
| `+M=`, `+K=`, `+N=` | Override runtime dimensions |
| `+BIAS_ENABLE=0/1` | Disable or enable bias |
| `+TEST_DIR=<path>` | Override the selected package directory |
| `+A_FILE=<path>` | Override A input path |
| `+B_FILE=<path>` | Override B input path |
| `+BIAS_FILE=<path>` | Override bias path |
| `+OUTPUT_FILE=<path>` | Override NPU output path |
| `+TIMEOUT_CYCLES=<n>` | Override automatic timeout |
| `+INPUT_STALL_EVERY=<n>` | Stall every nth input cycle; 0 disables |
| `+OUTPUT_STALL_EVERY=<n>` | Stall every nth output cycle; 0 disables |
| `+INJECT_K_TAIL_SENTINEL=0/1` | Poison invalid final-K lanes; defaults on for C03/C04 |
| `+INJECT_DISABLED_BIAS_SENTINEL=0/1` | Poison the disabled bias bus; defaults on for Phase C |

The default package root is currently
`/home/qh/Downloads/transformers/test_<TEST_ID>`. Use `+TEST_DIR` if the
repository is moved. When `BIAS_ENABLE=0`, the testbench does not require or
read a bias file, and the PE bypasses the final bias adder exactly. Phase-C
tests leave this path poisoned so an accidental bias add cannot pass silently.

## Current limitations

- Only GEMM/bias and a generic contiguous batch loop are implemented.
  LayerNorm, Softmax, GELU, residual add, head layout conversion, and model
  sequencing are not present.
- The FP32 multiplier, four-level adder tree, accumulator add, and the
  normalization loop are combinational. This is useful for functional testing
  but is not a realistic high-Fmax implementation.
- The PE width remains fixed at 16 lanes.
- The controller loops over a generic matrix index, used as the head index in
  Phase C. Actual base/stride address generation remains in the testbench;
  there are no internal SRAM or address descriptors yet.
- QKᵀ packages provide K already transposed. P×V packages provide software
  Softmax probabilities. Split/transpose/merge and Softmax are not hardware.
- The static memories in the testbench are simulation models and are not part
  of the synthesizable NPU core.
- Numeric tolerance, rather than bit equality with PyTorch, remains the pass
  criterion because reduction orders differ.

Static Verilator lint with `--timing -Wno-fatal` passes for both the new generic
path and the legacy Q path. Remaining warnings are `WIDTHEXPAND` notices in the
FP32 package and testbench bookkeeping, plus testbench-only `UNUSEDSIGNAL` and
`BLKSEQ` notices. No long ModelSim GEMM simulation was run while creating this
revision.
