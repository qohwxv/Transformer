# M8 E04 mode-3 real-asset PASS and exact-repeat receipt

Date sealed: 2026-08-08 UTC  
Evidence class: `SIM-MEASURED` for the two completed Verilator simulations;
`VERIFIED` for source/input identity, remote-to-local checksum parity, and
repeat comparison.  
Disposition: `SAFE_FOR_NEXT_M8_NONBOARD_GATE`.

This immutable local receipt preserves one initial workspace-context failure,
the first complete E04 PASS, and a separately launched exact-pinned repeat
from the M8 server workspace. It is an E04 mode-3 RTL simulation result only:
it is not synthesis, implementation, DSP-use, timing, BIT/XSA, physical-board,
complete real-E05, or end-to-end model-accuracy evidence.

## Preserved runs

- `20260808T173100Z-m8-e04-mode3-observation` stopped during asset staging
  because the asset module could not discover the enclosing workspace root.
  It stopped before RTL compilation or simulation and is preserved as an
  expected harness/workspace-context failure, not a DUT failure.
- `20260808T174200Z-m8-e04-mode3-observation-contextfix` is the first terminal
  E04 PASS. Its 55-line outer log is 28,789 bytes with SHA-256
  `79939c50c72194b29aabca292cac8d9b5bd0bad2fdd3cbaa3d9061d012b3f673`.
- `20260808T175500Z-m8-e04-mode3-exact-repeat` is the exact-pinned repeat.
  Its 55-line outer log is 28,659 bytes with SHA-256
  `ccf1c672afd85190d46b3a9586d88b5b22c260888ae9cb632e3b8caadc2e434d`.

The raw remote directory trees are copied in full under `raw_remote_runs/`.
They contain 43 surviving files: 3 for the initial failure and 20 for each
PASS run.

## Exact source, harness, and asset identity

- Production closure: 80/80 unique ordered sources, SHA-256
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- Production `filelists/full_axi.f` SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- E04 testbench SHA-256:
  `56ef0ed5910f152ac4c00744b331eee1b261c01d2569c1a67d040134a4e4e1c6`.
- E04 Verilator filelist SHA-256:
  `ac98cc5a49a53d0f6fb5834639af37d1655244f052564c8b339476d44343d4d6`.
- Stager, asset module, 128-bit DDR model, complete package-v3 payload,
  activation, three behavioral goldens, M6 oracle, and parent/current adder
  references are copied and individually bound in
  `WORKSPACE_INPUT_SHA256SUMS.txt` and `INPUT_IDENTITY.txt`.
- The workspace snapshot contains 100 files: 80 exact production sources and
  20 explicitly selected non-production/reference/package inputs. The
  production filelist is intentionally present in both closure descriptions
  but exists once at its canonical path.

Each PASS run records identical `SOURCE_STATE_BEFORE.txt` and
`SOURCE_STATE_AFTER.txt`. Production RTL, testbench, E04 filelist, stager,
asset module, DDR model, activation, and goldens are unchanged between the
two runs.

## Runner transition and repeat meaning

The first PASS used runner SHA-256
`a7c524a821d39f5ebd538664e42102de9da26c4ab6fa53a1c9f59467e2e30642`.
That state was recovered exactly from the recorded source-state hash by
reverting the three post-observation assertion edits; it is retained as
`runner_states/observation_runner_a7c524a821d3.sh`.

After the first PASS, only three fail-closed regular expressions were changed
to pin the observed result, traffic, and structural metric values. The repeat
used runner SHA-256
`74d7b8e5c737bbb9ef201a378e918eb23cadab9a6272adaed323025499c3ce9f`.
The exact diff is `runner_states/RUNNER_STATE_DIFF.patch`.

The runner hash therefore intentionally changes between the two PASS runs.
Despite that assertion-only change, all six authoritative RTL outputs and
oracle reports are byte-identical across the runs:

1. final-layernorm RTL dump;
2. logits RTL dump;
3. probabilities RTL dump;
4. class-result RTL dump;
5. behavioral-golden comparison JSON;
6. M6 classifier-oracle comparison JSON.

Their exact hashes are in `AUTHORITATIVE_OUTPUTS_SHA256.txt`.

## Simulation result

Both runs report the same exact structural and traffic result:

```text
M7_MODE3_E04_RESULT class=879 logit=414886a0 logit_real=12.532867432 numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES
M7_MODE3_E04_TRAFFIC cycles=9010564 logical_reads=1694368 cache_hits=767234 external_u32=927134 ar=207134 r_beats=351134 full_r_beats=192000 narrow_r_beats=159134 linefills=48000 line_hits=720000 writes=154064
VIT_PHASE_E_AXI_E04_MODE3_REAL_RTL_STRUCTURAL_PASS checks=202 cycles=9010605 commands=5 external_u32=927134 writes=154064 model_reads=771534 scratch_reads=155600 class=879 logit=414886a0 numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES
```

Output structure is 151,296 final-layernorm words, 1,000 logits, 1,000
probabilities, and two class-result words, with zero nonfinite, sentinel, or
layout errors. Behavioral comparison has zero tolerance failures for all
three tensors and top-1/class 879. The M6 classifier oracle matches all 1,000
logits bit-exactly and also selects class 879.

## Integrity, transfer, and replay

Five checksum-mode rsync dry-runs produced no differences after collection:
one for each raw run and one for each workspace-input list. The remote server
was quiescent for the relevant account before sealing. Details are in
`TRANSFER_VERIFICATION.txt` and `REMOTE_QUIESCENCE.txt`.

`RECEIPT_SHA256SUMS.txt` binds every receipt file except itself. Its SHA-256
is the external receipt anchor. Run `./verify_receipt.sh` from any directory
to replay local file integrity, 80-source closure, exact input identities,
runner transition, expected context failure, both terminal PASS gates, JSON
semantics, and byte-identical six-file repeat evidence. The verifier does not
rerun the long simulation.

Collection was read-only on the server. This task created only this local
receipt directory; it did not edit remote files, RTL, tests, flow scripts,
project documentation, BUNDLE, or any global manifest.
