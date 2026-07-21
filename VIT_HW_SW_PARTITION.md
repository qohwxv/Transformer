# ViT-Base/224 hardware-software partition and remaining roadmap

The current milestone includes the runtime-configurable batched FP32 GEMM path,
the Phase-D execution engines, and a Phase-E functional integration top.
File-backed packages now cover Phase B/C, 23 named Phase-D cases, and E01–E05.
The new model sequencer emits a fixed 20-command encoder schedule, loops over
all 12 layers, and drives one execution adapter with an explicit logical
scratch map and reusable parameter window. The control regression passes, but
the arithmetic paths still need numerical ModelSim runs.

LayerNorm, Softmax, and GELU continue to use explicitly simulation-only
special-function helpers. The scratch/input/parameter arrays are logical
functional memories, not banked SRAM or an external-memory system. Thus this
is now an executable full-model reference NPU from prepared patch-A, but it is
not yet a synthesizable, deployable, or timing-closed NPU.

## Recommended boundary

For the first useful complete system, use this division:

```text
Host software
    |-- JPEG decode, resize, RGB normalization
    |-- model/weight loading and memory-map construction
    |-- NPU command submission and error handling
    |-- golden comparison, profiling, and debug
    `-- optional final logits Softmax/top-k
                |
                v
NPU hardware
    |-- external-memory/DMA interface
    |-- scratch-memory and address/layout controller
    |-- configurable GEMM tree-PE array
    |-- vector/reduction/SFU block
    |     add, multiply, max, sum, reciprocal, rsqrt, exp, GELU
    |-- Q/K/V head split, K transpose, and head merge data mover
    |-- LayerNorm, attention Softmax, residual operations
    `-- layer/model sequencer
```

This boundary keeps image-format work in software while keeping the large
intermediate tensors inside the accelerator memory domain. Moving every
LayerNorm/Softmax/GELU tensor back to the CPU is acceptable for early bring-up,
but it should not be the final architecture.

ViT-Base has roughly 86.6 million parameters, or about 346 MB in FP32. It is
not realistic to store all FP32 weights in small on-chip SRAM. A deployable
version will normally keep weights in external DDR and stream/cache tiles, or
move to BF16/FP16/INT8 after the FP32 functional reference is stable.

## Two viable development paths

### Fast hybrid bring-up

Hardware performs every GEMM, including Q/K/V/O, FC1/FC2, QK-transpose,
probability-times-V, patch projection, and classifier. Software performs
reshape/transpose, LayerNorm, scaling, Softmax, GELU, residual adds, and the
12-layer schedule.

Advantages:

- Reaches a correct full-model forward pass sooner.
- Reuses the current GEMM engine almost immediately.
- Makes each missing hardware block replaceable one at a time.

Disadvantages:

- Very high intermediate-memory traffic and synchronization overhead.
- It demonstrates a GEMM accelerator, not yet a self-contained ViT NPU.

### Recommended balanced NPU

Keep only preprocessing, driver work, and optional final top-k in software.
Implement layout movement, vector/reduction functions, scratch-memory control,
and the encoder-layer sequencer in hardware. This is the recommended target
after the hybrid path proves numerical correctness.

## Remaining functional-test count

The project checklist contains 26 functional groups:

```text
Phase A arithmetic/controller       2
Phase B biased GEMMs                8
Phase C attention GEMMs             4
Phase D non-GEMM ViT blocks         7
Phase E integration                 5
```

Only B01/Q has passed RTL comparison so far, so 25 groups remain open. The
generic RTL makes B02–B08 and C01–C04 executable, the Phase-D RTL/packages make
D01–D07 executable, and the Phase-E sequencer/top/packages make E01–E05
executable from their documented boundaries. Implementation does not count as
a pass until a ModelSim output is compared.

After A01/A02 and all seven remaining Phase-B GEMMs pass, 16 groups remain:
four attention-GEMM groups, seven non-GEMM blocks, and five integration groups.
E03 itself expands into 11 per-layer regressions.

After Phase C also passes, 12 groups remain at checklist level: seven Phase-D
non-GEMM blocks and five Phase-E integration groups. This count does not imply
that full-model work is small; E03 still expands to 11 additional encoder-layer
regressions.

## Twelve major implementation milestones to a balanced full model

1. Run arithmetic, handshake/stall, reset, and B01–B08 regressions.
2. Run the prepared no-bias QK-transpose tests for one head and all 12 heads.
3. Add head-aware base/stride addressing and split/transpose/merge movement.
4. Run the prepared probability-times-V tests and prove the K=197 hardware
   tail mask with poison lanes.
5. Add a vector ALU for residual add, position add, scale, and mask.
6. Add LayerNorm mean/variance/rsqrt/gamma/beta sequencing.
7. Add stable row-wise attention Softmax: max, exp, sum, reciprocal, normalize.
8. Add and characterize the chosen GELU implementation.
9. Add scratch-memory mapping, source/destination descriptors, and hidden-state
   lifetime planning. The functional map/descriptor is implemented; physical
   SRAM banking remains.
10. Add a layer sequencer and pass the complete encoder layer 0 checkpoint by
    checkpoint. The sequencer is implemented; the numerical pass remains.
11. Add layer-indexed parameter tables and pass encoder layers 1 through 11.
    The table handshake/data packages are implemented; numerical runs remain.
12. Integrate patch front end, final LayerNorm, CLS selection, classifier, and
    the full end-to-end regression. Prepared-patch integration is implemented;
    normalized-pixel patch extraction and the numerical E05 pass remain.

These are architecture milestones, not clock-time estimates. Work for bus/DMA,
Fmax pipelining, quantization, synthesis, timing closure, and physical resource
optimization comes after functional end-to-end correctness and is additional.

## Suggested ownership by operation

| Operation | First hybrid version | Balanced target |
|---|---|---|
| JPEG decode/resize | Software | Software |
| RGB normalization | Software | Software or small input unit |
| Patch im2col/address mapping | Software | Hardware data mover |
| Patch/Q/K/V/O/FC1/FC2/classifier GEMM | Hardware | Hardware |
| QK-transpose and probability-times-V | Hardware GEMM, software layout | Hardware GEMM + data mover |
| Head split/K transpose/head merge | Software | Hardware data mover |
| Position/residual add and scaling | Software | Hardware vector ALU |
| LayerNorm | Software | Hardware reduction/SFU |
| Attention Softmax | Software | Hardware reduction/SFU |
| GELU | Software | Hardware SFU/LUT/polynomial |
| Dropout at inference | Bypass | Bypass |
| 12-layer scheduling | Software command list | Hardware layer sequencer |
| Final Softmax/top-k | Software | Software; hardware is optional |

## Practical next action

Run `TEST_ID=2`, `3`, and `4` first because they exercise the same shape as the
known-good Q projection. Then run `5`, `8`, `6`, and `7`. For Phase C, use
`9` → `11` → `10` → `12`: first prove one-head no-bias arithmetic, then the
K=197 poison-tail path, and only then run the longer 12-head controller jobs.

For Phase D, start with the short directed cases: D03/test 15 case 2, D05/test
17 case 2, D07/test 19 case 2, and D06/test 18 case 8. Then run the full vector
and layout cases, LayerNorm, attention-head-0 Softmax, all-head Softmax, and the
optional class Softmax. Use `prepare_phase_d_tests.py --compare-all` only after
the testbenches have produced outputs; a missing output is deliberately not
treated as a pass.
