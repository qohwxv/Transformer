# M8 LayerNorm standalone OOC A/B receipt

Status: **SAFE / PASS** for the standalone LayerNorm OOC scope only.

This receipt preserves two Vivado 2023.2 server runs on
`xczu5ev-sfvc784-1-e` at 50 MHz: the fail-closed initial run
`20260808T162713Z-m8-layernorm-ooc-ab` and the corrected full A/B run
`20260808T164100Z-m8-layernorm-ooc-ab-generate-fix`. Both remote trees were
accessed read-only. Fresh SHA-256 snapshots taken before and after copying are
identical to the local copies: 4/4 files for the initial failure and 35/35
files for the corrected run.

## Preserved initial failure

The initial RTL source SHA-256 is
`c1f1342722104584e41ae753208f6295d3bae219927eae768ccff41d4c8a71b3`.
With `ENABLE_ROW_AFFINE_BUFFER=0`, Vivado still inferred three RAMB36 blocks.
The fail-closed gate expected zero and stopped immediately after synthesis:

```text
M8_LAYERNORM_OOC_FAIL post_synth enable=0 DSP=0 RAMB36=3 RAMB18=0 URAM=0 LUTRAM=0 blackbox=0 latch=0 expected_RAM36=0 and all others zero
```

The initial remote run contains only its input manifest, PID and two
byte-identical copies of the Vivado transcript. Because the gate stopped
before the report/checkpoint commands, that run produced no surviving report
or DCP; this absence is preserved rather than reconstructed.

The corrected source places the three RAM declarations inside the enabled
generate branch and drives the shared read ports to zero in the disabled
branch. Its SHA-256 is
`f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f`.
The OOC Tcl and runner did not change between runs. The two input manifests
differ only in this LayerNorm RTL file. A byte-identical capture of the local
final production source has the same `f3a88811...b4f` identity.

## Corrected authoritative OOC result

| case | buffer | WNS/WHS (ns) | LUT/FF | RAMB36 | DSP | routed nets |
|---|---:|---:|---:|---:|---:|---:|
| disabled | 0 | `+10.037/+0.012` | `1391/1247` | `0` | `0` | `1951/1951` |
| candidate | 1 | `+10.964/+0.019` | `1345/1245` | `3` | `0` | `1983/1983` |

Both corrected cases report zero RAMB18, URAM, LUTRAM primitives, black
boxes, latches, combinational loops and routing errors. Severe DRC and
methodology counts are zero. The candidate therefore proves the intended
three-RAMB36 mapping while preserving the hard `DSP48/DSP58=0` gate; the
disabled case proves those optional memories elaborate away.

Evidence class: `MEASURED` from surviving Vivado logs, reports and DCPs,
limited to this standalone OOC leaf. Each routed case intentionally retains
one explicit OOC partition gap and false-paths boundary hold timing. This is
not full-design timing/resource closure, BIT/XSA, physical-board, full-model
or end-to-end performance evidence.

## Receipt contents

- `initial_disabled_ram_failure/remote_run/`: byte-identical four-file failed
  run.
- `initial_disabled_ram_failure/input_snapshot/`: exact old staged inputs and
  M7-S8 provenance.
- `corrected_full_pass/remote_run/`: byte-identical passing run, including all
  summaries, logs, reports and four post-synthesis/post-route DCPs.
- `corrected_full_pass/input_snapshot/`: exact corrected staged inputs and
  M7-S8 provenance.
- `local_final_source/`: byte-identical capture of the local final LayerNorm
  production source at receipt creation.
- `REMOTE_*SHA256SUMS.*` and `LOCAL_*SHA256SUMS.txt`: whole-tree server/local
  comparisons before and after transfer.
- `RECEIPT_SHA256SUMS.txt`: every immutable receipt payload except itself and
  the root-hash file.
- `RECEIPT_MANIFEST.sha256`: the final receipt root identity.

Run `./VERIFY_RECEIPT.sh` from any directory to verify all hashes and semantic
gates. No remote file was modified.

