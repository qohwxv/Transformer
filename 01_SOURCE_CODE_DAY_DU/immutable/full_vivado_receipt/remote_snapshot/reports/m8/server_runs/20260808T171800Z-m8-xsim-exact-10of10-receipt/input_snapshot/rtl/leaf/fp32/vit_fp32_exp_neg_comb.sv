`timescale 1ns/1ps

// exp(value) for value <= 0 using ln(2) range reduction and a degree-eight
// Horner polynomial.  Every add and multiply is an explicit leaf instance.
module vit_fp32_exp_neg_comb (
    input  logic [31:0] value,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_QNAN    = 32'h7fc0_0000;
    localparam logic [31:0] FP32_ZERO    = 32'h0000_0000;
    localparam logic [31:0] FP32_ONE     = 32'h3f80_0000;
    localparam logic [31:0] FP32_NEG_INF = 32'hff80_0000;
    localparam logic [31:0] EXP_LN2      = 32'h3f31_7218;
    localparam logic [31:0] EXP_INV_LN2  = 32'h3fb8_aa3b;
    localparam logic [31:0] EXP_C8       = 32'h37d0_0d01;
    localparam logic [31:0] EXP_C7       = 32'hb950_0d01;
    localparam logic [31:0] EXP_C6       = 32'h3ab6_0b61;
    localparam logic [31:0] EXP_C5       = 32'hbc08_8889;
    localparam logic [31:0] EXP_C4       = 32'h3d2a_aaab;
    localparam logic [31:0] EXP_C3       = 32'hbe2a_aaab;
    localparam logic [31:0] EXP_C2       = 32'h3f00_0000;
    localparam logic [31:0] EXP_C1       = 32'hbf80_0000;
    localparam logic [31:0] EXP_C0       = 32'h3f80_0000;

    logic [31:0] magnitude;
    logic [31:0] scaled;
    logic [31:0] scale_integer_initial;
    logic [31:0] scale_integer_after_negative;
    logic [31:0] scale_integer_final;
    logic [31:0] scale_fp_initial;
    logic [31:0] scale_fp_after_negative;
    logic [31:0] scale_product_initial;
    logic [31:0] scale_product_after_negative;
    logic [31:0] remainder_initial;
    logic [31:0] remainder_negative_candidate;
    logic [31:0] remainder_after_negative;
    logic [31:0] remainder_positive_candidate;
    logic [31:0] remainder_final;
    logic        correct_negative_bin;
    logic        correct_positive_bin;

    logic [31:0] polynomial_mul_7;
    logic [31:0] polynomial_7;
    logic [31:0] polynomial_mul_6;
    logic [31:0] polynomial_6;
    logic [31:0] polynomial_mul_5;
    logic [31:0] polynomial_5;
    logic [31:0] polynomial_mul_4;
    logic [31:0] polynomial_4;
    logic [31:0] polynomial_mul_3;
    logic [31:0] polynomial_3;
    logic [31:0] polynomial_mul_2;
    logic [31:0] polynomial_2;
    logic [31:0] polynomial_mul_1;
    logic [31:0] polynomial_1;
    logic [31:0] polynomial_mul_0;
    logic [31:0] polynomial_0;
    logic [31:0] scaled_polynomial;

    logic value_nan;
    logic value_zero;

    assign magnitude = {1'b0, value[30:0]};
    assign value_nan = (value[30:23] == 8'hff) &&
                       (value[22:0] != 23'd0);
    assign value_zero = (value[30:0] == 31'd0);

    vit_fp32_mul_comb_nodsp u_scale_multiply (
        .a      (magnitude),
        .b      (EXP_INV_LN2),
        .result (scaled)
    );

    vit_fp32_to_u32_floor_comb u_scale_to_integer (
        .value  (scaled),
        .result (scale_integer_initial)
    );

    vit_fp32_from_u32_comb u_initial_integer_to_float (
        .value  (scale_integer_initial),
        .result (scale_fp_initial)
    );

    vit_fp32_mul_comb_nodsp u_initial_ln2_multiply (
        .a      (scale_fp_initial),
        .b      (EXP_LN2),
        .result (scale_product_initial)
    );

    vit_fp32_sub_comb u_initial_remainder (
        .a      (magnitude),
        .b      (scale_product_initial),
        .result (remainder_initial)
    );

    assign correct_negative_bin =
        remainder_initial[31] &&
        (remainder_initial[30:0] != 31'd0) &&
        (scale_integer_initial != 0);
    assign scale_integer_after_negative =
        correct_negative_bin ?
        (scale_integer_initial - 1'b1) :
        scale_integer_initial;

    vit_fp32_from_u32_comb u_corrected_integer_to_float (
        .value  (scale_integer_after_negative),
        .result (scale_fp_after_negative)
    );

    vit_fp32_mul_comb_nodsp u_corrected_ln2_multiply (
        .a      (scale_fp_after_negative),
        .b      (EXP_LN2),
        .result (scale_product_after_negative)
    );

    vit_fp32_sub_comb u_negative_corrected_remainder (
        .a      (magnitude),
        .b      (scale_product_after_negative),
        .result (remainder_negative_candidate)
    );

    assign remainder_after_negative =
        correct_negative_bin ?
        remainder_negative_candidate :
        remainder_initial;

    assign correct_positive_bin =
        !correct_negative_bin &&
        !remainder_after_negative[31] &&
        (remainder_after_negative[30:0] >= EXP_LN2[30:0]);
    assign scale_integer_final =
        correct_positive_bin ?
        (scale_integer_after_negative + 1'b1) :
        scale_integer_after_negative;

    vit_fp32_sub_comb u_positive_corrected_remainder (
        .a      (remainder_after_negative),
        .b      (EXP_LN2),
        .result (remainder_positive_candidate)
    );

    assign remainder_final =
        correct_positive_bin ?
        remainder_positive_candidate :
        remainder_after_negative;

    vit_fp32_mul_comb_nodsp u_poly_mul_7 (
        .a(remainder_final), .b(EXP_C8), .result(polynomial_mul_7)
    );
    vit_fp32_add_comb u_poly_add_7 (
        .a(EXP_C7), .b(polynomial_mul_7), .result(polynomial_7)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_6 (
        .a(remainder_final), .b(polynomial_7), .result(polynomial_mul_6)
    );
    vit_fp32_add_comb u_poly_add_6 (
        .a(EXP_C6), .b(polynomial_mul_6), .result(polynomial_6)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_5 (
        .a(remainder_final), .b(polynomial_6), .result(polynomial_mul_5)
    );
    vit_fp32_add_comb u_poly_add_5 (
        .a(EXP_C5), .b(polynomial_mul_5), .result(polynomial_5)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_4 (
        .a(remainder_final), .b(polynomial_5), .result(polynomial_mul_4)
    );
    vit_fp32_add_comb u_poly_add_4 (
        .a(EXP_C4), .b(polynomial_mul_4), .result(polynomial_4)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_3 (
        .a(remainder_final), .b(polynomial_4), .result(polynomial_mul_3)
    );
    vit_fp32_add_comb u_poly_add_3 (
        .a(EXP_C3), .b(polynomial_mul_3), .result(polynomial_3)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_2 (
        .a(remainder_final), .b(polynomial_3), .result(polynomial_mul_2)
    );
    vit_fp32_add_comb u_poly_add_2 (
        .a(EXP_C2), .b(polynomial_mul_2), .result(polynomial_2)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_1 (
        .a(remainder_final), .b(polynomial_2), .result(polynomial_mul_1)
    );
    vit_fp32_add_comb u_poly_add_1 (
        .a(EXP_C1), .b(polynomial_mul_1), .result(polynomial_1)
    );
    vit_fp32_mul_comb_nodsp u_poly_mul_0 (
        .a(remainder_final), .b(polynomial_1), .result(polynomial_mul_0)
    );
    vit_fp32_add_comb u_poly_add_0 (
        .a(EXP_C0), .b(polynomial_mul_0), .result(polynomial_0)
    );

    vit_fp32_scale_pow2_down_comb u_scale_down (
        .value  (polynomial_0),
        .amount (scale_integer_final),
        .result (scaled_polynomial)
    );

    always_comb begin
        if (value_nan)
            result = FP32_QNAN;
        else if (value == FP32_NEG_INF)
            result = FP32_ZERO;
        else if (value_zero)
            result = FP32_ONE;
        else if (!value[31])
            result = FP32_QNAN;
        else if (scale_integer_initial >= 32'd127)
            result = FP32_ZERO;
        else
            result = scaled_polynomial;
    end

endmodule
