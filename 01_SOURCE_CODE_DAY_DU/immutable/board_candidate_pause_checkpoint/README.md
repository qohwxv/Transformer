# M8 board-candidate pause checkpoint

Created: 2026-08-09T05:00:53Z

Status: `M8_BOARD_CANDIDATE_PAUSE_SAFE_NOT_BOARD_TESTED`

This immutable checkpoint is the safe stopping point requested before the
next lab session. It is deliberately **not** named `M8_SAFE_NONBOARD` and does
not claim a complete real E02/E03/E05 numerical qualification or a physical
board result.

## What is closed

- Exact M8 IP-v1.13 production identity: 80 sources, ordered SHA-256
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`,
  `full_axi.f` SHA-256
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- Vivado 2023.2 full clean-project flow at 50 MHz: fully routed, WNS/WHS
  `+0.045/+0.010 ns`, DSP48/DSP58 zero, exact 41 RAMB36, RAMB18/URAM zero,
  no LayerNorm/Softmax LUTRAM fallback, DRC/methodology zero.
- Exact BIT SHA-256
  `462d78a91d9fb35b2cb5832ab222c39952a1052d3ff6766d94e37405f887a275`
  and XSA SHA-256
  `47e764324d9eaedcc343b3cdf66190dbb90635cf8e51b4f6e65b4746c43680ee`.
  They are generated and sign-off checked but not board-tested.
- The immutable full-Vivado receipt is
  `reports/m8/server_runs/20260809T032300Z-m8-board-candidate-67c18532-full-vivado-pass-receipt`,
  whose `RECEIPT_SHA256SUMS.txt` anchor is
  `060bea427080f8fb8cfb9321f2d95b39a9442de0256051869e33949b1468f437`.
- The earlier scoped simulation qualification remains bound by checkpoint
  anchor `a73adcf2e6597ef81e733dcdccbf9e6d95938b5edad0581617412133c446da3f`.

## Deliberately stopped work

The corrected real E02 layer-0 simulation was stopped at the user's request
after the latest complete progress marker at 850,000,000 cycles. It had 17
commands and 16 checkpoints but had not produced a terminal output,
structural gate, numerical gate, or `LAYER_PASS`. The outer exit is 1 with
pipeline status `143,0,0`. Its immutable receipt is included in the portable
package and is correctly labelled `INTERRUPTED_PARTIAL_NOT_PASS`; receipt
manifest SHA-256:
`068eea24b27c7f6b124d89885995397c5db312460026e07fffb28321c48169ff`.

No E03 or full E05 run was launched. The hardened E05 harness exists, but its
multi-day run remains pending.

The Genesys FSBL/PMUFW build is also pending. The failed headless attempt was
an Eclipse/SWT display failure (`gtk_init_check() failed`), not an XSA or RTL
failure. No FSBL ELF, PMUFW ELF, boot receipt, JTAG connection, FPGA program,
flash write, or board access occurred. Resume with a fresh workspace and the
official XSCT wrapper under Xvfb; never reuse the partial Vitis workspace.

## Portable package

`M8_BOARD_CANDIDATE_PACKAGE.tar` is a self-contained 78-file payload with:

- BIT, XSA, run status and output checksum receipt;
- exact source snapshot and M8 metadata/ABI/verifier;
- package-v3 model, table, input, package reports and golden logits/probabilities;
- board identity and host/JTAG tooling;
- decisive route/timing/resource/DRC/methodology reports;
- full-Vivado receipt pointers; and
- the immutable interrupted layer-0 receipt.

Archive SHA-256:
`898cfee0e08769f203dbb299b4d250eed0adfdb5afb3c60683d8cc5763fdf8c1`.
The archive contains `PAYLOAD_SHA256SUMS.txt` with 77 payload records; the
manifest itself is the 78th file.

Run the offline replay before using the package:

```bash
./VERIFY_CHECKPOINT.sh
```

## Tomorrow's safe order

1. Replay this checkpoint and the full-Vivado receipt.
2. Build a new exact-XSA Genesys FSBL/PMUFW receipt in a fresh Vitis workspace.
3. Run host-only board preflight and audit the complete JTAG cable serial.
4. Cold power-cycle, program volatile JTAG only, run DDR smoke, then one M8
   image while capturing all counters and 2,000 numerical outputs.
5. Preserve the physical receipt before deciding whether the slow E02/E03/E05
   simulations are still necessary for the desired claim.

The user's confidence threshold (>80%) is recorded only as an `ESTIMATED`
board-bring-up decision. It is not a numerical-accuracy or runtime result.
