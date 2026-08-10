`timescale 1ns/1ps

// Generic synchronous counter used by block controllers.  Keeping the
// incrementer in a leaf module makes counter width and resource cost visible in
// hierarchical synthesis reports.
module vit_counter #(
    parameter integer WIDTH = 32
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 clear,
    input  logic                 load,
    input  logic                 enable,
    input  logic [WIDTH-1:0]     load_value,
    input  logic [WIDTH-1:0]     step,
    output logic [WIDTH-1:0]     value
);

    always_ff @(posedge clk) begin
        if (rst || clear)
            value <= '0;
        else if (load)
            value <= load_value;
        else if (enable)
            value <= value + step;
    end

endmodule
