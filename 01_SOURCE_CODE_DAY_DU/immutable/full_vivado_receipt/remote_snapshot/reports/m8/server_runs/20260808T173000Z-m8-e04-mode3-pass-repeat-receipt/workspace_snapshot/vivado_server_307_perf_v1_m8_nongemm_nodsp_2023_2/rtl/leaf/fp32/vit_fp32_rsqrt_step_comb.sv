`timescale 1ns/1ps

// One Newton-Raphson reciprocal-square-root step:
// y_next = y * (1.5 - 0.5 * x * y * y)
module vit_fp32_rsqrt_step_comb (
    input  logic [31:0] operand,
    input  logic [31:0] estimate,
    output logic [31:0] next_estimate
);

    localparam logic [31:0] FP32_HALF     = 32'h3f00_0000;
    localparam logic [31:0] FP32_ONE_HALF = 32'h3fc0_0000;

    logic [31:0] estimate_squared;
    logic [31:0] operand_product;
    logic [31:0] scaled_product;
    logic [31:0] correction;

    vit_fp32_mul_comb_nodsp u_square (
        .a(estimate), .b(estimate), .result(estimate_squared)
    );
    vit_fp32_mul_comb_nodsp u_operand_product (
        .a(operand), .b(estimate_squared), .result(operand_product)
    );
    vit_fp32_mul_comb_nodsp u_half_product (
        .a(FP32_HALF), .b(operand_product), .result(scaled_product)
    );
    vit_fp32_sub_comb u_correction (
        .a(FP32_ONE_HALF), .b(scaled_product), .result(correction)
    );
    vit_fp32_mul_comb_nodsp u_next_estimate (
        .a(estimate), .b(correction), .result(next_estimate)
    );

endmodule
