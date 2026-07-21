# Phase-E functional ViT NPU integration

Phase E defines the functional integration contract above the existing GEMM,
vector, layout, LayerNorm, Softmax, GELU, and argmax engines. It sequences a
prepared patch matrix through embeddings, 12 encoder layers, final LayerNorm,
the classifier, and class selection. Package details are in
[`PHASE_E_TEST_PACKAGES.md`](../PHASE_E_TEST_PACKAGES.md).

This milestone is not a complete deployable NPU. It has no AXI or other bus,
DMA, cache, arbitration fabric, physical SRAM macro, software driver, or raw
image patch extractor. Logical memories are currently behavioral arrays in the
execution adapter and are bulk-loaded by the file-backed testbench. Package
generation, a clean RTL compile, or completion of the testbench schedule is
not numerical pass evidence.

## Functional architecture

```text
test_20 ... test_24 manifests/files
                |
                v
tb_vit_phase_e
    |-- bulk INPUT/PARAM/SCRATCH loading
    |-- layer and operand-load service
    |-- checkpoint dump / optional golden injection
    `-- job valid/ready
                |
                v
vit_phase_e_npu
    |-- vit_phase_e_sequencer
    |     |-- four-command embedding schedule
    |     |-- fixed 20-operation layer schedule
    |     |-- model/layer loop
    |     `-- command and checkpoint handshakes
    `-- vit_phase_e_engine_top
          |-- behavioral INPUT/PARAM/SCRATCH arrays
          |-- descriptor-to-native-handshake adapter
          |-- GEMM, vector, and layout engines
          |-- LayerNorm, Softmax, and GELU reference engines
          `-- argmax engine
                |
                v
npu_checkpoints/ -> prepare_phase_e_tests.py comparator
```

The sequencer emits operation descriptors; it is not itself a GEMM datapath,
an SFU, a memory, or a bus master. `vit_phase_e_engine_top` is the current
one-command execution adapter: it translates a descriptor into the native
request/data/result handshake of the selected engine and returns exactly one
completion or error. Its named arrays are behavioral simulation/bring-up
storage, not SRAM macros.

`vit_phase_e_npu` connects the sequencer to the execution adapter.
`tb_vit_phase_e` supplies jobs, bulk-loads package tensors, services
layer/operand requests, and writes checkpoint files. This is a functional
simulation stack, not a bus-connected or SRAM-backed implementation.

The Phase-E integration sources are:

| File | Purpose |
|---|---|
| `vit_phase_e_pkg.sv` | Shared job, operation, checkpoint, address, and shape definitions |
| `vit_phase_e_sequencer.sv` | Model/layer state machine and descriptor generator |
| `vit_phase_e_engine_top.sv` | One-command adapter, engine instances, and behavioral memories |
| `vit_phase_e_npu.sv` | Functional top wiring the sequencer to the execution adapter |
| `tb_vit_phase_e.sv` | File-backed E01-E05 functional testbench and checkpoint writer |
| `vit_phase_e_ref.f` | Full integration compile order |
| `tb_vit_phase_e_sequencer.sv` | Small control-only schedule/backpressure regression |
| `vit_phase_e_control.f` | Control-only compile order |

Exact testbench filenames and simulator plusargs may evolve. The package
manifest and the types/constants in `vit_phase_e_pkg.sv` are authoritative.

Current verification evidence is deliberately split:

- the control-only sequencer regression has passed all E01-E05 schedules,
  command/opcode counts, layer requests, forced ready/valid stalls, and invalid
  phase/layer checks under Icarus;
- no full `tb_vit_phase_e` checkpoint set is recorded as numerically passing.

The first result proves controller behavior only. It does not execute FP32
GEMM, LayerNorm, Softmax, or GELU arithmetic.

## Supported model boundary

The runnable E01 and E05 paths begin at prepared patch-A:

```text
prepared A_patch[196,768]
  -> patch projection GEMM
  -> copy CLS then projected patches into one hidden region
  -> positional add
  -> embedding dropout identity (no issued descriptor)
```

Patch-A has already performed image patch extraction/im2col and is already
token-major. It is not normalized CHW input. Therefore:

- no flatten/transpose follows patch GEMM;
- JPEG decode, resize, RGB normalization, and patch extraction are outside
  this runnable boundary;
- a separate blocked E05 manifest records the future normalized-pixel path;
- embedding dropout is a zero-cost identity at inference because its
  probability is zero. Its checkpoint aliases the positional-add result and
  it does not issue another descriptor.

Prepared patch-A is in the `INPUT` namespace. The patch weight, patch bias,
CLS token, positional tensor, encoder parameters, and final classifier
parameters are in the `PARAM` namespace. The adapter represents those spaces
with SystemVerilog arrays; neither is a physical NPU memory in this functional
stage.

## Command schedules

### E01 — four embedding commands

| Descriptor | Engine | Source -> destination |
|---:|---|---|
| 1 | GEMM | `PATCH_A * patch_weight + bias -> LINEAR_TMP` |
| 2 | layout mover | `CLS[768] -> HIDDEN_A + 0x000000` |
| 3 | layout mover | `LINEAR_TMP[196,768] -> HIDDEN_A + 0x000300` |
| 4 | vector add | `HIDDEN_A + POSITION -> HIDDEN_A` in place |

Descriptors 2 and 3 together implement prepend-CLS. No transpose is hidden in
descriptor 3. The Step-03 token layout is an alias/view of descriptor-1 output,
and the Step-06 dropout checkpoint is an alias of descriptor-4 output. They do
not increase the command count. A checkpoint is offered after each issued
descriptor; a package may additionally compare those named alias boundaries.

### E02/E03 — fixed 20-operation encoder layer

Every encoder layer uses the same schedule; only the layer index and parameter
set change. `HIDDEN_A` remains the persistent layer input/output address:

| Op | Operation | Preferred storage transition |
|---:|---|---|
| 01 | LayerNorm before attention | `HIDDEN_A -> HIDDEN_B` |
| 02 | Q projection | `HIDDEN_B -> LINEAR_TMP` |
| 03 | split Q heads | `LINEAR_TMP -> Q_HEAD` |
| 04 | K projection | `HIDDEN_B -> LINEAR_TMP` |
| 05 | split K heads | `LINEAR_TMP -> K_HEAD` |
| 06 | V projection | `HIDDEN_B -> LINEAR_TMP` |
| 07 | split V heads | `LINEAR_TMP -> V_HEAD` |
| 08 | transpose K per head | `K_HEAD -> LINEAR_TMP` |
| 09 | Q times K-transpose | `Q_HEAD * LINEAR_TMP -> SCORE_PROB` |
| 10 | scale; all-zero model mask bypass | `SCORE_PROB -> SCORE_PROB` |
| 11 | row-wise Softmax | `SCORE_PROB -> SCORE_PROB` |
| 12 | probabilities times V | `SCORE_PROB * V_HEAD -> Q_HEAD` |
| 13 | merge heads | `Q_HEAD -> LINEAR_TMP` |
| 14 | attention output projection | `LINEAR_TMP -> HIDDEN_B` |
| 15 | attention residual add | `HIDDEN_B + HIDDEN_A -> HIDDEN_B` |
| 16 | LayerNorm before MLP | `HIDDEN_B -> HIDDEN_A` |
| 17 | FC1 projection | `HIDDEN_A -> FC1` |
| 18 | GELU | `FC1 -> FC1` |
| 19 | FC2 projection | `FC1 -> LINEAR_TMP` |
| 20 | MLP residual add | `LINEAR_TMP + HIDDEN_B -> HIDDEN_A` |

The Q/K/V projections all consume op-01 output in `HIDDEN_B`. Each projection
is immediately split so `LINEAR_TMP` can be reused by the next one. Op 08
physically copies `K_HEAD` to transposed `[12,64,197]` data in `LINEAR_TMP`; a
later adapter may replace that copy with a strided view. After QK consumes Q
and transposed K, op 12 overwrites the now-dead `Q_HEAD` region with the
P-times-V output.

There is deliberately no hidden-bank swap between layers. `HIDDEN_A` holds
the persistent layer input and final layer output. Op 14 reuses `HIDDEN_B`
after Q/K/V no longer need LN1; op 15 leaves the attention residual in
`HIDDEN_B`; op 16 may then overwrite the old input by writing LN2 to
`HIDDEN_A`; and op 20 adds FC2 to the still-live `HIDDEN_B` residual and writes
the next layer input back to `HIDDEN_A`. E02 executes this schedule for layer
0. E03 supports one 20-operation job for each layer 1 through 11 and one
uninterrupted 220-op chain covering all eleven layers.

Attention-probability dropout, attention-output dropout, and MLP dropout are
all identities for this checkpoint in evaluation mode. They do not add three
more descriptors; their saved boundaries alias the preceding producer result.

### E04 — final path

```text
final LayerNorm
  -> select CLS
  -> classifier GEMM
  -> argmax on original logits -> index and maximum logit
  -> optional 1,000-class Softmax -> class probability region
```

| Descriptor | Transition |
|---:|---|
| 1 | final LayerNorm `HIDDEN_A -> HIDDEN_B` |
| 2 | select CLS `HIDDEN_B[0,:] -> LINEAR_TMP[0,:]` |
| 3 | classifier `LINEAR_TMP * weight + bias -> LOGITS` |
| 4 | argmax `LOGITS -> class_index/class_logit` output ports |
| 5, optional | Softmax `LOGITS -> CLASS_PROB` |

Argmax is descriptor 4 and always reads logits. When enabled, class Softmax is
descriptor 5 and also reads the preserved logits. It changes only the optional
probability/confidence result and cannot change the class-selection source.
The required final path has four commands; enabling class Softmax adds a fifth.

### E05 — composed model job

A required prepared-input E05 job contains 248 model-level commands:

```text
4 embeddings + (12 * 20 encoder operations) + 4 required final operations
```

Optional class Softmax makes 249. The sequencer must not reload an activation
between layers in the chained job. Parameter changes and checkpoint stalls are
allowed only through their defined handshakes.

## Fixed logical scratch map

Scratch addresses are 32-bit **FP32 word addresses**, not byte addresses. The
map is fixed for package manifests and descriptor checking:

| Region | Base word address | Capacity (words) | Main contents |
|---|---:|---:|---|
| `HIDDEN_A` | `0x000000` | `0x025000` | persistent `[197,768]` layer input/output |
| `HIDDEN_B` | `0x025000` | `0x025000` | LN1/final-LN, O-projection, and attention-residual temporary |
| `LINEAR_TMP` | `0x04A000` | `0x025000` | projection output, K-transpose, merge, FC2, or CLS |
| `Q_HEAD` | `0x06F000` | `0x025000` | Q heads, then P-times-V output |
| `K_HEAD` | `0x094000` | `0x025000` | untransposed K heads |
| `V_HEAD` | `0x0B9000` | `0x025000` | V heads |
| `SCORE_PROB` | `0x0DE000` | `0x072000` | `[12,197,197]` raw/scaled scores then probabilities |
| `FC1` | `0x150000` | `0x094000` | `[197,3072]` FC1 then GELU |
| `LOGITS` | `0x1E4000` | `0x001000` | `[1000]` classifier logits |
| `CLASS_PROB` | `0x1E5000` | `0x001000` | optional `[1000]` probabilities |

The capacities include small alignment guards:

```text
[197,768]       = 151,296 = 0x024F00 words
[12,197,197]    = 465,708 = 0x071B2C words
[197,3072]      = 605,184 = 0x093C00 words
```

The declared scratch extent ends at `0x1E6000`, or 1,990,656 FP32 words
(7,962,624 bytes). This is a logical simulation address space, not evidence
that roughly 7.6 MiB of SRAM has been instantiated. `SCORE_PROB` intentionally
reuses one allocation across raw scores, scaled scores, and probabilities;
`FC1` similarly permits in-place GELU. An engine/adapter must finish every
read required for a command before an in-place write can destroy its source.

Patch-A, weights, biases, LayerNorm gamma/beta, CLS, positional embeddings,
and the attention mask are not allocated in this scratch table. They are
loaded/read through the separate INPUT/PARAM behavioral arrays. The adapter's
default input array is 150,528 words. Its reusable parameter staging array is
split logically into:

| Parameter window | Base | Capacity | Use |
|---|---:|---:|---|
| `MAIN` | `0x000000` | `0x240000` words | current weight, gamma, position, CLS, or other main operand |
| `AUX` | `0x240000` | `0x001000` words | current bias, beta, or other small companion operand |

`MAIN` is sized for one largest FC1/FC2 B matrix (`3072*768` words), and `AUX`
is sized for the largest 3,072-element bias with alignment headroom. The total
`PARAM` array is `0x241000` words. Only the current command's operands are
resident; this is not a whole-layer or whole-model weight store. These
simulation capacities must not be presented as implemented on-chip memory.

## Parameter-loader handshake

There are two distinct parameter handshakes.

First, before each encoder layer the sequencer asserts
`layer_param_request` with stable `layer_param_index`. It waits for
`layer_param_valid` and latches one `phase_e_layer_params_t` containing the 16
base addresses for that layer's two LayerNorm pairs and six weight/bias pairs.
E02 forces layer 0, E03 uses its requested inclusive range, and E05 requests
layers 0 through 11. Global embedding/final base addresses arrive with the
accepted job as `global_params`. These structures are reusable staging-base
tables, not proof that all referenced layer parameters are resident at once;
the layer index still tells the loader which canonical files to select.

Second, after `vit_phase_e_engine_top` accepts any descriptor that references
the PARAM space, it asserts `parameter_request` and presents the stable full
descriptor on `parameter_command`. At the `vit_phase_e_npu` boundary these are
named `operand_load_request`, `operand_load_command`, and
`operand_load_ready`. A testbench loader stages the command's main operand at
`MAIN` and, when present, its bias/beta companion at `AUX`, then asserts ready.
Only then does the adapter launch the selected engine. The one-bit ready does
not itself return a hash or word count, so those checks remain a testbench and
manifest responsibility.

This scheme models correct lifetime and backpressure, but it does not model
DDR bandwidth and does not prove DMA or a double-buffered parameter cache. A
loader must not replace a parameter while an accepted command can still read
it. Layers 1 through 11 require their own two LayerNorm gamma/beta pairs;
using layer-0 parameters as a default is an error.

## Command and checkpoint handshakes

The integration control uses five independent transactions:

- `job_valid/job_ready`: accepts one E01/E02/E03/E04/E05 request and options;
- `layer_param_request/layer_param_valid`: loads one layer's base-address
  table into the sequencer;
- `cmd_valid/cmd_ready` followed by exactly one `cmd_done` or `cmd_error`:
  launches an engine descriptor and waits for completion;
- `parameter_request/parameter_ready` inside the adapter: stages PARAM operands
  before the selected engine starts;
- optional `checkpoint_valid/checkpoint_ready`: reports phase, section, layer,
  step, tag, opcode, and destination tensor ID after each successful command.

All valid payloads remain stable while ready is low. A command is never
re-issued merely because completion is delayed. When checkpointing is enabled,
the sequencer does not advance to a command that can overwrite the reported
region until the checkpoint is accepted. The checkpoint port does not carry a
base address or word count; the collector resolves those from the destination
tensor, issued descriptor, and case manifest. A disabled checkpoint is a
bypass, not an implicit pass. The chained E03/E05 runs rely on these rules to
detect stale parameters, incomplete writes, leaked accumulator state, and
incorrect reuse of `HIDDEN_A`/`HIDDEN_B`.

## Arithmetic and synthesis status

The integration target currently mixes ordinary RTL candidates with
simulation-only functional math:

| Path | Current status |
|---|---|
| GEMM/tree PE | Functional FP32 RTL; combinational and not timing-closed |
| vector add/scale/mask | RTL candidate |
| layout mover | RTL candidate |
| argmax | RTL candidate |
| LayerNorm rsqrt | simulator `shortreal`/`real` reference |
| Softmax exp/reciprocal | simulator `shortreal`/`real` reference |
| GELU erf approximation | simulator `shortreal`/`real` reference |

Consequently, a future ModelSim Phase-E match would prove functional schedule,
addressing, handshakes, and the selected numerical references. It would not
prove that LayerNorm, Softmax, or GELU can be synthesized, meet Fmax, or fit a
resource budget. Those three paths still need characterized LUT/PWL/polynomial
or iterative hardware and implementation-matched error budgets.

## ModelSim usage

Run the short control-only regression first:

```tcl
vlib work
vlog -sv -f compute_engine/vit_phase_e_control.f
vsim work.tb_vit_phase_e_sequencer
run -all
```

Compile the functional integration stack and run one package from the
repository root so relative package links resolve:

```tcl
vlog -sv -f compute_engine/vit_phase_e_ref.f
vsim work.tb_vit_phase_e +TEST_ID=20 +CASE_ID=1 \
  +CHECKPOINT_INJECT=1 +MAJOR_ONLY=0
run -all
```

The implemented test selection is:

| `TEST_ID` | `CASE_ID` | Job |
|---:|---:|---|
| 20 | 1 | E01 prepared patch-A embedding |
| 21 | 1 | E02 encoder layer 0 |
| 22 | 1..11 | E03 standalone selected layer |
| 22 | 12 | E03 chained layers 1 through 11 |
| 23 | 1 | E04 logits and argmax |
| 23 | 2 | E04 plus class Softmax/confidence |
| 24 | 1 | E05 prepared patch-A through logits/argmax |
| 24 | 2 | E05 plus class Softmax/confidence |

`test_24` case 3 is manifest-only and deliberately stops with an error because
the normalized-pixel patch extractor does not exist.

| Plusarg | Meaning |
|---|---|
| `+TEST_ID=20..24` | Select Phase-E package |
| `+CASE_ID=<n>` | Select the case shown above |
| `+CASE_DIR=<path>` | Override the generated case directory |
| `+CHECKPOINT_INJECT=0/1` | After dumping each NPU result, optionally replace its destination with the golden injection tensor; default 1 |
| `+MAJOR_ONLY=0/1` | Dump only major boundaries when 1; defaults to 1 for E05 and chained E03, otherwise 0 |

Golden injection is a diagnostic mode. With `CHECKPOINT_INJECT=1`, each
operation receives the expected previous boundary, so a mismatch localizes to
that operation. Use `CHECKPOINT_INJECT=0` for a true continuous chain in which
numerical differences propagate. `MAJOR_ONLY=1` reduces file I/O but still
injects every boundary when injection is enabled; compare that run with the
same `--major-only` policy.

After simulation, run the comparator command printed by the testbench. For
example:

```bash
.venv/bin/python prepare_phase_e_tests.py \
  --compare test_20/case_01_prepared_patch_a
```

The testbench message `PASS functional run complete` checks completion,
command/checkpoint counts, and controller error status. It does **not** compare
the dumped FP32 tensors. Only a subsequent Python comparator pass is numerical
evidence.

## Verification order and runtime

Run integration from the shortest boundary outward:

```text
E01 embedding
  -> E02 layer 0, checkpoint by checkpoint
  -> E03 each layer 1..11
  -> E03 chained layers 1..11
  -> E04 required logits/argmax
  -> E04 optional probability
  -> E05 prepared patch-A full chain
```

The existing GEMM controller estimates about 24.36 million zero-stall cycles
per encoder layer. Twelve layers plus patch projection and classifier exceed
294 million GEMM cycles before non-GEMM passes, file I/O, adapter latency,
checkpoint stalls, and waveform overhead. Including the simple reference
cycle models for layouts and non-GEMM passes, the generated E05 manifests
estimate 352,273,508 zero-stall cycles without class Softmax and 352,277,509
with it. These are timeout-sizing estimates, not throughput claims. A full E05
event simulation can be very slow; disable unnecessary waveform capture and
first diagnose failures at the nearest checkpoint.

No Phase-E case is called numerically passed until a simulator has written all
required NPU checkpoint files and the package comparator has checked word
counts, layouts, finite values, per-boundary tolerances, and final metadata.
Expected index 232 and confidence near `0.7210189` are golden targets, not
current RTL pass claims.
