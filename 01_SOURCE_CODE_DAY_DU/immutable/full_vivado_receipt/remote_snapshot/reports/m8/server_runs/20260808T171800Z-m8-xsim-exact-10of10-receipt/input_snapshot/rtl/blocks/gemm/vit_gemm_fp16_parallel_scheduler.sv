`timescale 1ns/1ps

// Controlled M7 production scheduler for the R8/C2 FP16 streaming array.
//
// Non-packed FP16 commands retain the established single-staging-register
// schedule.  Packed-v3 commands use two explicitly owned K16 panel banks, so
// the frontend may complete two look-ahead panels while the stream array owns
// the preceding chunk.  Producer coordinates are held from request through
// data_valid; consumer K/last/data always come from the claimed bank.  The
// Gate-2 advances to the next output tile as soon as a result is enqueued.
// A depth-two result FIFO decouples compute from store backpressure; the final
// tile enters an explicit drain state and DONE is asserted only after every
// queued result has been accepted.  Every external interface is preserved.
(* keep_hierarchy = "yes", use_dsp = "no" *)
module vit_gemm_fp16_parallel_scheduler #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16,
    parameter integer FP16_STREAMS = 8
) (
    input  logic                                    clk,
    input  logic                                    rst,

    input  logic                                    start,
    input  logic [31:0]                             cfg_m,
    input  logic [31:0]                             cfg_k,
    input  logic [31:0]                             cfg_n,
    input  logic [31:0]                             cfg_batch_count,
    input  logic                                    cfg_bias_enable,
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
    // Absolute word address and command generation associated with the
    // result being computed.  Packed mode captures both into the result FIFO
    // before any scheduler coordinate may advance.
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

    output logic                                    profile_gemm_tile_step_o,
    output logic [15:0]                             profile_valid_mac_delta_o,
    output logic [15:0]                             profile_tail_mac_delta_o,
    output logic [4:0]                              profile_term_accept_delta_o,
    output logic [4:0]                              profile_disabled_term_delta_o,
    output logic                                    profile_input_wait_o,
    output logic                                    profile_term_stall_o,
    output logic                                    profile_result_backpressure_o,
    output logic                                    profile_compute_active_o,
    output logic                                    profile_dot_start_o,
    output logic                                    profile_result_vector_o,
    output logic [4:0]                              profile_invalid_delta_o,
    output logic [4:0]                              profile_overflow_delta_o,
    output logic [4:0]                              profile_length_error_delta_o,
    output logic [4:0]                              profile_subnormal_flushed_delta_o,
    output logic                                    profile_panel_load_active_o,
    output logic                                    profile_panel_compute_active_o,
    output logic                                    profile_panel_commit_o,
    output logic                                    profile_panel_claim_o,
    output logic [1:0]                              profile_panel_claim_mask_o,
    output logic                                    profile_panel_release_o,
    output logic                                    profile_panel_empty_stall_o,
    output logic                                    profile_panel_full_stall_o,
    output logic [1:0]                              profile_panel_occupancy_o,
    output logic                                    profile_result_fifo_enqueue_o,
    output logic                                    profile_result_fifo_dequeue_o,
    output logic                                    profile_result_fifo_full_stall_o,
    output logic [1:0]                              profile_result_fifo_occupancy_o
);

    localparam logic [32:0] ARRAY_ROWS_WIDE = 33'(ARRAY_ROWS);
    localparam logic [32:0] ARRAY_COLS_WIDE = 33'(ARRAY_COLS);
    localparam logic [32:0] PE_LANES_WIDE   = 33'(PE_LANES);
    localparam logic [15:0] PROFILE_TILE_MAC_SLOTS =
        16'(FP16_STREAMS * PE_LANES);
    localparam logic FP16_TWO_PASS = (FP16_STREAMS == ARRAY_ROWS);

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_REQUEST_CHUNK,
        STATE_START_TILE,
        STATE_SEND_CHUNK,
        STATE_WAIT_RESULT,
        STATE_PACK_WAIT_FIRST,
        STATE_PACK_START_TILE,
        STATE_PACK_WAIT_PANEL,
        STATE_PACK_SEND_CHUNK,
        STATE_PACK_WAIT_RESULT,
        STATE_PACK_DRAIN_RESULT,
        STATE_DONE
    } state_t;

    typedef enum logic [1:0] {
        PANEL_FREE,
        PANEL_RESERVED,
        PANEL_READY,
        PANEL_COMPUTE
    } panel_state_t;

    state_t state;
    logic [31:0] active_m;
    logic [31:0] active_k;
    logic [31:0] active_n;
    logic [31:0] active_batch_count;
    logic        active_bias_enable;
    logic        active_weight_fp16_packed2;
    logic [7:0]  active_result_generation;
    logic        config_error_q;
    // STREAMS=8 evaluates one physical R8/C1 pass at a time.  Column zero is
    // always first; column one reuses the same logical output tile after K is
    // rewound.  STREAMS=16 keeps the historical single-pass behavior.
    logic        fallback_column_q;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] activation_q;
    logic [ARRAY_COLS*PE_LANES*32-1:0] weight_q;
    logic [ARRAY_COLS*32-1:0] bias_q;

    panel_state_t panel_state_q [0:1];
    // Bank 0 deliberately reuses the established activation_q/weight_q/bias_q
    // staging registers.  Only bank 1 adds payload storage, keeping the
    // incremental ping-pong cost to one 5,184-bit panel rather than two.
    logic [ARRAY_ROWS*PE_LANES*32-1:0] panel1_activation_q;
    logic [ARRAY_COLS*PE_LANES*32-1:0] panel1_weight_q;
    logic [ARRAY_COLS*32-1:0] panel1_bias_q;
    logic [31:0] panel_token_q [0:1];
    logic [31:0] panel_output_q [0:1];
    logic [31:0] panel_k_q [0:1];
    logic [31:0] panel_batch_q [0:1];
    logic panel_last_q [0:1];
    logic load_request_active_q;
    logic load_bank_q;
    logic compute_bank_q;
    logic [31:0] next_load_k_q;
    logic all_chunks_loaded_q;

    logic free_bank_available;
    logic free_bank_select;
    logic ready_bank_available;
    logic ready_bank_select;
    logic [1:0] panel_occupancy_comb;
    logic packed_state_active;
    logic packed_load_state_active;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] selected_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] selected_weight_data;
    logic [ARRAY_COLS*32-1:0] selected_bias_data;
    logic [31:0] selected_token_base;
    logic [31:0] selected_output_base;
    logic [31:0] selected_k_base;
    logic [31:0] selected_batch_index;
    logic selected_last_k_chunk;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] routed_activation;
    logic [ARRAY_COLS*PE_LANES*32-1:0] routed_weight;
    logic [ARRAY_COLS*32-1:0] routed_bias;
    logic [PE_LANES-1:0] lane_valid;
    logic [ARRAY_ROWS-1:0] token_valid;
    logic [ARRAY_COLS-1:0] output_valid;

    logic bridge_start_ready;
    logic bridge_chunk_ready;
    logic bridge_busy;
    logic bridge_result_valid;
    logic bridge_result_ready;
    logic [7:0] bridge_result_token_mask;
    logic [1:0] bridge_result_output_mask;
    logic [511:0] bridge_result_data;
    logic [15:0] bridge_result_invalid;
    logic [15:0] bridge_result_overflow;
    logic [15:0] bridge_result_subnormal_flushed;
    logic [15:0] bridge_result_length_error;
    logic bridge_numerical_error;
    logic bridge_done;
    logic [4:0] bridge_term_accept_count;
    logic [4:0] bridge_disabled_term_accept_count;
    logic bridge_feeder_stall;
    logic bridge_result_backpressure;
    logic bridge_compute_active;

    logic fifo_flush;
    logic fifo_input_valid;
    logic fifo_input_ready;
    logic fifo_output_valid;
    logic fifo_output_ready;
    logic [65:0] fifo_output_address_base;
    logic [31:0] fifo_output_token_base;
    logic [31:0] fifo_output_output_base;
    logic [31:0] fifo_output_batch_index;
    logic [ARRAY_ROWS-1:0] fifo_output_token_mask;
    logic [ARRAY_COLS-1:0] fifo_output_output_mask;
    logic [7:0] fifo_output_generation;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] fifo_output_data;
    logic fifo_push_fire;
    logic fifo_pop_fire;
    logic [1:0] fifo_occupancy;
    logic packed_fifo_head_active;
    logic packed_tile_final;
    logic second_column_valid;

    logic last_k_chunk;
    logic chunk_fire;
    logic [15:0] profile_valid_mac_delta_comb;
    integer profile_row;
    integer profile_col;
    integer profile_lane;
    integer profile_result_index;
    integer profile_invalid_count;
    integer profile_overflow_count;
    integer profile_length_error_count;
    integer profile_subnormal_flushed_count;
    logic bridge_result_consume;
    logic [15:0] bridge_logical_result_mask;

    initial begin
        if ((ARRAY_ROWS != 8) || (ARRAY_COLS != 2) || (PE_LANES != 16))
            $fatal(1,
                   "FP16 scheduler requires the locked R8/C2/L16 geometry");
        if ((FP16_STREAMS != 8) && (FP16_STREAMS != 16))
            $fatal(1, "FP16 scheduler supports only 8 or 16 streams");
    end

    always_comb begin
        free_bank_available = 1'b0;
        free_bank_select = 1'b0;
        if (panel_state_q[0] == PANEL_FREE) begin
            free_bank_available = 1'b1;
            free_bank_select = 1'b0;
        end else if (panel_state_q[1] == PANEL_FREE) begin
            free_bank_available = 1'b1;
            free_bank_select = 1'b1;
        end

        ready_bank_available = 1'b0;
        ready_bank_select = 1'b0;
        if ((panel_state_q[0] == PANEL_READY) &&
            (panel_state_q[1] == PANEL_READY)) begin
            ready_bank_available = 1'b1;
            ready_bank_select = panel_k_q[1] < panel_k_q[0];
        end else if (panel_state_q[0] == PANEL_READY) begin
            ready_bank_available = 1'b1;
            ready_bank_select = 1'b0;
        end else if (panel_state_q[1] == PANEL_READY) begin
            ready_bank_available = 1'b1;
            ready_bank_select = 1'b1;
        end

        panel_occupancy_comb = 2'd0;
        if (panel_state_q[0] != PANEL_FREE)
            panel_occupancy_comb = panel_occupancy_comb + 2'd1;
        if (panel_state_q[1] != PANEL_FREE)
            panel_occupancy_comb = panel_occupancy_comb + 2'd1;
    end

    assign packed_state_active =
        (state == STATE_PACK_WAIT_FIRST) ||
        (state == STATE_PACK_START_TILE) ||
        (state == STATE_PACK_WAIT_PANEL) ||
        (state == STATE_PACK_SEND_CHUNK) ||
        (state == STATE_PACK_WAIT_RESULT) ||
        (state == STATE_PACK_DRAIN_RESULT);
    assign packed_load_state_active =
        (state == STATE_PACK_WAIT_FIRST) ||
        (state == STATE_PACK_START_TILE) ||
        (state == STATE_PACK_WAIT_PANEL) ||
        (state == STATE_PACK_SEND_CHUNK);
    assign packed_fifo_head_active =
        packed_state_active && fifo_output_valid;
    assign second_column_valid =
        ({1'b0, output_base} + 33'd1) < {1'b0, active_n};
    assign packed_tile_final =
        (!FP16_TWO_PASS || fallback_column_q || !second_column_valid) &&
        (({1'b0, output_base} + ARRAY_COLS_WIDE) >=
         {1'b0, active_n}) &&
        (({1'b0, token_base} + ARRAY_ROWS_WIDE) >=
         {1'b0, active_m}) &&
        ((batch_index + 1'b1) >= active_batch_count);

    always_comb begin
        selected_activation_data = activation_q;
        selected_weight_data = weight_q;
        selected_bias_data = bias_q;
        selected_token_base = token_base;
        selected_output_base = output_base;
        selected_k_base = k_base;
        selected_batch_index = batch_index;
        selected_last_k_chunk =
            (({1'b0, k_base} + PE_LANES_WIDE) >= {1'b0, active_k});
        if (packed_state_active) begin
            if (compute_bank_q) begin
                selected_activation_data = panel1_activation_q;
                selected_weight_data = panel1_weight_q;
                selected_bias_data = panel1_bias_q;
            end
            selected_token_base = panel_token_q[compute_bank_q];
            selected_output_base = panel_output_q[compute_bank_q];
            selected_k_base = panel_k_q[compute_bank_q];
            selected_batch_index = panel_batch_q[compute_bank_q];
            selected_last_k_chunk = panel_last_q[compute_bank_q];
        end
    end

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign config_error = config_error_q;
    assign data_request = (state == STATE_REQUEST_CHUNK) ||
                          (packed_load_state_active &&
                           load_request_active_q);
    assign last_k_chunk = selected_last_k_chunk;

    // Non-packed FP16 remains the exact direct bridge-to-store path.  Packed
    // mode first transfers the complete result identity into the FIFO and
    // presents only the FIFO head to the external store path.
    assign result_valid =
        ((state == STATE_WAIT_RESULT) && bridge_result_valid &&
         !bridge_numerical_error) ||
        packed_fifo_head_active;
    assign bridge_result_ready =
        ((state == STATE_WAIT_RESULT) && bridge_result_valid &&
         (bridge_numerical_error || result_ready)) ||
        ((state == STATE_PACK_WAIT_RESULT) && bridge_result_valid &&
         (bridge_numerical_error || fifo_input_ready));
    assign result_address_base_o =
        packed_fifo_head_active ?
            fifo_output_address_base : result_address_base_i;
    assign result_generation_o =
        packed_fifo_head_active ?
            fifo_output_generation : active_result_generation;
    assign result_token_base =
        packed_fifo_head_active ?
            fifo_output_token_base : token_base;
    assign result_output_base =
        packed_fifo_head_active ?
            fifo_output_output_base : output_base;
    assign result_batch_index =
        packed_fifo_head_active ?
            fifo_output_batch_index : batch_index;
    assign result_token_mask =
        packed_fifo_head_active ?
            fifo_output_token_mask : bridge_result_token_mask;
    assign result_output_mask =
        packed_fifo_head_active ?
            fifo_output_output_mask : bridge_result_output_mask;
    assign result_data =
        packed_fifo_head_active ?
            fifo_output_data : bridge_result_data;

    assign fifo_flush = (state == STATE_IDLE) && start;
    assign fifo_input_valid =
        (state == STATE_PACK_WAIT_RESULT) && bridge_result_valid &&
        !bridge_numerical_error;
    assign fifo_output_ready =
        packed_state_active && result_ready;

    vit_gemm_result_fifo #(
        .ARRAY_ROWS      (ARRAY_ROWS),
        .ARRAY_COLS      (ARRAY_COLS),
        .GENERATION_BITS (8),
        .DEPTH           (2)
    ) u_result_fifo (
        .clk                    (clk),
        .rst                    (rst),
        .flush_i                (fifo_flush),
        .input_valid_i          (fifo_input_valid),
        .input_ready_o          (fifo_input_ready),
        .input_address_base_i   (result_address_base_i),
        .input_token_base_i     (panel_token_q[compute_bank_q]),
        .input_output_base_i    (panel_output_q[compute_bank_q]),
        .input_batch_index_i    (panel_batch_q[compute_bank_q]),
        .input_token_mask_i     (bridge_result_token_mask),
        .input_output_mask_i    (bridge_result_output_mask),
        .input_generation_i     (active_result_generation),
        .input_data_i           (bridge_result_data),
        .output_valid_o         (fifo_output_valid),
        .output_ready_i         (fifo_output_ready),
        .output_address_base_o  (fifo_output_address_base),
        .output_token_base_o    (fifo_output_token_base),
        .output_output_base_o   (fifo_output_output_base),
        .output_batch_index_o   (fifo_output_batch_index),
        .output_token_mask_o    (fifo_output_token_mask),
        .output_output_mask_o   (fifo_output_output_mask),
        .output_generation_o    (fifo_output_generation),
        .output_data_o          (fifo_output_data),
        .push_fire_o            (fifo_push_fire),
        .pop_fire_o             (fifo_pop_fire),
        .occupancy_o            (fifo_occupancy)
    );

    assign chunk_fire =
        ((state == STATE_SEND_CHUNK) ||
         (state == STATE_PACK_SEND_CHUNK)) && bridge_chunk_ready;
    assign profile_gemm_tile_step_o = chunk_fire;

    always_comb begin
        profile_valid_mac_delta_comb = 16'd0;
        if (chunk_fire) begin
            for (profile_row = 0; profile_row < ARRAY_ROWS;
                 profile_row = profile_row + 1)
                for (profile_col = 0; profile_col < ARRAY_COLS;
                     profile_col = profile_col + 1)
                    for (profile_lane = 0; profile_lane < PE_LANES;
                         profile_lane = profile_lane + 1)
                        if (token_valid[profile_row] &&
                            output_valid[profile_col] &&
                            (!FP16_TWO_PASS ||
                             (profile_col == fallback_column_q)) &&
                            lane_valid[profile_lane])
                            profile_valid_mac_delta_comb =
                                profile_valid_mac_delta_comb + 16'd1;
        end
    end

    assign profile_valid_mac_delta_o = profile_valid_mac_delta_comb;
    assign profile_tail_mac_delta_o = chunk_fire ?
        (PROFILE_TILE_MAC_SLOTS - profile_valid_mac_delta_comb) : 16'd0;
    assign profile_term_accept_delta_o = bridge_term_accept_count;
    assign profile_disabled_term_delta_o =
        bridge_disabled_term_accept_count;
    assign profile_input_wait_o =
        (((state == STATE_REQUEST_CHUNK) ||
          (packed_load_state_active && load_request_active_q)) &&
         !data_valid);
    assign profile_term_stall_o = bridge_feeder_stall;
    assign profile_result_backpressure_o =
        bridge_result_backpressure ||
        (packed_fifo_head_active && !result_ready);
    assign profile_compute_active_o = bridge_compute_active;
    assign profile_dot_start_o =
        (((state == STATE_START_TILE) ||
          (state == STATE_PACK_START_TILE)) && bridge_start_ready);
    assign profile_result_vector_o = bridge_result_consume;

    assign profile_panel_load_active_o =
        packed_load_state_active && load_request_active_q;
    assign profile_panel_compute_active_o =
        packed_state_active && bridge_compute_active;
    assign profile_panel_commit_o =
        packed_load_state_active && load_request_active_q && data_valid;
    assign profile_panel_claim_o =
        ((state == STATE_PACK_START_TILE) && bridge_start_ready) ||
        ((state == STATE_PACK_WAIT_PANEL) && ready_bank_available);
    assign profile_panel_claim_mask_o =
        ((state == STATE_PACK_START_TILE) && bridge_start_ready) ?
            (compute_bank_q ? 2'b10 : 2'b01) :
        ((state == STATE_PACK_WAIT_PANEL) && ready_bank_available) ?
            (ready_bank_select ? 2'b10 : 2'b01) : 2'b00;
    assign profile_panel_release_o =
        (state == STATE_PACK_SEND_CHUNK) && bridge_chunk_ready;
    assign profile_panel_empty_stall_o =
        (((state == STATE_PACK_WAIT_FIRST) ||
          (state == STATE_PACK_WAIT_PANEL)) && !ready_bank_available);
    assign profile_panel_full_stall_o =
        packed_load_state_active && !load_request_active_q &&
        !all_chunks_loaded_q && !free_bank_available;
    assign profile_panel_occupancy_o =
        packed_state_active ? panel_occupancy_comb : 2'd0;
    assign profile_result_fifo_enqueue_o = fifo_push_fire;
    assign profile_result_fifo_dequeue_o = fifo_pop_fire;
    assign profile_result_fifo_full_stall_o =
        (state == STATE_PACK_WAIT_RESULT) && bridge_result_valid &&
        !bridge_numerical_error && !fifo_input_ready;
    assign profile_result_fifo_occupancy_o = fifo_occupancy;

    assign bridge_result_consume = bridge_result_valid && bridge_result_ready;
    always_comb begin
        bridge_logical_result_mask = 16'd0;
        profile_invalid_count = 0;
        profile_overflow_count = 0;
        profile_length_error_count = 0;
        profile_subnormal_flushed_count = 0;
        for (profile_result_index = 0;
             profile_result_index < ARRAY_ROWS*ARRAY_COLS;
             profile_result_index = profile_result_index + 1) begin
            bridge_logical_result_mask[profile_result_index] =
                bridge_result_token_mask[profile_result_index / ARRAY_COLS] &&
                bridge_result_output_mask[profile_result_index % ARRAY_COLS];
            if (bridge_result_consume &&
                bridge_logical_result_mask[profile_result_index]) begin
                if (bridge_result_invalid[profile_result_index])
                    profile_invalid_count = profile_invalid_count + 1;
                if (bridge_result_overflow[profile_result_index])
                    profile_overflow_count = profile_overflow_count + 1;
                if (bridge_result_length_error[profile_result_index])
                    profile_length_error_count =
                        profile_length_error_count + 1;
                if (bridge_result_subnormal_flushed[profile_result_index])
                    profile_subnormal_flushed_count =
                        profile_subnormal_flushed_count + 1;
            end
        end
        profile_invalid_delta_o = 5'(profile_invalid_count);
        profile_overflow_delta_o = 5'(profile_overflow_count);
        profile_length_error_delta_o = 5'(profile_length_error_count);
        profile_subnormal_flushed_delta_o =
            5'(profile_subnormal_flushed_count);
    end

    vit_gemm_operand_router #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) u_operand_router (
        .active_m               (active_m),
        .active_k               (active_k),
        .active_n               (active_n),
        .token_base             (selected_token_base),
        .output_base            (selected_output_base),
        .k_base                 (selected_k_base),
        .activation_data        (selected_activation_data),
        .weight_data            (selected_weight_data),
        .bias_data              (selected_bias_data),
        .routed_activation_data (routed_activation),
        .routed_weight_data     (routed_weight),
        .routed_bias_data       (routed_bias),
        .lane_valid             (lane_valid),
        .token_valid            (token_valid),
        .output_valid           (output_valid)
    );

    vit_gemm_fp16_stream_array #(
        .STREAMS          (FP16_STREAMS),
        .FLUSH_SUBNORMALS (0)
    ) u_stream_array (
        .clk                                  (clk),
        .rst                                  (rst),
        .start_valid_i                        (
            (state == STATE_START_TILE) ||
            (state == STATE_PACK_START_TILE)
        ),
        .start_ready_o                        (bridge_start_ready),
        .bias_enable_i                        (active_bias_enable),
        .token_valid_i                        (token_valid),
        .output_valid_i                       (output_valid),
        .fallback_column_i                    (fallback_column_q),
        .weight_fp16_packed2_i                (
            active_weight_fp16_packed2
        ),
        .bias_data_i                          (routed_bias),
        .chunk_valid_i                        (
            (state == STATE_SEND_CHUNK) ||
            (state == STATE_PACK_SEND_CHUNK)
        ),
        .chunk_ready_o                        (bridge_chunk_ready),
        .chunk_last_i                         (last_k_chunk),
        .lane_valid_i                         (lane_valid),
        .activation_data_i                    (routed_activation),
        .weight_data_i                        (routed_weight),
        .busy_o                               (bridge_busy),
        .result_valid_o                       (bridge_result_valid),
        .result_ready_i                       (bridge_result_ready),
        .result_token_mask_o                  (bridge_result_token_mask),
        .result_output_mask_o                 (bridge_result_output_mask),
        .result_data_o                        (bridge_result_data),
        .result_invalid_o                     (bridge_result_invalid),
        .result_overflow_o                    (bridge_result_overflow),
        .result_subnormal_flushed_o           (
            bridge_result_subnormal_flushed
        ),
        .result_length_error_o                (bridge_result_length_error),
        .numerical_error_o                    (bridge_numerical_error),
        .done_o                               (bridge_done),
        .profile_term_accept_count_o          (bridge_term_accept_count),
        .profile_disabled_term_accept_count_o (
            bridge_disabled_term_accept_count
        ),
        .profile_feeder_stall_o                (bridge_feeder_stall),
        .profile_result_backpressure_o        (
            bridge_result_backpressure
        ),
        .profile_compute_active_o              (bridge_compute_active)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            active_m <= 32'd0;
            active_k <= 32'd0;
            active_n <= 32'd0;
            active_batch_count <= 32'd0;
            active_bias_enable <= 1'b0;
            active_weight_fp16_packed2 <= 1'b0;
            active_result_generation <= 8'd0;
            config_error_q <= 1'b0;
            fallback_column_q <= 1'b0;
            token_base <= 32'd0;
            output_base <= 32'd0;
            k_base <= 32'd0;
            batch_index <= 32'd0;
            activation_q <= '0;
            weight_q <= '0;
            bias_q <= '0;
            panel_state_q[0] <= PANEL_FREE;
            panel_state_q[1] <= PANEL_FREE;
            panel1_activation_q <= '0;
            panel1_weight_q <= '0;
            panel1_bias_q <= '0;
            panel_token_q[0] <= 32'd0;
            panel_token_q[1] <= 32'd0;
            panel_output_q[0] <= 32'd0;
            panel_output_q[1] <= 32'd0;
            panel_k_q[0] <= 32'd0;
            panel_k_q[1] <= 32'd0;
            panel_batch_q[0] <= 32'd0;
            panel_batch_q[1] <= 32'd0;
            panel_last_q[0] <= 1'b0;
            panel_last_q[1] <= 1'b0;
            load_request_active_q <= 1'b0;
            load_bank_q <= 1'b0;
            compute_bank_q <= 1'b0;
            next_load_k_q <= 32'd0;
            all_chunks_loaded_q <= 1'b0;
        end else begin
            // Packed producer.  Only one native frontend request may be
            // outstanding, but either free panel bank may own it.  Request
            // coordinates and ownership remain stable until data_valid.
            if (packed_load_state_active) begin
                if (load_request_active_q) begin
                    if (data_valid) begin
                        if (load_bank_q) begin
                            panel1_activation_q <= activation_data;
                            panel1_weight_q <= weight_data;
                            panel1_bias_q <= bias_data;
                        end else begin
                            activation_q <= activation_data;
                            weight_q <= weight_data;
                            bias_q <= bias_data;
                        end
                        panel_state_q[load_bank_q] <= PANEL_READY;
                        load_request_active_q <= 1'b0;
                        if (panel_last_q[load_bank_q]) begin
                            all_chunks_loaded_q <= 1'b1;
                        end else begin
                            next_load_k_q <=
                                panel_k_q[load_bank_q] + PE_LANES;
                        end
                    end
                end else if (!all_chunks_loaded_q && free_bank_available) begin
                    load_bank_q <= free_bank_select;
                    panel_state_q[free_bank_select] <= PANEL_RESERVED;
                    panel_token_q[free_bank_select] <= token_base;
                    panel_output_q[free_bank_select] <= output_base;
                    panel_k_q[free_bank_select] <= next_load_k_q;
                    panel_batch_q[free_bank_select] <= batch_index;
                    panel_last_q[free_bank_select] <=
                        (({1'b0, next_load_k_q} + PE_LANES_WIDE) >=
                         {1'b0, active_k});
                    k_base <= next_load_k_q;
                    load_request_active_q <= 1'b1;
                end
            end

            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_base <= 32'd0;
                        output_base <= 32'd0;
                        k_base <= 32'd0;
                        batch_index <= 32'd0;
                        config_error_q <= 1'b0;
                        fallback_column_q <= 1'b0;
                        panel_state_q[0] <= PANEL_FREE;
                        panel_state_q[1] <= PANEL_FREE;
                        load_request_active_q <= 1'b0;
                        load_bank_q <= 1'b0;
                        compute_bank_q <= 1'b0;
                        next_load_k_q <= 32'd0;
                        all_chunks_loaded_q <= 1'b0;
                        if ((cfg_batch_count == 0) || (cfg_m == 0) ||
                            (cfg_k == 0) || (cfg_n == 0)) begin
                            config_error_q <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            active_m <= cfg_m;
                            active_k <= cfg_k;
                            active_n <= cfg_n;
                            active_batch_count <= cfg_batch_count;
                            active_bias_enable <= cfg_bias_enable;
                            active_weight_fp16_packed2 <=
                                cfg_weight_fp16_packed2;
                            active_result_generation <=
                                result_generation_i;
                            if (cfg_weight_fp16_packed2)
                                state <= STATE_PACK_WAIT_FIRST;
                            else
                                state <= STATE_REQUEST_CHUNK;
                        end
                    end
                end

                STATE_REQUEST_CHUNK: begin
                    if (data_valid) begin
                        activation_q <= activation_data;
                        weight_q <= weight_data;
                        bias_q <= bias_data;
                        if (k_base == 0)
                            state <= STATE_START_TILE;
                        else
                            state <= STATE_SEND_CHUNK;
                    end
                end

                STATE_START_TILE: begin
                    if (bridge_start_ready)
                        state <= STATE_SEND_CHUNK;
                end

                STATE_SEND_CHUNK: begin
                    if (bridge_chunk_ready) begin
                        if (last_k_chunk)
                            state <= STATE_WAIT_RESULT;
                        else begin
                            k_base <= k_base + PE_LANES;
                            state <= STATE_REQUEST_CHUNK;
                        end
                    end
                end

                STATE_PACK_WAIT_FIRST: begin
                    if (ready_bank_available) begin
                        compute_bank_q <= ready_bank_select;
                        state <= STATE_PACK_START_TILE;
                    end
                end

                STATE_PACK_START_TILE: begin
                    if (bridge_start_ready) begin
                        panel_state_q[compute_bank_q] <= PANEL_COMPUTE;
                        state <= STATE_PACK_SEND_CHUNK;
                    end
                end

                STATE_PACK_WAIT_PANEL: begin
                    if (ready_bank_available) begin
                        compute_bank_q <= ready_bank_select;
                        panel_state_q[ready_bank_select] <= PANEL_COMPUTE;
                        state <= STATE_PACK_SEND_CHUNK;
                    end
                end

                STATE_PACK_SEND_CHUNK: begin
                    if (bridge_chunk_ready) begin
                        panel_state_q[compute_bank_q] <= PANEL_FREE;
                        if (panel_last_q[compute_bank_q])
                            state <= STATE_PACK_WAIT_RESULT;
                        else
                            state <= STATE_PACK_WAIT_PANEL;
                    end
                end

                STATE_PACK_WAIT_RESULT: begin
                    if (bridge_result_valid && bridge_numerical_error) begin
                        config_error_q <= 1'b1;
                        panel_state_q[0] <= PANEL_FREE;
                        panel_state_q[1] <= PANEL_FREE;
                        load_request_active_q <= 1'b0;
                        all_chunks_loaded_q <= 1'b0;
                        // Gate-2 may already have older, valid results queued
                        // or in the serialized store path.  Do not flush the
                        // FIFO underneath that valid/ready contract.  Consume
                        // only the poisoned bridge result, then drain every
                        // older entry before reporting the command error.
                        if ((fifo_occupancy == 0) ||
                            ((fifo_occupancy == 1) && fifo_pop_fire))
                            state <= STATE_DONE;
                        else
                            state <= STATE_PACK_DRAIN_RESULT;
                    end else if (fifo_push_fire) begin
                        panel_state_q[0] <= PANEL_FREE;
                        panel_state_q[1] <= PANEL_FREE;
                        load_request_active_q <= 1'b0;
                        load_bank_q <= 1'b0;
                        compute_bank_q <= 1'b0;
                        next_load_k_q <= 32'd0;
                        all_chunks_loaded_q <= 1'b0;
                        k_base <= 32'd0;
                        if (FP16_TWO_PASS && !fallback_column_q &&
                            second_column_valid) begin
                            // Same logical R8/C2 tile, second physical R8/C1
                            // pass.  Keep output/base/generation identity and
                            // rewind K/panel ownership only.
                            fallback_column_q <= 1'b1;
                            state <= STATE_PACK_WAIT_FIRST;
                        end else if (packed_tile_final) begin
                            // The final result has just become FIFO-owned.
                            // Keep the scheduler alive until every queued
                            // entry, including a depth-2 tail, is acknowledged.
                            state <= STATE_PACK_DRAIN_RESULT;
                        end else if (({1'b0, output_base} +
                                     ARRAY_COLS_WIDE) < {1'b0, active_n}) begin
                            fallback_column_q <= 1'b0;
                            output_base <= output_base + ARRAY_COLS;
                            state <= STATE_PACK_WAIT_FIRST;
                        end else begin
                            fallback_column_q <= 1'b0;
                            output_base <= 32'd0;
                            if (({1'b0, token_base} + ARRAY_ROWS_WIDE) <
                                {1'b0, active_m}) begin
                                token_base <= token_base + ARRAY_ROWS;
                                state <= STATE_PACK_WAIT_FIRST;
                            end else begin
                                token_base <= 32'd0;
                                batch_index <= batch_index + 1'b1;
                                state <= STATE_PACK_WAIT_FIRST;
                            end
                        end
                    end
                end

                STATE_PACK_DRAIN_RESULT: begin
                    if (fifo_pop_fire && (fifo_occupancy == 1)) begin
                        panel_state_q[0] <= PANEL_FREE;
                        panel_state_q[1] <= PANEL_FREE;
                        load_request_active_q <= 1'b0;
                        load_bank_q <= 1'b0;
                        compute_bank_q <= 1'b0;
                        next_load_k_q <= 32'd0;
                        all_chunks_loaded_q <= 1'b0;
                        k_base <= 32'd0;
                        state <= STATE_DONE;
                    end
                end

                STATE_WAIT_RESULT: begin
                    if (bridge_result_valid && bridge_numerical_error) begin
                        // Consume the poisoned result internally.  No result
                        // valid reaches the memory frontend, and DONE carries
                        // config_error so the command fails closed.
                        config_error_q <= 1'b1;
                        state <= STATE_DONE;
                    end else if (bridge_result_valid && result_ready) begin
                        k_base <= 32'd0;
                        if (FP16_TWO_PASS && !fallback_column_q &&
                            second_column_valid) begin
                            fallback_column_q <= 1'b1;
                            state <= STATE_REQUEST_CHUNK;
                        end else if (({1'b0, output_base} + ARRAY_COLS_WIDE) <
                            {1'b0, active_n}) begin
                            fallback_column_q <= 1'b0;
                            output_base <= output_base + ARRAY_COLS;
                            state <= STATE_REQUEST_CHUNK;
                        end else begin
                            fallback_column_q <= 1'b0;
                            output_base <= 32'd0;
                            if (({1'b0, token_base} + ARRAY_ROWS_WIDE) <
                                {1'b0, active_m}) begin
                                token_base <= token_base + ARRAY_ROWS;
                                state <= STATE_REQUEST_CHUNK;
                            end else if ((batch_index + 1'b1) <
                                         active_batch_count) begin
                                token_base <= 32'd0;
                                batch_index <= batch_index + 1'b1;
                                state <= STATE_REQUEST_CHUNK;
                            end else begin
                                state <= STATE_DONE;
                            end
                        end
                    end
                end

                STATE_DONE: begin
                    panel_state_q[0] <= PANEL_FREE;
                    panel_state_q[1] <= PANEL_FREE;
                    load_request_active_q <= 1'b0;
                    all_chunks_loaded_q <= 1'b0;
                    state <= STATE_IDLE;
                end

                default: begin
                    config_error_q <= 1'b1;
                    panel_state_q[0] <= PANEL_FREE;
                    panel_state_q[1] <= PANEL_FREE;
                    load_request_active_q <= 1'b0;
                    all_chunks_loaded_q <= 1'b0;
                    state <= STATE_DONE;
                end
            endcase
        end
    end

    // These bridge observability hooks are intentionally held at this local
    // seam until the append-only M7 counter ABI gate.  Keep them visible to
    // lint without changing the existing profile register meanings here.
    logic unused_bridge_status;
    assign unused_bridge_status =
        bridge_busy ^ bridge_done ^ bridge_result_invalid[0] ^
        bridge_result_overflow[0] ^ bridge_result_subnormal_flushed[0] ^
        bridge_result_length_error[0] ^ bridge_term_accept_count[0] ^
        bridge_disabled_term_accept_count[0] ^ bridge_logical_result_mask[0];

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (((state == STATE_START_TILE) ||
                 (state == STATE_PACK_START_TILE)) &&
                !bridge_start_ready &&
                !bridge_busy)
                $fatal(1, "FP16 bridge start handshake deadlock");
            if (((state == STATE_WAIT_RESULT) ||
                 (state == STATE_PACK_WAIT_RESULT)) &&
                bridge_result_valid &&
                bridge_numerical_error && result_valid &&
                !packed_fifo_head_active)
                $fatal(1, "poisoned FP16 result escaped fail-closed gate");
            if (packed_fifo_head_active && !result_ready) begin
                if ((result_address_base_o !== fifo_output_address_base) ||
                    (result_generation_o !== fifo_output_generation) ||
                    (result_token_base !== fifo_output_token_base) ||
                    (result_output_base !== fifo_output_output_base) ||
                    (result_batch_index !== fifo_output_batch_index) ||
                    (result_token_mask !== fifo_output_token_mask) ||
                    (result_output_mask !== fifo_output_output_mask) ||
                    (result_data !== fifo_output_data))
                    $fatal(1, "packed result FIFO head metadata mismatch");
            end
            if ((state == STATE_DONE) && active_weight_fp16_packed2) begin
                if (fifo_occupancy != 0)
                    $fatal(1, "packed DONE asserted before FIFO drain");
                if ((panel_occupancy_comb != 0) ||
                    load_request_active_q || bridge_compute_active)
                    $fatal(1, "packed DONE asserted with active stage");
            end
            if (packed_load_state_active && data_valid &&
                !load_request_active_q)
                $fatal(1, "packed panel response has no reserved owner");
            if (load_request_active_q &&
                (panel_state_q[load_bank_q] != PANEL_RESERVED))
                $fatal(1, "packed load owner is not RESERVED");
            if ((state == STATE_PACK_SEND_CHUNK) &&
                (panel_state_q[compute_bank_q] != PANEL_COMPUTE))
                $fatal(1, "packed consumer bank is not COMPUTE");
            if ((panel_state_q[0] == PANEL_COMPUTE) &&
                (panel_state_q[1] == PANEL_COMPUTE))
                $fatal(1, "both packed banks claimed for one stream array");
        end
    end
`endif

endmodule
