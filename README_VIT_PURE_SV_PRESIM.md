# Pure-SystemVerilog full ViT pre-simulation

This flow evaluates the prepared-input `google/vit-base-patch16-224` model
using SystemVerilog only. It does not load the C++ VPI model and does not call
Python, PyTorch, or Transformers for inference.

## Boundary

- `vit_phase_e_sequencer.sv` is the clocked, synthesizable-style controller.
- The descriptor/address contract, tensor routing, and raw FP32 memory map are
  unchanged from Phase E.
- `vit_phase_e_behavioral_engine_top.sv` is the replaceable simulation-only
  backend. Its dynamic raw/shadow memories, per-element address loops, `real`
  arithmetic, and whole-operation tasks are deliberately not claimed as
  synthesizable. The current pure-SV path validates the replaceable interface;
  it is not itself the future synthesis backend.
- `tb_vit_phase_e.sv` is solely responsible for `$readmemh`, `$fdisplay`, and
  checkpoint files; the behavioral backend reports arithmetic progress.
- A later Xilinx-IP/RTL FP32 backend can consume the same descriptors and
  handshakes without changing the controller.

The input remains prepared patch-A `[196,768]`, one IEEE-754 FP32 word per
line. It is not a JPEG or raw RGB tensor.

## Model schedule

The controller issues 249 commands:

```text
4 embedding
+ 12 * 20 encoder-layer operations
+ 5 final LayerNorm/classifier/argmax/Softmax operations
```

All 200 parameter tensors are loaded on demand through one reusable static
`$readmemh` staging buffer, then copied into the backend's active raw/shadow
parameter window. The flow therefore never needs a monolithic
86.6-million-word weight memory.

Every descriptor stores explicitly rounded FP32 outputs before the next
descriptor consumes them. GEMM uses SystemVerilog `real` accumulation for
practical functional-simulation speed.

## Run

From the repository root:

```bash
compute_engine/run_vit_pure_sv_presim.sh
```

An alternate case directory with the same file contract can be passed as the
first argument. The full Icarus run is expected to take several hours.

The run deliberately forces:

```text
CHECKPOINT_INJECT=0
```

so no intermediate result is replaced by golden data.

Final files are written below `CASE_DIR/npu_checkpoints`, including logits,
class index, probabilities, confidence, `prediction.txt`, and every major
model boundary. For the bundled case the expected result is class index 232
with confidence close to 72.1019 percent. The default bundled run checks both
values inside SystemVerilog, rejects incomplete HEX inputs, and verifies that
all major output files are newer than the current run marker. The
`pure_sv_run_complete.marker` file is created only after those checks pass.
The runner clears an older completion marker before starting. A pre-existing
`prediction.json` is a legacy foreign-backend artifact and is deliberately not
used; the pure-SV result is `prediction.txt` plus the HEX checkpoints.

`PASS functional run complete` confirms the 249-command protocol and the
bundled final prediction check. For development-grade comparison of every
major tensor against the packaged golden files, run this after simulation:

```bash
.venv/bin/python -u prepare_phase_e_tests.py \
  --compare test_24/case_02_prepared_patch_a_probability --major-only
```

That Python command is only a checkpoint comparator; model inference itself
has already been performed entirely by SystemVerilog.

## Verified bundled run

The bundled probability case completed under Icarus on 2026-07-21 in
`07:54:41` wall-clock time:

```text
commands=249
checkpoints=249
parameter_loads=101
class_index=232
confidence=0.721019030
confidence_percent=72.101903%
```

The packaged golden confidence is `0.721018910`, so the absolute confidence
error was `1.1920929e-7`. Final LayerNorm, all 1,000 logits, exact class index,
maximum logit, all 1,000 probabilities, and confidence passed their manifest
tolerances.

The strict major-boundary comparison passed 13 of 19 checkpoints. Encoder
layers 6 through 11 contained respectively 2, 4, 2, 9, 15, and 14 values just
outside the PyTorch-oriented tolerance, out of 151,296 values per layer. No
NaN or infinity was present, and the final outputs passed. This is the
expected numerical limit of this backend: GEMM reduction and transcendental
operations use simulator `real` arithmetic and round at operation boundaries;
they are not bit-exact replicas of PyTorch's FP32 kernel reduction order.
Those deviations should not be hidden by checkpoint injection or a relaxed
comparator. A later Xilinx-IP/RTL backend needs its own numerical contract.
