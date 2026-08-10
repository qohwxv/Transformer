`timescale 1ns/1ps

// Fabric-only binary16 multiplier with a binary32 result.
//
// M6 numerical contract:
//   * finite binary16 operands are multiplied exactly; their product fits in
//     the binary32 significand and exponent range without rounding;
//   * zero is preserved with the XOR product sign;
//   * gradual binary16 subnormal handling is the default; an explicit FTZ
//     parameter exists for a later speed/resource A/B and reports every flush;
//   * NaN and Inf*zero produce canonical binary32 qNaN;
//   * Inf times a finite non-zero operand produces signed binary32 Inf.
//
// The downstream dot accumulator preserves a single signed infinity, turns
// conflicting infinities into qNaN, and treats NaN as dot-level invalid.  No
// DSP primitive is permitted.
(* use_dsp = "no" *)
module vit_fp16_mul_to_fp32_comb_nodsp #(
    parameter integer FLUSH_SUBNORMALS = 0
) (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] result,
    output logic        nonfinite,
    output logic        result_is_nan,
    output logic        result_is_inf,
    output logic        result_inf_sign,
    output logic        subnormal_flushed
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

    logic        sign_result;
    logic [4:0]  exp_a;
    logic [4:0]  exp_b;
    logic [9:0]  frac_a;
    logic [9:0]  frac_b;
    logic        a_nan;
    logic        b_nan;
    logic        a_inf;
    logic        b_inf;
    logic        a_zero;
    logic        b_zero;
    logic        a_subnormal;
    logic        b_subnormal;
    logic        a_effective_zero;
    logic        b_effective_zero;
    logic [10:0] mantissa_a;
    logic [10:0] mantissa_b;
    (* use_dsp = "no" *) logic [21:0] mantissa_product;
    logic [7:0]  result_exponent;
    logic [22:0] result_fraction;
    logic [23:0] normalized_product;
    logic        found_leading_one;
    integer      scale_exponent_a;
    integer      scale_exponent_b;
    integer      leading_index;
    integer      result_exponent_integer;
    integer      scan_index;

    always_comb begin
        sign_result = a[15] ^ b[15];
        exp_a = a[14:10];
        exp_b = b[14:10];
        frac_a = a[9:0];
        frac_b = b[9:0];

        a_nan = (exp_a == 5'h1F) && (frac_a != 10'd0);
        b_nan = (exp_b == 5'h1F) && (frac_b != 10'd0);
        a_inf = (exp_a == 5'h1F) && (frac_a == 10'd0);
        b_inf = (exp_b == 5'h1F) && (frac_b == 10'd0);
        a_zero = (exp_a == 5'd0) && (frac_a == 10'd0);
        b_zero = (exp_b == 5'd0) && (frac_b == 10'd0);
        a_subnormal = (exp_a == 5'd0) && (frac_a != 10'd0);
        b_subnormal = (exp_b == 5'd0) && (frac_b != 10'd0);
        a_effective_zero =
            a_zero || ((FLUSH_SUBNORMALS != 0) && a_subnormal);
        b_effective_zero =
            b_zero || ((FLUSH_SUBNORMALS != 0) && b_subnormal);

        mantissa_a = (exp_a == 5'd0) ? {1'b0, frac_a} : {1'b1, frac_a};
        mantissa_b = (exp_b == 5'd0) ? {1'b0, frac_b} : {1'b1, frac_b};
        mantissa_product = mantissa_a * mantissa_b;
        result_exponent = 8'd0;
        result_fraction = 23'd0;
        normalized_product = 24'd0;
        found_leading_one = 1'b0;
        scale_exponent_a = (exp_a == 5'd0)
            ? -24
            : ({27'd0, exp_a} - 25);
        scale_exponent_b = (exp_b == 5'd0)
            ? -24
            : ({27'd0, exp_b} - 25);
        leading_index = 0;
        result_exponent_integer = 0;
        nonfinite = 1'b0;
        result_is_nan = 1'b0;
        result_is_inf = 1'b0;
        result_inf_sign = sign_result;
        subnormal_flushed =
            (FLUSH_SUBNORMALS != 0) && (a_subnormal || b_subnormal);

        for (scan_index = 21; scan_index >= 0; scan_index = scan_index - 1)
            if (!found_leading_one && mantissa_product[scan_index]) begin
                found_leading_one = 1'b1;
                leading_index = scan_index;
            end

        if (a_nan || b_nan ||
            ((a_inf || b_inf) &&
             (a_effective_zero || b_effective_zero))) begin
            result = FP32_QNAN;
            nonfinite = 1'b1;
            result_is_nan = 1'b1;
        end else if (a_inf || b_inf) begin
            result = {sign_result, 8'hFF, 23'd0};
            nonfinite = 1'b1;
            result_is_inf = 1'b1;
        end else if (a_effective_zero || b_effective_zero) begin
            result = {sign_result, 31'd0};
        end else begin
            // value = integer significand product * 2^(scale_a+scale_b).
            // Aligning its leading one to FP32 bit 23 is exact because the
            // product has no more than 22 significant bits.
            normalized_product =
                {{2{1'b0}}, mantissa_product} << (23 - leading_index);
            result_exponent_integer =
                scale_exponent_a + scale_exponent_b + leading_index + 127;
            result_exponent = result_exponent_integer[7:0];
            result_fraction = normalized_product[22:0];
            result = {sign_result, result_exponent, result_fraction};
        end
    end

endmodule
