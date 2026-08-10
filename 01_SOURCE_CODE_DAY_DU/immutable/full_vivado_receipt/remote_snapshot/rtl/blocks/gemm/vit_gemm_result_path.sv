`timescale 1ns/1ps

// Stable, explicit boundary between the PE array and the external tile-result
// channel.  The PE results themselves are registered on finish; this module
// adds no latency and preserves the original STATE_WRITE hold behavior.
module vit_gemm_result_path #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2
) (
    input  logic                                    tile_valid,
    input  logic [31:0]                             token_base,
    input  logic [31:0]                             output_base,
    input  logic [31:0]                             batch_index,
    input  logic [ARRAY_ROWS-1:0]                   token_mask,
    input  logic [ARRAY_COLS-1:0]                   output_mask,
    input  logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     pe_result_data,

    output logic                                    result_valid,
    output logic [31:0]                             result_token_base,
    output logic [31:0]                             result_output_base,
    output logic [31:0]                             result_batch_index,
    output logic [ARRAY_ROWS-1:0]                   result_token_mask,
    output logic [ARRAY_COLS-1:0]                   result_output_mask,
    output logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     result_data
);

    assign result_valid        = tile_valid;
    assign result_token_base   = token_base;
    assign result_output_base  = output_base;
    assign result_batch_index  = batch_index;
    assign result_token_mask   = token_mask;
    assign result_output_mask  = output_mask;
    assign result_data         = pe_result_data;

endmodule
