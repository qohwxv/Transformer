`timescale 1ns/1ps

// One-entry ready/valid register.  Compute blocks use this leaf to hold data
// stable while a downstream memory writer applies backpressure.
module vit_stream_buffer #(
    parameter integer DATA_WIDTH = 32
) (
    input  logic                      clk,
    input  logic                      rst,
    input  logic                      input_valid,
    output logic                      input_ready,
    input  logic [DATA_WIDTH-1:0]     input_data,
    output logic                      output_valid,
    input  logic                      output_ready,
    output logic [DATA_WIDTH-1:0]     output_data
);

    assign input_ready = !output_valid || output_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            output_valid <= 1'b0;
            output_data  <= '0;
        end else if (input_ready) begin
            output_valid <= input_valid;
            if (input_valid)
                output_data <= input_data;
        end
    end

endmodule
