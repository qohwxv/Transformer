`timescale 1ns/1ps

// Runtime-configurable FP32 batched-GEMM engine for the ViT Phase-B/C tests.
//
//   C[b,M,N] = A[b,M,K] * B[b,K,N]
//              + (bias_enable ? bias[N] : 0)
//
// batch_count/M/K/N are latched when start is accepted. Phase B uses one
// matrix; the Phase-C testbench maps the generic batch index onto attention
// heads.
// ARRAY_ROWS, ARRAY_COLS, and the 16-lane tree-PE shape remain hardware/
// elaboration parameters.
module vit_gemm_tree_array #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16
)(
    input  logic                                    clk,
    input  logic                                    rst,

    input  logic                                    start,
    input  logic [31:0]                             cfg_m,
    input  logic [31:0]                             cfg_k,
    input  logic [31:0]                             cfg_n,
    input  logic [31:0]                             cfg_batch_count,
    input  logic                                    cfg_bias_enable,
    output logic                                    busy,
    output logic                                    done,
    output logic                                    config_error,

    // The memory-side producer supplies one A vector for every active array
    // row and one B vector for every active array column. A chunk is accepted
    // only when data_request and data_valid are both high.
    output logic                                    data_request,
    input  logic                                    data_valid,
    output logic [31:0]                             token_base,
    output logic [31:0]                             output_base,
    output logic [31:0]                             k_base,
    output logic [31:0]                             batch_index,
    input  logic [ARRAY_ROWS*PE_LANES*32-1:0]       activation_data,
    input  logic [ARRAY_COLS*PE_LANES*32-1:0]       weight_data,
    input  logic [ARRAY_COLS*32-1:0]                bias_data,

    // The result tile remains stable in STATE_WRITE until result_ready is
    // asserted. Tile elements are ordered as row*ARRAY_COLS + column.
    output logic                                    result_valid,
    input  logic                                    result_ready,
    output logic [31:0]                             result_token_base,
    output logic [31:0]                             result_output_base,
    output logic [31:0]                             result_batch_index,
    output logic [ARRAY_ROWS-1:0]                   result_token_mask,
    output logic [ARRAY_COLS-1:0]                   result_output_mask,
    output logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     result_data
);

    localparam integer PE_COUNT = ARRAY_ROWS * ARRAY_COLS;
    localparam logic [32:0] ARRAY_ROWS_WIDE = ARRAY_ROWS;
    localparam logic [32:0] ARRAY_COLS_WIDE = ARRAY_COLS;
    localparam logic [32:0] PE_LANES_WIDE = PE_LANES;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_CLEAR,
        STATE_COMPUTE,
        STATE_BIAS,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic [31:0] active_m;
    logic [31:0] active_k;
    logic [31:0] active_n;
    logic [31:0] active_batch_count;
    logic active_bias_enable;

    logic pe_clear;
    logic pe_step;
    logic pe_finish;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] pe_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] pe_weight_data;
    logic [ARRAY_COLS*32-1:0] pe_bias_data;
    logic [PE_COUNT*32-1:0] pe_result;
    logic [PE_LANES-1:0] current_lane_mask;
    logic [ARRAY_ROWS-1:0] current_token_mask;
    logic [ARRAY_COLS-1:0] current_output_mask;

    integer mask_row;
    integer mask_col;
    integer mask_lane;

    // STATE_DONE does not accept a new start, so busy remains asserted until
    // the controller has returned to IDLE. This prevents a one-cycle command
    // from being lost between back-to-back jobs.
    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_COMPUTE);

    assign pe_clear = (state == STATE_CLEAR);
    assign pe_step = (state == STATE_COMPUTE) && data_valid;
    assign pe_finish = (state == STATE_BIAS);

    assign result_valid = (state == STATE_WRITE);
    assign result_token_base = token_base;
    assign result_output_base = output_base;
    assign result_batch_index = batch_index;
    assign result_token_mask = current_token_mask;
    assign result_output_mask = current_output_mask;
    assign result_data = pe_result;

    genvar row;
    genvar col;

    generate
        for (row = 0; row < ARRAY_ROWS; row = row + 1) begin : gen_token_mask
            assign current_token_mask[row] =
                (({1'b0, token_base} + row) < {1'b0, active_m});
        end

        for (col = 0; col < ARRAY_COLS; col = col + 1) begin : gen_output_mask
            assign current_output_mask[col] =
                (({1'b0, output_base} + col) < {1'b0, active_n});
        end
    endgenerate

    // Mask M/N boundaries here. K-tail bus values deliberately pass through
    // to the PE, where lane_valid must suppress them before multiplication.
    // The producer is therefore not trusted to zero invalid K lanes.
    always_comb begin
        pe_activation_data = '0;
        pe_weight_data = '0;
        pe_bias_data = '0;
        current_lane_mask = '0;

        for (mask_lane = 0; mask_lane < PE_LANES; mask_lane = mask_lane + 1)
            current_lane_mask[mask_lane] =
                (({1'b0, k_base} + mask_lane) < {1'b0, active_k});

        for (mask_row = 0; mask_row < ARRAY_ROWS; mask_row = mask_row + 1) begin
            for (mask_lane = 0; mask_lane < PE_LANES; mask_lane = mask_lane + 1) begin
                if (({1'b0, token_base} + mask_row) <
                    {1'b0, active_m}) begin
                    pe_activation_data[(mask_row*PE_LANES+mask_lane)*32 +: 32] =
                        activation_data[(mask_row*PE_LANES+mask_lane)*32 +: 32];
                end
            end
        end

        for (mask_col = 0; mask_col < ARRAY_COLS; mask_col = mask_col + 1) begin
            // Keep the external bias value visible at the PE even when bias is
            // disabled. The PE's bias_enable mux must perform the true bypass;
            // Phase-C tests poison this bus to prove that behavior.
            if (({1'b0, output_base} + mask_col) <
                {1'b0, active_n})
                pe_bias_data[mask_col*32 +: 32] = bias_data[mask_col*32 +: 32];

            for (mask_lane = 0; mask_lane < PE_LANES; mask_lane = mask_lane + 1) begin
                if (({1'b0, output_base} + mask_col) <
                    {1'b0, active_n}) begin
                    pe_weight_data[(mask_col*PE_LANES+mask_lane)*32 +: 32] =
                        weight_data[(mask_col*PE_LANES+mask_lane)*32 +: 32];
                end
            end
        end
    end

    // 2-D output-stationary array. Each PE owns one C element for the full K
    // reduction and consumes a 16-element dot-product chunk per accepted step.
    generate
        for (row = 0; row < ARRAY_ROWS; row = row + 1) begin : gen_pe_rows
            for (col = 0; col < ARRAY_COLS; col = col + 1) begin : gen_pe_cols
                localparam integer PE_INDEX = row * ARRAY_COLS + col;

                vit_tree_pe_fp32 u_pe (
                    .clk              (clk),
                    .rst              (rst),
                    .clear_accumulator(pe_clear),
                    .step_valid       (
                        pe_step && current_token_mask[row] && current_output_mask[col]
                    ),
                    .finish           (pe_finish),
                    .bias_enable      (active_bias_enable),
                    .lane_valid       (current_lane_mask),
                    .activation_lanes (
                        pe_activation_data[row*PE_LANES*32 +: PE_LANES*32]
                    ),
                    .weight_lanes     (
                        pe_weight_data[col*PE_LANES*32 +: PE_LANES*32]
                    ),
                    .bias             (pe_bias_data[col*32 +: 32]),
                    .result           (pe_result[PE_INDEX*32 +: 32])
                );
            end
        end
    endgenerate

    initial begin
        if (PE_LANES != 16)
            $fatal(1, "vit_gemm_tree_array requires PE_LANES=16");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= STATE_IDLE;
            config_error       <= 1'b0;
            active_m           <= 32'd0;
            active_k           <= 32'd0;
            active_n           <= 32'd0;
            active_batch_count <= 32'd0;
            active_bias_enable <= 1'b0;
            token_base         <= 32'd0;
            output_base        <= 32'd0;
            k_base             <= 32'd0;
            batch_index        <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_base  <= 32'd0;
                        output_base <= 32'd0;
                        k_base      <= 32'd0;
                        batch_index <= 32'd0;

                        if ((cfg_batch_count == 0) || (cfg_m == 0) ||
                            (cfg_k == 0) || (cfg_n == 0)) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_m           <= cfg_m;
                            active_k           <= cfg_k;
                            active_n           <= cfg_n;
                            active_batch_count <= cfg_batch_count;
                            active_bias_enable <= cfg_bias_enable;
                            state              <= STATE_CLEAR;
                        end
                    end
                end

                STATE_CLEAR: begin
                    k_base <= 32'd0;
                    state <= STATE_COMPUTE;
                end

                STATE_COMPUTE: begin
                    if (data_valid) begin
                        if (({1'b0, k_base} + PE_LANES_WIDE) >=
                            {1'b0, active_k})
                            state <= STATE_BIAS;
                        else
                            k_base <= k_base + PE_LANES;
                    end
                end

                STATE_BIAS: begin
                    state <= STATE_WRITE;
                end

                STATE_WRITE: begin
                    if (result_ready) begin
                        if (({1'b0, output_base} + ARRAY_COLS_WIDE) <
                            {1'b0, active_n}) begin
                            output_base <= output_base + ARRAY_COLS;
                            state <= STATE_CLEAR;
                        end else begin
                            output_base <= 32'd0;
                            if (({1'b0, token_base} + ARRAY_ROWS_WIDE) <
                                {1'b0, active_m}) begin
                                token_base <= token_base + ARRAY_ROWS;
                                state <= STATE_CLEAR;
                            end else if ((batch_index + 1) < active_batch_count) begin
                                token_base  <= 32'd0;
                                batch_index <= batch_index + 1;
                                state       <= STATE_CLEAR;
                            end else begin
                                state <= STATE_DONE;
                            end
                        end
                    end
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    config_error <= 1'b1;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
