`timescale 1ns/1ps

// Backward-compatible name retained for existing unit benches and external
// filelists.  The implementation now lives in the structured GEMM hierarchy.
module vit_tree_pe_fp32 (
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

    vit_gemm_pe u_structured_pe (
        .clk               (clk),
        .rst               (rst),
        .clear_accumulator (clear_accumulator),
        .step_valid        (step_valid),
        .finish            (finish),
        .bias_enable       (bias_enable),
        .lane_valid        (lane_valid),
        .activation_lanes  (activation_lanes),
        .weight_lanes      (weight_lanes),
        .bias              (bias),
        .result            (result)
    );

endmodule
