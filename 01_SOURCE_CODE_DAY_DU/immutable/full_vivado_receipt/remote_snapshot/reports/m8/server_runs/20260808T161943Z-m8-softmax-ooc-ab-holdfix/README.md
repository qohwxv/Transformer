# M8 Softmax standalone OOC A/B receipt

Status: **SAFE / PASS** for the standalone Softmax OOC scope only.

This receipt is an immutable local copy of the completed Vivado 2023.2 server
run `20260808T161943Z-m8-softmax-ooc-ab-holdfix` on
`xczu5ev-sfvc784-1-e` at 50 MHz. The server evidence was copied read-only and
all 38 files in the passing run matched a fresh remote SHA-256 snapshot.

## Authoritative OOC result

| implementation | exact RTL SHA-256 | WNS/WHS (ns) | LUT/FF | RAMB36 | DSP | routed nets |
|---|---|---:|---:|---:|---:|---:|
| exact M7-S8 parent | `4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da` | `+4.567/+0.023` | `1748/1064` | `0` | `0` | `2385/2385` |
| M8 candidate | `9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9` | `+4.472/+0.033` | `1795/1060` | `1` | `0` | `2485/2485` |

Both implementations also report zero RAMB18, URAM, LUTRAM primitives,
black boxes, latches, combinational loops and routing errors. The terminal
flow gates report zero severe methodology findings and zero severe DRC
findings. The candidate therefore proves the intended one-RAMB36 inference
with the hard `DSP48/DSP58=0` gate intact.

Evidence class: `MEASURED` from surviving Vivado reports and DCPs, limited to
this standalone OOC leaf. This is not full-design implementation, BIT/XSA,
physical-board, full-model or end-to-end performance evidence.

## Contents

- `remote_run/`: byte-identical passing server run, including both console
  logs, summaries, all reports, post-synthesis/post-route DCPs and the server
  SHA manifests.
- `input_snapshot/`: the exact 13 input files named by the passing run's
  `INPUT_SHA256SUMS.txt`; all hashes verify.
- `initial_parent_hold_failure/`: byte-identical preservation of the earlier
  fail-closed parent run. It records WNS/WHS `+2.776/-0.020 ns` under the old
  flow SHA `58c98b85913e0d1fa16025af84834c67619d928fcc897bfad9492e2fabfea07e`.
  Its immutable payload manifest SHA-256 is
  `e217074da4d12b2b2dd7c7d1fa9251b05e7e39eb66cb0a14b130cb4d866b3072`.
- `REMOTE_*SHA256SUMS.txt` and `LOCAL_*SHA256SUMS.txt`: fresh whole-tree
  remote/local hash snapshots for the passing and initial-failure runs.
- `RECEIPT_SHA256SUMS.txt`: all receipt payload hashes except itself and the
  root-hash file.
- `RECEIPT_MANIFEST.sha256`: final receipt root identity.

Run `./VERIFY_RECEIPT.sh` from any directory to recheck every immutable payload
and every terminal gate. The remote source was not altered.
