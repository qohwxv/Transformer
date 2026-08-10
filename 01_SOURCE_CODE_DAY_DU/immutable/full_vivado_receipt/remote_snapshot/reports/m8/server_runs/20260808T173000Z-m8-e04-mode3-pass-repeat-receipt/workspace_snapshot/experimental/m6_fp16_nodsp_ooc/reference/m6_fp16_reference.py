#!/usr/bin/env python3
"""Bit-exact, dependency-free numerical reference for the M6 FP16 OOC work.

The arithmetic is expressed with Python integers.  It deliberately does not
use the host's half-precision implementation for its answers.

Two operand policies are supported:

``ftz=True``
    Decode an encoded binary16 subnormal as signed zero (DAZ).  This matches
    the RTL's explicit ``FLUSH_SUBNORMALS=1`` comparison mode.

``ftz=False``
    Decode binary16 subnormals gradually.  This is the preferred numerical
    reference for the exact fixed/Kulisch candidate.  A binary16 product then
    has an exact common fixed-point representation with LSB 2**-48.

All conversions and the final binary32 result use round-to-nearest,
ties-to-even (RNE).  NaNs are canonicalized.  The dot special-value policy is
documented by :func:`dot_fp16_exact`.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence


FP16_CANONICAL_QNAN = 0x7E00
FP32_CANONICAL_QNAN = 0x7FC00000
FP16_POS_INF = 0x7C00
FP16_NEG_INF = 0xFC00
FP32_POS_INF = 0x7F800000
FP32_NEG_INF = 0xFF800000

# Every finite binary16 value is an integer multiple of 2**-24.  Therefore
# every product is an integer multiple of 2**-48, including products of two
# gradual subnormals.
KULISCH_LSB_EXP = -48
DEFAULT_ACC_WIDTH = 93


@dataclass(frozen=True)
class DecodedBinary:
    """An exact decoded floating-point value.

    For ``kind == 'finite'``, the magnitude is
    ``significand * 2**exponent2``.  Zero, infinity, and NaN carry no finite
    significand.  ``encoded_subnormal`` remains true even if DAZ converts the
    operand to zero.
    """

    kind: str
    sign: int
    significand: int = 0
    exponent2: int = 0
    encoded_subnormal: bool = False
    flushed: bool = False


@dataclass(frozen=True)
class ProductResult:
    """Exact result of one M6 binary16 multiplication."""

    fp32_bits: int
    kind: str
    sign: int
    fixed_int: int | None
    subnormal_flushed: bool


@dataclass(frozen=True)
class DotResult:
    """Result of a dot product accumulated exactly at LSB 2**-48."""

    fp32_bits: int
    kind: str
    sign: int
    fixed_sum: int | None
    term_count: int
    flushed_operand_count: int


def _check_unsigned_bits(value: int, width: int, name: str) -> int:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an int")
    if value < 0 or value >= (1 << width):
        raise ValueError(f"{name} must fit in {width} bits")
    return value


def _round_shift_right_rne(value: int, shift: int) -> int:
    """Return ``round(value / 2**shift)`` using RNE for non-negative value."""

    if value < 0:
        raise ValueError("rounding helper accepts only non-negative values")
    if shift <= 0:
        return value << (-shift)
    quotient, remainder = divmod(value, 1 << shift)
    halfway = 1 << (shift - 1)
    if remainder > halfway or (remainder == halfway and (quotient & 1)):
        quotient += 1
    return quotient


def _scale_integer_rne(value: int, binary_shift: int) -> int:
    """RNE-scale non-negative ``value`` by an integral power of two."""

    if binary_shift >= 0:
        return value << binary_shift
    return _round_shift_right_rne(value, -binary_shift)


def _encode_finite_binary(
    sign: int,
    significand: int,
    exponent2: int,
    *,
    exponent_bits: int,
    fraction_bits: int,
    bias: int,
) -> int:
    """Encode ``significand * 2**exponent2`` with IEEE-style RNE.

    This helper supports gradual output underflow.  Overflow rounds to signed
    infinity.  ``significand`` is an arbitrary-precision non-negative integer.
    """

    if sign not in (0, 1):
        raise ValueError("sign must be zero or one")
    if significand < 0:
        raise ValueError("significand must be non-negative")

    sign_field_shift = exponent_bits + fraction_bits
    sign_field = sign << sign_field_shift
    if significand == 0:
        return sign_field

    max_exponent_field = (1 << exponent_bits) - 1
    min_normal_exponent = 1 - bias
    max_normal_exponent = (max_exponent_field - 1) - bias
    precision = fraction_bits + 1

    leading_exponent = significand.bit_length() - 1 + exponent2

    if leading_exponent >= min_normal_exponent:
        if leading_exponent > max_normal_exponent:
            return sign_field | (max_exponent_field << fraction_bits)

        # Retain ``precision`` leading bits and round all discarded bits once.
        retained = _scale_integer_rne(
            significand,
            exponent2 - leading_exponent + fraction_bits,
        )
        if retained == (1 << precision):
            retained >>= 1
            leading_exponent += 1
            if leading_exponent > max_normal_exponent:
                return sign_field | (max_exponent_field << fraction_bits)

        exponent_field = leading_exponent + bias
        fraction_field = retained - (1 << fraction_bits)
        return (
            sign_field
            | (exponent_field << fraction_bits)
            | fraction_field
        )

    # Subnormal output: its fixed unit is 2**(Emin-fraction_bits).
    subnormal = _scale_integer_rne(
        significand,
        exponent2 - min_normal_exponent + fraction_bits,
    )
    if subnormal == 0:
        return sign_field
    if subnormal >= (1 << fraction_bits):
        # Rounded across the gradual/normal boundary.
        return sign_field | (1 << fraction_bits)
    return sign_field | subnormal


def decode_fp16(bits: int, *, ftz: bool = False) -> DecodedBinary:
    """Decode a binary16 word exactly, optionally applying operand DAZ."""

    bits = _check_unsigned_bits(bits, 16, "binary16 bits")
    sign = (bits >> 15) & 1
    exponent = (bits >> 10) & 0x1F
    fraction = bits & 0x3FF

    if exponent == 0x1F:
        return DecodedBinary("nan" if fraction else "inf", sign)
    if exponent == 0:
        if fraction == 0:
            return DecodedBinary("zero", sign)
        if ftz:
            return DecodedBinary(
                "zero",
                sign,
                encoded_subnormal=True,
                flushed=True,
            )
        # binary16 gradual subnormal: fraction * 2**-24.
        return DecodedBinary(
            "finite",
            sign,
            fraction,
            -24,
            encoded_subnormal=True,
        )

    # (1024 + fraction) / 1024 * 2**(exponent-15).
    return DecodedBinary("finite", sign, 0x400 | fraction, exponent - 25)


def decode_fp32(bits: int) -> DecodedBinary:
    """Decode a binary32 word exactly, including gradual subnormals."""

    bits = _check_unsigned_bits(bits, 32, "binary32 bits")
    sign = (bits >> 31) & 1
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF

    if exponent == 0xFF:
        return DecodedBinary("nan" if fraction else "inf", sign)
    if exponent == 0:
        if fraction == 0:
            return DecodedBinary("zero", sign)
        return DecodedBinary(
            "finite",
            sign,
            fraction,
            -149,
            encoded_subnormal=True,
        )
    return DecodedBinary(
        "finite",
        sign,
        0x800000 | fraction,
        exponent - 150,
    )


def fp16_bits_to_fp32_bits(bits: int, *, ftz: bool = False) -> int:
    """Convert binary16 bits to canonical binary32 bits.

    The conversion is exact for every finite non-flushed binary16 operand.
    """

    decoded = decode_fp16(bits, ftz=ftz)
    if decoded.kind == "nan":
        return FP32_CANONICAL_QNAN
    if decoded.kind == "inf":
        return FP32_NEG_INF if decoded.sign else FP32_POS_INF
    if decoded.kind == "zero":
        return decoded.sign << 31
    return _encode_finite_binary(
        decoded.sign,
        decoded.significand,
        decoded.exponent2,
        exponent_bits=8,
        fraction_bits=23,
        bias=127,
    )


def fp32_bits_to_fp16_bits(bits: int) -> int:
    """Convert binary32 bits to binary16 using RNE and gradual underflow."""

    decoded = decode_fp32(bits)
    if decoded.kind == "nan":
        return FP16_CANONICAL_QNAN
    if decoded.kind == "inf":
        return FP16_NEG_INF if decoded.sign else FP16_POS_INF
    if decoded.kind == "zero":
        return decoded.sign << 15
    return _encode_finite_binary(
        decoded.sign,
        decoded.significand,
        decoded.exponent2,
        exponent_bits=5,
        fraction_bits=10,
        bias=15,
    )


def fixed_to_fp32_bits(fixed_value: int, *, zero_sign: int = 0) -> int:
    """Round an exact signed 2**-48 fixed value once to binary32."""

    if not isinstance(fixed_value, int):
        raise TypeError("fixed_value must be an int")
    if zero_sign not in (0, 1):
        raise ValueError("zero_sign must be zero or one")
    if fixed_value == 0:
        return zero_sign << 31
    sign = int(fixed_value < 0)
    return _encode_finite_binary(
        sign,
        abs(fixed_value),
        KULISCH_LSB_EXP,
        exponent_bits=8,
        fraction_bits=23,
        bias=127,
    )


def fp16_mul_to_fp32(
    a_bits: int,
    b_bits: int,
    *,
    ftz: bool = False,
) -> ProductResult:
    """Multiply two binary16 encodings and return an exact binary32 product.

    Special policy:

    * any NaN, or effective-zero times infinity -> canonical qNaN;
    * infinity times finite nonzero/infinity -> signed infinity;
    * zero products preserve the XOR product sign;
    * finite products are exact in binary32 and in the 2**-48 fixed domain.

    Under ``ftz=True``, a subnormal is an *effective* signed zero, so a
    subnormal times infinity is invalid and returns qNaN.
    """

    a = decode_fp16(a_bits, ftz=ftz)
    b = decode_fp16(b_bits, ftz=ftz)
    sign = a.sign ^ b.sign
    flushed = a.flushed or b.flushed

    if a.kind == "nan" or b.kind == "nan":
        return ProductResult(
            FP32_CANONICAL_QNAN, "nan", 0, None, flushed
        )
    if ((a.kind == "inf" and b.kind == "zero") or
            (b.kind == "inf" and a.kind == "zero")):
        return ProductResult(
            FP32_CANONICAL_QNAN, "nan", 0, None, flushed
        )
    if a.kind == "inf" or b.kind == "inf":
        return ProductResult(
            FP32_NEG_INF if sign else FP32_POS_INF,
            "inf",
            sign,
            None,
            flushed,
        )
    if a.kind == "zero" or b.kind == "zero":
        return ProductResult(sign << 31, "zero", sign, 0, flushed)

    fixed_shift = a.exponent2 + b.exponent2 - KULISCH_LSB_EXP
    if fixed_shift < 0:
        raise AssertionError("binary16 product fell below the 2**-48 grid")
    magnitude = (a.significand * b.significand) << fixed_shift
    fixed_int = -magnitude if sign else magnitude
    return ProductResult(
        fixed_to_fp32_bits(fixed_int),
        "finite",
        sign,
        fixed_int,
        flushed,
    )


def dot_fp16_exact(
    pairs: Iterable[tuple[int, int]],
    *,
    ftz: bool = False,
) -> DotResult:
    """Accumulate FP16 products exactly, then round once to FP32.

    The fixed accumulator has LSB 2**-48.  NaN and ``0*Inf`` are sticky and
    produce canonical qNaN.  A single infinity sign is preserved; observing
    both positive and negative infinite products produces canonical qNaN.
    An exactly cancelling finite sum returns positive zero.
    """

    total = 0
    term_count = 0
    flushed_operand_count = 0
    saw_nan = False
    saw_pos_inf = False
    saw_neg_inf = False

    for a_bits, b_bits in pairs:
        term_count += 1
        a_decoded = decode_fp16(a_bits, ftz=ftz)
        b_decoded = decode_fp16(b_bits, ftz=ftz)
        flushed_operand_count += int(a_decoded.flushed)
        flushed_operand_count += int(b_decoded.flushed)
        product = fp16_mul_to_fp32(a_bits, b_bits, ftz=ftz)
        if product.kind == "nan":
            saw_nan = True
        elif product.kind == "inf":
            if product.sign:
                saw_neg_inf = True
            else:
                saw_pos_inf = True
        elif product.fixed_int is not None:
            total += product.fixed_int

    if saw_nan or (saw_pos_inf and saw_neg_inf):
        return DotResult(
            FP32_CANONICAL_QNAN,
            "nan",
            0,
            None,
            term_count,
            flushed_operand_count,
        )
    if saw_pos_inf or saw_neg_inf:
        sign = int(saw_neg_inf)
        return DotResult(
            FP32_NEG_INF if sign else FP32_POS_INF,
            "inf",
            sign,
            None,
            term_count,
            flushed_operand_count,
        )

    kind = "zero" if total == 0 else "finite"
    sign = int(total < 0)
    return DotResult(
        fixed_to_fp32_bits(total),
        kind,
        sign,
        total,
        term_count,
        flushed_operand_count,
    )


def max_finite_product_fixed() -> int:
    """Return abs(max-FP16 * max-FP16) in the 2**-48 fixed domain."""

    product = fp16_mul_to_fp32(0x7BFF, 0x7BFF, ftz=False)
    if product.fixed_int is None:
        raise AssertionError("max finite product unexpectedly non-finite")
    return product.fixed_int


def kulisch_signed_width_for_terms(term_count: int) -> int:
    """Minimum two's-complement width for any sum of ``term_count`` products."""

    if not isinstance(term_count, int) or term_count < 0:
        raise ValueError("term_count must be a non-negative integer")
    max_sum = term_count * max_finite_product_fixed()
    # One sign bit in addition to all positive-magnitude bits.  Width one is
    # sufficient for the degenerate all-zero accumulator.
    return max(1, max_sum.bit_length() + 1)


def kulisch_terms_capacity(acc_width: int = DEFAULT_ACC_WIDTH) -> int:
    """Maximum all-positive max-product terms fitting in signed ``acc_width``."""

    if not isinstance(acc_width, int) or acc_width < 2:
        raise ValueError("acc_width must be an integer of at least two")
    return ((1 << (acc_width - 1)) - 1) // max_finite_product_fixed()


def result_to_dict(result: ProductResult | DotResult) -> dict[str, object]:
    """Return a stable JSON-compatible representation for vector generation."""

    if isinstance(result, ProductResult):
        return {
            "fp32_bits": f"0x{result.fp32_bits:08X}",
            "kind": result.kind,
            "sign": result.sign,
            "fixed_int": (
                None if result.fixed_int is None else str(result.fixed_int)
            ),
            "subnormal_flushed": result.subnormal_flushed,
        }
    if isinstance(result, DotResult):
        return {
            "fp32_bits": f"0x{result.fp32_bits:08X}",
            "kind": result.kind,
            "sign": result.sign,
            "fixed_sum": (
                None if result.fixed_sum is None else str(result.fixed_sum)
            ),
            "term_count": result.term_count,
            "flushed_operand_count": result.flushed_operand_count,
        }
    raise TypeError(f"unsupported result type: {type(result)!r}")


def dot_from_flat_words(
    activation_words: Sequence[int],
    weight_words: Sequence[int],
    *,
    ftz: bool = False,
) -> DotResult:
    """Convenience wrapper that rejects mismatched vector lengths."""

    if len(activation_words) != len(weight_words):
        raise ValueError("activation and weight vectors must have equal length")
    return dot_fp16_exact(zip(activation_words, weight_words), ftz=ftz)


__all__ = [
    "DEFAULT_ACC_WIDTH",
    "DecodedBinary",
    "DotResult",
    "FP16_CANONICAL_QNAN",
    "FP16_NEG_INF",
    "FP16_POS_INF",
    "FP32_CANONICAL_QNAN",
    "FP32_NEG_INF",
    "FP32_POS_INF",
    "KULISCH_LSB_EXP",
    "ProductResult",
    "decode_fp16",
    "decode_fp32",
    "dot_fp16_exact",
    "dot_from_flat_words",
    "fixed_to_fp32_bits",
    "fp16_bits_to_fp32_bits",
    "fp16_mul_to_fp32",
    "fp32_bits_to_fp16_bits",
    "kulisch_signed_width_for_terms",
    "kulisch_terms_capacity",
    "max_finite_product_fixed",
    "result_to_dict",
]
