`timescale 1ns/1ps

// Compatibility-preserving production GEMM selector.
//
// With INCLUDE_LEGACY_GEMM=1, cfg_fp16_enable=0 is the promoted M5/R8 FP32
// tree path.  The production M7-S8 engine sets the parameter to zero and
// rejects every non-FP16 start, allowing synthesis to remove that tree.  The
// FP16 path exists only for the locked R8/C2/L16 geometry.  Packed-v3 B is a
// submode of FP16 compute and fails closed when requested without FP16;
// unsupported geometries likewise fail instead of silently falling back.
(* keep_hierarchy = "yes", use_dsp = "no" *)
module vit_gemm_dual_mode_array #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16,
    parameter integer FP16_STREAMS = 8,
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0,
    // Keep the default for focused legacy-compatibility tests and reusable
    // leaf instantiations.  The production M7-S8 engine overrides this to
    // zero so the promoted M5 FP32 GEMM tree is removed at elaboration.
    parameter integer INCLUDE_LEGACY_GEMM = 1
) (
    input  logic                                    clk,
    input  logic                                    rst,
    input  logic                                    start,
    input  logic [31:0]                             cfg_m,
    input  logic [31:0]                             cfg_k,
    input  logic [31:0]                             cfg_n,
    input  logic [31:0]                             cfg_batch_count,
    input  logic                                    cfg_bias_enable,
    input  logic                                    cfg_fp16_enable,
    input  logic                                    cfg_weight_fp16_packed2,
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
    input  logic [65:0]                             result_address_base_i,
    input  logic [7:0]                              result_generation_i,
    output logic                                    result_valid,
    input  logic                                    result_ready,
    output logic [65:0]                             result_address_base_o,
    output logic [7:0]                              result_generation_o,
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
    output logic                                    profile_gemm_tile_step_o,
    output logic [15:0]                             profile_valid_mac_delta_o,
    output logic [15:0]                             profile_tail_mac_delta_o,
    output logic [4:0]                              profile_m7_term_accept_delta_o,
    output logic [4:0]                              profile_m7_disabled_term_delta_o,
    output logic                                    profile_m7_input_wait_o,
    output logic                                    profile_m7_term_stall_o,
    output logic                                    profile_m7_result_backpressure_o,
    output logic                                    profile_m7_compute_active_o,
    output logic                                    profile_m7_dot_start_o,
    output logic                                    profile_m7_result_vector_o,
    output logic [4:0]                              profile_m7_invalid_delta_o,
    output logic [4:0]                              profile_m7_overflow_delta_o,
    output logic [4:0]                              profile_m7_length_error_delta_o,
    output logic [4:0]                              profile_m7_subnormal_flushed_delta_o,
    output logic                                    profile_m7_panel_load_active_o,
    output logic                                    profile_m7_panel_compute_active_o,
    output logic                                    profile_m7_panel_commit_o,
    output logic                                    profile_m7_panel_claim_o,
    output logic [1:0]                              profile_m7_panel_claim_mask_o,
    output logic                                    profile_m7_panel_release_o,
    output logic                                    profile_m7_panel_empty_stall_o,
    output logic                                    profile_m7_panel_full_stall_o,
    output logic [1:0]                              profile_m7_panel_occupancy_o,
    output logic                                    profile_m7_result_fifo_enqueue_o,
    output logic                                    profile_m7_result_fifo_dequeue_o,
    output logic                                    profile_m7_result_fifo_full_stall_o,
    output logic [1:0]                              profile_m7_result_fifo_occupancy_o
);

    logic mode_fp16_q;
    logic packed_without_fp16_q;
    logic legacy_unavailable_q;

    logic legacy_busy;
    logic legacy_done;
    logic legacy_config_error;
    logic legacy_data_request;
    logic [31:0] legacy_token_base;
    logic [31:0] legacy_output_base;
    logic [31:0] legacy_k_base;
    logic [31:0] legacy_batch_index;
    logic legacy_result_valid;
    logic [31:0] legacy_result_token_base;
    logic [31:0] legacy_result_output_base;
    logic [31:0] legacy_result_batch_index;
    logic [ARRAY_ROWS-1:0] legacy_result_token_mask;
    logic [ARRAY_COLS-1:0] legacy_result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] legacy_result_data;
    logic [31:0] legacy_mul_operand_a;
    logic [31:0] legacy_mul_operand_b;
    logic [31:0] legacy_add_operand_a;
    logic [31:0] legacy_add_operand_b;
    logic legacy_profile_tile_step;
    logic [15:0] legacy_profile_valid_mac;
    logic [15:0] legacy_profile_tail_mac;

    logic fp16_busy;
    logic fp16_done;
    logic fp16_config_error;
    logic fp16_data_request;
    logic [31:0] fp16_token_base;
    logic [31:0] fp16_output_base;
    logic [31:0] fp16_k_base;
    logic [31:0] fp16_batch_index;
    logic fp16_result_valid;
    logic [65:0] fp16_result_address_base;
    logic [7:0] fp16_result_generation;
    logic [31:0] fp16_result_token_base;
    logic [31:0] fp16_result_output_base;
    logic [31:0] fp16_result_batch_index;
    logic [ARRAY_ROWS-1:0] fp16_result_token_mask;
    logic [ARRAY_COLS-1:0] fp16_result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] fp16_result_data;
    logic fp16_profile_tile_step;
    logic [15:0] fp16_profile_valid_mac;
    logic [15:0] fp16_profile_tail_mac;
    logic [4:0] fp16_profile_term_accept;
    logic [4:0] fp16_profile_disabled_term;
    logic fp16_profile_input_wait;
    logic fp16_profile_term_stall;
    logic fp16_profile_result_backpressure;
    logic fp16_profile_compute_active;
    logic fp16_profile_dot_start;
    logic fp16_profile_result_vector;
    logic [4:0] fp16_profile_invalid;
    logic [4:0] fp16_profile_overflow;
    logic [4:0] fp16_profile_length_error;
    logic [4:0] fp16_profile_subnormal_flushed;
    logic fp16_profile_panel_load_active;
    logic fp16_profile_panel_compute_active;
    logic fp16_profile_panel_commit;
    logic fp16_profile_panel_claim;
    logic [1:0] fp16_profile_panel_claim_mask;
    logic fp16_profile_panel_release;
    logic fp16_profile_panel_empty_stall;
    logic fp16_profile_panel_full_stall;
    logic [1:0] fp16_profile_panel_occupancy;
    logic fp16_profile_result_fifo_enqueue;
    logic fp16_profile_result_fifo_dequeue;
    logic fp16_profile_result_fifo_full_stall;
    logic [1:0] fp16_profile_result_fifo_occupancy;

    always_ff @(posedge clk) begin
        if (rst) begin
            mode_fp16_q <= 1'b0;
            packed_without_fp16_q <= 1'b0;
            legacy_unavailable_q <= 1'b0;
        end else begin
            packed_without_fp16_q <= 1'b0;
            legacy_unavailable_q <= 1'b0;
            if (start) begin
                mode_fp16_q <= cfg_fp16_enable;
                packed_without_fp16_q <=
                    cfg_weight_fp16_packed2 && !cfg_fp16_enable;
                legacy_unavailable_q <=
                    !cfg_fp16_enable && (INCLUDE_LEGACY_GEMM == 0);
            end
        end
    end

    generate
        if (INCLUDE_LEGACY_GEMM != 0) begin : gen_legacy
            vit_gemm_tree_array #(
                .ARRAY_ROWS      (ARRAY_ROWS),
                .ARRAY_COLS      (ARRAY_COLS),
                .PE_LANES        (PE_LANES),
                .USE_EXTERNAL_MUL(USE_EXTERNAL_MUL),
                .USE_EXTERNAL_ADD(USE_EXTERNAL_ADD)
            ) u_legacy (
                .clk                      (clk),
                .rst                      (rst),
                .start                    (
                    start && !cfg_fp16_enable &&
                    !cfg_weight_fp16_packed2
                ),
                .cfg_m                    (cfg_m),
                .cfg_k                    (cfg_k),
                .cfg_n                    (cfg_n),
                .cfg_batch_count          (cfg_batch_count),
                .cfg_bias_enable          (cfg_bias_enable),
                .busy                     (legacy_busy),
                .done                     (legacy_done),
                .config_error             (legacy_config_error),
                .data_request             (legacy_data_request),
                .data_valid               (data_valid && !mode_fp16_q),
                .token_base               (legacy_token_base),
                .output_base              (legacy_output_base),
                .k_base                   (legacy_k_base),
                .batch_index              (legacy_batch_index),
                .activation_data          (activation_data),
                .weight_data              (weight_data),
                .bias_data                (bias_data),
                .result_valid             (legacy_result_valid),
                .result_ready             (result_ready && !mode_fp16_q),
                .result_token_base        (legacy_result_token_base),
                .result_output_base       (legacy_result_output_base),
                .result_batch_index       (legacy_result_batch_index),
                .result_token_mask        (legacy_result_token_mask),
                .result_output_mask       (legacy_result_output_mask),
                .result_data              (legacy_result_data),
                .mul_operand_a            (legacy_mul_operand_a),
                .mul_operand_b            (legacy_mul_operand_b),
                .external_mul_result      (external_mul_result),
                .add_operand_a            (legacy_add_operand_a),
                .add_operand_b            (legacy_add_operand_b),
                .external_add_result      (external_add_result),
                .profile_gemm_tile_step_o (legacy_profile_tile_step),
                .profile_valid_mac_delta_o(legacy_profile_valid_mac),
                .profile_tail_mac_delta_o (legacy_profile_tail_mac)
            );
        end else begin : gen_no_legacy
            assign legacy_busy = 1'b0;
            assign legacy_done = 1'b0;
            assign legacy_config_error = 1'b0;
            assign legacy_data_request = 1'b0;
            assign legacy_token_base = 32'd0;
            assign legacy_output_base = 32'd0;
            assign legacy_k_base = 32'd0;
            assign legacy_batch_index = 32'd0;
            assign legacy_result_valid = 1'b0;
            assign legacy_result_token_base = 32'd0;
            assign legacy_result_output_base = 32'd0;
            assign legacy_result_batch_index = 32'd0;
            assign legacy_result_token_mask = '0;
            assign legacy_result_output_mask = '0;
            assign legacy_result_data = '0;
            assign legacy_mul_operand_a = 32'd0;
            assign legacy_mul_operand_b = 32'd0;
            assign legacy_add_operand_a = 32'd0;
            assign legacy_add_operand_b = 32'd0;
            assign legacy_profile_tile_step = 1'b0;
            assign legacy_profile_valid_mac = 16'd0;
            assign legacy_profile_tail_mac = 16'd0;
        end
    endgenerate

    generate
        if ((ARRAY_ROWS == 8) && (ARRAY_COLS == 2) && (PE_LANES == 16)) begin : gen_fp16
            vit_gemm_fp16_parallel_scheduler #(
                .ARRAY_ROWS (ARRAY_ROWS),
                .ARRAY_COLS (ARRAY_COLS),
                .PE_LANES   (PE_LANES),
                .FP16_STREAMS(FP16_STREAMS)
            ) u_fp16 (
                .clk                      (clk),
                .rst                      (rst),
                .start                    (start && cfg_fp16_enable),
                .cfg_m                    (cfg_m),
                .cfg_k                    (cfg_k),
                .cfg_n                    (cfg_n),
                .cfg_batch_count          (cfg_batch_count),
                .cfg_bias_enable          (cfg_bias_enable),
                .cfg_weight_fp16_packed2  (cfg_weight_fp16_packed2),
                .busy                     (fp16_busy),
                .done                     (fp16_done),
                .config_error             (fp16_config_error),
                .data_request             (fp16_data_request),
                .data_valid               (data_valid && mode_fp16_q),
                .token_base               (fp16_token_base),
                .output_base              (fp16_output_base),
                .k_base                   (fp16_k_base),
                .batch_index              (fp16_batch_index),
                .activation_data          (activation_data),
                .weight_data              (weight_data),
                .bias_data                (bias_data),
                .result_address_base_i    (result_address_base_i),
                .result_generation_i      (result_generation_i),
                .result_valid             (fp16_result_valid),
                .result_ready             (result_ready && mode_fp16_q),
                .result_address_base_o    (fp16_result_address_base),
                .result_generation_o      (fp16_result_generation),
                .result_token_base        (fp16_result_token_base),
                .result_output_base       (fp16_result_output_base),
                .result_batch_index       (fp16_result_batch_index),
                .result_token_mask        (fp16_result_token_mask),
                .result_output_mask       (fp16_result_output_mask),
                .result_data              (fp16_result_data),
                .profile_gemm_tile_step_o (fp16_profile_tile_step),
                .profile_valid_mac_delta_o(fp16_profile_valid_mac),
                .profile_tail_mac_delta_o (fp16_profile_tail_mac),
                .profile_term_accept_delta_o(fp16_profile_term_accept),
                .profile_disabled_term_delta_o(
                    fp16_profile_disabled_term
                ),
                .profile_input_wait_o      (fp16_profile_input_wait),
                .profile_term_stall_o      (fp16_profile_term_stall),
                .profile_result_backpressure_o(
                    fp16_profile_result_backpressure
                ),
                .profile_compute_active_o  (fp16_profile_compute_active),
                .profile_dot_start_o       (fp16_profile_dot_start),
                .profile_result_vector_o   (fp16_profile_result_vector),
                .profile_invalid_delta_o   (fp16_profile_invalid),
                .profile_overflow_delta_o  (fp16_profile_overflow),
                .profile_length_error_delta_o(
                    fp16_profile_length_error
                ),
                .profile_subnormal_flushed_delta_o(
                    fp16_profile_subnormal_flushed
                ),
                .profile_panel_load_active_o(
                    fp16_profile_panel_load_active
                ),
                .profile_panel_compute_active_o(
                    fp16_profile_panel_compute_active
                ),
                .profile_panel_commit_o(fp16_profile_panel_commit),
                .profile_panel_claim_o(fp16_profile_panel_claim),
                .profile_panel_claim_mask_o(
                    fp16_profile_panel_claim_mask
                ),
                .profile_panel_release_o(fp16_profile_panel_release),
                .profile_panel_empty_stall_o(
                    fp16_profile_panel_empty_stall
                ),
                .profile_panel_full_stall_o(
                    fp16_profile_panel_full_stall
                ),
                .profile_panel_occupancy_o(
                    fp16_profile_panel_occupancy
                ),
                .profile_result_fifo_enqueue_o(
                    fp16_profile_result_fifo_enqueue
                ),
                .profile_result_fifo_dequeue_o(
                    fp16_profile_result_fifo_dequeue
                ),
                .profile_result_fifo_full_stall_o(
                    fp16_profile_result_fifo_full_stall
                ),
                .profile_result_fifo_occupancy_o(
                    fp16_profile_result_fifo_occupancy
                )
            );
        end else begin : gen_no_fp16
            logic reject_active_q;
            always_ff @(posedge clk) begin
                if (rst)
                    reject_active_q <= 1'b0;
                else if (start && cfg_fp16_enable)
                    reject_active_q <= 1'b1;
                else
                    reject_active_q <= 1'b0;
            end
            assign fp16_busy = reject_active_q;
            assign fp16_done = reject_active_q;
            assign fp16_config_error = reject_active_q;
            assign fp16_data_request = 1'b0;
            assign fp16_token_base = 32'd0;
            assign fp16_output_base = 32'd0;
            assign fp16_k_base = 32'd0;
            assign fp16_batch_index = 32'd0;
            assign fp16_result_valid = 1'b0;
            assign fp16_result_address_base = 66'd0;
            assign fp16_result_generation = 8'd0;
            assign fp16_result_token_base = 32'd0;
            assign fp16_result_output_base = 32'd0;
            assign fp16_result_batch_index = 32'd0;
            assign fp16_result_token_mask = '0;
            assign fp16_result_output_mask = '0;
            assign fp16_result_data = '0;
            assign fp16_profile_tile_step = 1'b0;
            assign fp16_profile_valid_mac = 16'd0;
            assign fp16_profile_tail_mac = 16'd0;
            assign fp16_profile_term_accept = 5'd0;
            assign fp16_profile_disabled_term = 5'd0;
            assign fp16_profile_input_wait = 1'b0;
            assign fp16_profile_term_stall = 1'b0;
            assign fp16_profile_result_backpressure = 1'b0;
            assign fp16_profile_compute_active = 1'b0;
            assign fp16_profile_dot_start = 1'b0;
            assign fp16_profile_result_vector = 1'b0;
            assign fp16_profile_invalid = 5'd0;
            assign fp16_profile_overflow = 5'd0;
            assign fp16_profile_length_error = 5'd0;
            assign fp16_profile_subnormal_flushed = 5'd0;
            assign fp16_profile_panel_load_active = 1'b0;
            assign fp16_profile_panel_compute_active = 1'b0;
            assign fp16_profile_panel_commit = 1'b0;
            assign fp16_profile_panel_claim = 1'b0;
            assign fp16_profile_panel_claim_mask = 2'b00;
            assign fp16_profile_panel_release = 1'b0;
            assign fp16_profile_panel_empty_stall = 1'b0;
            assign fp16_profile_panel_full_stall = 1'b0;
            assign fp16_profile_panel_occupancy = 2'd0;
            assign fp16_profile_result_fifo_enqueue = 1'b0;
            assign fp16_profile_result_fifo_dequeue = 1'b0;
            assign fp16_profile_result_fifo_full_stall = 1'b0;
            assign fp16_profile_result_fifo_occupancy = 2'd0;
        end
    endgenerate

    always_comb begin
        profile_m7_term_accept_delta_o = 5'd0;
        profile_m7_disabled_term_delta_o = 5'd0;
        profile_m7_input_wait_o = 1'b0;
        profile_m7_term_stall_o = 1'b0;
        profile_m7_result_backpressure_o = 1'b0;
        profile_m7_compute_active_o = 1'b0;
        profile_m7_dot_start_o = 1'b0;
        profile_m7_result_vector_o = 1'b0;
        profile_m7_invalid_delta_o = 5'd0;
        profile_m7_overflow_delta_o = 5'd0;
        profile_m7_length_error_delta_o = 5'd0;
        profile_m7_subnormal_flushed_delta_o = 5'd0;
        profile_m7_panel_load_active_o = 1'b0;
        profile_m7_panel_compute_active_o = 1'b0;
        profile_m7_panel_commit_o = 1'b0;
        profile_m7_panel_claim_o = 1'b0;
        profile_m7_panel_claim_mask_o = 2'b00;
        profile_m7_panel_release_o = 1'b0;
        profile_m7_panel_empty_stall_o = 1'b0;
        profile_m7_panel_full_stall_o = 1'b0;
        profile_m7_panel_occupancy_o = 2'd0;
        profile_m7_result_fifo_enqueue_o = 1'b0;
        profile_m7_result_fifo_dequeue_o = 1'b0;
        profile_m7_result_fifo_full_stall_o = 1'b0;
        profile_m7_result_fifo_occupancy_o = 2'd0;
        if (packed_without_fp16_q || legacy_unavailable_q) begin
            // One-cycle reset-free rejection pulse, matching the existing
            // unsupported-geometry fail-closed behavior.
            busy = 1'b1;
            done = 1'b1;
            config_error = 1'b1;
            data_request = 1'b0;
            token_base = 32'd0;
            output_base = 32'd0;
            k_base = 32'd0;
            batch_index = 32'd0;
            result_valid = 1'b0;
            result_address_base_o = 66'd0;
            result_generation_o = 8'd0;
            result_token_base = 32'd0;
            result_output_base = 32'd0;
            result_batch_index = 32'd0;
            result_token_mask = '0;
            result_output_mask = '0;
            result_data = '0;
            profile_gemm_tile_step_o = 1'b0;
            profile_valid_mac_delta_o = 16'd0;
            profile_tail_mac_delta_o = 16'd0;
            mul_operand_a = 32'd0;
            mul_operand_b = 32'd0;
            add_operand_a = 32'd0;
            add_operand_b = 32'd0;
        end else if (mode_fp16_q) begin
            busy = fp16_busy;
            done = fp16_done;
            config_error = fp16_config_error;
            data_request = fp16_data_request;
            token_base = fp16_token_base;
            output_base = fp16_output_base;
            k_base = fp16_k_base;
            batch_index = fp16_batch_index;
            result_valid = fp16_result_valid;
            result_address_base_o = fp16_result_address_base;
            result_generation_o = fp16_result_generation;
            result_token_base = fp16_result_token_base;
            result_output_base = fp16_result_output_base;
            result_batch_index = fp16_result_batch_index;
            result_token_mask = fp16_result_token_mask;
            result_output_mask = fp16_result_output_mask;
            result_data = fp16_result_data;
            profile_gemm_tile_step_o = fp16_profile_tile_step;
            profile_valid_mac_delta_o = fp16_profile_valid_mac;
            profile_tail_mac_delta_o = fp16_profile_tail_mac;
            profile_m7_term_accept_delta_o = fp16_profile_term_accept;
            profile_m7_disabled_term_delta_o = fp16_profile_disabled_term;
            profile_m7_input_wait_o = fp16_profile_input_wait;
            profile_m7_term_stall_o = fp16_profile_term_stall;
            profile_m7_result_backpressure_o =
                fp16_profile_result_backpressure;
            profile_m7_compute_active_o = fp16_profile_compute_active;
            profile_m7_dot_start_o = fp16_profile_dot_start;
            profile_m7_result_vector_o = fp16_profile_result_vector;
            profile_m7_invalid_delta_o = fp16_profile_invalid;
            profile_m7_overflow_delta_o = fp16_profile_overflow;
            profile_m7_length_error_delta_o = fp16_profile_length_error;
            profile_m7_subnormal_flushed_delta_o =
                fp16_profile_subnormal_flushed;
            profile_m7_panel_load_active_o =
                fp16_profile_panel_load_active;
            profile_m7_panel_compute_active_o =
                fp16_profile_panel_compute_active;
            profile_m7_panel_commit_o = fp16_profile_panel_commit;
            profile_m7_panel_claim_o = fp16_profile_panel_claim;
            profile_m7_panel_claim_mask_o = fp16_profile_panel_claim_mask;
            profile_m7_panel_release_o = fp16_profile_panel_release;
            profile_m7_panel_empty_stall_o =
                fp16_profile_panel_empty_stall;
            profile_m7_panel_full_stall_o =
                fp16_profile_panel_full_stall;
            profile_m7_panel_occupancy_o = fp16_profile_panel_occupancy;
            profile_m7_result_fifo_enqueue_o =
                fp16_profile_result_fifo_enqueue;
            profile_m7_result_fifo_dequeue_o =
                fp16_profile_result_fifo_dequeue;
            profile_m7_result_fifo_full_stall_o =
                fp16_profile_result_fifo_full_stall;
            profile_m7_result_fifo_occupancy_o =
                fp16_profile_result_fifo_occupancy;
            // The FP16 array owns its arithmetic.  Keep the shared legacy
            // FP32 services at benign values while the selected path runs.
            mul_operand_a = 32'd0;
            mul_operand_b = 32'd0;
            add_operand_a = 32'd0;
            add_operand_b = 32'd0;
        end else begin
            busy = legacy_busy;
            done = legacy_done;
            config_error = legacy_config_error;
            data_request = legacy_data_request;
            token_base = legacy_token_base;
            output_base = legacy_output_base;
            k_base = legacy_k_base;
            batch_index = legacy_batch_index;
            result_valid = legacy_result_valid;
            result_address_base_o = result_address_base_i;
            result_generation_o = result_generation_i;
            result_token_base = legacy_result_token_base;
            result_output_base = legacy_result_output_base;
            result_batch_index = legacy_result_batch_index;
            result_token_mask = legacy_result_token_mask;
            result_output_mask = legacy_result_output_mask;
            result_data = legacy_result_data;
            profile_gemm_tile_step_o = legacy_profile_tile_step;
            profile_valid_mac_delta_o = legacy_profile_valid_mac;
            profile_tail_mac_delta_o = legacy_profile_tail_mac;
            mul_operand_a = legacy_mul_operand_a;
            mul_operand_b = legacy_mul_operand_b;
            add_operand_a = legacy_add_operand_a;
            add_operand_b = legacy_add_operand_b;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && start &&
            (legacy_busy || fp16_busy || packed_without_fp16_q ||
             legacy_unavailable_q))
            $fatal(1, "GEMM mode selector observed start while busy");
    end
`endif

endmodule
