`timescale 1ns/1ps

// Exact-erf-style GELU using the Abramowitz-Stegun 7.1.26 approximation.
// The arithmetic graph is intentionally visible as FP32 leaf instances so
// synthesis reports show the multiplier/addition cost instead of attributing
// one opaque cone to a package function.
(* use_dsp = "no" *)
module vit_fp32_gelu_comb (
    input  logic [31:0] value,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_QNAN       = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO   = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF    = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF    = 32'hff80_0000;
    localparam logic [31:0] FP32_ONE        = 32'h3f80_0000;
    localparam logic [31:0] FP32_HALF       = 32'h3f00_0000;
    localparam logic [31:0] GELU_INV_SQRT2  = 32'h3f35_04f3;
    localparam logic [31:0] GELU_P          = 32'h3ea7_ba05;
    localparam logic [31:0] GELU_A1         = 32'h3e82_7906;
    localparam logic [31:0] GELU_A2         = 32'hbe91_a98e;
    localparam logic [31:0] GELU_A3         = 32'h3fb5_f0e3;
    localparam logic [31:0] GELU_A4         = 32'hbfba_00e3;
    localparam logic [31:0] GELU_A5         = 32'h3f87_dc22;

    logic [31:0] absolute_value;
    logic [31:0] scaled_value;
    logic [31:0] p_scaled_value;
    logic [31:0] reciprocal_denominator;
    logic [31:0] reciprocal_term;
    logic [31:0] polynomial_mul_a5;
    logic [31:0] polynomial_a4;
    logic [31:0] polynomial_mul_a4;
    logic [31:0] polynomial_a3;
    logic [31:0] polynomial_mul_a3;
    logic [31:0] polynomial_a2;
    logic [31:0] polynomial_mul_a2;
    logic [31:0] polynomial_a1;
    logic [31:0] polynomial;
    logic [31:0] squared_value;
    logic [31:0] negative_squared_value;
    logic [31:0] exponential;
    logic [31:0] polynomial_exponential;
    logic [31:0] erf_unclamped;
    logic [31:0] erf_magnitude;
    logic [31:0] signed_erf;
    logic [31:0] one_plus_erf;
    logic [31:0] half_value;
    logic [31:0] finite_result;
    logic        value_is_nan;
    logic        value_is_zero;

    assign absolute_value = {1'b0, value[30:0]};
    assign negative_squared_value = {1'b1, squared_value[30:0]};
    assign value_is_nan = (value[30:23] == 8'hff) &&
                          (value[22:0] != 23'd0);
    assign value_is_zero = (value[30:0] == 31'd0);

    vit_fp32_mul_comb_nodsp u_scale (
        .a(absolute_value), .b(GELU_INV_SQRT2), .result(scaled_value)
    );
    vit_fp32_mul_comb_nodsp u_denominator_product (
        .a(GELU_P), .b(scaled_value), .result(p_scaled_value)
    );
    vit_fp32_add_comb u_denominator_add (
        .a(FP32_ONE), .b(p_scaled_value), .result(reciprocal_denominator)
    );
    vit_fp32_recip_comb u_reciprocal (
        .value(reciprocal_denominator), .result(reciprocal_term)
    );

    vit_fp32_mul_comb_nodsp u_polynomial_mul_a5 (
        .a(GELU_A5), .b(reciprocal_term), .result(polynomial_mul_a5)
    );
    vit_fp32_add_comb u_polynomial_add_a4 (
        .a(polynomial_mul_a5), .b(GELU_A4), .result(polynomial_a4)
    );
    vit_fp32_mul_comb_nodsp u_polynomial_mul_a4 (
        .a(polynomial_a4), .b(reciprocal_term), .result(polynomial_mul_a4)
    );
    vit_fp32_add_comb u_polynomial_add_a3 (
        .a(polynomial_mul_a4), .b(GELU_A3), .result(polynomial_a3)
    );
    vit_fp32_mul_comb_nodsp u_polynomial_mul_a3 (
        .a(polynomial_a3), .b(reciprocal_term), .result(polynomial_mul_a3)
    );
    vit_fp32_add_comb u_polynomial_add_a2 (
        .a(polynomial_mul_a3), .b(GELU_A2), .result(polynomial_a2)
    );
    vit_fp32_mul_comb_nodsp u_polynomial_mul_a2 (
        .a(polynomial_a2), .b(reciprocal_term), .result(polynomial_mul_a2)
    );
    vit_fp32_add_comb u_polynomial_add_a1 (
        .a(polynomial_mul_a2), .b(GELU_A1), .result(polynomial_a1)
    );
    vit_fp32_mul_comb_nodsp u_polynomial_final (
        .a(polynomial_a1), .b(reciprocal_term), .result(polynomial)
    );

    vit_fp32_mul_comb_nodsp u_square (
        .a(scaled_value), .b(scaled_value), .result(squared_value)
    );
    vit_fp32_exp_neg_comb u_exponential (
        .value(negative_squared_value), .result(exponential)
    );
    vit_fp32_mul_comb_nodsp u_polynomial_exponential (
        .a(polynomial), .b(exponential), .result(polynomial_exponential)
    );
    vit_fp32_sub_comb u_erf_subtract (
        .a(FP32_ONE), .b(polynomial_exponential), .result(erf_unclamped)
    );

    always_comb begin
        if (erf_unclamped[31])
            erf_magnitude = FP32_POS_ZERO;
        else if (erf_unclamped[30:0] > FP32_ONE[30:0])
            erf_magnitude = FP32_ONE;
        else
            erf_magnitude = erf_unclamped;
    end

    assign signed_erf = value[31] ?
                        {1'b1, erf_magnitude[30:0]} :
                        erf_magnitude;

    vit_fp32_add_comb u_one_plus_erf (
        .a(FP32_ONE), .b(signed_erf), .result(one_plus_erf)
    );
    vit_fp32_mul_comb_nodsp u_half_value (
        .a(FP32_HALF), .b(value), .result(half_value)
    );
    vit_fp32_mul_comb_nodsp u_result (
        .a(half_value), .b(one_plus_erf), .result(finite_result)
    );

    always_comb begin
        if (value_is_nan || (value == FP32_NEG_INF))
            result = FP32_QNAN;
        else if (value == FP32_POS_INF)
            result = FP32_POS_INF;
        else if (value_is_zero)
            result = FP32_POS_ZERO;
        else
            result = finite_result;
    end

endmodule
