`timescale 1ns/1ps

// LayerNorm output transform:
// beta + gamma * inv_std * (sample - mean).
(* use_dsp = "no" *)
module vit_layernorm_affine_datapath (
    input  logic [31:0] sample,
    input  logic [31:0] mean,
    input  logic [31:0] inverse_standard_deviation,
    input  logic [31:0] gamma,
    input  logic [31:0] beta,
    output logic [31:0] result
);

    logic [31:0] centered_sample;
    logic [31:0] normalized_sample;
    logic [31:0] scaled_sample;

    vit_fp32_sub_comb u_center (
        .a(sample), .b(mean), .result(centered_sample)
    );
    vit_fp32_mul_comb_nodsp u_normalize (
        .a(centered_sample),
        .b(inverse_standard_deviation),
        .result(normalized_sample)
    );
    vit_fp32_mul_comb_nodsp u_gamma (
        .a(normalized_sample), .b(gamma), .result(scaled_sample)
    );
    vit_fp32_add_comb u_beta (
        .a(scaled_sample), .b(beta), .result(result)
    );

endmodule
