# M8 exact XSim 10/10 PASS and repeat receipt

Date sealed: 2026-08-08 UTC  
Evidence class: `SIM-MEASURED` for simulation results; `VERIFIED` for hashes,
source closure, copied-file parity, and repeat comparison.  
Disposition: `SAFE_FOR_NEXT_M8_NONBOARD_GATE`.

This receipt preserves the first terminal 10/10 XSim PASS and one separately
launched exact-pinned repeat from the M8 server workspace. It also preserves
four earlier attempts that stopped for harness/tool-launch reasons. No result
in this receipt is a synthesis, route, DSP-use, BIT/XSA, physical-board,
complete real-E05, or model-accuracy claim.

## Exact production and simulation inputs

- Production closure: 80/80 unique ordered sources, SHA-256
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- Filelist SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- Current exact runner SHA-256:
  `67c9201e9f868b41e4eabb15222ac61c29abce8186d8a31609c3811599c3ce74`.
- All nine non-production SystemVerilog testbench/model inputs compiled by
  that runner are individually bound in `XSIM_INPUT_IDENTITY.txt`.
- The complete 80-source production tree, filelist, runner, and nine
  test/model inputs are copied under `input_snapshot/` and replay-verified by
  `verify_receipt.sh`.
- Tool identity is Vivado Simulator 2023.2, SW build 4029153. Wrapper and
  resolved xvlog/xelab/xsim executable hashes are in `TOOL_IDENTITY.txt`.

The current runner was staged at 2026-08-08T17:05:33.143932633Z, after the
first PASS completed and before the repeat began. Its hash therefore binds
the exact repeat and current input snapshot. The first PASS raw log itself
proves all ten exact result signatures and the identical compact metric line;
this receipt does not manufacture a byte hash for the earlier runner copy.
Every production RTL and non-production SV input mtime predates the first
PASS, and production state before the XSim attempts and at receipt collection
replays to the same `db4e84...fb7e` identity.

Portable-Icarus wrappers and focused parent-reference files were not XSim
inputs and are deliberately not presented as such here.

## Two terminal PASS runs

First PASS:

- Run directory:
  `20260808T171600Z-m8-xsim-observation-checkcount`.
- Raw log: 759 lines, 57,712 bytes, SHA-256
  `9ad9a6d1c9d7aa5308e408baa1ca867fdbb94b0b63d0a9b2b6aa16324fba14b4`.
- Result: exactly 10/10 case signatures plus one final suite PASS marker.

Exact-pinned repeat:

- Run directory: `20260808T172400Z-m8-xsim-exact-repeat`.
- Raw log: 759 lines, 57,712 bytes, SHA-256
  `46568808fe2c486665547aaf4dad44f216ad2d372cc437522a08f94f2e8e2b33`.
- Result: exactly 10/10 case signatures plus one final suite PASS marker.

The ten authoritative signature lines are byte-identical across the two
runs. Each extracted file has SHA-256
`f3d81767f162f5b80ce5f4fb9355cfbd441fa685a596e9412e3ab6676e0f3c2c`.
The raw full logs intentionally differ in temporary directory names, exit
timestamps, and host free-memory/runtime telemetry; they are not described as
byte-identical full logs.

The compact mode-3 metric line is byte-identical in both runs, SHA-256
`16b2717b049c30fa5f1551bdbd4da38cd4ef80be9b13a5bdfcc1d4be7373f814`:

```text
VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=3 rows=8 cols=2 checks=2081 cycles=444212 job_cycles=436680 commands=249 blocked_gemm=74 packed_gemm=74 fp16_gemm=98 row_major_gemm=24 packed_tiles=1175 nonpacked_tiles=264 reads=35139 writes=10646 axi_stalls=2886 model_reads=20829 input_reads=32 scratch_reads=14278 cmd_active=435703 logical_reads=91403 cache_hits=55080 valid_mac=59376 tail_mac=124816 class=3 logit=40e00000
```

The other nine exact signatures cover the AXI memory adapter, AXI wrapper,
logical-memory engine, production engine-to-AXI seam, legacy performance
counters, profile counters, M7 overlap counters, and clean compact mode-0/1
execution-mode rejection. See `PASS_SIGNATURES_FIRST.txt` and
`PASS_SIGNATURES_REPEAT.txt`.

## Preserved failed attempts

The complete remote directories are retained under `raw_remote_runs/`:

- `20260808T165200Z-m8-sim-observation`: no Icarus executable in PATH;
  stopped before RTL compilation.
- `20260808T165900Z-m8-sim-observation-portable-iverilog`: focused vector and
  router gates passed, then a nonexistent sibling M7 reference path stopped
  the linefill launcher.
- `20260808T170200Z-m8-sim-observation-selfcontained`: focused gates,
  production Icarus, and lint completed; xelab rejected illegal `--mt 1`
  before the first XSim DUT run.
- `20260808T171100Z-m8-xsim-observation`: the first three XSim DUT cases
  passed, then a stale harness marker expected 1799 rather than the observed
  exact logical-memory check count 1671.

These are harness/tool-launch failures, not evidence of an RTL mismatch.
Their exact scope and stopping points are recorded in
`EXPECTED_HARNESS_FAILURES.txt`; they are not counted as PASS runs.

## Receipt integrity and scope

`TRANSFER_VERIFICATION.txt` records checksum parity between the remote source
and every copied run/input. `RECEIPT_SHA256SUMS.txt` binds every receipt file
except itself; the SHA-256 of that manifest is the external receipt anchor.
Run `./verify_receipt.sh` from any directory to replay the complete local
checksum, production-source, 10/10-signature, metric, suite-marker, and
historical-failure gates.

This collection was read-only on the server. This task created only this
receipt directory; it did not edit RTL, testbenches, flow scripts, BUNDLE,
project documentation, or the project/development manifests.
