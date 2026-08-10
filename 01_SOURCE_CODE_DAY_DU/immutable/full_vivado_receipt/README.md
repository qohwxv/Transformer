# M8 IP-v1.13 full-Vivado board-candidate receipt

This directory is the immutable local receipt for the exact remote run
`20260809T032300Z-m8-board-candidate-67c18532`. The outer process began at
approximately `2026-08-09T03:21:53Z` (the preserved PID-file timestamp) and
finished at `2026-08-09T04:26:29Z` with exit code zero. The flow used Vivado
2023.2 build 4029153, a clean project, all ten XSim cases, OOC synthesis, full
board synthesis, placement, routing, strict sign-off, BIT generation and XSA
generation.

The disposition of this exact non-board artifact set is
`SAFE_FOR_BOARD_CANDIDATE_NOT_BOARD_TESTED`. That phrase means the preserved
BIT/XSA are eligible for exact-hash board programming when the Genesys ZU-5EV
is available. It does not mean that a physical board, full real-image E05,
accuracy, latency, repeatability, boot or power test has passed. The source
bundle remains `DEVELOPMENT_UNSEALED`; this receipt does not silently promote
or rename the source revision as `M8_SAFE_NONBOARD`.

## Exact design identity

- Ordered 80-source SHA-256:
  `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e`.
- 409-entry M8 development-manifest SHA-256:
  `67c18532e3bb16b24ec6983f99cc54a3ffafb05fe6c02cf0385465c316b31078`.
- `filelists/full_axi.f` SHA-256:
  `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524`.
- `BUNDLE_INFO.json` SHA-256:
  `25c430d3ef64b23ed083a9a43c2400c924f9c8091920c3de954a8ba4a844c9a5`.
- ABI-v1.13 JSON SHA-256:
  `b15765c858edb0785c34ea75fa50fa5df873f1d22cd53ed2bc0b898db13d8e90`.
- Strict M8 verifier SHA-256:
  `edff30ef9da8b065c3002e6fd6a5ff31efb6ee19fc03470535d9c7cd930bca6f`.
- Target: Digilent Genesys ZU-5EV, `xczu5ev-sfvc784-1-e`, IP v1.13
  (`0x0001000D`), native AXI-128 and 50 MHz (`20.000 ns`).

Fresh remote and self-contained local replays both pass the 409-entry
development manifest, all six prerequisite receipts (658 payload entries plus
three sidecars), and the strict M8 verifier.

## Gates reached

`SIM-MEASURED` for the exact revision:

- Seven base XSim tests pass.
- Compact E05 modes 0 and 1 reject as required, and compact mode 3 passes.
- The compact fixture is not a real full-model numerical result. Complete real
  E02/E03, full E05 and physical-board validation remain pending.

`MEASURED` from authoritative Vivado 2023.2 reports:

- OOC synthesis: DSP48/DSP58=0, loops/latches/black boxes=0, exact 41 RAMB36,
  setup WNS `+5.400 ns` at 50 MHz.
- Full-board synthesis: DSP48/DSP58=0, loops/latches/black boxes=0, exact
  41 RAMB36, setup WNS `+5.390 ns`.
- Post-route: WNS/WHS `+0.045/+0.010 ns`; fully routed; zero route errors;
  zero DRC and methodology violations; zero constraint-coverage failures;
  zero loops, latches and black boxes; DSP48/DSP58=0.
- Post-route RAM hierarchy is exactly 32 activation + 4 bias + 3 LayerNorm +
  1 Softmax + 1 layer-table RAMB36, with RAMB18=0, URAM=0 and no named
  LayerNorm/Softmax LUTRAM fallback.
- Post-route utilization is 101,134/117,120 CLB LUT, 63,997 registers,
  5,521 CARRY8 and 14,547/14,640 CLBs (99.36%, 93 CLBs free).

## Generated artifacts

- OOC DCP: 32,307,867 bytes,
  `6d8a617b8fe33a7d9b37297226f24b23d7bb168e5606d1acf49c543b393467c5`.
- Board-synth DCP: 35,058,563 bytes,
  `59458d0a80211a5832f59f40968b13b85c1fd8a41a457ea4f2c0fc909569f974`.
- Routed DCP: 67,855,541 bytes,
  `73c5ee9861774e3dc9fb09d44b72953ca9e05b5bbc1d47f0f8bbc2f14f44c409`.
- BIT: 7,797,814 bytes,
  `462d78a91d9fb35b2cb5832ab222c39952a1052d3ff6766d94e37405f887a275`.
- XSA: 3,855,492 bytes,
  `47e764324d9eaedcc343b3cdf66190dbb90635cf8e51b4f6e65b4746c43680ee`.

The independent ZIP replay passes. The XSA contains exactly one BIT and the
canonical HWH set `vit_system.hwh`,
`vit_system_smartconnect_control_0.hwh` and
`vit_system_smartconnect_ddr_0.hwh`; its embedded BIT is byte-identical to the
external BIT.

## Receipt integrity

`remote_snapshot/` contains 1,193 exact remote files (583,642,787 bytes): all
409 development inputs, all 84 collector-bound outputs, the six prerequisite
receipts needed for a self-contained strict replay, raw `OUTER.*`, project/BD
identity, generated run logs, authoritative reports, DCPs, BIT and XSA.

The server revision was quiescent before the final snapshot audit. Remote
access was read-only. Remote-to-local SHA-256 comparison passes for all 1,193
files. `REMOTE_SNAPSHOT_SHA256SUMS.txt` has SHA-256
`9cb13a07c059730f36c1e70634657a465e2e7953790e4476da2459d997e4cc29`.

`RECEIPT_SHA256SUMS.txt` binds every receipt file except itself and the
one-line `RECEIPT_MANIFEST.sha256` pointer. The digest in that pointer is the
external receipt anchor. Run `./verify_receipt.sh` from any directory to
replay receipt closure, source identity, strict verification, all flow gates,
artifact hashes and XSA/BIT equality.

