#!/usr/bin/env python3
"""Canonical ViT-Base/16 parameter schema and binary table constants."""

from __future__ import annotations

import struct
from dataclasses import dataclass


ALIGNMENT_BYTES = 64
ALIGNMENT_WORDS = ALIGNMENT_BYTES // 4
EXPECTED_TENSOR_COUNT = 200
EXPECTED_SOURCE_WORDS = 86_567_656
EXPECTED_STORAGE_WORDS = 86_567_664
EXPECTED_MODEL_BYTES = EXPECTED_STORAGE_WORDS * 4
EXPECTED_INPUT_WORDS = 150_528

TABLE_MAGIC = b"VITMTBL\x00"
TABLE_MAJOR = 1
TABLE_MINOR = 0
TABLE_HEADER_BYTES = 128
TABLE_ENTRY_BYTES = 64
TABLE_ENDIAN_LITTLE = 1
TABLE_DTYPE_FP32_BITS = 1
TABLE_CRC32_ISO_HDLC = 1
TABLE_FLAGS = 0x0000_001F

# 128-byte header:
# magic, major/minor, seven u32 values, five u64 values, four u32 values,
# and the SHA-256 of the complete model payload including zero padding.
TABLE_HEADER_STRUCT = struct.Struct("<8sHH7I5Q4I32s")

# 64-byte entry:
# id, group, layer, slot, name hash, word offset/count, rank/layout,
# four dimensions, tensor CRC32, flags.
TABLE_ENTRY_STRUCT = struct.Struct("<IHBBQQQ" + "I" * 8)

GROUP_GLOBAL = 0
GROUP_ENCODER = 1
GLOBAL_LAYER_SENTINEL = 0xFF

LAYOUT_VECTOR = 1
LAYOUT_ROW_MAJOR = 2
LAYOUT_GEMM_B_KN = 3

FLAG_WEIGHT_B = 1 << 0
FLAG_BIAS = 1 << 1
FLAG_GAMMA = 1 << 2
FLAG_BETA = 1 << 3
FLAG_EMBEDDING = 1 << 4
FLAG_FINAL = 1 << 5
FLAG_ENCODER = 1 << 6


@dataclass(frozen=True)
class TensorSpec:
    tensor_id: int
    group: int
    layer: int
    slot: int
    role: str
    filename: str
    word_count: int
    shape: tuple[int, ...]
    layout: int
    flags: int

    @property
    def rank(self) -> int:
        return len(self.shape)

    @property
    def padded_shape(self) -> tuple[int, int, int, int]:
        return (*self.shape, *(0 for _ in range(4 - self.rank)))


def _flags(filename: str, *, group: int) -> int:
    value = FLAG_ENCODER if group == GROUP_ENCODER else 0
    if filename.startswith("embedding_"):
        value |= FLAG_EMBEDDING
    if filename.startswith("post_encoder_"):
        value |= FLAG_FINAL
    if "_weight_B_" in filename:
        value |= FLAG_WEIGHT_B
    if "_bias_" in filename:
        value |= FLAG_BIAS
    if "_gamma_" in filename:
        value |= FLAG_GAMMA
    if "_beta_" in filename:
        value |= FLAG_BETA
    return value


GLOBAL_DEFINITIONS = (
    (
        "patch_weight_base",
        "embedding_patch_weight_B_f32.hex",
        589_824,
        (768, 768),
        LAYOUT_GEMM_B_KN,
    ),
    (
        "patch_bias_base",
        "embedding_patch_bias_f32.hex",
        768,
        (768,),
        LAYOUT_VECTOR,
    ),
    (
        "cls_base",
        "embedding_cls_token_f32.hex",
        768,
        (768,),
        LAYOUT_VECTOR,
    ),
    (
        "position_base",
        "embedding_position_f32.hex",
        151_296,
        (197, 768),
        LAYOUT_ROW_MAJOR,
    ),
    (
        "final_ln_gamma_base",
        "post_encoder_final_ln_gamma_f32.hex",
        768,
        (768,),
        LAYOUT_VECTOR,
    ),
    (
        "final_ln_beta_base",
        "post_encoder_final_ln_beta_f32.hex",
        768,
        (768,),
        LAYOUT_VECTOR,
    ),
    (
        "classifier_weight_base",
        "post_encoder_classifier_weight_B_f32.hex",
        768_000,
        (768, 1000),
        LAYOUT_GEMM_B_KN,
    ),
    (
        "classifier_bias_base",
        "post_encoder_classifier_bias_f32.hex",
        1_000,
        (1000,),
        LAYOUT_VECTOR,
    ),
)

LAYER_DEFINITIONS = (
    ("ln1_gamma_base", "ln_before_gamma", 768, (768,), LAYOUT_VECTOR),
    ("ln1_beta_base", "ln_before_beta", 768, (768,), LAYOUT_VECTOR),
    ("q_weight_base", "q_weight_B", 589_824, (768, 768), LAYOUT_GEMM_B_KN),
    ("q_bias_base", "q_bias", 768, (768,), LAYOUT_VECTOR),
    ("k_weight_base", "k_weight_B", 589_824, (768, 768), LAYOUT_GEMM_B_KN),
    ("k_bias_base", "k_bias", 768, (768,), LAYOUT_VECTOR),
    ("v_weight_base", "v_weight_B", 589_824, (768, 768), LAYOUT_GEMM_B_KN),
    ("v_bias_base", "v_bias", 768, (768,), LAYOUT_VECTOR),
    ("o_weight_base", "o_weight_B", 589_824, (768, 768), LAYOUT_GEMM_B_KN),
    ("o_bias_base", "o_bias", 768, (768,), LAYOUT_VECTOR),
    ("ln2_gamma_base", "ln_after_gamma", 768, (768,), LAYOUT_VECTOR),
    ("ln2_beta_base", "ln_after_beta", 768, (768,), LAYOUT_VECTOR),
    (
        "fc1_weight_base",
        "fc1_weight_B",
        2_359_296,
        (768, 3072),
        LAYOUT_GEMM_B_KN,
    ),
    ("fc1_bias_base", "fc1_bias", 3_072, (3072,), LAYOUT_VECTOR),
    (
        "fc2_weight_base",
        "fc2_weight_B",
        2_359_296,
        (3072, 768),
        LAYOUT_GEMM_B_KN,
    ),
    ("fc2_bias_base", "fc2_bias", 768, (768,), LAYOUT_VECTOR),
)


def tensor_specs() -> tuple[TensorSpec, ...]:
    specs: list[TensorSpec] = []
    for slot, (role, filename, words, shape, layout) in enumerate(
        GLOBAL_DEFINITIONS
    ):
        specs.append(
            TensorSpec(
                tensor_id=slot,
                group=GROUP_GLOBAL,
                layer=GLOBAL_LAYER_SENTINEL,
                slot=slot,
                role=role,
                filename=filename,
                word_count=words,
                shape=shape,
                layout=layout,
                flags=_flags(filename, group=GROUP_GLOBAL),
            )
        )

    for layer in range(12):
        for slot, (role, stem, words, shape, layout) in enumerate(
            LAYER_DEFINITIONS
        ):
            filename = f"encoder_layer_{layer:02d}_{stem}_f32.hex"
            specs.append(
                TensorSpec(
                    tensor_id=8 + layer * 16 + slot,
                    group=GROUP_ENCODER,
                    layer=layer,
                    slot=slot,
                    role=role,
                    filename=filename,
                    word_count=words,
                    shape=shape,
                    layout=layout,
                    flags=_flags(filename, group=GROUP_ENCODER),
                )
            )

    result = tuple(specs)
    assert len(result) == EXPECTED_TENSOR_COUNT
    assert sum(spec.word_count for spec in result) == EXPECTED_SOURCE_WORDS
    return result


def fnv1a64(text: str) -> int:
    value = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def align_words(word_offset: int) -> int:
    return (word_offset + ALIGNMENT_WORDS - 1) & ~(ALIGNMENT_WORDS - 1)


def layout_name(layout: int) -> str:
    return {
        LAYOUT_VECTOR: "VECTOR",
        LAYOUT_ROW_MAJOR: "ROW_MAJOR",
        LAYOUT_GEMM_B_KN: "GEMM_B_KN",
    }[layout]
