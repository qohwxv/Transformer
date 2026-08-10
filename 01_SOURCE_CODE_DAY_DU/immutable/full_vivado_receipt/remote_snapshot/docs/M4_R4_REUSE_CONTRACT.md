# M4-R4 production contract

This child is derived only from sealed M3 manifest
`dd08e62fbae12d136bada36605a59779da5659a2ee74b4854aadba54a100ae39`.

Geometry and identity:

- `ARRAY_ROWS=4`, `ARRAY_COLS=2`, `PE_LANES=16`;
- FP32 and model-package-v2 blocked-B bytes are unchanged;
- AXI/register/profile ABI is unchanged;
- `IP_VERSION=0x00010004` distinguishes M4-R4 from M3;
- post-route `DSP48/DSP58=0` remains mandatory.

Exact full-E05 scalar counter targets:

| Counter | Expected |
|---|---:|
| commands | 249 |
| logical reads | 13,310,291,912 |
| AXI AR/R | 4,547,264,216 |
| AXI AW/W/B | 59,130,368 |
| B bypass | 4,457,957,376 |
| cache lookup/hit/miss | 8,787,007,720 / 8,763,027,696 / 23,980,024 |
| A lookup/hit/miss | 8,782,821,888 / 8,758,926,576 / 23,895,312 |
| bias lookup/hit/miss | 4,185,832 / 4,101,120 / 84,712 |
| tile steps | 139,483,968 |
| valid/tail MAC slots | 17,563,828,224 / 290,119,680 |

The counter tolerance is zero before M5.  Physical promotion additionally
requires all 1,000 logits and 1,000 probabilities to match M3, no counter/
trace error or overflow, and job cycles below M3's 287,348,780,797 cycles.
