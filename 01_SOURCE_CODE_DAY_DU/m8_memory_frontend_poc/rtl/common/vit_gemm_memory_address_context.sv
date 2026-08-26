`timescale 1ns/1ps

// Incremental GEMM address bases.
//
// GEMM controller coordinates advance in the fixed nested order
// batch -> token tile -> output tile -> K chunk.  Keeping hierarchical bases
// for those loops removes all runtime 32x32 address multipliers from the hot
// memory router.  The 66-bit contexts preserve the exact unsigned mathematical
// sum and therefore the original overflow behavior.
(* use_dsp = "no" *)
module vit_gemm_memory_address_context #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16
) (
    input  logic                          clk,
    input  logic                          rst,
    input  logic                          clear,
    input  logic                          request_start,
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,
    input  logic [31:0]                   token_base,
    input  logic [31:0]                   output_base,
    input  logic [31:0]                   k_base,
    input  logic [31:0]                   batch_index,

    output logic [65:0] activation_address_base,
    output logic [65:0] weight_address_base,
    output logic [65:0] bias_address_base,
    output logic [65:0] result_address_base
);

    import vit_phase_e_pkg::*;

    logic context_valid;
    logic [31:0] previous_token_base;
    logic [31:0] previous_output_base;
    logic [31:0] previous_k_base;
    logic [31:0] previous_batch_index;

    logic [65:0] activation_batch_base;
    logic [65:0] activation_token_base;
    logic [65:0] weight_batch_base;
    logic [65:0] weight_output_base;
    logic [65:0] result_batch_base;
    logic [65:0] result_token_base;

    function automatic logic [65:0] widen32(
        input logic [31:0] value
    );
        begin
            widen32 = {34'd0, value};
        end
    endfunction

    function automatic logic [65:0] stride_times_rows(
        input logic [31:0] stride
    );
        integer row_step;
        begin
            stride_times_rows = 66'd0;
            for (row_step = 0; row_step < ARRAY_ROWS;
                 row_step = row_step + 1)
                stride_times_rows =
                    stride_times_rows + widen32(stride);
        end
    endfunction

    function automatic logic [65:0] stride_times_lanes(
        input logic [31:0] stride
    );
        integer lane_step;
        begin
            stride_times_lanes = 66'd0;
            for (lane_step = 0; lane_step < PE_LANES;
                 lane_step = lane_step + 1)
                stride_times_lanes =
                    stride_times_lanes + widen32(stride);
        end
    endfunction

    localparam logic [65:0] ARRAY_COLS_WIDE = 66'(ARRAY_COLS);
    localparam logic [65:0] PE_LANES_WIDE = 66'(PE_LANES);
    localparam logic [65:0] BLOCKED_B_WORDS_WIDE =
        66'(ARRAY_COLS * PE_LANES);
    localparam logic [65:0] PACKED_B_WORDS_WIDE =
        66'(((ARRAY_COLS + 1) / 2) * PE_LANES);

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(
                1,
                "vit_gemm_memory_address_context requires ARRAY_ROWS > 0"
            );
        if (ARRAY_COLS <= 0)
            $fatal(
                1,
                "vit_gemm_memory_address_context requires ARRAY_COLS > 0"
            );
        if (PE_LANES <= 0)
            $fatal(
                1,
                "vit_gemm_memory_address_context requires PE_LANES > 0"
            );
    end

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            context_valid          <= 1'b0;
            previous_token_base    <= 32'd0;
            previous_output_base   <= 32'd0;
            previous_k_base        <= 32'd0;
            previous_batch_index   <= 32'd0;
            activation_batch_base  <= 66'd0;
            activation_token_base  <= 66'd0;
            activation_address_base <= 66'd0;
            weight_batch_base      <= 66'd0;
            weight_output_base     <= 66'd0;
            weight_address_base    <= 66'd0;
            bias_address_base      <= 66'd0;
            result_batch_base      <= 66'd0;
            result_token_base      <= 66'd0;
            result_address_base    <= 66'd0;
        end else if (request_start) begin
            previous_token_base  <= token_base;
            previous_output_base <= output_base;
            previous_k_base      <= k_base;
            previous_batch_index <= batch_index;

            if (!context_valid) begin
                context_valid <= 1'b1;

                activation_batch_base <=
                    widen32(active_cmd.src0_base);
                activation_token_base <=
                    widen32(active_cmd.src0_base);
                activation_address_base <=
                    widen32(active_cmd.src0_base);

                weight_batch_base <=
                    widen32(active_cmd.src1_base);
                weight_output_base <=
                    widen32(active_cmd.src1_base);
                weight_address_base <=
                    widen32(active_cmd.src1_base);

                bias_address_base <=
                    widen32(active_cmd.src2_base);

                result_batch_base <=
                    widen32(active_cmd.dst_base);
                result_token_base <=
                    widen32(active_cmd.dst_base);
                result_address_base <=
                    widen32(active_cmd.dst_base);
            end else if (batch_index != previous_batch_index) begin
                activation_batch_base <=
                    activation_batch_base +
                    widen32(active_cmd.stride0);
                activation_token_base <=
                    activation_batch_base +
                    widen32(active_cmd.stride0);
                activation_address_base <=
                    activation_batch_base +
                    widen32(active_cmd.stride0);

                weight_batch_base <=
                    weight_batch_base +
                    widen32(active_cmd.stride2);
                weight_output_base <=
                    weight_batch_base +
                    widen32(active_cmd.stride2);
                weight_address_base <=
                    weight_batch_base +
                    widen32(active_cmd.stride2);

                bias_address_base <=
                    widen32(active_cmd.src2_base);

                result_batch_base <=
                    result_batch_base +
                    widen32(active_cmd.stride4);
                result_token_base <=
                    result_batch_base +
                    widen32(active_cmd.stride4);
                result_address_base <=
                    result_batch_base +
                    widen32(active_cmd.stride4);
            end else if (token_base != previous_token_base) begin
                activation_token_base <=
                    activation_token_base +
                    stride_times_rows(active_cmd.stride1);
                activation_address_base <=
                    activation_token_base +
                    stride_times_rows(active_cmd.stride1);

                weight_output_base <= weight_batch_base;
                weight_address_base <= weight_batch_base;
                bias_address_base <=
                    widen32(active_cmd.src2_base);

                result_token_base <=
                    result_token_base +
                    stride_times_rows(active_cmd.immediate);
                result_address_base <=
                    result_token_base +
                    stride_times_rows(active_cmd.immediate);
            end else if (output_base != previous_output_base) begin
                activation_address_base <= activation_token_base;

                if ((active_cmd.header.flags &
                     PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                    weight_output_base <=
                        weight_output_base + widen32(active_cmd.stride3);
                    weight_address_base <=
                        weight_output_base + widen32(active_cmd.stride3);
                end else begin
                    weight_output_base <=
                        weight_output_base + ARRAY_COLS_WIDE;
                    weight_address_base <=
                        weight_output_base + ARRAY_COLS_WIDE;
                end
                bias_address_base <=
                    bias_address_base + ARRAY_COLS_WIDE;
                result_address_base <=
                    result_address_base + ARRAY_COLS_WIDE;
            end else if (k_base != previous_k_base) begin
                if (k_base < previous_k_base) begin
                    // Controlled S8 second-column pass: output/tile identity is
                    // unchanged while K rewinds to zero.  Restore the exact
                    // tile-local A/B bases rather than treating the rewind as
                    // another forward K16 step.
                    activation_address_base <= activation_token_base;
                    weight_address_base <= weight_output_base;
                end else begin
                    activation_address_base <=
                        activation_address_base + PE_LANES_WIDE;
                    if ((active_cmd.header.flags &
                         PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                        if ((active_cmd.header.flags &
                             PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0)
                            weight_address_base <=
                                weight_address_base + PACKED_B_WORDS_WIDE;
                        else
                            weight_address_base <=
                                weight_address_base + BLOCKED_B_WORDS_WIDE;
                    end
                    else
                        weight_address_base <=
                            weight_address_base +
                            stride_times_lanes(active_cmd.stride3);
                end
            end
        end
    end

endmodule
