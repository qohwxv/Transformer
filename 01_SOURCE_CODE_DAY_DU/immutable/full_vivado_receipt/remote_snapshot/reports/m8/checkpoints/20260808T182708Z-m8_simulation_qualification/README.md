# M8 scoped simulation qualification checkpoint

Date: 2026-08-09 (Asia/Ho_Chi_Minh)  
Created: 2026-08-08T18:27:08Z  
Status: `DEVELOPMENT_UNSEALED` / `PENDING_M8_SEAL` / `NOT_PROMOTED`  
Scope: exact production-source identity, standalone leaf OOC, XSim, and
phase-level real-asset E04/E01 simulation evidence only.

This checkpoint closes the currently available M8 simulation qualification
for IP v1.13. It is deliberately not a final development checkpoint, a
full-design Vivado result, a BIT/XSA release, a complete real E05 result, or
physical-board evidence.

## Exact production identity and M7 parent

- Production closure: 80/80 unique ordered sources.
- M8 ordered source SHA-256:
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- `filelists/full_axi.f` SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- Exact M7-S8 parent ordered source SHA-256:
  `1ffe0295790435ba762659aee2cac1e1d8f7bace7317ee4715ef4f33474e5888`.
- Parent checkpoint `SHA256SUMS.txt` SHA-256:
  `bf29ff0b8d9d73be9a7528d7bd7f2151bd91746c3ae227210fb9eea6a7ec86ee`.

Exactly six reachable production files differ from the M7-S8 parent:

| Production file | M7-S8 SHA-256 | M8 SHA-256 |
|---|---|---|
| `rtl/blocks/vector/vit_vector_engine_fp32.sv` | `0aa640ad395ef79dada35b287fec615e54047bd578d6e5c15fe4b734d55fc1fa` | `c71542773318964a538384d81bf9b842361678e81132986d5a31ad0b1ec96df2` |
| `rtl/blocks/layernorm/vit_layernorm_engine_fp32.sv` | `a61ec7471de9a5641744195dbded3f33202e325e4822da5d113d575346776187` | `f3a88811ee2f992eaadf808d1c1bc34f9624addd7e44a53b905ffe784ad83b4f` |
| `rtl/blocks/softmax/vit_softmax_engine_fp32.sv` | `4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da` | `9ddbb13b65f53be82a3bde83f572e1124fe9333b557582b7f60d2d8b8d7b1ec9` |
| `rtl/core/vit_phase_e_read_address_router.sv` | `5e2a44ed50a48a16dfd428d4c9fe36669b11052a5aadc94d23027d22f21a5319` | `4dcd75977601711b9324e431f7582b9791b69dd17720f4fd5e7184df8bb12219` |
| `rtl/core/vit_phase_e_engine_top.sv` | `866bf6477d8611b02da832370961aa774ef64b83b182ffa218be810ba2fe09b4` | `0056ebc96dfd23a0de2fd2ad25d3acd53ad2985ee69bebdab5253946609fe512` |
| `rtl/axi/control/vit_axi_lite_control_regs.sv` | `7ab2cb6211294a7c8e58704bd2e0bb2e0c0f1904d923809d578d6b4a7c838b7c` | `00eceb2222ea89eb1d4d0149baf4185047be8c72047a0958e0a18dbdc54426b6` |

IP version is `0x0001000D`. Production explicitly enables the 1,024-word
LayerNorm row/affine buffers and the 1,024-word Softmax row/exp buffer. The
other M8 changes bypass provably unused Vector arithmetic and expose bounded
Vector/GELU read-ahead only for complete gathers before result publication.
Hidden sizes or rows beyond the buffer depth retain the legacy fallback.

## Replay-verified evidence

Every receipt checksum manifest and semantic verifier passed immediately
before this checkpoint was created.

| Gate | Evidence class and exact result | Receipt path | Entries / anchor SHA-256 |
|---|---|---|---|
| Softmax standalone OOC | `MEASURED`, Vivado 2023.2 leaf only; candidate `WNS/WHS=+4.472/+0.033 ns`, one RAMB36, DSP=0 | `reports/m8/server_runs/20260808T161943Z-m8-softmax-ooc-ab-holdfix` | 94 / `e5aa7485c96bf9789dcfca76af29b4580bfc0a767d4608ea662ab3caea5f3174` |
| LayerNorm standalone OOC | `MEASURED`, Vivado 2023.2 leaf only; candidate `WNS/WHS=+10.964/+0.019 ns`, three RAMB36, DSP=0 | `reports/m8/server_runs/20260808T164100Z-m8-layernorm-ooc-ab-generate-fix` | 71 / `a1f7e6c42eea1ba71f0768cb17c2b3f407d739424047b6bd0ee6f92ab0fb0f09` |
| Exact XSim suite | `SIM-MEASURED`, 10/10 PASS twice with identical ten-line signatures and compact metric | `reports/m8/server_runs/20260808T171800Z-m8-xsim-exact-10of10-receipt` | 143 / `83c88bf0458cd8ac29a0e8cd76014ad49c97507c0513d538cf3be78da3f8c059` |
| Real-asset E04 mode 3 | `SIM-MEASURED`, two terminal PASS runs and 6/6 byte-identical outputs/reports | `reports/m8/server_runs/20260808T173000Z-m8-e04-mode3-pass-repeat-receipt` | 162 / `8d2d448aefc24ac386ea4bc80087584a85c357179686396b85016158535f85cf` |
| Real-asset E01 mode 3 | `SIM-MEASURED`, three terminal PASS runs and 3/3 byte-identical authoritative artifacts | `reports/m8/server_runs/20260808T181104Z-m8-e01-mode3-threepass-receipt` | 185 / `05df7fff6d1b714b5b8c5f519325f5a416f27c0c1c33c1f6c7b0cfaebcf9a3e0` |

The E01 launcher did not preserve an outer shell exit-status file. Its receipt
therefore uses three terminal numerical PASS logs, exact source state,
hash-exact output/oracle gates, remote quiescence, and complete transfer
parity; it does not claim a captured launcher exit code.

## Exact simulation metrics

- Compact mode 3: 2,081 checks, 444,212 total / 436,680 job cycles,
  249 commands, 35,139 reads, 10,646 writes, 2,886 AXI stalls, and
  class/logit `3/0x40E00000`.
- Real E04: 202 checks, 9,010,605 structural cycles, five commands,
  1,694,368 logical reads, 767,234 cache hits, 927,134 external words,
  207,134 AR, 351,134 R beats, 154,064 writes, and class/logit
  `879/0x414886A0`. All six outputs/reports are byte-identical across the M8
  repeat and the matching M7-S8 run.
- Real E01: 266 checks, 82,215,315 cycles, four commands, 15,351,550
  external reads, 1,243,870 AR, 4,065,406 R beats, and 453,120 writes.
  All 151,296 embedding words match the M6/current-adder oracle exactly and
  have zero behavioral failures at absolute tolerance `5e-3`.

`DERIVED` from matching simulation scopes, M8 reduces compact job cycles by
10.574483379% (`1.118249061x`), E04 cycles by 37.109253783%
(`1.590059047x`), and E01 cycles by 1.406132756% (`1.014261868x`) versus
M7-S8. These are phase/fixture simulation comparisons, not complete-E05 or
physical-board speedups.

## Deterministic source snapshot

`SOURCE_SNAPSHOT.tar.gz` contains exactly 82 regular files:

- `filelists/full_axi.f`;
- the exact 80 reachable production sources in that filelist; and
- `M8_SIMULATION_SOURCE_SHA256SUMS.txt`, an 81-entry checksum manifest for
  the filelist and sources.

The archive was generated twice with normalized order, timestamp, owner and
gzip header, and the two copies were byte-identical. It is 140,007 bytes with
SHA-256
`97edd5c7f9132a825247640681153f8744ebfd56a49d82684e5b310a48e463aa`.
The internal source manifest SHA-256 is
`a443edaedd73f33fe422c95c82534e3dccbde6160e47d09f45938e780ff18935`.

Large receipt payloads are not duplicated in the source archive. Their
independently sealed paths and anchors are bound above and in `STATUS.json`.

## Explicit limits and next phase

- 50 MHz is the M8 target clock, not a full-design closed clock result.
- Full-design Vivado, synthesis, implementation, placement and route have not
  run for M8. Full-design WNS/WHS and post-route DSP use are unverified.
- DSP48/DSP58=0 remains the hard future full-design gate; current DSP=0
  measurements apply only to the two standalone leaf OOC receipts.
- No M8 BIT or XSA has been generated. M7-S8 BIT/XSA and full-Vivado reports
  are parent evidence only and are not M8 artifacts.
- Complete real E05/full-model and physical-board validation remain pending;
  no board is currently available.
- The M8 ABI-v1.13 JSON, current BUNDLE, strict development verifier, and
  global development manifest are `PENDING_NEXT_PHASE`. They are deliberately
  not prerequisites for this source-and-simulation-only checkpoint.

The next gate is metadata/ABI/preflight closure followed by a sequential
server full-Vivado run. Stop at this checkpoint before starting that phase.

## Local replay

From the M8 bundle root:

```bash
checkpoint=reports/m8/checkpoints/20260808T182708Z-m8_simulation_qualification
(cd "$checkpoint" && sha256sum -c SHA256SUMS.txt && \
  sha256sum -c RECEIPT_MANIFEST.sha256)

replay_dir="$(mktemp -d /tmp/vit_m8_sim_snapshot_replay.XXXXXX)"
tar -xzf "$checkpoint/SOURCE_SNAPSHOT.tar.gz" -C "$replay_dir"
(cd "$replay_dir" && \
  sha256sum -c M8_SIMULATION_SOURCE_SHA256SUMS.txt)
```

