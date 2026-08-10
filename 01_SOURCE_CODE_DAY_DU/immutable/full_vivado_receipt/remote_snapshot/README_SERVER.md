# ViT NPU M8 non-GEMM/no-DSP development bundle

Date: 2026-08-09  
Vivado: 2023.2  
Target: Digilent Genesys ZU-5EV, `xczu5ev-sfvc784-1-e`  
Production PL clock: 50 MHz (`20.000 ns`)  
Status: `DEVELOPMENT_UNSEALED` / `PENDING_M8_SEAL`

This directory is the isolated IP-v1.13 M8 child. It accelerates reachable
Vector, GELU, LayerNorm and Softmax behavior while preserving the M7-S8
FP16-only GEMM schedule, AXI ABI, register map, counters, numerical contract
and hard `DSP48/DSP58=0` policy.

M8 has passed the available simulation and standalone LayerNorm/Softmax leaf
OOC gates. Full-device synthesis, placement, route, full-design WNS/WHS,
post-route DSP/RAM closure, M8 BIT/XSA, complete real E05 and physical-board
execution have not run. A 50 MHz target is therefore not yet an M8 timing
measurement.

## Exact production identity

- Filelist: `filelists/full_axi.f`, 80/80 ordered unique sources.
- Filelist SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- Ordered sha256sum-record stream SHA-256:
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- Host-visible IP version: `0x0001000D`.
- ABI document: `docs/PERF_PROFILE_ABI_V1_13.json`.
- Production geometry: logical `R8xC2`, physical FP16 `R8xC1`, eight
  streams, two ordered output-column passes.
- Clean-idle START modes: exact 3 and 5 only; all other values fail closed
  with `0x80000003` before a job, profile epoch or DDR request starts.

Exactly six reachable production files differ from the direct M7-S8 parent:

| File | M8 SHA-256 |
|---|---|
| `rtl/blocks/vector/vit_vector_engine_fp32.sv` | `c71542773318964a538384d81bf9b842361678e81132986d5a31ad0b1ec96df2` |
| `rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv` | `f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f` |
| `rtl/blocks/softmax/vit_softmax_engine_fp32.sv` | `9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9` |
| `rtl/core/vit_phase_e_read_address_router.sv` | `4dcd75977601711b9324e431f7582b9791b69dd17720f4fd5e7184df8bb12219` |
| `rtl/core/vit_phase_e_engine_top.sv` | `0056ebc96dfd23a0de2fd2ad25d3acd53ad2985ee69bebdab5253946609fe512` |
| `rtl/axi/control/vit_axi_lite_control_regs.sv` | `00eceb2222ea89eb1d4d0149baf4185047be8c72047a0958e0a18dbdc54426b6` |

The production engine explicitly binds the LayerNorm row/affine buffer and
Softmax row/exp buffer to enable=1 and depth=1,024 words. Oversize work keeps
the parent external-memory schedule. The full-device RAM gate is exact:

| Hierarchy | Required RAMB36 |
|---|---:|
| GEMM activation cache | 32 |
| GEMM bias cache | 4 |
| LayerNorm row/affine buffers | 3 |
| Softmax row/exp buffer | 1 |
| Layer parameter table | 1 |
| Total | 41 |

RAMB18 and URAM must be zero. The new LayerNorm and Softmax buffers must use
zero LUTRAM. Inherited distributed RAM elsewhere in the design is reported
but is not falsely required to be globally zero.

## Direct-parent boundary

`PARENT_M7S8_PROVENANCE.txt` binds the exact direct parent:

- bundle `vivado_server_307_perf_v1_m7s8_fp16_parallel_overlap_2023_2`;
- 361-entry parent development manifest SHA-256
  `0fd289058fbcfb2eff5a63664d14232f39b2b9e30e3023c890e8f6ddc901f838`;
- parent ordered source SHA-256
  `1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888`;
- parent final non-board checkpoint `SHA256SUMS.txt` SHA-256
  `bf29ff0b8d9d73be9a7528d7bd7f2151bd91746c3ae227210fb9eea6a7ec86ee`.

The inherited M7 qualification objects in `BUNDLE_INFO.json` are immutable
history. M7 full-Vivado reports, BIT, XSA and any board evidence are parent
artifacts only and never satisfy an M8 gate.

## Current M8 evidence

The scoped checkpoint is
`reports/m8/checkpoints/20260808T182708Z-m8_simulation_qualification`.
Its receipt anchors the exact production identity and these independently
sealed receipts:

- Softmax standalone leaf OOC: WNS/WHS `+4.472/+0.033 ns`, one RAMB36,
  DSP=0.
- LayerNorm standalone leaf OOC: WNS/WHS `+10.964/+0.019 ns`, three
  RAMB36, DSP=0.
- Exact XSim suite: 10/10 PASS twice with byte-identical signatures.
- Real E04 mode 3: two terminal PASS runs, 6/6 byte-identical authoritative
  artifacts, 9,010,605 cycles, 927,134 external words, class/logit
  `879/0x414886A0`.
- Real E01 mode 3: three terminal PASS runs, 3/3 byte-identical authoritative
  artifacts, 82,215,315 cycles, 15,351,550 external reads and all 151,296
  embedding words exact against the M6/current-adder oracle.
- Compact mode 3: 2,081 checks, 444,212 total / 436,680 job cycles,
  35,139 reads, 10,646 writes, 2,886 AXI stalls and class/logit
  `3/0x40E00000`.

These are `SIM-MEASURED` fixture/phase results and standalone-leaf OOC tool
results as scoped. They are not complete-E05 or board speed measurements.

## Development manifest rule

`M8_DEVELOPMENT_SHA256SUMS.txt` is the final fail-closed input manifest for
the full flow. It covers root metadata plus `docs`, `filelists`, `rtl`, `run`,
`scripts`, `sim`, `third_party` and `tools`; independently sealed large
receipt payloads under `reports` are bound by their receipt-manifest anchors
instead of being copied into the development closure. Metadata-only preflight
checks each manifest hash, safe/no-symlink path set, exact declared/current
directory closure, expected entry count and documented sidecar. Strict/full
preflight additionally replays all 658 payload SHA-256 records across the six
bound M8 receipt/checkpoint directories.

Do not generate the final manifest while any harness, metadata or flow file is
still changing. After every writer is quiescent:

```bash
python3 tools/m8/m8_development_manifest.py generate
run/00_verify_m8_development.sh
```

Any later edit intentionally breaks the verifier and requires one new final
manifest generation before a Vivado run.

## Full Vivado gate sequence

The default runner is sequential and cleans generated outputs before use.
M8 sign-off hard-requires `VIT_REUSE_PROJECT=0`; any reuse request is rejected,
and the old Vivado project plus `.Xil` state are removed before project creation.

```bash
source /tools/Xilinx/Vivado/2023.2/settings64.sh
export VIT_VIVADO_THREADS=2
export VIT_VIVADO_JOBS=4
export VIT_XSIM_THREADS=2
export VIT_REUSE_PROJECT=0
export VIT_VIVADO_TIMEOUT_SECONDS=86400
export VIT_XSIM_TIMEOUT_SECONDS=14400
run/run_all.sh
```

The executable path may instead be supplied through `VIVADO_BIN`. The full
run requires all stages; `VIT_RUN_XSIM`, `VIT_RUN_OOC_SYNTH` and
`VIT_RUN_IMPLEMENTATION` default to 1. Any skipped stage produces only a
partial receipt.

`VIT_XSIM_THREADS` defaults to `2`. Its only legal values are `auto`, `off`,
or a canonical integer greater than or equal to 2; `1` is rejected explicitly
before `xelab` starts.

Strict M8 metadata, receipt and development-manifest verification always uses
the fixed `/usr/bin/python3` entry. Its resolved target must be a nonsymlink
regular executable named `/usr/bin/python3.N`; `VIT_SYSTEM_PYTHON` overrides
are forbidden and fail before verification begins.

The fail-closed order is:

1. exact M8 ABI, metadata, six closed/replayed receipts, 80-source identity and
   final development manifest;
2. Vivado 2023.2/part/board/IP catalog preflight;
3. exact production XSim smoke and compact mode 0/1 rejection plus mode 3;
4. standalone NPU+AXI OOC synthesis;
5. clean project and native AXI-128 block design;
6. full-board synthesis;
7. placement and route;
8. post-route structural, route, timing, constraint, DRC and methodology
   gates;
9. current-run BIT generation and XSA export containing exactly one BIT and
   the canonical three-HWH set (`vit_system.hwh`,
   `vit_system_smartconnect_control_0.hwh`, and
   `vit_system_smartconnect_ddr_0.hwh`), with the embedded BIT byte-identical
   to the external artifact;
10. terminal strict manifest/receipt replay after the long Vivado stages;
11. `PENDING_COLLECTION` receipt followed by a collector-side strict replay;
12. atomic promotion to `DEVELOPMENT_UNSEALED` with a checksummed final status,
    an exact collector XSA/BIT equality/hash and three-HWH-set receipt, and an
    output receipt only after collection succeeds.

Standalone and board synthesis must each prove non-vacuous NPU logic,
blackboxes=0, inferred latches=0, combinational loops=0, DSP48/DSP58=0,
the exact 41-RAMB36 hierarchy, zero new-buffer LUTRAM and CLB-LUT fit before
implementation. Post-route repeats those structural gates and additionally
requires complete routing with no route errors, setup WNS>=0, hold WHS>=0,
clean internal timing-constraint coverage, zero total DRC violations and zero
total methodology violations. BIT/XSA are written only after all those gates
pass. A complete-looking status is never written before the collector exits
successfully and preserves `OUTPUT_SHA256SUMS` plus its terminal marker. The
runner also replays every record in `OUTPUT_SHA256SUMS`, including the final
status and both strict-verifier transcripts, before it reports success.

## Pending acceptance

M8 remains unsealed and unpromoted until the exact current source and final
manifest pass full-device Vivado, a distinct M8 BIT/XSA identity is preserved,
complete real E05 passes, and that exact artifact is exercised on the board.
No board is currently available, so the flow must stop after simulation and
Vivado artifact closure and report that boundary explicitly.
