# ViT Q-projection tree-PE array

The full functional bring-up plan and architecture evolution checklist is in
[`VIT_NPU_TEST_CHECKLIST.md`](VIT_NPU_TEST_CHECKLIST.md).
Prepared B02–B08 GEMM package mappings and compatibility notes are in
[`PHASE_B_TEST_PACKAGES.md`](../PHASE_B_TEST_PACKAGES.md).
Prepared C01–C04 attention-GEMM mappings are in
[`PHASE_C_TEST_PACKAGES.md`](../PHASE_C_TEST_PACKAGES.md).
The new runtime-configurable engine is documented in
[`README_PHASE_B_NPU.md`](README_PHASE_B_NPU.md), and the full hardware/software
partition is in [`VIT_HW_SW_PARTITION.md`](VIT_HW_SW_PARTITION.md).

This is a first compute-engine experiment for `test_1`. It computes only the
encoder-layer-0 Q projection:

```text
C[197,768] = A[197,768] * B[768,768] + bias[768]
```

Its ModelSim top level is `tb_vit_q_tree_array` and its RTL top level is
`vit_q_tree_array`.

## Architecture choice

The array is a 2x2 output-stationary topology:

```text
                         B columns
                    B0                B1
                     |                 |
A token row 0 --> [tree PE 0,0]   [tree PE 0,1]
A token row 1 --> [tree PE 1,0]   [tree PE 1,1]
```

- A 16-value activation vector is broadcast across each PE row.
- A 16-value weight vector is broadcast down each PE column.
- Each PE keeps one output value stationary while reducing all 768 K values.
- Boundary masks handle token 196 because 197 is not divisible by two.

Each PE is wider than a conventional one-MAC PE:

```text
16 FP32 multipliers
        |
8 FP32 adders
        |
4 FP32 adders
        |
2 FP32 adders
        |
1 FP32 adder          balanced reduction tree, depth 4
        |
local FP32 accumulator
        |
bias add
```

`n=16` was selected because:

- `768 / 16 = 48` exact chunks, with no K-tail padding;
- the internal tree has only four addition levels;
- a 2x2 array uses 64 multipliers and 60 tree adders, which is a reasonable
  first resource point;
- changing directly to n=64 would quadruple multiplier count and input
  bandwidth per PE before the basic controller and memory layout are proven.

The current tree is combinational and one 16-wide chunk is accepted per clock.
For synthesis at a higher clock frequency, registers can later be inserted
between tree levels without changing the array dataflow.

## Files

| File | Purpose |
|---|---|
| `vit_fp32_pkg.sv` | FP32 multiply/add functions, round-to-nearest-even |
| `vit_tree_pe_fp32.sv` | 16-multiplier tree PE and local accumulator |
| `vit_q_tree_array.sv` | 2x2 output-stationary array and full Q controller |
| `tb_vit_q_tree_array.sv` | Reads `test_1`, runs the full projection, writes hex |
| `vit_q_tree_array.f` | ModelSim compilation order |

The initial arithmetic package flushes binary32 subnormal inputs and
underflowed outputs to zero. The supplied `test_1` operands are normal finite
values or exact zeros. NaN and infinity cases are handled, but they are not
part of this workload.

## ModelSim commands

Run from the repository root so the default `test_1/...` paths resolve:

```tcl
vlib work
vlog -sv -f compute_engine/vit_q_tree_array.f
vsim work.tb_vit_q_tree_array
run -all
```

The testbench writes:

```text
test_1/npu_q_output_f32.hex
```

Optional file overrides are available:

```text
+A_FILE=<path>
+B_FILE=<path>
+BIAS_FILE=<path>
+OUTPUT_FILE=<path>
```

Compare the generated output with the Python golden reference:

```bash
.venv/bin/python prepare_test_1.py \
  --compare test_1/npu_q_output_f32.hex \
  --atol 5e-5 --rtol 1e-4
```

Bit-exact equality with PyTorch is not expected because this PE uses a balanced
tree and rounds every FP32 multiplication/addition, while the CPU GEMM can use
FMA and a different reduction order. The tensor shape, memory layout, and
numeric error report should be used for the comparison.

## Input memory layout

The testbench consumes the three separate `test_1` files:

```text
A[token,k]       address = token * 768 + k
B[k,out_channel] address = k * 768 + out_channel
bias[out_channel]
C[token,out]     address = token * 768 + out_channel
```

The B address is important: `02_weight_B_f32.hex` is already the transposed
PyTorch weight and is stored as `[K,N]`. It must not be transposed again.
