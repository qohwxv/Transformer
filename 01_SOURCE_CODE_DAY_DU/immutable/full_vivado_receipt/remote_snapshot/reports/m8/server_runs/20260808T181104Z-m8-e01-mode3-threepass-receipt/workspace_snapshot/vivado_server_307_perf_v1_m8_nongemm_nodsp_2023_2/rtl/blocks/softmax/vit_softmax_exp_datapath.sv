`timescale 1ns/1ps

// Shared Softmax datapath for exp(x-row_max).  The same exponential result is
// selected by the controller either for accumulation or normalization.
(* use_dsp = "no" *)
module vit_softmax_exp_datapath (
    input  logic [31:0] input_value,
    input  logic [31:0] row_maximum,
    input  logic [31:0] exponential_sum,
    input  logic [31:0] reciprocal_sum,
    output logic [31:0] exponential_value,
    output logic [31:0] next_exponential_sum,
    output logic [31:0] normalized_value
);

    logic [31:0] centered_value;

    vit_fp32_sub_comb u_center (
        .a(input_value), .b(row_maximum), .result(centered_value)
    );
    vit_fp32_exp_neg_comb u_exponential (
        .value(centered_value), .result(exponential_value)
    );
    vit_fp32_add_comb u_accumulate (
        .a(exponential_sum),
        .b(exponential_value),
        .result(next_exponential_sum)
    );
    vit_fp32_mul_comb_nodsp u_normalize (
        .a(exponential_value),
        .b(reciprocal_sum),
        .result(normalized_value)
    );

endmodule
