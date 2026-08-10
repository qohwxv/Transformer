`timescale 1ns/1ps

// Positive finite reciprocal with four explicitly instantiated Newton-Raphson
// refinements.  The hierarchy exposes the exact arithmetic cost.
module vit_fp32_recip_comb (
    input  logic [31:0] value,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;
    localparam logic [31:0] FP32_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_INF  = 32'h7f80_0000;
    localparam logic [31:0] FP32_TWO  = 32'h4000_0000;
    localparam logic [31:0] RECIP_MAGIC = 32'h7ef3_11c3;

    logic [31:0] estimate_0;
    logic [31:0] product_0;
    logic [31:0] correction_0;
    logic [31:0] estimate_1;
    logic [31:0] product_1;
    logic [31:0] correction_1;
    logic [31:0] estimate_2;
    logic [31:0] product_2;
    logic [31:0] correction_2;
    logic [31:0] estimate_3;
    logic [31:0] product_3;
    logic [31:0] correction_3;
    logic [31:0] estimate_4;
    logic value_nan;
    logic value_zero;

    assign value_nan = (value[30:23] == 8'hff) &&
                       (value[22:0] != 23'd0);
    assign value_zero = (value[30:0] == 31'd0);
    assign estimate_0 = RECIP_MAGIC - value;

    vit_fp32_mul_comb_nodsp u_product_0 (
        .a(value), .b(estimate_0), .result(product_0)
    );
    vit_fp32_sub_comb u_correction_0 (
        .a(FP32_TWO), .b(product_0), .result(correction_0)
    );
    vit_fp32_mul_comb_nodsp u_estimate_1 (
        .a(estimate_0), .b(correction_0), .result(estimate_1)
    );

    vit_fp32_mul_comb_nodsp u_product_1 (
        .a(value), .b(estimate_1), .result(product_1)
    );
    vit_fp32_sub_comb u_correction_1 (
        .a(FP32_TWO), .b(product_1), .result(correction_1)
    );
    vit_fp32_mul_comb_nodsp u_estimate_2 (
        .a(estimate_1), .b(correction_1), .result(estimate_2)
    );

    vit_fp32_mul_comb_nodsp u_product_2 (
        .a(value), .b(estimate_2), .result(product_2)
    );
    vit_fp32_sub_comb u_correction_2 (
        .a(FP32_TWO), .b(product_2), .result(correction_2)
    );
    vit_fp32_mul_comb_nodsp u_estimate_3 (
        .a(estimate_2), .b(correction_2), .result(estimate_3)
    );

    vit_fp32_mul_comb_nodsp u_product_3 (
        .a(value), .b(estimate_3), .result(product_3)
    );
    vit_fp32_sub_comb u_correction_3 (
        .a(FP32_TWO), .b(product_3), .result(correction_3)
    );
    vit_fp32_mul_comb_nodsp u_estimate_4 (
        .a(estimate_3), .b(correction_3), .result(estimate_4)
    );

    always_comb begin
        if (value_nan || value[31])
            result = FP32_QNAN;
        else if (value == FP32_INF)
            result = FP32_ZERO;
        else if (value_zero)
            result = FP32_INF;
        else
            result = estimate_4;
    end

endmodule
