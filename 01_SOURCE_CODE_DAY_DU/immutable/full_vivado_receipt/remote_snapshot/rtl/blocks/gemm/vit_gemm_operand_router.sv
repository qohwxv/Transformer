`timescale 1ns/1ps

// Boundary masking and operand fanout for one GEMM array tile.
//
// The router is intentionally combinational: inserting storage here would
// change the established data_request/data_valid cycle contract.  Invalid M/N
// elements are zeroed, while invalid K lanes are explicitly identified by
// lane_valid so the PE can suppress 0*Inf/NaN before accumulation.
module vit_gemm_operand_router #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16
) (
    input  logic [31:0] active_m,
    input  logic [31:0] active_k,
    input  logic [31:0] active_n,
    input  logic [31:0] token_base,
    input  logic [31:0] output_base,
    input  logic [31:0] k_base,

    input  logic [ARRAY_ROWS*PE_LANES*32-1:0] activation_data,
    input  logic [ARRAY_COLS*PE_LANES*32-1:0] weight_data,
    input  logic [ARRAY_COLS*32-1:0]          bias_data,

    output logic [ARRAY_ROWS*PE_LANES*32-1:0] routed_activation_data,
    output logic [ARRAY_COLS*PE_LANES*32-1:0] routed_weight_data,
    output logic [ARRAY_COLS*32-1:0]          routed_bias_data,
    output logic [PE_LANES-1:0]               lane_valid,
    output logic [ARRAY_ROWS-1:0]              token_valid,
    output logic [ARRAY_COLS-1:0]              output_valid
);

    integer row_index;
    integer col_index;
    integer lane_index;

    always_comb begin
        routed_activation_data = '0;
        routed_weight_data     = '0;
        routed_bias_data       = '0;
        lane_valid             = '0;
        token_valid            = '0;
        output_valid           = '0;

        for (lane_index = 0; lane_index < PE_LANES;
             lane_index = lane_index + 1) begin
            lane_valid[lane_index] =
                (({1'b0, k_base} + lane_index) < {1'b0, active_k});
        end

        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1) begin
            token_valid[row_index] =
                (({1'b0, token_base} + row_index) < {1'b0, active_m});

            for (lane_index = 0; lane_index < PE_LANES;
                 lane_index = lane_index + 1) begin
                if (({1'b0, token_base} + row_index) <
                    {1'b0, active_m}) begin
                    routed_activation_data[
                        (row_index*PE_LANES+lane_index)*32 +: 32
                    ] = activation_data[
                        (row_index*PE_LANES+lane_index)*32 +: 32
                    ];
                end
            end
        end

        for (col_index = 0; col_index < ARRAY_COLS;
             col_index = col_index + 1) begin
            output_valid[col_index] =
                (({1'b0, output_base} + col_index) < {1'b0, active_n});

            // Bias is routed independently of cfg_bias_enable.  The final
            // mux in the PE accumulator is the only functional bypass.
            if (({1'b0, output_base} + col_index) <
                {1'b0, active_n}) begin
                routed_bias_data[col_index*32 +: 32] =
                    bias_data[col_index*32 +: 32];
            end

            for (lane_index = 0; lane_index < PE_LANES;
                 lane_index = lane_index + 1) begin
                if (({1'b0, output_base} + col_index) <
                    {1'b0, active_n}) begin
                    routed_weight_data[
                        (col_index*PE_LANES+lane_index)*32 +: 32
                    ] = weight_data[
                        (col_index*PE_LANES+lane_index)*32 +: 32
                    ];
                end
            end
        end
    end

endmodule
