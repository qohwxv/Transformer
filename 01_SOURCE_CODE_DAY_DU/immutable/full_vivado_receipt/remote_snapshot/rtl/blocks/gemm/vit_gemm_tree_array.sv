`timescale 1ns/1ps

// Runtime-configurable FP32 batched GEMM:
//
//   C[b,M,N] = A[b,M,K] * B[b,K,N]
//              + (bias_enable ? bias[N] : 0)
//
// This top-level preserves the original external interface and cycle contract,
// while making the leaf-to-top implementation hierarchy explicit:
//
//   controller -> operand router -> PE array -> result path.
module vit_gemm_tree_array #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16,
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
) (
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

    output logic                                    data_request,
    input  logic                                    data_valid,
    output logic [31:0]                             token_base,
    output logic [31:0]                             output_base,
    output logic [31:0]                             k_base,
    output logic [31:0]                             batch_index,
    input  logic [ARRAY_ROWS*PE_LANES*32-1:0]       activation_data,
    input  logic [ARRAY_COLS*PE_LANES*32-1:0]       weight_data,
    input  logic [ARRAY_COLS*32-1:0]                bias_data,

    output logic                                    result_valid,
    input  logic                                    result_ready,
    output logic [31:0]                             result_token_base,
    output logic [31:0]                             result_output_base,
    output logic [31:0]                             result_batch_index,
    output logic [ARRAY_ROWS-1:0]                   result_token_mask,
    output logic [ARRAY_COLS-1:0]                   result_output_mask,
    output logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     result_data,

    output logic [31:0]                             mul_operand_a,
    output logic [31:0]                             mul_operand_b,
    input  logic [31:0]                             external_mul_result,

    output logic [31:0]                             add_operand_a,
    output logic [31:0]                             add_operand_b,
    input  logic [31:0]                             external_add_result,

    // One event per accepted K-chunk/tile step.  Deltas account for all
    // physical row/column/lane slots consumed by that step.
    output logic                                    profile_gemm_tile_step_o,
    output logic [15:0]                             profile_valid_mac_delta_o,
    output logic [15:0]                             profile_tail_mac_delta_o
);

    logic        controller_result_valid;
    logic        pe_clear;
    logic        pe_step;
    logic        pe_step_done;
    logic        pe_finish;
    logic        pe_finish_done;
    logic [31:0] active_m;
    logic [31:0] active_k;
    logic [31:0] active_n;
    logic        active_bias_enable;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] routed_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] routed_weight_data;
    logic [ARRAY_COLS*32-1:0]          routed_bias_data;
    logic [PE_LANES-1:0]               lane_valid;
    logic [ARRAY_ROWS-1:0]              token_valid;
    logic [ARRAY_COLS-1:0]              output_valid;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] pe_result_data;

    localparam logic [15:0] PROFILE_TILE_MAC_SLOTS =
        16'(ARRAY_ROWS * ARRAY_COLS * PE_LANES);
    integer profile_row_index;
    integer profile_col_index;
    integer profile_lane_index;

    assign profile_gemm_tile_step_o = pe_step;

    // This nested population count is exactly
    // popcount(lane_valid)*popcount(token_valid)*popcount(output_valid), but
    // avoids describing a general multiplier that synthesis could map to DSP.
    always_comb begin
        profile_valid_mac_delta_o = 16'd0;
        if (pe_step) begin
            for (profile_row_index = 0;
                 profile_row_index < ARRAY_ROWS;
                 profile_row_index = profile_row_index + 1)
                for (profile_col_index = 0;
                     profile_col_index < ARRAY_COLS;
                     profile_col_index = profile_col_index + 1)
                    for (profile_lane_index = 0;
                         profile_lane_index < PE_LANES;
                         profile_lane_index = profile_lane_index + 1)
                        if (token_valid[profile_row_index] &&
                            output_valid[profile_col_index] &&
                            lane_valid[profile_lane_index])
                            profile_valid_mac_delta_o =
                                profile_valid_mac_delta_o + 16'd1;
        end

        profile_tail_mac_delta_o = pe_step ?
            (PROFILE_TILE_MAC_SLOTS - profile_valid_mac_delta_o) : 16'd0;
    end

    initial begin
        if ((ARRAY_ROWS * ARRAY_COLS * PE_LANES) > 16'hffff)
            $fatal(1, "GEMM profile MAC delta must fit 16 bits");
    end

    vit_gemm_controller #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) u_controller (
        .clk                (clk),
        .rst                (rst),
        .start              (start),
        .cfg_m              (cfg_m),
        .cfg_k              (cfg_k),
        .cfg_n              (cfg_n),
        .cfg_batch_count    (cfg_batch_count),
        .cfg_bias_enable    (cfg_bias_enable),
        .data_valid         (data_valid),
        .pe_step_done       (pe_step_done),
        .pe_finish_done     (pe_finish_done),
        .result_ready       (result_ready),
        .busy               (busy),
        .done               (done),
        .config_error       (config_error),
        .data_request       (data_request),
        .result_valid       (controller_result_valid),
        .pe_clear           (pe_clear),
        .pe_step            (pe_step),
        .pe_finish          (pe_finish),
        .active_m           (active_m),
        .active_k           (active_k),
        .active_n           (active_n),
        .active_bias_enable (active_bias_enable),
        .token_base         (token_base),
        .output_base        (output_base),
        .k_base             (k_base),
        .batch_index        (batch_index)
    );

    vit_gemm_operand_router #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) u_operand_router (
        .active_m               (active_m),
        .active_k               (active_k),
        .active_n               (active_n),
        .token_base             (token_base),
        .output_base            (output_base),
        .k_base                 (k_base),
        .activation_data        (activation_data),
        .weight_data            (weight_data),
        .bias_data              (bias_data),
        .routed_activation_data (routed_activation_data),
        .routed_weight_data     (routed_weight_data),
        .routed_bias_data       (routed_bias_data),
        .lane_valid             (lane_valid),
        .token_valid            (token_valid),
        .output_valid           (output_valid)
    );

    vit_gemm_pe_array #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES),
        .USE_EXTERNAL_MUL (USE_EXTERNAL_MUL),
        .USE_EXTERNAL_ADD (USE_EXTERNAL_ADD)
    ) u_pe_array (
        .clk                (clk),
        .rst                (rst),
        .clear_accumulators (pe_clear),
        .step_valid         (pe_step),
        .step_done          (pe_step_done),
        .finish             (pe_finish),
        .finish_done        (pe_finish_done),
        .bias_enable        (active_bias_enable),
        .lane_valid         (lane_valid),
        .token_valid        (token_valid),
        .output_valid       (output_valid),
        .activation_data    (routed_activation_data),
        .weight_data        (routed_weight_data),
        .bias_data          (routed_bias_data),
        .result_data        (pe_result_data),
        .mul_operand_a      (mul_operand_a),
        .mul_operand_b      (mul_operand_b),
        .external_mul_result(external_mul_result),
        .add_operand_a      (add_operand_a),
        .add_operand_b      (add_operand_b),
        .external_add_result(external_add_result)
    );

    vit_gemm_result_path #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS)
    ) u_result_path (
        .tile_valid         (controller_result_valid),
        .token_base         (token_base),
        .output_base        (output_base),
        .batch_index        (batch_index),
        .token_mask         (token_valid),
        .output_mask        (output_valid),
        .pe_result_data     (pe_result_data),
        .result_valid       (result_valid),
        .result_token_base  (result_token_base),
        .result_output_base (result_output_base),
        .result_batch_index (result_batch_index),
        .result_token_mask  (result_token_mask),
        .result_output_mask (result_output_mask),
        .result_data        (result_data)
    );

endmodule
