# M8 continuous real-E05 qualification harness

Status: `HARNESS_READY_NOT_RUN` on 2026-08-09. This document is not a
simulation PASS, Vivado PASS, BIT/XSA claim, or board result.

## Bound design and data

- Production closure: 80 ordered sources from `filelists/full_axi.f`.
- Ordered-source SHA-256:
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- Filelist SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- IP/ABI seam: v1.13 (`0x0001000D`), execution mode 3, R8/C2/L16/S8.
- Package-v3 model SHA-256:
  `d29d85553b9ec339b27cdd3a3aecb45ffb6ea78a7d2449f51e97c14bd70e28b5`.
- The helper pins the table, runtime configuration, prepared input, one
  embedding golden, twelve encoder-layer output goldens, final LayerNorm,
  1,000 logits, and 1,000 probabilities.

The production RTL, the E01/E04 harnesses, and all existing receipt-bound
files are read-only inputs to this additive harness.

Before creating a run directory or staging assets, the runner verifies
`m8_e05_launch_manifest.json`.  The separate data-only manifest binds all
seven audited E05 files, the common asset/oracle helper, DDR model, M6
reference, current FP32-adder oracle RTL, manifest verifier, and raw-evidence
helper.  A mismatch fails before compilation.  The final immutable M8 bundle
must in turn bind the manifest and its verifier as the external trust root.

## Commands

The default is build-only plus an absolute-plusarg/package-loader smoke:

```bash
bash sim/end_to_end/run_e05_mode3_real_axi_rtl_verilator.sh
```

A bounded structural/protocol probe loads the full model but makes no
numerical claim:

```bash
VIT_M8_MODE3_E05_BUILD_ONLY=0 \
VIT_M8_MODE3_E05_PROBE_STOP_CYCLES=1000000 \
bash sim/end_to_end/run_e05_mode3_real_axi_rtl_verilator.sh
```

The uninterrupted 249-command qualification is explicit:

```bash
VIT_M8_MODE3_E05_BUILD_ONLY=0 \
VIT_M8_MODE3_E05_PROBE_STOP_CYCLES=0 \
VIT_M8_MODE3_E05_RUN_TIMEOUT_SECONDS=604800 \
VIT_M8_MODE3_E05_RUN_ID="m8-e05-full-$(date -u +%Y%m%dT%H%M%SZ)" \
bash sim/end_to_end/run_e05_mode3_real_axi_rtl_verilator.sh
```

Run from the M8 revision root. Use one job and `nice=15`; the runner enforces
both. Give every server run a fresh output directory or run ID.

## PASS contract

A full PASS requires all of the following in one uninterrupted RTL job:

1. Exact v1.13/package/config/source identities before and after the run.
2. Exactly 249 accepted commands and 249 command checkpoints in the exact
   E01 + 12 encoder layers + E04 opcode/context order.
3. Thirteen dumped model boundaries: embedding and layer 0 through layer 11.
4. Final LayerNorm, logits, probabilities, class index, and class logit dumps.
5. Clean AXI bounds, 4 KiB, response, status/error/overflow, trace, histogram,
   M5 and M7 counter-algebra gates.
6. Exact full-E01 M6/current-adder endpoint arithmetic.
7. Exact classifier arithmetic from the RTL final-LN CLS vector.
8. All sixteen independent behavioral vectors within their frozen pre-run
   limits, finite, fully written, probability sum within tolerance, and exact
   top-1 class 879.

If the simulator exits nonzero only because the final, post-dump structural
gate fails, the runner validates all ordered markers and all 17 dump files,
runs both numerical comparators, and preserves their reports for diagnosis.
That path remains `STRUCTURAL_FAIL`, returns nonzero, and can never emit the
continuous-run PASS marker.  Timeout, partial output, malformed output,
missing output, a failed log pipeline, or an unrelated crash is not salvaged.

Full-E05 cycle/read totals have never been observed for M8. The first run
records them and gates only schedule-derived identities and counter algebra;
it does not compare those totals with inherited M7 estimates.

## Runtime and evidence boundary

The runtime is `UNKNOWN` until the first complete server run. A planning
range is roughly 1.5 to 5 days (`ESTIMATED`) from the prior 82.2-million-cycle
E01 simulation rate and current 12-to-40-billion-cycle models. The runner's
seven-day shell timeout preserves a timed-out directory as incomplete
evidence.  The testbench also has an intentional 40,000,000,000-cycle
watchdog; this is the effective cycle cap and is roughly 3.7 days at the
current bounded-probe rate.  Crossing either limit is incomplete, never PASS.

Every created run directory records `TOOLCHAIN.json`, the compiled simulator
SHA-256 and build-end timestamp in `run.log`, source state before/after, and a
terminal `RUN_STATUS.txt` containing mode, result, exit code and UTC start/end
times.  The compiled executable itself remains temporary, so its logged hash
must be retained in the final evidence bundle.

Verilator/DDR-model success is `SIM-MEASURED` only. It cannot establish
post-route timing, physical DDR/PS/JTAG behavior, board repeatability, or
M8 BIT/XSA correctness.
