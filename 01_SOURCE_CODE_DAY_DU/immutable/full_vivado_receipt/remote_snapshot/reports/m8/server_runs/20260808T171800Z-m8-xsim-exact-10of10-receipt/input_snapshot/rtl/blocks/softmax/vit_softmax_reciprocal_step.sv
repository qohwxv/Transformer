`timescale 1ns/1ps

// One registered-controller step of reciprocal Newton-Raphson:
// estimate_next = estimate * (2 - operand * estimate).
(* use_dsp = "no" *)
module vit_softmax_reciprocal_step (
    input  logic [31:0] operand,
    input  logic [31:0] estimate,
    output logic [31:0] next_estimate
);

    localparam logic [31:0] FP32_TWO = 32'h4000_0000;

    logic [31:0] operand_product;
    logic [31:0] correction;

    vit_fp32_mul_comb_nodsp u_operand_product (
        .a(operand), .b(estimate), .result(operand_product)
    );
    vit_fp32_sub_comb u_correction (
        .a(FP32_TWO), .b(operand_product), .result(correction)
    );
    vit_fp32_mul_comb_nodsp u_next_estimate (
        .a(estimate), .b(correction), .result(next_estimate)
    );

endmodule
