`timescale 1ns/1ps

// Output-stationary accumulator and optional bias result path for one PE.
module vit_gemm_accumulator (
    input  logic        clk,
    input  logic        rst,
    input  logic        clear,
    input  logic        step_valid,
    input  logic        finish,
    input  logic        bias_enable,
    input  logic [31:0] partial_sum,
    input  logic [31:0] bias,
    output logic [31:0] result
);

    logic [31:0] accumulator_value;
    logic [31:0] biased_sum;

    vit_fp32_accumulator u_partial_accumulator (
        .clk    (clk),
        .rst_n  (!rst),
        .clear  (clear),
        .enable (step_valid),
        .addend (partial_sum),
        .result (accumulator_value)
    );

    vit_fp32_add_comb u_bias_add (
        .a      (accumulator_value),
        .b      (bias),
        .result (biased_sum)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            result <= 32'd0;
        end else if (clear) begin
            result <= 32'd0;
        end else begin
            // finish follows the final step by one cycle.  Therefore the
            // registered accumulator already includes the complete K range.
            if (finish)
                result <= bias_enable ? biased_sum : accumulator_value;
        end
    end

endmodule
