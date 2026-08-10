`timescale 1ns/1ps

// Single-lane binary32 accumulator composed from vit_fp32_add_comb.
// Reset and clear are synchronous; clear has priority over enable.
module vit_fp32_accumulator (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        enable,
    input  logic [31:0] addend,
    output logic [31:0] result
);

    logic [31:0] next_result;

    vit_fp32_add_comb u_add (
        .a      (result),
        .b      (addend),
        .result (next_result)
    );

    always_ff @(posedge clk) begin
        if (!rst_n)
            result <= 32'h0000_0000;
        else if (clear)
            result <= 32'h0000_0000;
        else if (enable)
            result <= next_result;
    end

endmodule
