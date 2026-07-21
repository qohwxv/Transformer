# Phase-D non-GEMM ViT engines

This directory now contains functional execution paths for checklist D01
through D07. Their input/golden packages are `test_13` through `test_19`.
Implementation is complete enough for file-backed ModelSim bring-up, but no
Phase-D package is called numerically passed until its generated NPU output is
checked with `prepare_phase_d_tests.py`.

## What was added

| Checklist | Module | Datapath | Synthesis status |
|---|---|---|---|
| D01/D03 | `vit_vector_engine_fp32.sv` | 16-lane FP32 add or scale-plus-mask | Candidate synthesizable RTL |
| D02 | `vit_layernorm_engine_fp32.sv` | Three reads/token: mean, centered variance, affine | Functional simulation reference |
| D04 | `vit_softmax_engine_fp32.sv` | Three reads/row: max, exp sum, normalized output | Functional simulation reference |
| D05 | `vit_gelu_engine_fp32.sv` | 16-lane exact-erf-style GELU boundary | Functional simulation reference |
| D06 | `vit_layout_engine.sv` | Rank-3 strided source to contiguous destination | Candidate synthesizable RTL |
| D07 | `vit_argmax_engine_fp32.sv` | Streaming FP32 max plus lowest winning index | Candidate synthesizable RTL |

`vit_fp32_math_ref_pkg.sv` converts between FP32 bits and simulator
`shortreal` and supplies sqrt/rsqrt, reciprocal, exp, and the
Abramowitz-Stegun erf approximation. Anything importing that package is
**not synthesis-ready**. Questa/ModelSim is the numerical target for those
modules; Verilator 5.020 promotes `shortreal` and is suitable only as a syntax
lint here.

## Current memory boundary

```text
HEX files
   |
   v
testbench memory arrays
   |-- request/index -> selected memory word(s)
   `-- valid/data    -> Phase-D engine
                           |
                           `-- valid/ready/index/data -> output collector
```

The new modules contain local operation controllers, not input/output SRAM,
AXI, or DMA. The global controller that chooses GEMM versus a Phase-D engine
and manages scratch-memory lifetimes belongs to Phase E. Keeping the engines
independent now makes each numerical boundary diagnosable.

## File lists and testbench tops

| File list | Testbench top | Tests |
|---|---|---|
| `vit_phase_d_synth.f` | `tb_vit_phase_d_synth` | D01, D03, D06, D07 argmax |
| `vit_phase_d_ref.f` | `tb_vit_phase_d_ref` | D02, D04, D05, D07 class Softmax |
| `vit_phase_d.f` | both tops | all Phase-D engines |

Compile all engines once from the repository root:

```tcl
vlib work
vlog -sv -f compute_engine/vit_phase_d.f
```

Example synthesizable-path run:

```tcl
vsim work.tb_vit_phase_d_synth +TEST_ID=13 +CASE_ID=1 \
  +INPUT_STALL_EVERY=7 +OUTPUT_STALL_EVERY=11
run -all
```

Example functional-reference run:

```tcl
vsim work.tb_vit_phase_d_ref +TEST_ID=16 +CASE_ID=1
run -all
```

Both benches accept `+CASE_DIR=<path>` to override their default package path.
They also accept deterministic input/output stall plusargs documented in their
source headers. The benches write the expected `npu_output_f32.hex`; D07
argmax instead writes `npu_output_u32.hex` and
`npu_max_value_f32.hex`.

Compare one output from a shell:

```bash
.venv/bin/python prepare_phase_d_tests.py \
  --compare test_13/case_01_positional_add \
  test_13/case_01_positional_add/npu_output_f32.hex
```

Compare every output file that currently exists:

```bash
.venv/bin/python prepare_phase_d_tests.py --compare-all
```

The comparator prints word count, bit mismatches, numerical mismatches, maximum
and mean absolute error, maximum relative error, and first/largest-error
coordinates. Softmax adds a row-sum check. Class Softmax adds class-index and
confidence checks. D07 argmax requires both its index and maximum-value files.

## Runtime test selection

| TEST_ID | CASE_ID values | Engine |
|---:|---|---|
| 13 | 1 positional, 2 attention residual, 3 MLP residual | vector ADD |
| 14 | 1 before-attention LN, 2 after-attention LN, 3 final LN | LayerNorm ref |
| 15 | 1 full zero-mask model, 2 directed non-zero mask | vector SCALE_MASK |
| 16 | 1 attention head 0, 2 all 12 heads | Softmax ref |
| 17 | 1 full layer-0 FC1, 2 directed 19-element tail case | GELU ref |
| 18 | 1 patch reorder, 2 prepend CLS, 3/4/5 split Q/K/V, 6 K-transpose, 7 merge, 8 select CLS | layout mover |
| 19 | 1 model-logit argmax, 2 directed tie, 3 optional class Softmax/confidence | argmax or Softmax ref |

Run directed/short cases before full tensors:

```text
D03 case 2 -> D05 case 2 -> D07 case 2 -> D06 case 8
-> D01 cases -> D02 cases -> D04 head 0 -> D04 all heads
-> D05 full -> all D06 layouts -> D07 model/class Softmax
```

## Engine details

### Shared vector engine

The 16-lane engine latches operation, length, scalar, and mask enable. A final
partial vector carries a lane mask. In ADD mode B is the second vector. In
SCALE_MASK mode:

```text
scaled = fp32_mul(A, scalar)
result = mask_enable ? fp32_add(scaled, B) : scaled
```

Disabling the mask is a true bypass; the B bus may be poisoned in a future
directed test without affecting the result.

### LayerNorm reference

For each token the controller sequences:

```text
SUM -> MEAN -> VARIANCE_SUM -> VARIANCE -> INV_STD -> AFFINE
```

Variance is centered and biased (`correction=0`), hidden size is 768, and
epsilon is `1e-12`. It rereads the source rather than storing a complete token.
The debug ports expose mean, variance, and inverse standard deviation.
The reference testbench writes one word per token for all three statistics,
and the D02 manifest requires the comparator to check those auxiliary files as
well as the final affine output. The normalized-before-affine tensor remains a
packaged offline debug checkpoint rather than a separate DUT output port.

### Softmax reference

For each row the controller sequences:

```text
MAX -> EXP_SUM -> RECIPROCAL -> OUTPUT
```

It subtracts the row maximum and recomputes exponentials in the output pass,
avoiding an internal row buffer. Attention uses row length 197; optional class
confidence uses row length 1,000. Comparison is tolerant because reduction
order and subnormal handling differ from PyTorch.

### GELU reference

The model target is `0.5*x*(1+erf(x/sqrt(2)))`. The simulator helper evaluates
erf with Abramowitz-Stegun 7.1.26 and rounds the final result to FP32. On the
saved layer-0 FC1 tensor, the characterized maximum difference from the
official exact-erf checkpoint is below `1e-6`. The tanh GELU approximation is
not used because its error against this golden is much larger.

### Layout mover

One descriptor supplies source bank/base, destination base, three destination
dimensions, and three source strides:

```text
src = src_base + i0*stride0 + i1*stride1 + i2*stride2
dst = dst_base + contiguous_linear_index
```

The module validates descriptor size and final address against the 32-bit word
address interface. Prepend CLS is two descriptors. In a final optimized NPU,
split/transpose/merge should often be folded into consumer addressing instead
of physically copying a full tensor.

### Argmax

The comparator is sign-aware for finite FP32 words, treats `+0` and `-0` as
equal, and updates only for a strict greater-than. Equal maxima therefore keep
the lowest index like `torch.argmax`. A sticky error reports NaN/infinity;
label-string lookup remains a software task.

## What is still missing before full ViT

- Numerical ModelSim PASS evidence for all Phase-D packages.
- Synthesizable and pipelined rsqrt, reciprocal, exp, and GELU approximations.
- Physical scratch buffers, an address map, bus/DMA, and arbitration.
- A top sequencer that connects GEMM, layout, vector, LayerNorm, Softmax, GELU,
  and argmax into embeddings, one encoder layer, all 12 layers, and the final
  classifier path (Phase E).
- Fmax/resource optimization. The existing FP32 arithmetic is deliberately
  functional and combinational, not timing-closed.
