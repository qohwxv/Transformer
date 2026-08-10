#!/usr/bin/env python3
"""Generate deterministic, dependency-free FP32->FP16 RNE oracle vectors."""

from __future__ import annotations

import argparse
import random
from pathlib import Path


FP16_QNAN = 0x7E00


def round_shift_rne(value: int, shift: int) -> int:
    if shift <= 0:
        return value << (-shift)
    quotient, remainder = divmod(value, 1 << shift)
    halfway = 1 << (shift - 1)
    if remainder > halfway or (remainder == halfway and (quotient & 1)):
        quotient += 1
    return quotient


def encode_half(sign: int, significand: int, exponent2: int) -> int:
    sign_field = sign << 15
    if significand == 0:
        return sign_field

    leading_exponent = significand.bit_length() - 1 + exponent2
    if leading_exponent >= -14:
        if leading_exponent > 15:
            return sign_field | 0x7C00
        retained = round_shift_rne(
            significand,
            -(exponent2 - leading_exponent + 10),
        )
        if retained == (1 << 11):
            retained >>= 1
            leading_exponent += 1
            if leading_exponent > 15:
                return sign_field | 0x7C00
        return sign_field | ((leading_exponent + 15) << 10) | (retained - 1024)

    subnormal = round_shift_rne(significand, -(exponent2 + 24))
    if subnormal == 0:
        return sign_field
    if subnormal >= 1024:
        return sign_field | 0x0400
    return sign_field | subnormal


def fp32_to_fp16(bits: int) -> int:
    sign = bits >> 31
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    if exponent == 0xFF:
        return (sign << 15) | 0x7C00 if fraction == 0 else FP16_QNAN
    if exponent == 0:
        if fraction == 0:
            return sign << 15
        return encode_half(sign, fraction, -149)
    return encode_half(sign, 0x800000 | fraction, exponent - 150)


DIRECTED = [
    0x00000000,
    0x80000000,
    0x00000001,
    0x33000000,
    0x33000001,
    0x33800000,
    0x387FC000,
    0x38800000,
    0x3F800000,
    0x3F801000,
    0x3F801001,
    0x477FEFFF,
    0x477FF000,
    0x7F7FFFFF,
    0x7F800000,
    0xFF800000,
    0x7F800001,
    0xFFC12345,
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--random-count", type=int, default=16384)
    args = parser.parse_args()

    rng = random.Random(0x4D375246503136)
    words = list(DIRECTED)
    words.extend(rng.getrandbits(32) for _ in range(args.random_count))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as handle:
        for word in words:
            handle.write(f"{word:08x} {fp32_to_fp16(word):04x}\n")
    print(f"M7_FP32_TO_FP16_ORACLE_VECTORS={len(words)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
