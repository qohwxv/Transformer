`timescale 1ns/1ps

// Shared LayerNorm statistics datapath.
//
// SUM mode:      accumulation_next = accumulator + sample
// VARIANCE mode: accumulation_next = accumulator + (sample-mean)^2
//
// The controller also reuses one scale multiplier for mean and variance, and
// this module exposes variance+epsilon for reciprocal-square-root setup.
(* use_dsp = "no" *)
module vit_layernorm_statistics_datapath (
    input  logic        variance_mode,
    input  logic [31:0] sample,
    input  logic [31:0] mean,
    input  logic [31:0] accumulator,
    input  logic [31:0] scale_operand,
    input  logic [31:0] reciprocal_hidden_size,
    input  logic [31:0] variance,
    input  logic [31:0] epsilon,
    output logic [31:0] accumulation_next,
    output logic [31:0] scaled_statistic,
    output logic [31:0] variance_plus_epsilon
);

    logic [31:0] centered_sample;
    logic [31:0] centered_square;
    logic [31:0] accumulation_addend;

    vit_fp32_sub_comb u_center_sample (
        .a(sample), .b(mean), .result(centered_sample)
    );
    vit_fp32_mul_comb_nodsp u_square_sample (
        .a(centered_sample),
        .b(centered_sample),
        .result(centered_square)
    );

    assign accumulation_addend =
        variance_mode ? centered_square : sample;

    vit_fp32_add_comb u_accumulate (
        .a(accumulator),
        .b(accumulation_addend),
        .result(accumulation_next)
    );
    vit_fp32_mul_comb_nodsp u_scale_statistic (
        .a(scale_operand),
        .b(reciprocal_hidden_size),
        .result(scaled_statistic)
    );
    vit_fp32_add_comb u_add_epsilon (
        .a(variance),
        .b(epsilon),
        .result(variance_plus_epsilon)
    );

endmodule
