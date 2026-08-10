# M8 E01 mode-3 three-PASS hash-exact receipt

Date sealed: 2026-08-08 UTC  
Evidence class: `SIM-MEASURED` for the three completed Verilator RTL
simulations; `VERIFIED` for source/input identity, transfer parity, runner
provenance, cross-run byte identity, and remote quiescence.  
Disposition: `SAFE_FOR_NEXT_M8_NONBOARD_GATE`.

This immutable local receipt preserves one launch-wrapper preflight failure,
the first complete M8 E01 observation, an exact-metric repeat, and a final
hash-exact repeat. It is E01 mode-3 real-asset RTL simulation evidence only.
It is not synthesis, implementation, DSP-use, timing, BIT/XSA, physical-board,
full E05, or end-to-end model-accuracy evidence.

## Preserved runs

- `20260808T172200Z-m8-e01-mode3-observation` stopped because its `e01_run`
  output directory had already been created and the fail-closed runner refused
  reuse. Its one-line, 227-byte log has SHA-256
  `aef07e6634b637b5ebe48f5ab869b2159f2e73fab5e82004db83bd82f3054021`.
  No asset staging, build, or RTL simulation started, so this is a launch
  wrapper/output-directory failure rather than a DUT failure.
- `20260808T172400Z-m8-e01-mode3-observation` is the first terminal PASS. Its
  90-line, 32,698-byte outer log has SHA-256
  `98cc7457de6ab93eda006a6cc55a7e1d4b0a8d22d03f7e11b32827a2cfe4f94c`.
- `20260808T173900Z-m8-e01-mode3-exact-repeat` is the exact-metric repeat. Its
  90-line, 32,711-byte outer log has SHA-256
  `58722569304ca8fdc72865305422059859e2355f88a9b76663c0f911cfcb3968`.
- `20260808T175400Z-m8-e01-mode3-hash-exact-final` is the final hash-exact
  repeat. Its 90-line, 32,845-byte outer log has SHA-256
  `a914d22df53b26007a31565af9ae1c818a2fb8802157ee6fd948c7a95bc98bf3`.

All four remote directory trees are copied in full under `raw_remote_runs/`:
62 files total, comprising two files for the preflight failure and 20 files
for each successful run.

## Source, harness, package, and oracle identity

- Production closure is 80/80 unique ordered sources at SHA-256
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- Production `filelists/full_axi.f` SHA-256 is
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- The E01 testbench and Verilator filelist hashes are respectively
  `f4ab571dc7a0dcce158ba1a9448ae62220be95272e4127248ad0e4458b18bd2f`
  and `8ce965dabef7611c75e8f2e90179670711805e4a48563bb40ac2b82d8e2ce79a`.
- The stager, asset module, asset tests, 128-bit DDR model, complete package-v3
  payload, prepared input, embedding golden, M6 reference, and parent/current
  FP32 adder references are copied and bound in
  `WORKSPACE_INPUT_SHA256SUMS.txt` and `INPUT_IDENTITY.txt`.
- `workspace_snapshot/` contains 98 unique files: the 80 production sources
  once, plus 18 explicitly selected non-production harness/package/reference
  inputs. `PRODUCTION_SOURCE_STATE.txt` preserves the exact ordered 80-source
  checksum record.

Each successful run has byte-identical `SOURCE_STATE_BEFORE.txt`,
`SOURCE_STATE_AFTER.txt`, and `SOURCE_STATE_FINAL.txt`. The differing source
state hashes across runs are entirely explained by the three recorded runner
states; the common production, harness, package input, golden, and oracle
identities remain fixed.

## Observation, exact repeat, and final closure

The first observation used runner SHA-256
`1a12cdc9ad0567bba8dd01b9505ff8bc0374a6b12c81d7480a9d77813c184beb`.
At that point the cycle count, detailed M7 status bits, and overlap counters
were observed but were still accepted by bounded/general expressions.

The first repeat used runner SHA-256
`5a4c39e58a800eb03a3e11afc54c91de0fe6187c06269bfcd3a3acdc29d8f238`.
Its assertion-only transition pins the observed status, counters, and exact
`82,215,315` structural cycles.

The final repeat used runner SHA-256
`0f376c03632d9fa5148b1939004d992ebecf4b88e71cd977ff0573b1c1ab98f6`.
Its second assertion-only transition additionally pins the RTL embedding hash,
both oracle-report hashes, and the exact behavioral mismatch/max/mean values.
Both transition patches are preserved under `runner_states/`; the final runner
is byte-identical to the copied current workspace runner.

## Exact terminal result and three-run identity

The nine path-independent traffic/structural/M7/output-oracle terminal lines
are preserved verbatim in `THREE_RUN_TERMINAL_SIGNATURE.txt`. Their SHA-256 is
`7f05ddfbe299fcc5b15683dba246b12841aac0ba419e86189525f81aa45e0cde`,
identical 3/3 across the successful runs. They establish:

- 266 structural checks, 82,215,315 cycles, four commands, 15,351,550
  external reads, and 453,120 writes;
- AXI AR/R-beat counts of 1,243,870 / 4,065,406, with 3,762,048 full and
  303,358 narrow R beats;
- M7 overlap counters of 117,964,800 terms, 19,200 dots/results, 921,600
  commits/claims/releases, bank maximum two, FIFO maximum one, and exact
  load/compute/store overlap values preserved in the signature;
- 151,296 finite, non-sentinel embedding words with no hidden-B modification;
- an exact M6/current-adder match for all 151,296 words; and
- zero behavioral tolerance failures at absolute tolerance `5e-3`, with
  150,515 bit-exact mismatches, maximum absolute error
  `3.846675158e-03`, and mean absolute error `2.339259978e-04`.

The three authoritative artifacts are byte-identical across all three runs:

1. RTL embedding SHA-256
   `e06079ecc3bcd16678fafeec44c52535ac955876569bd96449b15f01978b7df9`;
2. M6/current-adder report SHA-256
   `dfe799398f72578c6135d5b5e573bd75d060bcd0bff18f52e3419b79f5e27dfb`;
3. behavioral report SHA-256
   `3807e2f88c188a5ac7dab8001aa455c0f7fa1bf942628898551060f609c46b3d`.

All seven staged-asset/evidence files and both standalone oracle logs are also
byte-identical 3/3.

## Completion limitation, transfer, and replay

The outer `nohup` launch wrapper preserved each PID and outer log but did not
write an outer shell exit-status file. This receipt therefore does **not**
claim a captured exit code. Closure instead rests on three outer logs that end
at `M7_MODE3_E01_NUMERICAL_RUN_PASS`, stable before/after/final source state,
all exact output/oracle gates, and a later quiescence check showing all four
recorded PIDs absent and zero relevant account-owned processes. The limitation
is retained explicitly in `RUN_COMPLETION_EVIDENCE.txt`.

Six checksum-mode rsync dry-runs produced zero differences after collection:
four raw run trees, the 80 production workspace paths, and the 18 selected
input paths. The current runner's independently queried remote and local
SHA-256 values also match. Collection was read-only on the server.

`RECEIPT_SHA256SUMS.txt` binds 185 receipt entries and excludes only itself;
its own SHA-256 is the external receipt anchor. Run `./verify_receipt.sh` from
any directory to replay local integrity, 80-source closure, exact input and
three-runner identity, expected preflight failure, all three terminal gates,
the 9-line signature, JSON semantics, 3/3 artifact identity, explicit missing
outer-exit-status limitation, and read-only sealing. It does not rerun the
long simulation or contact the server.

This collection created only this local receipt directory. It did not modify
remote files, RTL, tests, flow scripts, project documentation, BUNDLE, or any
global manifest.
