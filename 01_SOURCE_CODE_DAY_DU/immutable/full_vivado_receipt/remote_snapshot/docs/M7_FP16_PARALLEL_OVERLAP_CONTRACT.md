# M7 FP16 parallel GEMM and overlap contract

Status on 2026-08-08: the controlled eight-stream fallback preserves the
historical M7.4c-B FIFO/generation contract and maps logical `R8xC2` work to
ordered physical `R8xC1` column passes. The corrected-adder pre-v1.12 source
passed server XSim/OOC/BD/full synthesis with DSP=0, then failed placement
with `Place 30-487` because 9,172 CLBs were required and only 8,797 were
available. The active IP-v1.12 source specializes production to FP16 GEMM
modes 3/5 and removes the duplicate legacy FP32 GEMM; promoted M5 remains the
separate FP32 fallback. That exact 80-source v1.12 revision now passes the
complete 50 MHz Vivado-2023.2 flow, and true mode-3 real E04 and E01 each pass
twice in RTL/AXI simulation. The child remains `DEVELOPMENT_UNSEALED` with
`source_design_sha256=PENDING_M7_SEAL`; full real E05, final promotion and
physical-board validation remain pending.

## Immutable parents

- Promoted M5 bundle manifest SHA-256:
  `60f7f369902af23a02dd7b7b6451ac73dd29e34adb0623c2fc76fe5279b00571`.
- M5 ordered production-source SHA-256:
  `824c2a57b83e754eba6e7478e4c37d5f24d663e10624bac047eea033c721a77e`.
- Isolated M6 source-manifest SHA-256:
  `72c15f8bbd0683115efa9430c9d20d29e837d5434aa5f0b8cbbe8773ce3d3697`.
- M5 stays the comparison baseline. M6 remains an isolated primitive input;
  neither parent may be edited by M7.

`PARENT_M5_MANIFEST.sha256` is a byte-for-byte copy of the accepted M5
manifest. It is provenance input, not a manifest for this unsealed child.

## Numerical boundary

- GEMM operands are converted/stored as IEEE-754 binary16 using round to
  nearest, ties to even, with gradual subnormals by default.
- Each physical stream uses the M6 exact finite FP16 product and 93-bit
  carry-save/Kulisch-style accumulation, then rounds once to FP32 at dot end.
- Bias, result/scratch storage, residual, LayerNorm, Softmax, GELU, Argmax and
  all statistics remain FP32 for the first integration.
- DAZ/FTZ, narrower accumulation and FP16 scratch are separate controlled A/B
  experiments; they are disabled in the primary M7 candidate.
- M7 is not expected to be bit-exact with FP32 M5. Numerical acceptance needs
  explicit full-model tolerance, top-1 and multi-image evidence.

## Compute geometry and data delivery

The historical primary proposal was `R8/C2/L16` with 16 physical streams:

```text
stream = row * 2 + column
one K position per accepted cycle
8 FP16 A values + 2 FP16 B values -> 16 products/cycle
```

The current controlled child selects the eight-stream fallback because the
S16 full-device attempt exceeded the device LUT budget. Its external/logical
geometry remains `R8/C2/L16`, while each physical pass is `R8/C1/L16`:

```text
FP16_STREAMS = 8
pass 0: rows 0..7 x column 0, result mask 01
pass 1: rows 0..7 x column 1, result mask 10 (skipped for odd-N tail)
```

Pass 1 rewinds K plus A/B address context and preserves logical output base,
command generation and valid same-tag A-cache contents. The first full
integration target remains the existing common 50 MHz clock. A later 75/100
MHz sweep is permitted only after the 50 MHz functional/full-route gate
passes; no CDC is introduced implicitly.

The production compile-time specialization sets `INCLUDE_LEGACY_GEMM=0`.
Exact modes 3 and 5 use the S8 FP16 datapath. Mode 3 consumes packed-v3 FP16
persistent B; mode 5 consumes blocked-v2 FP32 B and converts it at the seam.
Modes 0/1 are retained only as readable/writable ABI encodings and reject at
START. FP32 A/B or emergency board fallback uses the separate promoted M5
artifact, not a second datapath inside M7-S8.

The v3 model package keeps 126 non-B tensors and prepared input in FP32. The
74 persistent GEMM-B tensors use a new blocked layout:

```text
[N_TILE][K_CHUNK][LANE][COL]
K_CHUNK = 16, N_TILE = 2 columns
one 32-bit word = {B[k,n+1]_fp16, B[k,n]_fp16}
one K16/N2 block = 16 words = 64 bytes
```

Tensor starts remain at least 128-byte aligned. The package and RTL must agree
on table version/layout/flags, physical word offsets, half-word selection,
tails and 4 KiB containment.

## Control and ownership contract

M7 separates four cooperating control roles:

1. load/prefetch;
2. compute/tile;
3. store/result drain;
4. error/flush.

The final M7.4 target requires two operand banks with explicit generation tags
and exclusive ownership. A bank cannot be refilled until compute releases it;
compute cannot consume a bank until load commits it. Result entries similarly
retain token, output, batch, absolute destination and generation until the
store handshake completes. Gate2 implements this contract for packed mode 3:
the memory frontend snapshots FIFO-head metadata for the complete store and
fails closed on stale generation. Logical FIFO reset/error drain is tested;
disposition of an arbitrary already-issued physical SmartConnect/slave
response remains an M7.4d gate.

The existing AXI-Lite register/counter ABI remains append-only. M7 profiling counts feeder
starvation, buffer-bank wait/occupancy, valid/tail accepted MAC terms, result
FIFO backpressure and true load/compute/store overlap. The current IP identity
is v1.12 (`0x0001000C`); the exact S8 FP16-only map is
[`PERF_PROFILE_ABI_V1_12.json`](PERF_PROFILE_ABI_V1_12.json), SHA-256
`25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35`.
It retains the v1.11/v1.10 23-counter map and all earlier addresses/meanings,
but explicitly narrows clean-idle START admission to exact modes 3/5. Every
other 32-bit mode value returns `WRAPPER_ERROR_EXECUTION_MODE=0x80000003`,
records the value in `ERROR_INFO` and starts no job/profile epoch/DDR request.
Historical v1.9/v1.10/v1.11 documents remain immutable.

## Gate sequence

| Gate | Required proof |
|---|---|
| M7.0 | **COMPLETE:** immutable parent hashes, child isolation, numerical/feed/resource contract |
| M7.1 | **COMPLETE:** v3 package for all 200 tensors; unpack/quantization/address/4 KiB verifier |
| M7.2 | **COMPLETE for leaf simulation and pre-final-mux OOC:** 16-stream R8/C2 bridge, 8-stream fallback, conversion/tail/TLAST/reset/error tests |
| M7.3a | **COMPLETE for bounded simulation:** no-overlap production integration, legacy blocked-v2 compatibility and opt-in FP16 compute |
| M7.3b | **COMPLETE for compact simulation:** packed-v3 addressing/frontend/direct-FP16 compute seam through the production AXI wrapper |
| M7.4a | **COMPLETE for simulation:** append-only v1.9 M7 counter bank, 23 x 64-bit counters at `0x810..0x8E4` |
| M7.4b | **COMPLETE for limited simulation:** packed-mode same-output-tile two-bank K-panel ping-pong; no generation tags/result FIFO/full stage overlap |
| M7.4c-A | **COMPLETE for compact simulation and cache-leaf OOC:** vector activation-cache delivery, legacy isolation and BRAM inference proof |
| M7.4c-B | **COMPLETE for local Gate2 simulation:** depth-2 result FIFO, absolute result address, 8-bit generation, final drain, multi-chunk bias and nonzero compute/store overlap |
| M7.4d | **PENDING:** complete tagged physical-response error/flush disposition and decide any later load/store/three-way overlap extension |
| M7.5 | **COMPLETE for the exact 50 MHz server scope:** historical S16 fails pre-place LUT and corrected-adder S8 fails `Place 30-487`; active FP16-only v1.12 passes 10/10 XSim, OOC, BD, full synthesis/place/route/timing/DRC/methodology/loops/blackboxes/post-route DSP=0 and deterministic true mode-3 E04 2/2 plus E01 2/2. The optional 75/100 MHz sweep was not run. |
| M7.6 | **PARTIAL:** the final 361-entry unsealed development manifest and strict qualification metadata pass; exact BIT/XSA are generated and hash/ZIP verified but not board-tested. Full real E05, boot, cold-board outputs/counters, repeatability and soak remain open. |

No gate may infer the next gate's result. In particular, M6 OOC 100 MHz does
not prove M7 full-device timing, and static FP16 conversion error does not
prove ViT accuracy.

## M7.1–M7.3b checkpoint evidence

### Package v3

`VERIFIED`: [`../../build/model_package/v3_blocked_b_fp16_mixed/`](../../build/model_package/v3_blocked_b_fp16_mixed/)
contains all 200 tensors. Seventy-four persistent GEMM-B tensors use packed
FP16 and 126 tensors remain bit-exact FP32. The verifier passes 1,026 checks,
200,040 converter-conformance comparisons and 2,696,640 4 KiB-contained
blocks. The model is 173,685,760 bytes; its package-manifest SHA-256 is
`74cdd537ba765e1ce9f64f3afc6a5c037dce6d67e47c6b9587e6a8acd82b3324`.
Model/table SHA-256 values are
`d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5`
and `10eaacba3be3f3ff18caa1e1612e25118a5730714fd3f7802c25849e2857ea0a`.

### Parallel leaf and bounded integration

`SIM-MEASURED`: the FP32-to-FP16 converter passes 16,402 vectors; both the
16-stream primary array and 8-stream fallback pass handshake, tail, reset and
error tests. The production dual-mode GEMM regression passes 4,505 checks.
Legacy mode 1 remains blocked-v2 FP32; mode 3 is blocked/packed-v3 FP16; the
host-visible IP version is `0x00010008` (v1.8).

`MEASURED` Vivado-2023.2 leaf OOC reports, produced before the final packed
input mux, close 50 MHz with DSP=0:

| Stream count | WNS/WHS | Total LUT | FF | CARRY8 | DSP |
|---:|---:|---:|---:|---:|---:|
| 8 | `+3.083/+0.010 ns` | 36,044 | 12,562 | 3,078 | 0 |
| 16 | `+1.663/+0.005 ns` | 63,157 | 19,285 | 5,438 | 0 |

Run evidence:
[`8-stream 50 MHz`](../reports/m7/leaf_ooc_runs/20260807T110803Z-local-m7-leaf-8x50-21905/)
and
[`16-stream 50 MHz`](../reports/m7/leaf_ooc_runs/20260807T112456Z-local-m7-leaf-16x50-32279/).

The LUT values above are the top-row `Total LUTs` from each authoritative
`post_route_utilization.rpt`. The older `SUMMARY.txt` labels 56,429/99,291
raw primitive-cell sums as `POST_ROUTE_LUT`; those are not device LUT
utilization and must not be used for headroom arithmetic. Both cases route all
routable nets without route errors, DRC/methodology findings, loops,
blackboxes or latches. Each nevertheless retains one explicit OOC partition
gap plus boundary-hold/reset exceptions. The 16-stream run also exposes
high-fanout clock-like routing and a 53-logic-level bias/result critical path.
It is not current-source or full-chip timing sign-off.

### Compact production-wrapper A/B

`SIM-MEASURED`: the exact checkpoint under
[`../evidence/m7_local_2026-08-07/m7_3b_compact/`](../evidence/m7_local_2026-08-07/m7_3b_compact/)
passes through the production AXI wrapper:

| Metric | Mode 1 blocked-v2 FP32 | Mode 3 packed-v3 FP16 |
|---|---:|---:|
| Checks / commands | 2,001 / 249 | 2,001 / 249 |
| Total / job cycles | 907,897 / 900,581 | 501,201 / 493,885 |
| External / MODEL reads | 38,251 / 22,455 | 28,843 / 13,047 |
| AXI AR / R beats | 20,611 / 24,139 | 20,023 / 21,787 |
| AXI stalls | 3,810 | 2,717 |
| Result | class 3, `0x40e00000` | class 3, `0x40e00000` |

`DERIVED`: mode 3 reduces compact job cycles by 45.1593% (`1.82346x`),
external reads by 24.5954%, MODEL reads by 41.8971% and AXI stalls by
28.6877%. This zero-activation compact fixture verifies routing, half ordering,
traffic and counters. It does not prove real-image/full-model accuracy or
physical speed.

The checkpoint binds 78 ordered production sources with SHA-256
`7ae81491d0ab5c0207641bc11ebaccc62831b7ada842372000cd786b20c1b15a`;
the ordered filelist SHA-256 is
`e1bf389d2cb6cbaefe8c5ca228bb2bbd17b8c7225027d4fa795209eaa50bca04`.
These are checkpoint identities, not a sealed final M7 manifest. The source
field in `BUNDLE_INFO.json` intentionally remains `PENDING_M7_SEAL`.

## M7.4a–M7.4c-A local checkpoint evidence

`SIM-MEASURED`: the append-only v1.9 bank publishes 23 atomic 64-bit counters
at `0x810..0x8E4`; its focused regression passes 246 checks. The packed-only
two-bank operand scheduler passes 23,841 checks with K-distinct payloads,
tails, backpressure, reset/error and two-panel look-ahead. This is same-output-
tile K-panel ownership only: it has no generation field and no production
result FIFO. The current compact run measures all four exact overlap counters
(load/compute, compute/store, load/store and three-way) as zero and maximum
published panel occupancy as one; the focused scheduler test alone reaches a
two-panel look-ahead state.
The exact machine-readable current ABI is
[`PERF_PROFILE_ABI_V1_9.json`](PERF_PROFILE_ABI_V1_9.json), SHA-256
`449170fad38ae14f870f666087a9218b280b76546c70a4809ab4a594ee5af9a3`.

The vector-cache frontend reuses all eight existing row-bank BRAM read ports,
delivers one K lane across eight rows per cycle on a legal packed mode-3 cache
hit, and preserves scalar delivery for modes 0/1/5 and cache misses. Focused
memory/cache tests pass 6/6 plus 514 cache checks. Error recovery blocks a new
START after an NPU error until software issues SOFT_RESET; this prevents a new
job from consuming adapter-local stale state, but it is not proof that an
arbitrary already-issued physical SmartConnect/slave response is cancelled.

The exact current compact checkpoint is
[`../reports/m7/checkpoints/20260807T145736Z-m7_4c_vector_cache_local/`](../reports/m7/checkpoints/20260807T145736Z-m7_4c_vector_cache_local/).
It binds 79 ordered production sources with SHA-256
`0ed13bcee395fb6c9f5d7b1fa2358949247be295dd8466d477d9f34d751d7a89`;
the filelist SHA-256 is
`8949f9643316157d0435378e9860c08a415795136309e7ef38e838a00449824e`.
The checkpoint manifest SHA-256 is
`0f4bc162a47eab312a5d35f5365d4cc5c1ba5f8ee28a6bffee439d190b6c5957`.

| Metric | Mode 1 blocked-v2 FP32 | Mode 3 packed-v3 FP16 |
|---|---:|---:|
| Checks / commands | 2,086 / 249 | 2,074 / 249 |
| Total / job cycles | 908,113 / 900,581 | 421,257 / 413,725 |
| External / MODEL reads | 38,251 / 22,455 | 28,843 / 13,047 |
| AXI stalls | 3,810 | 2,928 |
| Result | class 3, `0x40e00000` | class 3, `0x40e00000` |

`DERIVED`, compact only: current mode 3 is `2.176762x` mode 1 and reduces job
cycles by 54.060212%. It saves 80,160 cycles (16.230499%) against the sealed
493,885-cycle M7.3b checkpoint. The fixture uses zero activations and does not
establish real-image accuracy or full-model/board speed.

`VERIFIED` Vivado-2023.2 tool reports for the standalone R8 x 3072 activation
cache show why the RTL read-template correction is material. The first A/B
attempt inferred 0 RAMB36 and 3,840 RAM64M8 primitives. With scalar/vector
addresses pre-muxed into one memory-read expression per bank, the corrected
post-route DCP has 32 RAMB36, 0 LUTRAM/RAMB18/URAM/DSP, 124 LUT, WNS
`+11.494 ns` at 50 MHz, 503/503 routable nets and zero route, DRC,
methodology, loop, blackbox or latch errors. The corrected postcheck manifest
SHA-256 is
`cacd2110f2f24b87899c53d2f8bab4b664b36481cd416c6779ba1054666f039e`.

This is cache-leaf OOC only. WHS is `N/A` after boundary-hold false paths;
there is one explicit OOC partition gap and unplaced boundary pins. It is not
current-source full-NPU/full-device timing closure.

The isolated 692-bit, depth-2 result-FIFO leaf passes 28,592 checks, including
full simultaneous enqueue/dequeue and held-head backpressure. It is ready for
M7.4c-B integration but is not in this checkpoint's 79-source production
filelist and does not justify setting the FIFO/generation capability bits.

The preceding paragraph is the preserved M7.4c-A state. It is superseded as
the current development state by the Gate2 event below; its checkpoint hashes
remain historical identities.

## M7.4c-B Gate2 local evidence — 2026-08-08

`VERIFIED`: all eight production address/generation/FIFO-profile ports that
were missing at Gate-1 are connected. Packed mode 3 carries a 66-bit absolute
destination and 8-bit command-generation value from the scheduler through
`engine_top` into the memory frontend. The frontend snapshots FIFO-head
destination/generation/token/output/batch metadata and uses that snapshot for
the complete write; it does not derive the store address from a later live
load context. Stale metadata fails closed. Modes 0/1/5 remain on their legacy
non-FIFO path.

The replayable checkpoint is
[`20260808T003404Z-m7_4c_b_gate2_local`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/).
It contains 80/80 unique production sources. Filelist SHA-256 is
`88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`;
ordered source-stream SHA-256 is
`91a2019ccfc60ed7bb3035965beec0df2cda6a026e48b129ca0393241fa45f75`.
Its status is `DEVELOPMENT_UNSEALED_LOCAL_SIM_PASS`, not a final source seal.

`SIM-MEASURED` focused Gate2 results are:

| Gate | Result |
|---|---:|
| 692-bit FIFO leaf | 28,592 checks; depth 2; 1,070 full simultaneous pop/push exchanges |
| Packed scheduler | 42,622 checks; 4 enqueue/4 dequeue, max occupancy 2, two full-stall cycles, final depth-2 drain PASS |
| Production dual-mode seam | 13,822 checks; 4 results/enqueue/dequeue, max occupancy 2; address/generation/order/data/mask and legacy isolation PASS |
| Production compile | Icarus exit 0; Verilator `%Error=0`; missing production pins = 0 |

The scheduler regression also covers reset while occupancy is two followed by
a fresh command, and error drain while an older valid result is queued.
Non-final tiles may advance after enqueue; final command completion waits for
the FIFO to drain. These tests prove logical ownership/drain behavior, not
cancellation of arbitrary physical responses already issued to SmartConnect
or DDR.

`SIM-MEASURED`: the earlier final-K16 bias snapshot bug is corrected by
refreshing the bias at the accepted final K16 chunk. Directed packed-mode 3/5
tests with nonzero bias at `K=17/32/33/3072` pass with exact expected outputs.
This closes the focused reproduction but is not real E01/E04 or full-model
accuracy evidence.

Current compact production-wrapper A/B is:

| Metric | Mode 1 blocked-v2 FP32 | Mode 3 packed-v3 FP16 Gate2 |
|---|---:|---:|
| Checks / commands | 2,086 / 249 | 2,077 / 249 |
| Total / job cycles | 908,113 / 900,581 | 399,161 / 391,629 |
| External / MODEL reads | 38,251 / 22,455 | 28,843 / 13,047 |
| Writes / AXI stalls | 10,646 / 3,810 | 10,646 / 2,757 |
| Result | class 3, `0x40e00000` | class 3, `0x40e00000` |

Mode 3 publishes the following exact M7 counters:

```text
accepted terms / disabled tail = 187392 / 128016
dots / results                 = 732 / 732
feeder stall / result BP       = 130873 / 90034
load / compute / store         = 131461 / 28548 / 42598
stage union                    = 175667
load-compute / compute-store   = 0 / 20016
load-store / three-way         = 6924 / 0
commits / claims / releases    = 588 / 588 / 588
empty-wait / full-wait         = 94261 / 0
FIFO enqueue / dequeue / max   = 588 / 588 / 2
```

The frontend observes that a FIFO result becomes visible one cycle before the
next look-ahead load request. It therefore defers that newly visible result
for exactly one cycle, then alternates one look-ahead load and one queued store
when both remain pending. The diagnostic counts are 54,210 conflicts, 514
idle-conflicts, 20,016 queued-compute cycles and 514 queued deliveries. This
is the mechanism behind the nonzero compute/store count; it is not a claim of
three independent physical AXI channels.

`DERIVED`, compact only: mode 3 is `2.299576895x` mode 1 and reduces job
cycles by 56.513739464%. It saves 22,096 cycles (5.340745664%) relative to the
M7.4c-A mode-3 checkpoint. The fixture uses zero activations, so it proves
control/traffic/counters but not real-image numerical accuracy or board
latency.

Primary local logs and their SHA-256 values are:

| Evidence | SHA-256 |
|---|---|
| [`compact mode 1`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/compact_e05_mode1.log) | `3277c5158f959e7c55f528cff9e6a8607a965c9e8d4acc2fe22132ae8ffe0dea` |
| [`compact mode 3`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/compact_e05_mode3.log) | `c5b16b662eda58889545448695d5fcc145d2eaf3a3b9ddfc986dfefb58b86caa` |
| [`FIFO`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/result_fifo_simulation.log) | `87a2c7c85906b7f9bd3ef84f5c440b77f45019c13e48a3e3ca851c73ce9f7401` |
| [`scheduler`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/scheduler_simulation.log) | `a1c8518e09b7e5e6ca218df285b5dce1848c796cad5c88afbd1c23a5d1782d76` |
| [`dual mode`](../reports/m7/checkpoints/20260808T003404Z-m7_4c_b_gate2_local/dual_mode_simulation.log) | `0a3a6c791965b40a415515f3d085b3ceb0639e4f75e63e9d174ebf260f6105f5` |

Source-level anchors at this local result are scheduler
`3809aecd3c3b4660cf3be1dfb21953f6b178e844c48f70dd28e27a615dc96ec4`,
memory frontend
`60a190e079a675dfa2490e39445d2b741c86dd068cb526a027166de2646aa1ea`,
stream array
`af2ecd2dfc84a702b4b97389e6fbdae25ba564ee77000a39cd3e5cd922aa0985`
and ABI v1.10
`c46f9831c7c5d75dc8c3a692dcb98a25247da0e1018426623c0d450e4d35f570`.
These are quiescent local anchors, not a sealed ordered-source manifest.

At this historical Gate2 checkpoint, the remaining gates were current-source
XSim/Vivado 2023.2, real E01/E04 and full-model numerical A/B, 50 MHz
OOC/full-device route/timing/DRC/loop/blackbox/post-route DSP=0, final source
seal, BIT/XSA/boot identity and cold physical E05. The exact v1.12 revision
later closed the server Vivado, E04 and E01 parts as recorded below. Full real
E05, final sealing and physical execution remain open; no historical Gate2
result is retroactively promoted.

## Controlled S8 fallback local evidence — 2026-08-08

The preceding Gate2 section is preserved as the historical S16 checkpoint.
The pre-specialization S8 child changed compile-time `FP16_STREAMS` to eight throughout the
production hierarchy and reports geometry `0x08100208`. Modes 3 and 5 execute
column 0 then valid column 1 as two ordered `R8xC1` physical passes under one
logical `R8xC2` identity. The second pass rewinds K plus A/B address context;
partial FIFO entries use masks `01` and `10`. Odd N retires only column 0.
At this historical point modes 0/1 still used the duplicate legacy FP32
schedule; the v1.12 specialization below supersedes that one statement.

`SIM-MEASURED` focused closure:

| Gate | Result |
|---|---:|
| Packed scheduler | 66,146 checks; 7 enqueue/dequeue; max FIFO 2; 4 full pop/push exchanges; 3 final depth-two drains |
| Production dual-mode seam | 21,199 checks; both columns, odd N, reset/error/FIFO metadata and modes 0/1 equivalence PASS |
| Address/cache seams | 6/6; packed-v3, blocked-v2 and row-major scratch-B K64/K197 rewind; same-tag A-cache replay PASS |
| Counter/control | 246/490 checks; geometry `0x08100208`; IP `0x0001000B` |

Bias is checked independently in modes 3 and 5 at `K=17/32/33/3072`.
Random response/result backpressure, reset at FIFO depth two and ordered drain
of older valid entries before a poisoned result pass. The directed scheduler
test reaches non-vacuous final occupancy two; this preserves rather than
weakens the inherited Gate2 ownership proof.

`SIM-MEASURED`: the production-wrapper compact mode-3 S8 replay passes 2,081
checks and 249 commands:

```text
total / job cycles              = 495849 / 488317
external reads / writes         = 39185 / 10646
logical reads / core-cache hits = 95449 / 55080
AR / R beats                    = 22670 / 25973
full / narrow R beats           = 4404 / 21569
linefill starts / hits          = 1101 / 17699
accepted / disabled terms       = 184192 / 124816
dots / results                  = 1439 / 1439
panel commits/claims/releases   = 1175 / 1175 / 1175
FIFO enqueue/dequeue/max        = 1175 / 1175 / 2
load / compute / store cycles   = 208809 / 44609 / 55675
compute-store overlap           = 34047
valid / tail MAC slots          = 59376 / 124816
class / logit                   = 3 / 0x40e00000
```

The first observation exposed four stale S16 testbench identities while the
runtime counters above were internally consistent. Those old assertions were
replaced by S8 physical-pass capacity and exact first-observation traffic
oracles; a second independent replay passed. In particular, 39,185 reads
supersede the inherited 28,843-read S16 compact estimate. This local
zero-activation fixture does not prove full-model accuracy, resource fit,
timing, DSP=0 post-route or physical-board latency.

The second replay's raw stdout and provenance note are preserved under
[`s8_fallback_local_20260808`](../reports/m7/s8_fallback_local_20260808/),
with raw-log SHA-256
`99f47f65317e2c14d4703e6259e6e93ee78a7071a7435b6245f0274f6745074b`.

The pre-specialization ordered 80-source production SHA-256 is
`9b4a0e9bdc3f555741096533e5f2e7047cb923e666a49f58999f4f7a1b09df19`;
filelist SHA-256 is
`88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
That historical source remained `DEVELOPMENT_UNSEALED`.

`DERIVED`, exact static full-model schedule only: each S8 physical pass consumes
eight A values and one selected B value per accepted K cycle. The frontend has
no B cache, so column 1 rereads the same packed word/block after rewind rather
than receiving both columns from one physical compute cycle. The exact static
schedule predicts 139,512,000 physical K16 passes, 17,857,536,000 MAC slots,
17,563,828,224 valid and 293,707,776 tail slots, with 2,232,192,000 ideal feed
cycles. Its traffic model is 2,138,880,000 packed-B words, 181,324,800 dynamic
row-major-B words, 89,306,840 other/A/bias words, 2,409,511,640 total reads,
805,351,640 R beats and 404,311,640 AR transactions. Total reads, R beats and
AR are each 90,547,200 above the corresponding M5 model. These are not
simulation, Vivado or physical-board measurements. The calculation is
reproducible with
[`m7_cycle_bandwidth_model.py`](../tools/m7/m7_cycle_bandwidth_model.py), whose
default is the current S8 child; the historical S16 schedule requires the
explicit option `--fp16-streams 16`.

## Corrected-adder Vivado evidence and exact placement failure — 2026-08-08

The mapped-loop failure in the original S8 bias adder was corrected with a
strictly feed-forward implementation. `VERIFIED`: it contains 53 continuous
assignments, no procedural block and no procedural loop; RTL SHA-256 is
`3721a6d130e655c524c642513bf5920d32c0a75a3abb88e0378ed7b5c2352141`.
`SIM-MEASURED`: direct adder A/B, FP32 leaf and special-value tests pass
8,245/62,002/12,031 checks, and the S8 FIFO/scheduler/dual-mode gates remain
28,592/66,146/21,199 PASS. Evidence:
[`20260808T025450Z-m7s8_fp32_adder_feedforward_local`](../reports/m7/checkpoints/20260808T025450Z-m7s8_fp32_adder_feedforward_local/),
checksum-manifest SHA-256
`dd77b69a59c7e042a29419fe5556ece59c3feccd4f20a52b9cd4b9839a1552eb`.

`MEASURED`, isolated leaf scope: server Vivado-2023.2 run
[`20260808T070827Z-server-m7s8-adderff-8x50`](../reports/m7/leaf_ooc_runs/20260808T070827Z-server-m7s8-adderff-8x50/)
passes at 50 MHz with post-route WNS/WHS `+5.138/+0.012 ns`, zero
loop/blackbox/DSP and 30,868/30,868 routed nets. Authoritative top Total LUT
is 35,752 post-synth and 35,517 post-route, FF is 12,562; 55,923/55,904 are
raw primitive counts from the gate script. Receipt SHA-256 is
`8629952427b3d82b1637f913c077be1df0d47dc2d682856986581bedda79cc8e`.
One explicit OOC gap and boundary exceptions remain; this is not full-device
sign-off.

The exact pre-v1.12 full-flow source identity is
`7d89768f2b8820bbf3aa13a628a05696b460d2d8f758313e83d104d54b2e5cf5`.
`SIM-MEASURED`: all nine server XSim cases pass, including compact mode 1 at
2,086 checks/900,581 job cycles and mode 3 at 2,081 checks/488,317 job cycles.
The compact fixture remains zero-activation evidence only.

`MEASURED`: OOC, BD and full-board synthesis pass with zero
loop/blackbox/DSP. OOC adjusted use is 109,292/117,120 CLB LUT. Board synthesis
reports 111,747 CLB LUT, 72,681 FF, 5,640 CARRY8, 37 RAMB36 and zero URAM/DSP;
its `+5.146 ns` is only a post-synthesis setup proxy. `init_design` and
`opt_design` complete, then detail placement fails:

```text
failure codes             Place 30-487, Place 30-99
device CLBs total         14640
CLBs available to place    8797
CLBs required              9172
CLB deficit                 375
control sets                806
LUTs combined            127937
LUTs total               144009
FFs                       72337
```

The synthesis gate's apparent 5,373-CLB-LUT headroom is therefore superseded
for the fit decision by the placer result. Placement did not complete. Route,
post-route timing/hold/DRC/methodology/loop/DSP, BIT, XSA and board execution
were not run.

The immutable receipt is
[`20260808T082621Z-m7s8_place_30_487_failure`](../reports/m7/server_runs/20260808T082621Z-m7s8_place_30_487_failure/).
Its receipt-manifest SHA-256 is
`e6455349faaf59927c771c664d82ea2b7c1df31c819162a01f69be69bad06a0e`;
the `RECEIPT_MANIFEST.sha256` pointer file itself hashes to
`485b8ca42459a5fbcde60b9c0c9a1deced541d8bba9d01280bf640bca8ccd788`.

## FP16-only production specialization — 2026-08-08

The failed board-synthesis hierarchy measured the duplicate legacy
`u_legacy` FP32 GEMM at 6,910 LUT and 8,183 FF. The accepted working decision
is to compile that hierarchy out of M7-S8 and retain promoted M5 as the
separate immutable FP32 fallback. These are exact old-hierarchy counts, not a
guarantee that a new optimized top will shrink by precisely the same amounts.

`VERIFIED`: IP v1.12 (`0x0001000C`) has no legacy GEMM in the production
`engine_top` instantiation. It admits exact execution modes 3 and 5 only:

| Mode | Storage/package | Compute | START disposition |
|---:|---|---|---|
| 3 | package-v3 packed FP16 persistent B | S8 FP16 | legal; packed MODEL base must be 128-byte aligned |
| 5 | package-v2 blocked FP32 persistent B | convert at seam, then S8 FP16 | legal compatibility/A-B path |
| 0, 1, all others | historical/reserved encodings | legacy FP32 GEMM absent | reject clean-idle START with `0x80000003`, no job/profile epoch/DDR request |

The append-only map is
[`PERF_PROFILE_ABI_V1_12.json`](PERF_PROFILE_ABI_V1_12.json), SHA-256
`25f1bb5359dba4169f77c0d37f5c141d45a672a909913c8855ffa35260b2ef35`.
The active ordered 80-source SHA-256 is
`1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888`;
filelist SHA-256 remains
`88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.

`SIM-MEASURED` current-source local gates:

| Gate | Result |
|---|---:|
| FP16-only GEMM | 66 checks; modes 3/5 produce ordered two-pass S8 outputs; non-FP16 starts launch no traffic/result |
| AXI wrapper | 178 checks; exact mode 3/5 snapshots and representative illegal-mode rejection PASS |
| Compact mode 0 / mode 1 rejection | 36 / 36 checks; error/info `0x80000003/0x00000000` and `0x80000003/0x00000001` |
| FIFO / scheduler / dual mode / counter | 28,592 / 66,146 / 21,199 / 246 checks PASS |
| Production compile/lint | Icarus exit 0; Verilator has no `%Error` |
| Final compact mode 3 | 2,081 checks; 495,849 total / 488,317 job cycles; 249 commands; class/logit `3/0x40e00000` |

The final mode-3 replay reproduces the pre-specialization S8 traffic/counter
values exactly. It is still a zero-activation compact fixture. The following
section supersedes the old pending statement for current-source Vivado and
true mode-3 E04/E01. It does not supersede the pending full real E05, final
seal or physical-board boundaries.

## Final v1.12 server closure and real-data evidence — 2026-08-08

Every result in this section uses the same 80-source ordered production
identity
`1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888`
and filelist SHA-256
`88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
Evidence classes and workload boundaries remain explicit.

### Full Vivado-2023.2 gate

The immutable
[`v1.12 full-Vivado PASS receipt`](../reports/m7/server_runs/20260808T101823Z-m7s8_fp16only_v112_full_vivado_pass/),
receipt-manifest SHA-256
`791c31e52c60e8e6af4bcf6c29f55cea6f79553bb89024705b5cc061df305a8d`,
records `SIM-MEASURED` PASS for 10/10 XSim cases. `MEASURED` authoritative
Vivado reports pass OOC, block-design, full synthesis, placement, route,
timing, DRC/methodology, loop, black-box, no-clock, unconstrained-endpoint and
post-route `DSP48/DSP58=0` gates at 50 MHz. All 137,878 routable nets route
with zero route error. Post-route WNS/WHS is `+1.273/+0.010 ns`.

Post-route use is 101,519 CLB LUT, 64,196 registers, 5,492 CARRY8, 37
RAMB36, zero URAM and zero DSP. The placer occupies 14,594/14,640 physical
CLBs, or 99.69%, leaving only 46 CLBs. This is exact-revision closure and a
strong congestion/headroom warning: any reachable RTL change requires a new
complete implementation and cannot inherit this timing result.

BIT SHA-256 is
`09339351720f7aa776755234438cc61a25744dcd69de7f52f7aef625049ee8f3`;
XSA SHA-256 is
`7e3726ab94d7c4937bb788f193319b62f1feadf69cb25c2c4446e301585e52d8`.
The XSA ZIP is valid and its embedded BIT is byte-identical to the external
BIT. These are `VERIFIED` generated artifacts, not board measurements.

### True mode-3 real E04 deterministic pair

`SIM-MEASURED`: canonical and independent-repeat receipts are
[`20260808T112044Z-m7s8_mode3_e04_real_pass`](../reports/m7/server_runs/20260808T112044Z-m7s8_mode3_e04_real_pass/)
and
[`20260808T113352Z-m7s8_mode3_e04_real_repeat_pass`](../reports/m7/server_runs/20260808T113352Z-m7s8_mode3_e04_real_repeat_pass/),
with receipt-manifest SHA-256 values
`2859cb707350057026702f48d3cbabe72e2a8c8575e77d9bef6a43d9811ffa5e`
and
`c23876063b85fed2f014caa3c6a4d1e6dbfda5021bd7bf95597a8cdb2cc5b61f`.
Both pass 202 structural checks, 14,327,394 reported cycles and five commands.
Traffic is identical:

```text
logical reads / cache hits            = 2299248 / 767234
external u32 / MODEL / SCRATCH reads  = 1532014 / 1072590 / 459424
AR / R beats                           = 812014 / 956014
full / narrow R beats                  = 192000 / 764014
linefills / line hits                  = 48000 / 720000
writes                                 = 154064
```

Each run emits 151,296 final-LayerNorm words, 1,000 logits, 1,000
probabilities and a two-word class result. All relevant top-1 paths select
class 879. Behavioral comparison has zero tolerance failures at `1e-4`
(final LayerNorm), `1e-3` (logits) and `1e-5` (probabilities). The independent
M6 classifier oracle matches all 1,000 logits exactly. Four output files and
both reports are byte-identical across the two runs. This closes E04
simulation repeatability only, not complete E05 or physical repeatability.

### True mode-3 real E01 deterministic pair

The first two E01 attempts are preserved immutable failure evidence:

- [`traffic-oracle failure`](../reports/m7/server_runs/20260808T120951Z-m7s8_mode3_e01_real_traffic_oracle_failure/),
  receipt-manifest
  `7426c5090ca0b2ec4156399e848f110d19f1a0e59df1d12c48642d98e2313e9e`:
  its old traffic oracle omitted 766 legitimate second-pass bias refetches;
- [`M7-status-oracle failure`](../reports/m7/server_runs/20260808T123843Z-m7s8_mode3_e01_oraclefix_m7_status_failure/),
  receipt-manifest
  `9d54ff2b30b7b247d258b90dc81f0e703607aa24de266b256d7ca190201dd573`:
  its stale test asserted the whole status word rather than checking defined
  status fields and counter relationships.

These were test-only oracle defects. Neither changed any of the 80 production
sources, and neither reached the numerical oracles.

`SIM-MEASURED`: canonical and independent-repeat PASS receipts are
[`20260808T130525Z-m7s8_mode3_e01_real_pass`](../reports/m7/server_runs/20260808T130525Z-m7s8_mode3_e01_real_pass/)
and
[`20260808T132251Z-m7s8_mode3_e01_real_repeat_pass`](../reports/m7/server_runs/20260808T132251Z-m7s8_mode3_e01_real_repeat_pass/),
with receipt-manifest SHA-256 values
`280650dafbb5c4c7fae944a3daa59ae6437abbe27df4e290ed9cca4e1e11d235`
and
`3b4d67f6fa884a5df73a076da46d29009da1600151ba60ef6d4cc55499fe6aa7`.
Both pass 266 structural checks, 83,387,859 reported cycles and four commands.
Their exact AXI/DDR-model traffic is:

```text
external reads / writes                = 15351550 / 453120
MODEL / INPUT / SCRATCH reads          = 14899198 / 150528 / 301824
AR transactions / R beats              = 1527550 / 4292350
full / narrow R beats                   = 3686400 / 605950
linefills / line hits                   = 921600 / 13824000
maximum read outstanding / invalid     = 1 / 0
bias lookups / hits / misses            = 38400 / 36866 / 1534
valid second-pass bias refetches        = 766
```

Terminal status is `0x00071BF2`: running, overflow and error are zero;
snapshot-valid, load/compute, compute/store, three-way and both-bank evidence
are asserted; claim mask is 3, maximum claimed banks is 2 and maximum FIFO
occupancy is 1. The field-aware status oracle ties these bits to the exact
counters:

```text
accepted / disabled / enabled terms    = 117964800 / 2359296 / 115605504
dots / results                         = 19200 / 19200
panel commits / claims / releases      = 921600 / 921600 / 921600
FIFO enqueue / dequeue / max           = 19200 / 19200 / 1
load / compute / store cycles          = 75268889 / 15033600 / 1380096
stage-union cycles                      = 75864134
load-compute / compute-store overlap   = 14438400 / 307184
load-store / three-way overlap         = 1380051 / 307184
```

Each E01 run emits 151,296 finite embedding words, no sentinel and no
alternate-hidden-buffer modification. The M6/current-adder arithmetic oracle
matches all 151,296 words exactly. The independent FP32 behavioral oracle has
zero failures at absolute tolerance `0.005`, maximum absolute error
`0.003846675157546997` and mean absolute error
`0.0002339259977672367`. Embedding and both report files are byte-identical
between canonical and repeat.

`DERIVED` from matching `SIM-MEASURED` E01 scopes: M7 takes 83,387,859 cycles
versus M5's 424,112,402, saving 340,724,543 cycles. This is
`5.086020999772x` and an `80.338264430192%` cycle reduction. M7 reads 766 more
external u32 words than M5 (15,351,550 versus 15,350,784), a
`0.004989973151%` increase caused by the valid physical two-pass bias-cache
fill/refetch schedule. The speedup and read delta are E01 server-simulation
comparisons, not full-E05 or board measurements.

### Remaining qualification boundary

The exact Vivado, E04 and E01 evidence does not establish full-model E05
accuracy or physical speed. `DEVELOPMENT_UNSEALED` and
`source_design_sha256=PENDING_M7_SEAL` remain mandatory. The final 361-entry
development manifest and strict metadata verifier pass, while the immutable
352-entry manifest remains the exact input identity of the completed Vivado
run. Still pending are full real E05, final source seal/promotion, exact
BIT/XSA board programming, physical outputs/counters/latency, multi-image
repeatability and soak.

## Resource and performance guardrails

The pre-final-mux M7.2 16-stream leaf uses 63,157 LUT while promoted M5 uses
42,125 LUT post-route. Their naive sum is 105,282 LUT (about 89.9% of the
117,120 device LUTs), before new feeder/control logic and before subtracting
the replaced serial GEMM. This arithmetic is a congestion warning, not an
integrated utilization result. The exact S16 full design subsequently failed
pre-place LUT capacity. The corrected-adder S8 full design passed synthesis
but failed CLB packing at placement, proving that adjusted-LUT headroom alone
is also insufficient. The exact FP16-only v1.12 source subsequently passed
full placement/route, but at 14,594/14,640 CLBs (99.69%, only 46 free). That
PASS does not provide reusable headroom: any reachable source change must
rerun the full implementation rather than subtracting the old
6,910-LUT/8,183-FF hierarchy on paper.

The historical S16 feeder target was the unique operand set for an R8/C2
Cartesian product: 8 A plus 2 B values per accepted K cycle. The current S8
child consumes 8 A plus one selected B value per physical pass; it retains A
reuse but has no B cache, so the packed B word is reread on column 1.
Starvation and overlap counters decide whether the physical streams are
actually utilized.

M5 measured `Tother=3,433,853,338` cycles (`68.677067 s` at nominal 50 MHz).
Therefore GEMM acceleration alone cannot establish the under-60-second goal at
50 MHz. M7 E01 simulation now measures nonzero overlap and a same-scope
`5.086020999772x` improvement, but E01 is not complete E05 and cannot be
converted into board latency. Full real E05 and exact-artifact board counters
must decide the under-60-second result; M8 and/or a higher closed clock may
still be required.
