`timescale 1ns/1ps

// One synchronous-read RAM holding the bias vector of the active GEMM.
//
// The memory frontend fills this bank while processing the first token tile,
// then reuses it for later token tiles/batches. Validity and command-level
// alias policy are owned by the frontend.
(* use_dsp = "no" *)
module vit_gemm_bias_cache #(
    parameter integer DEPTH_WORDS = 3072
) (
    input  logic clk,
    input  logic rst,
    input  logic clear,

    input  logic write_enable,
    input  logic [31:0] write_index,
    input  logic [31:0] write_data,

    input  logic read_enable,
    input  logic [31:0] read_index,
    output logic read_data_valid,
    output logic [31:0] read_data
);

    localparam integer ADDRESS_WIDTH =
        (DEPTH_WORDS <= 1) ? 1 : $clog2(DEPTH_WORDS);

    (* ram_style = "block" *)
    logic [31:0] bias_memory [0:DEPTH_WORDS-1];

    initial begin
        if (DEPTH_WORDS <= 0)
            $fatal(1, "vit_gemm_bias_cache requires DEPTH_WORDS > 0");
    end

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            read_data_valid <= 1'b0;
            read_data <= 32'd0;
        end else begin
            read_data_valid <= read_enable;

            if (write_enable)
                bias_memory[
                    write_index[ADDRESS_WIDTH-1:0]
                ] <= write_data;

            if (read_enable)
                read_data <=
                    bias_memory[
                        read_index[ADDRESS_WIDTH-1:0]
                    ];
        end
    end

endmodule
