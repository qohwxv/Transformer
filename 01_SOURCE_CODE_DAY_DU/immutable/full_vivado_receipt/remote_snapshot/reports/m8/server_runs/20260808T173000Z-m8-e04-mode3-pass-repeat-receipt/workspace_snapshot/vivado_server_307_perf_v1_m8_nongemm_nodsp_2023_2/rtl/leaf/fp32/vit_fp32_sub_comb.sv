`timescale 1ns/1ps

// Subtraction is deliberately built from the leaf adder, matching
// vit_fp32_pkg::fp32_sub_synth(a, b) = fp32_add(a, -b).
module vit_fp32_sub_comb (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result
);

    logic [31:0] negated_b;

    assign negated_b = {~b[31], b[30:0]};

    vit_fp32_add_comb u_add (
        .a      (a),
        .b      (negated_b),
        .result (result)
    );

endmodule
