`timescale 1ns/1ps

// One 16-lane output-stationary GEMM processing element.
module vit_gemm_pe (
    input  logic         clk,
    input  logic         rst,
    input  logic         clear_accumulator,
    input  logic         step_valid,
    input  logic         finish,
    input  logic         bias_enable,
    input  logic [15:0]  lane_valid,
    input  logic [511:0] activation_lanes,
    input  logic [511:0] weight_lanes,
    input  logic [31:0]  bias,
    output logic [31:0]  result
);

    logic [31:0]  dot_partial;

    vit_gemm_dot16 u_dot_product (
        .lane_valid       (lane_valid),
        .activation_lanes (activation_lanes),
        .weight_lanes     (weight_lanes),
        .partial_sum      (dot_partial)
    );

    vit_gemm_accumulator u_accumulator (
        .clk         (clk),
        .rst         (rst),
        .clear       (clear_accumulator),
        .step_valid  (step_valid),
        .finish      (finish),
        .bias_enable (bias_enable),
        .partial_sum (dot_partial),
        .bias        (bias),
        .result      (result)
    );

endmodule
