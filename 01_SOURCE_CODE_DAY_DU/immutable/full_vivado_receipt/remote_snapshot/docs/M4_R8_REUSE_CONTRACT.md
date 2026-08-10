# M4-R8 production contract

This child is derived only from accepted, sealed M4-R4 manifest
`bdff341bf387fd442249ece9af2f35d25a18394e38c69eef8ec51a93a3cb8fd6`.

Geometry and identity:

- `ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16`;
- FP32 and model-package-v2 blocked-B bytes are unchanged;
- AXI/register/profile ABI is unchanged;
- `IP_VERSION=0x00010005` distinguishes M4-R8 from M4-R4;
- post-route `DSP48/DSP58=0` remains mandatory.

Exact full-E05 scalar counter targets:

| Counter | Expected |
|---|---:|
| commands | 249 |
| GEMM commands | 98 |
| logical reads | 11,079,900,104 |
| AXI AR/R | 2,318,964,440 |
| AXI AW/W/B | 59,130,368 |
| total AXI word transactions | 2,378,094,808 |
| B bypass | 2,229,657,600 |
| cache lookup/hit/miss | 8,784,915,688 / 8,760,935,664 / 23,980,024 |
| A lookup/hit/miss | 8,782,821,888 / 8,758,926,576 / 23,895,312 |
| bias lookup/hit/miss | 2,093,800 / 2,009,088 / 84,712 |
| GEMM AXI reads | 2,253,637,624 |
| GEMM writes | 23,895,544 |
| non-GEMM reads/writes | 65,326,816 / 35,234,824 |
| tile steps | 69,763,200 |
| valid/tail MAC slots | 17,563,828,224 / 295,550,976 |
| A+bias cache payload | 110,592 bytes (108 KiB) |

The geometry bound to those values is exactly `R=8`, `C=2`, `L=16`.  The
machine-readable object in `BUNDLE_INFO.json` carries every field emitted by
`tools/m4/vit_m4_reuse_model.py`, not merely the aggregate read totals.  The
combined, A-only and bias-only lookup partitions and the AXI transaction
partitions must each be internally exact.

The counter tolerance is zero before M5.  Physical promotion additionally
requires all 1,000 logits and 1,000 probabilities to match accepted R4 and no
counter/trace error or overflow. The cycle decision is exact:

- `job_cycles <= 165,436,617,657`: at least 5% faster, eligible to `PROMOTE`;
- `165,436,617,658..174,143,808,059`: functional/performance PASS but `HOLD`;
- `job_cycles >= 174,143,808,060`: no R8 gain, `REJECT`.
