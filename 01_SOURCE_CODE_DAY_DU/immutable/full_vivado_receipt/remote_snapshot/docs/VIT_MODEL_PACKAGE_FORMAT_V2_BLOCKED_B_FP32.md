# ViT model package v2: blocked-B FP32

Status: `VERIFIED` package-format contract for M3. This document does not by
itself claim RTL simulation, synthesis, implementation, or board PASS.

## Purpose and compatibility boundary

Package v2 pre-packs the 74 persistent model tensors marked `WEIGHT_B` while
keeping every numerical value as its original 32-bit IEEE-754 bit pattern.
The 126 remaining model tensors and `prepared_input.bin` remain byte-exact
copies of package v1. Dynamic attention scratch operands (QK and PV) remain
row-major and are not part of the blocked package transformation.

Package v1 under `build/model_package/v1/` remains unchanged. M3 is pinned to
the following parent identity:

- parent manifest SHA-256:
  `12b3b0573f006f49f30fcb25a17d22f846a4f35ea7add1a1733be176b853a982`
- parent model SHA-256:
  `b573df09083b643150b2bdda990aec9f79ea8e51ded41980422f1534ffc8800e`
- parent table SHA-256:
  `6af25a98b2dfca525f8320bdd422cae31f3441dd407fa6cd507f02ef344b6380`
- input SHA-256:
  `3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54`

Pre-packing changes address order only. It does not reduce the number of B
data words fetched by the current GEMM schedule; it prepares contiguous
32-word blocks for later AXI burst work.

## Block layout

For a logical row-major B matrix `B[K][N]`, the stored order is:

```text
[N_TILE][K_CHUNK][COL][LANE]

N_TILE = n / 2
K_CHUNK = k / 16
COL = n % 2
LANE = k % 16
```

The stored word index is:

```text
((((n / 2) * ceil(K / 16) + (k / 16)) * 2 + (n % 2)) * 16
 + (k % 16))
```

Each complete block contains 32 FP32 words, or 128 bytes. Zero words are used
for K16/N2 tails. All 74 production weight tensors have K divisible by 16 and
N divisible by 2, so this package has no internal block-tail padding.

This binary layout is fixed to `PE_LANES=16` and `ARRAY_COLS=2`. Those are the
current production defaults. The RTL parameters are not a portable package
descriptor and there is currently no elaboration/START assertion that rejects
a different geometry. Therefore a build that overrides either parameter must
not consume this package until it has a correspondingly versioned layout and
verifier.

## Binary-table contract

The 128-byte header and 64-byte entry structs remain structurally compatible
with package v1. Their v2 semantics are:

| Field | v2 value / meaning |
| --- | --- |
| table version | `2.0` |
| tensor count | `200` |
| alignment | `128` bytes |
| source words | `86,567,656` logical FP32 words |
| storage words | `86,567,680` words including inter-tensor alignment |
| model bytes | `346,270,720` |
| blocked layout ID | `4` (`GEMM_B_BLOCKED_K16_N2`) |
| blocked entry flag | `0x00000080` in addition to existing tensor flags |
| table header flags | unchanged `0x0000001F` |

For v2 entries, `word_count` is the stored extent. The four `dims` fields
continue to describe the logical tensor shape. The JSON table records both
logical and stored word counts/shapes explicitly.

All tensor starts are 128-byte aligned. A physical `MODEL_BASE` must also be
128-byte aligned. Therefore each 128-byte B block is wholly contained within
one 4 KiB page. Relative addresses remain FP32-word offsets, not byte offsets.

The current scalar AXI adapter rejects a base that is not 4-byte aligned, but
it does not enforce the stronger 128-byte package requirement. Software must
enforce `MODEL_BASE[6:0] == 0`. A merely word-aligned base does not invalidate
the current one-beat address mapping, but it invalidates the package's 4 KiB
boundary guarantee and is not safe for a later 32-beat burst implementation.

Package geometry:

- 74 blocked tensors, 86,292,480 words, 2,696,640 complete blocks;
- 126 unchanged tensors, 275,176 words;
- 24 zero alignment words;
- 200 tensors total.

The eight global parameter offsets remain unchanged. Encoder layer 0 begins
at word offset `0x00171700`; subsequent encoder layer bases advance by
`0x006C2700` words.

## Runtime selection

The complete AXI-Lite programming contract for package v2 requires:

```text
EXECUTION_MODE[0] = 1
MODEL_WORDS       = 86,567,680
INPUT_WORDS       = 150,528
SCRATCH_WORDS     = 1,990,656 (`0x001E6000`)
MODEL_BASE        = 128-byte aligned
```

The execution mode must be selected before START and snapshotted with the job.
Only persistent `PHASE_E_TENSOR_WEIGHT` GEMM-B commands use the blocked flag.
Scratch QK/PV B matrices remain row-major.

The generated `vit_runtime_config.json` records `execution_mode`, all three
word limits (including `scratch_words=0x001E6000`), the 128-byte alignment
requirement and all global/layer offsets. The verifier requires those fields.
It deliberately does not contain physical DDR base addresses, so a board
loader must still allocate non-overlapping MODEL/INPUT/SCRATCH regions and
program their base registers before START.

## Generated artifact identities

Output directory: `build/model_package/v2_blocked_b_fp32/`.

| Artifact | SHA-256 |
| --- | --- |
| `vit_model.bin` | `7185df10b292534128c1a94bf211e498fe9a8bfc04975fc2eeaed29140fc7835` |
| `vit_model_table.bin` | `efb9a40ec02f956f1b73630162333495d92b6db614af52ce9942d32e1c31e6cf` |
| `prepared_input.bin` | `3e13bd9bf60b07eb967a0c67aff1087954a316a403f70d220a6713cf8999ec54` |
| `vit_model_table.json` | `d0c57dcec4b40082d2f48287c724547cea2c2897d6dbf09da5280f11f2bf683d` |
| `vit_runtime_config.json` | `318ddb74cdf586a5d936c0684ee62d1c251447a878a8e7720225425cf6baa6a7` |
| `hash_manifest.json` | `d5686ff0b19b9703817744affdb0ee89a1ca65dda8af64e68e7712fc83570d18` |

`verification_report.json` records `PASS` for 1,025 checks, all 200 tensors,
86,567,656 bit-exact logical words, and all 2,696,640 blocked 4 KiB boundary
checks. Its SHA-256 is
`437162b626966e4d1195cfd56dc3ae4ab62c161697e951810c807b3fd8b1b3fc`.

## Reproduction

From `vivado_server_307_perf_v1_m3_blocked_b_fp32_2023_2/tools/m3/`:

```bash
python3 -m unittest discover -s tests -p 'test_blocked_b_v2.py' -v
python3 pack_vit_blocked_b_v2.py \
  --v1-package ../../../build/model_package/v1 \
  --output-dir ../../../build/model_package/v2_blocked_b_fp32
python3 verify_vit_blocked_b_v2.py \
  --v1-package ../../../build/model_package/v1 \
  --package-dir ../../../build/model_package/v2_blocked_b_fp32
```

The packer refuses to overwrite an existing output directory. Remove or move
an old v2 output only as an explicit operator action after preserving any
needed evidence.
