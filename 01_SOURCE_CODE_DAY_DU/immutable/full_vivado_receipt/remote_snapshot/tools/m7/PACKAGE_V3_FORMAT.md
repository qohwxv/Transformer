# M7 package v3: mixed FP32 and packed blocked-B FP16

Status: package-generation contract for M7.1. This document does not claim
RTL integration, full-model numerical equivalence, synthesis, implementation,
BIT/XSA, or board performance.

## Scope

Package v3 is derived only from the hash-pinned canonical package v2. It:

- converts the 74 persistent `WEIGHT_B` tensors from FP32 to binary16 using
  round-to-nearest, ties-to-even, gradual underflow, signed zero, and canonical
  positive qNaN `0x7E00`;
- stores blocked weights as `[N_TILE][K_CHUNK][LANE][COL]`;
- packs `COL=0` in bits `[15:0]` and `COL=1` in bits `[31:16]` of one
  little-endian u32 for each lane;
- keeps the other 126 model tensors byte-exact FP32;
- keeps `prepared_input.bin` byte-exact FP32;
- requires scratch and dynamic QK/PV matrices to remain FP32 row-major in the
  first M7 integration gate.

The canonical parent identity is the v2 hash manifest
`d5686ff0b19b9703817744affdb0ee89a1ca65dda8af64e68e7712fc83570d18`.

## Binary table

The table topology is unchanged: a 128-byte header followed by 200 entries of
64 bytes, for a total of 12,928 bytes. The table version is `3.0`; header dtype
code `2` means mixed storage by entry.

- `word_offset` and `word_count` are physical u32 storage-container units for
  every entry. This preserves the MODEL_WORDS and AXI bounds unit.
- `dims` remain logical tensor dimensions.
- layout ID `5` identifies
  `GEMM_B_BLOCKED_K16_N2_FP16_PACKED2`.
- entry flag bit 8 (`0x00000100`) identifies two packed FP16 values per u32;
  the existing `WEIGHT_B` and blocked-B flags are retained.
- `tensor_crc32` covers stored bytes, not reconstructed FP32 values.
- the legacy header `source_words` field records the original logical scalar
  population, while `storage_words` records physical u32 containers.

The JSON sidecar makes logical element count, stored u32 count, dtype,
quantization, layout, and parent identity explicit for every tensor.

## Geometry and address contract

For logical `B[K][N]`:

```text
n_tile  = n / 2
k_chunk = k / 16
lane    = k % 16
col     = n % 2

u32_index = ((n_tile * ceil(K/16) + k_chunk) * 16) + lane
half_select = col                 # 0 = low16, 1 = high16
```

One K16/N2 block contains 32 FP16 values in 16 u32 words, or 64 bytes. With
128-byte tensor and MODEL_BASE alignment, every block begins on a 64-byte
boundary and therefore remains wholly inside one 4 KiB page. The later AXI
integration must still retain region and 4 KiB clamps.

Canonical geometry:

| Item | Value |
|---|---:|
| tensors | 200 |
| packed FP16 weight tensors | 74 |
| unchanged FP32 tensors | 126 |
| blocked FP16 values including production block slots | 86,292,480 |
| blocked-weight storage u32 | 43,146,240 |
| unchanged FP32 storage u32 | 275,176 |
| inter-tensor zero padding u32 | 24 |
| total MODEL_WORDS | 43,421,440 |
| model bytes | 173,685,760 |
| 64-byte blocks checked | 2,696,640 |

Runtime execution mode is `3`: bit 0 selects blocked K16/N2 model B and bit 1
selects packed FP16 model B. Physical DDR base addresses remain external to
the portable package.

## Reproduction

From the repository root:

```bash
python3 -m unittest discover \
  -s vivado_server_307_perf_v1_m7_fp16_parallel_overlap_2023_2/tools/m7/tests \
  -p 'test_blocked_b_fp16_v3.py' -v

python3 vivado_server_307_perf_v1_m7_fp16_parallel_overlap_2023_2/tools/m7/pack_vit_blocked_b_fp16_v3.py

python3 vivado_server_307_perf_v1_m7_fp16_parallel_overlap_2023_2/tools/m7/verify_vit_blocked_b_fp16_v3.py
```

The packer refuses to overwrite an existing output directory. Preserve or
move an old package explicitly before regeneration.
