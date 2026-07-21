# Monolithic ViT functional pre-simulation

This path runs the complete `google/vit-base-patch16-224` inference graph from
a prepared patch matrix through 12 encoder layers, final LayerNorm,
classifier, argmax, and class Softmax.

It is intentionally a **functional simulation model**, not synthesizable RTL:

- no clock, timing, FSM/controller, AXI, DMA, or board interface;
- SystemVerilog owns the testbench transaction;
- a compiled VPI behavioral datapath holds large FP32 tensors and calls CBLAS
  for matrix multiplication so the full model does not take hundreds of
  millions of interpreted simulator cycles;
- inference and final comparison do not call Python, PyTorch, or Transformers.

Build requirements are Icarus Verilog with VPI development headers,
a C++17 compiler, and a CBLAS-compatible `libblas` development package.

## Input contract

The image-side input is one IEEE-754 FP32 word per line:

```text
prepared_patch_A[196,768]
```

It is already resized, normalized, and converted to ViT patch rows. It is not
a JPEG, RGB byte array, or normalized CHW tensor. Each `*_weight_B_f32.hex`
parameter is already transposed into `C = A @ B + bias` row-major layout.

The current parameter package is a directory of 200 named HEX tensors rather
than one ambiguous concatenated file. The filenames preserve tensor bounds and
make incorrect weight offsets immediately detectable.

## Run

From the repository root:

```bash
compute_engine/run_vit_monolithic_presim.sh
```

Optional arguments are:

```text
run_vit_monolithic_presim.sh CASE_DIR [CONFIG_JSON] [OUTPUT_DIR]
```

For a custom prepared image using the same weights:

```bash
VIT_IMAGE_HEX=/absolute/path/image.hex \
VIT_PARAMETER_DIR=/absolute/path/parameters \
compute_engine/run_vit_monolithic_presim.sh /absolute/path/case
```

`CONFIG_JSON` is used only to map the numeric class index to a display label.
It has no effect on inference arithmetic.

Comparison is enabled automatically only when using the case's own image.
Set `VIT_GOLDEN_DIR=/path/to/checkpoints` to select another valid golden set,
or `VIT_SKIP_COMPARE=1` to disable comparison explicitly. The runner refuses
an output directory that resolves to the case's golden `checkpoints` directory.

## Outputs

The output directory receives the 19 major Phase-E checkpoints, including all
12 layer outputs, logits, probabilities, class index, maximum logit, and
confidence. It also receives:

- `prediction.txt` for a short human-readable result;
- `prediction.json` for class index/name, probability, percent, and top-5.

When the case has saved golden files, the compiled simulation model compares
the final LayerNorm, logits, class index, maximum logit, all probabilities, and
confidence against them. The twelve emitted layer boundaries remain available
for diagnostics; different host BLAS reduction orders can produce small,
accumulated FP32 differences at those internal boundaries even when the final
inference outputs satisfy their reference tolerances.
