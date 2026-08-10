`timescale 1ns/1ps

// Phase-E hierarchical core integration.
//
// Hierarchy:
//   command controller  - accepts/reports descriptors
//   engine dispatch     - decodes the active opcode and selects status
//   memory frontend     - gathers operands and scatters results
//   compute blocks      - GEMM, vector, layout, LayerNorm, softmax, GELU,
//                         and argmax
//
// Large input/parameter/scratch tensors stay behind the serialized logical
// word interface. The memory frontend only infers bounded GEMM A-panel and
// bias caches; compute blocks latch their current native tile/vector.
(* use_dsp = "no" *)
module vit_phase_e_engine_top #(
    parameter integer ARRAY_ROWS      = 2,
    parameter integer ARRAY_COLS      = 2,
    parameter integer PE_LANES        = 16,
    parameter integer FP16_STREAMS    = 8,
    parameter integer VECTOR_LANES    = 16,
    parameter integer GEMM_A_CACHE_DEPTH_WORDS = 3072,
    parameter integer GEMM_BIAS_CACHE_DEPTH_WORDS = 3072,
    parameter integer SCRATCH_WORDS   = 32'h001e_6000,
    parameter integer INPUT_WORDS     = 150_528,
    parameter integer PARAM_WORDS     = 32'h0024_1000
)(
    input  logic                           clk,
    input  logic                           rst,

    input  logic                           cmd_valid,
    output logic                           cmd_ready,
    input  vit_phase_e_pkg::phase_e_cmd_t  cmd,
    output logic                           cmd_done,
    output logic                           cmd_error,
    output logic                           busy,

    output logic                           parameter_request,
    input  logic                           parameter_ready,
    output vit_phase_e_pkg::phase_e_cmd_t  parameter_command,

    output logic                           mem_req_valid,
    input  logic                           mem_req_ready,
    output logic                           mem_req_write,
    output vit_phase_e_pkg::phase_e_mem_space_t mem_req_space,
    output logic [31:0]                    mem_req_word_address,
    output logic [31:0]                    mem_req_write_data,
    output logic [3:0]                     mem_req_write_strobe,
    output logic                           mem_req_read_ahead_safe,
    output logic [5:0]                     mem_req_contiguous_words,
    input  logic                           mem_rsp_valid,
    output logic                           mem_rsp_ready,
    input  logic [31:0]                    mem_rsp_read_data,
    input  logic                           mem_rsp_error,

    // Deprecated loader/debug pins retained for named-port compatibility.
    input  logic                           input_write_enable,
    input  logic [31:0]                    input_write_address,
    input  logic [31:0]                    input_write_data,
    input  logic                           parameter_write_enable,
    input  logic [31:0]                    parameter_write_address,
    input  logic [31:0]                    parameter_write_data,
    input  logic                           scratch_write_enable,
    input  logic [31:0]                    scratch_write_address,
    input  logic [31:0]                    scratch_write_data,
    input  logic [31:0]                    scratch_read_address,
    output logic [31:0]                    scratch_read_data,

    output logic                           class_result_valid,
    output logic [31:0]                    class_index,
    output logic [31:0]                    class_logit,

    output vit_phase_e_pkg::phase_e_profile_core_events_t
                                           profile_events,
    output vit_phase_e_pkg::phase_e_m7_profile_events_t
                                           m7_profile_events
);

    import vit_phase_e_pkg::*;

    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    phase_e_cmd_t active_cmd;
    logic command_accept;
    logic command_launch;
    logic command_execute;
    logic memory_error_latched;
    logic engine_rst;
    logic [2:0] state;
    logic [3:0] mem_state;
    logic selected_done;
    logic selected_error;
    logic selected_data_request;
    logic selected_result_valid;
    logic [15:0] read_word_count;
    logic [15:0] write_word_count;
    phase_e_cmd_t profile_command;
    logic selected_engine_busy;
    logic profile_logical_read_word;
    logic profile_logical_write_word;
    logic profile_load_active;
    logic profile_store_active;
    logic profile_a_cache_lookup;
    logic profile_a_cache_hit;
    logic profile_a_cache_miss;
    logic profile_bias_cache_lookup;
    logic profile_bias_cache_hit;
    logic profile_bias_cache_miss;
    logic profile_b_bypass;
    logic profile_frontend_error;
    logic [3:0] profile_m7_a_vector_hit_word_delta;
    logic profile_m7_a_vector_protocol_error;
    logic profile_gemm_tile_step;
    logic [15:0] profile_valid_mac_delta;
    logic [15:0] profile_tail_mac_delta;
    logic [4:0] profile_m7_term_accept_delta;
    logic [4:0] profile_m7_disabled_term_delta;
    logic profile_m7_input_wait;
    logic profile_m7_term_stall;
    logic profile_m7_result_backpressure;
    logic profile_m7_compute_active;
    logic profile_m7_dot_start;
    logic profile_m7_result_vector;
    logic [4:0] profile_m7_invalid_delta;
    logic [4:0] profile_m7_overflow_delta;
    logic [4:0] profile_m7_length_error_delta;
    logic [4:0] profile_m7_subnormal_flushed_delta;
    logic profile_m7_panel_load_active;
    logic profile_m7_panel_compute_active;
    logic profile_m7_panel_commit;
    logic profile_m7_panel_claim;
    logic [1:0] profile_m7_panel_claim_mask;
    logic profile_m7_panel_release;
    logic profile_m7_panel_empty_stall;
    logic profile_m7_panel_full_stall;
    logic [1:0] profile_m7_panel_occupancy;
    logic profile_m7_result_fifo_enqueue;
    logic profile_m7_result_fifo_dequeue;
    logic profile_m7_result_fifo_full_stall;
    logic [1:0] profile_m7_result_fifo_occupancy;
    logic profile_m7_result_generation_error;
    logic profile_m7_fp16_command;
    logic profile_m7_packed_command;

    // GEMM block.
    logic gemm_start;
    logic gemm_busy;
    logic gemm_done;
    logic gemm_config_error;
    logic gemm_data_request;
    logic gemm_data_valid;
    logic [31:0] gemm_token_base;
    logic [31:0] gemm_output_base;
    logic [31:0] gemm_k_base;
    logic [31:0] gemm_batch_index;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] gemm_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] gemm_weight_data;
    logic [ARRAY_COLS*32-1:0] gemm_bias_data;
    logic gemm_result_valid;
    logic gemm_result_ready;
    logic [65:0] gemm_result_address_base_current;
    logic [65:0] gemm_result_address_base_selected;
    logic [7:0] gemm_result_generation_q;
    logic [7:0] gemm_result_generation_selected;
    logic [31:0] gemm_result_token_base;
    logic [31:0] gemm_result_output_base;
    logic [31:0] gemm_result_batch_index;
    logic [ARRAY_ROWS-1:0] gemm_result_token_mask;
    logic [ARRAY_COLS-1:0] gemm_result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] gemm_result_data;
    logic [31:0] gemm_mul_operand_a;
    logic [31:0] gemm_mul_operand_b;
    logic [31:0] gemm_add_operand_a;
    logic [31:0] gemm_add_operand_b;

    // Vector block.
    logic vector_start;
    logic vector_busy;
    logic vector_done;
    logic vector_config_error;
    logic vector_data_request;
    logic vector_data_valid;
    logic [31:0] vector_element_base;
    logic [VECTOR_LANES*32-1:0] vector_input_a;
    logic [VECTOR_LANES*32-1:0] vector_input_b;
    logic vector_result_valid;
    logic vector_result_ready;
    logic [31:0] vector_result_base;
    logic [VECTOR_LANES-1:0] vector_result_lane_mask;
    logic [VECTOR_LANES*32-1:0] vector_result_data;
    logic [1:0] vector_engine_mode;
    logic [31:0] vector_mul_operand_a;
    logic [31:0] vector_mul_operand_b;
    logic [31:0] vector_add_operand_a;
    logic [31:0] vector_add_operand_b;

    // Layout block.
    logic layout_start;
    logic layout_busy;
    logic layout_done;
    logic layout_config_error;
    logic layout_data_request;
    logic layout_data_valid;
    logic layout_src_bank;
    logic [31:0] layout_source_address;
    logic [31:0] layout_source_data;
    logic layout_result_valid;
    logic layout_result_ready;
    logic [31:0] layout_result_address;
    logic [31:0] layout_result_data;

    // LayerNorm block.
    logic ln_start;
    logic ln_busy;
    logic ln_done;
    logic ln_config_error;
    logic ln_data_request;
    logic ln_input_valid;
    logic [1:0] ln_data_pass;
    logic [31:0] ln_data_index;
    logic [31:0] ln_data_channel_index;
    logic [31:0] ln_input_data;
    logic [31:0] ln_gamma_data;
    logic [31:0] ln_beta_data;
    logic ln_result_valid;
    logic ln_result_ready;
    logic [31:0] ln_result_index;
    logic [31:0] ln_result_data;
    logic [31:0] ln_debug_mean;
    logic [31:0] ln_debug_variance;
    logic [31:0] ln_debug_inv_std;
    logic [31:0] ln_mul_operand_a;
    logic [31:0] ln_mul_operand_b;
    logic [31:0] ln_add_operand_a;
    logic [31:0] ln_add_operand_b;

    // Softmax block.
    logic softmax_start;
    logic softmax_busy;
    logic softmax_done;
    logic softmax_config_error;
    logic softmax_data_request;
    logic softmax_input_valid;
    logic [1:0] softmax_data_pass;
    logic [31:0] softmax_data_index;
    logic [31:0] softmax_input_data;
    logic softmax_result_valid;
    logic softmax_result_ready;
    logic [31:0] softmax_result_index;
    logic [31:0] softmax_result_data;
    logic [31:0] softmax_debug_row_max;
    logic [31:0] softmax_debug_exp_sum;
    logic [31:0] softmax_mul_operand_a;
    logic [31:0] softmax_mul_operand_b;
    logic [31:0] softmax_add_operand_a;
    logic [31:0] softmax_add_operand_b;

    // GELU block.
    logic gelu_start;
    logic gelu_busy;
    logic gelu_done;
    logic gelu_config_error;
    logic gelu_data_request;
    logic gelu_input_valid;
    logic [31:0] gelu_data_base_index;
    logic [VECTOR_LANES-1:0] gelu_data_lane_mask;
    logic [VECTOR_LANES*32-1:0] gelu_input_data;
    logic gelu_result_valid;
    logic gelu_result_ready;
    logic [31:0] gelu_result_base_index;
    logic [VECTOR_LANES-1:0] gelu_result_lane_mask;
    logic [VECTOR_LANES*32-1:0] gelu_result_data;
    logic [31:0] gelu_mul_operand_a;
    logic [31:0] gelu_mul_operand_b;
    logic [31:0] gelu_add_operand_a;
    logic [31:0] gelu_add_operand_b;

    // The command controller permits only one compute opcode at a time.  Its
    // active opcode therefore also selects the sole production FP32
    // multiplier and adder without arbitration state or latency changes.
    logic [31:0] shared_mul_operand_a;
    logic [31:0] shared_mul_operand_b;
    logic [31:0] shared_mul_result;
    logic [31:0] shared_add_operand_a;
    logic [31:0] shared_add_operand_b;
    logic [31:0] shared_add_result;

    // Argmax block.
    logic argmax_start;
    logic argmax_busy;
    logic argmax_done;
    logic argmax_config_error;
    logic argmax_nonfinite_error;
    logic argmax_data_request;
    logic argmax_data_valid;
    logic [31:0] argmax_element_index;
    logic [31:0] argmax_input_data;
    logic argmax_result_valid;
    logic argmax_result_ready;
    logic [31:0] argmax_result_index;
    logic [31:0] argmax_result_value;

    // Keep deprecated inputs and non-functional debug signals visible to lint
    // without creating hidden storage or behavior.
    logic unused_legacy_inputs;
    assign unused_legacy_inputs =
        input_write_enable ^ input_write_address[0] ^ input_write_data[0] ^
        parameter_write_enable ^ parameter_write_address[0] ^
        parameter_write_data[0] ^ scratch_write_enable ^
        scratch_write_address[0] ^ scratch_write_data[0] ^
        scratch_read_address[0] ^ SCRATCH_WORDS[0] ^ INPUT_WORDS[0] ^
        PARAM_WORDS[0] ^ layout_src_bank ^ ln_debug_mean[0] ^
        ln_debug_variance[0] ^ ln_debug_inv_std[0] ^
        softmax_data_pass[0] ^ softmax_debug_row_max[0] ^
        softmax_debug_exp_sum[0] ^ gemm_busy ^ vector_busy ^ layout_busy ^
        ln_busy ^ softmax_busy ^ gelu_busy ^ argmax_busy;
    assign scratch_read_data = FP32_QNAN;

    // Select the running engine independently of frontend load/store state.
    // This phase-level definition intentionally includes engine-local control
    // and arithmetic states but excludes operand-request/result-drain waits.
    always_comb begin
        selected_engine_busy = 1'b0;
        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM:      selected_engine_busy = gemm_busy;
            PHASE_E_OP_VECTOR:    selected_engine_busy = vector_busy;
            PHASE_E_OP_LAYOUT:    selected_engine_busy = layout_busy;
            PHASE_E_OP_LAYERNORM: selected_engine_busy = ln_busy;
            PHASE_E_OP_SOFTMAX:   selected_engine_busy = softmax_busy;
            PHASE_E_OP_GELU:      selected_engine_busy = gelu_busy;
            PHASE_E_OP_ARGMAX:    selected_engine_busy = argmax_busy;
            default:              selected_engine_busy = 1'b0;
        endcase
    end

    // During the acceptance cycle active_cmd still contains the preceding
    // descriptor, so source trace metadata from the incoming command instead.
    always_comb begin
        profile_command = active_cmd;
        if (command_accept)
            profile_command = cmd;

        profile_events = '0;
        m7_profile_events = '0;
        m7_profile_events.m7_a_vector_hit_word_delta =
            profile_m7_a_vector_hit_word_delta;
        profile_events.command_accept = command_accept;
        profile_events.command_complete = cmd_done || cmd_error;
        profile_events.command_error = cmd_error;
        profile_events.command_opcode = profile_command.header.opcode;
        profile_events.command_tag = profile_command.header.tag;
        profile_events.command_section =
            phase_e_section_t'(profile_command.header.reserved[7:6]);
        profile_events.command_layer =
            profile_command.header.reserved[5:2];
        profile_events.command_step =
            profile_command.route.reserved[4:0];
        profile_events.logical_read_word = profile_logical_read_word;
        profile_events.logical_write_word = profile_logical_write_word;
        profile_events.load_active = profile_load_active;
        profile_events.compute_active =
            (selected_engine_busy &&
             !selected_data_request &&
             !selected_result_valid &&
             !selected_done) ||
            ((active_cmd.header.opcode == PHASE_E_OP_ARGMAX) &&
             argmax_data_valid);
        profile_events.store_active = profile_store_active;
        profile_events.a_cache_lookup = profile_a_cache_lookup;
        profile_events.a_cache_hit = profile_a_cache_hit;
        profile_events.a_cache_miss = profile_a_cache_miss;
        profile_events.bias_cache_lookup = profile_bias_cache_lookup;
        profile_events.bias_cache_hit = profile_bias_cache_hit;
        profile_events.bias_cache_miss = profile_bias_cache_miss;
        profile_events.b_bypass = profile_b_bypass;
        profile_events.gemm_tile_step = profile_gemm_tile_step;
        profile_events.gemm_valid_mac_delta = profile_valid_mac_delta;
        profile_events.gemm_tail_mac_delta = profile_tail_mac_delta;
        profile_events.frontend_error = profile_frontend_error;
        m7_profile_events.m7_fp16_term_accept_delta =
            profile_m7_term_accept_delta;
        m7_profile_events.m7_fp16_disabled_term_delta =
            profile_m7_disabled_term_delta;
        m7_profile_events.m7_fp16_input_wait = profile_m7_input_wait;
        m7_profile_events.m7_fp16_term_stall = profile_m7_term_stall;
        m7_profile_events.m7_fp16_result_backpressure =
            profile_m7_result_backpressure ||
            profile_m7_result_fifo_full_stall;
        m7_profile_events.m7_fp16_compute_active =
            profile_m7_compute_active;
        m7_profile_events.m7_fp16_dot_start = profile_m7_dot_start;
        m7_profile_events.m7_fp16_result_vector =
            profile_m7_result_vector;
        m7_profile_events.m7_fp16_invalid_delta = profile_m7_invalid_delta;
        m7_profile_events.m7_fp16_overflow_delta = profile_m7_overflow_delta;
        m7_profile_events.m7_fp16_length_error_delta =
            profile_m7_length_error_delta;
        m7_profile_events.m7_fp16_subnormal_flushed_delta =
            profile_m7_subnormal_flushed_delta;
        // Bit 3 is the reserved ownership/tag/protocol mismatch class.  A
        // vector-cache response/coordinate violation fails the command via
        // memory_error_latched and is also visible in the M7 typed bank.
        m7_profile_events.m7_error_events[3] =
            profile_m7_a_vector_protocol_error ||
            profile_m7_result_generation_error;
        m7_profile_events.m7_error_events[10] =
            profile_m7_invalid_delta != 0;
        m7_profile_events.m7_error_events[11] =
            profile_m7_overflow_delta != 0;
        m7_profile_events.m7_error_events[12] =
            profile_m7_length_error_delta != 0;
        m7_profile_events.m7_error_events[13] =
            profile_m7_subnormal_flushed_delta != 0;
        m7_profile_events.m7_error_events[19] =
            (profile_m7_invalid_delta != 0) ||
            (profile_m7_overflow_delta != 0) ||
            (profile_m7_length_error_delta != 0);
        // Packed-v3 commands report explicit two-bank ownership.  Non-packed
        // FP16 keeps the established serialized stage accounting unchanged.
        m7_profile_events.m7_panel_load_active = profile_m7_packed_command ?
            profile_m7_panel_load_active :
            (profile_m7_fp16_command && profile_load_active);
        m7_profile_events.m7_panel_compute_active = profile_m7_packed_command ?
            profile_m7_panel_compute_active : profile_m7_compute_active;
        m7_profile_events.m7_panel_store_active =
            profile_m7_fp16_command && profile_store_active;
        m7_profile_events.m7_panel_commit =
            profile_m7_packed_command && profile_m7_panel_commit;
        m7_profile_events.m7_panel_claim =
            profile_m7_packed_command && profile_m7_panel_claim;
        m7_profile_events.m7_panel_claim_mask = profile_m7_packed_command ?
            profile_m7_panel_claim_mask : 2'b00;
        m7_profile_events.m7_panel_release =
            profile_m7_packed_command && profile_m7_panel_release;
        m7_profile_events.m7_panel_empty_stall =
            profile_m7_packed_command && profile_m7_panel_empty_stall;
        m7_profile_events.m7_panel_full_stall =
            profile_m7_packed_command && profile_m7_panel_full_stall;
        m7_profile_events.m7_panel_occupancy = profile_m7_packed_command ?
            profile_m7_panel_occupancy : 2'd0;
        m7_profile_events.m7_result_fifo_enqueue =
            profile_m7_packed_command && profile_m7_result_fifo_enqueue;
        m7_profile_events.m7_result_fifo_dequeue =
            profile_m7_packed_command && profile_m7_result_fifo_dequeue;
        m7_profile_events.m7_result_fifo_occupancy =
            profile_m7_packed_command ?
                profile_m7_result_fifo_occupancy : 2'd0;
    end

    assign profile_m7_fp16_command =
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        ((active_cmd.header.flags & PHASE_E_FLAG_GEMM_FP16) != 0);
    assign profile_m7_packed_command =
        profile_m7_fp16_command &&
        ((active_cmd.header.flags &
          PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0);

    // A command-scoped generation tag protects a queued packed result from
    // being written under a later GEMM command.  command_accept precedes
    // launch, so the incremented value is stable when the scheduler starts.
    always_ff @(posedge clk) begin
        if (rst)
            gemm_result_generation_q <= 8'd0;
        else if (command_accept && (cmd.header.opcode == PHASE_E_OP_GEMM))
            gemm_result_generation_q <= gemm_result_generation_q + 1'b1;
    end

    always_comb begin
        shared_mul_operand_a = 32'd0;
        shared_mul_operand_b = 32'd0;
        shared_add_operand_a = 32'd0;
        shared_add_operand_b = 32'd0;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                shared_mul_operand_a = gemm_mul_operand_a;
                shared_mul_operand_b = gemm_mul_operand_b;
                shared_add_operand_a = gemm_add_operand_a;
                shared_add_operand_b = gemm_add_operand_b;
            end

            PHASE_E_OP_VECTOR: begin
                shared_mul_operand_a = vector_mul_operand_a;
                shared_mul_operand_b = vector_mul_operand_b;
                shared_add_operand_a = vector_add_operand_a;
                shared_add_operand_b = vector_add_operand_b;
            end

            PHASE_E_OP_LAYERNORM: begin
                shared_mul_operand_a = ln_mul_operand_a;
                shared_mul_operand_b = ln_mul_operand_b;
                shared_add_operand_a = ln_add_operand_a;
                shared_add_operand_b = ln_add_operand_b;
            end

            PHASE_E_OP_SOFTMAX: begin
                shared_mul_operand_a = softmax_mul_operand_a;
                shared_mul_operand_b = softmax_mul_operand_b;
                shared_add_operand_a = softmax_add_operand_a;
                shared_add_operand_b = softmax_add_operand_b;
            end

            PHASE_E_OP_GELU: begin
                shared_mul_operand_a = gelu_mul_operand_a;
                shared_mul_operand_b = gelu_mul_operand_b;
                shared_add_operand_a = gelu_add_operand_a;
                shared_add_operand_b = gelu_add_operand_b;
            end

            default: begin
            end
        endcase
    end

    vit_fp32_mul_comb_nodsp u_engine_shared_multiplier (
        .a      (shared_mul_operand_a),
        .b      (shared_mul_operand_b),
        .result (shared_mul_result)
    );

    vit_fp32_add_comb u_engine_shared_adder (
        .a      (shared_add_operand_a),
        .b      (shared_add_operand_b),
        .result (shared_add_result)
    );

    vit_phase_e_command_controller u_command_controller (
        .clk                    (clk),
        .rst                    (rst),
        .cmd_valid              (cmd_valid),
        .cmd_ready              (cmd_ready),
        .cmd                    (cmd),
        .cmd_done               (cmd_done),
        .cmd_error              (cmd_error),
        .busy                   (busy),
        .parameter_request      (parameter_request),
        .parameter_ready        (parameter_ready),
        .parameter_command      (parameter_command),
        .memory_error_latched   (memory_error_latched),
        .selected_done          (selected_done),
        .selected_error         (selected_error),
        .argmax_result_valid    (argmax_result_valid),
        .argmax_result_ready    (argmax_result_ready),
        .argmax_result_index    (argmax_result_index),
        .argmax_result_value    (argmax_result_value),
        .active_cmd             (active_cmd),
        .command_accept         (command_accept),
        .launch                 (command_launch),
        .execute                (command_execute),
        .engine_rst             (engine_rst),
        .debug_state            (state),
        .class_result_valid     (class_result_valid),
        .class_index            (class_index),
        .class_logit            (class_logit)
    );

    vit_phase_e_engine_dispatch #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES)
    ) u_engine_dispatch (
        .active_cmd              (active_cmd),
        .launch                  (command_launch),
        .memory_error_latched    (memory_error_latched),
        .gemm_done               (gemm_done),
        .gemm_config_error       (gemm_config_error),
        .gemm_data_request       (gemm_data_request),
        .gemm_result_valid       (gemm_result_valid),
        .vector_done             (vector_done),
        .vector_config_error     (vector_config_error),
        .vector_data_request     (vector_data_request),
        .vector_result_valid     (vector_result_valid),
        .layout_done             (layout_done),
        .layout_config_error     (layout_config_error),
        .layout_data_request     (layout_data_request),
        .layout_result_valid     (layout_result_valid),
        .ln_done                 (ln_done),
        .ln_config_error         (ln_config_error),
        .ln_data_request         (ln_data_request),
        .ln_result_valid         (ln_result_valid),
        .softmax_done            (softmax_done),
        .softmax_config_error    (softmax_config_error),
        .softmax_data_request    (softmax_data_request),
        .softmax_result_valid    (softmax_result_valid),
        .gelu_done               (gelu_done),
        .gelu_config_error       (gelu_config_error),
        .gelu_data_request       (gelu_data_request),
        .gelu_result_valid       (gelu_result_valid),
        .argmax_done             (argmax_done),
        .argmax_config_error     (argmax_config_error),
        .argmax_nonfinite_error  (argmax_nonfinite_error),
        .argmax_data_request     (argmax_data_request),
        .argmax_result_valid     (argmax_result_valid),
        .gemm_start              (gemm_start),
        .vector_start            (vector_start),
        .layout_start            (layout_start),
        .ln_start                (ln_start),
        .softmax_start           (softmax_start),
        .gelu_start              (gelu_start),
        .argmax_start            (argmax_start),
        .selected_done           (selected_done),
        .selected_error          (selected_error),
        .selected_data_request   (selected_data_request),
        .selected_result_valid   (selected_result_valid),
        .read_word_count         (read_word_count),
        .write_word_count        (write_word_count),
        .vector_engine_mode      (vector_engine_mode)
    );

    vit_phase_e_memory_frontend #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES),
        .GEMM_A_CACHE_DEPTH_WORDS(GEMM_A_CACHE_DEPTH_WORDS),
        .GEMM_BIAS_CACHE_DEPTH_WORDS(GEMM_BIAS_CACHE_DEPTH_WORDS)
    ) u_memory_frontend (
        .clk                         (clk),
        .rst                         (rst),
        .command_accept              (command_accept),
        .execute                     (command_execute),
        .active_cmd                  (active_cmd),
        .selected_data_request       (selected_data_request),
        .selected_result_valid       (selected_result_valid),
        .read_word_count             (read_word_count),
        .write_word_count            (write_word_count),
        .memory_error_latched        (memory_error_latched),
        .debug_mem_state             (mem_state),
        .profile_logical_read_word_o (profile_logical_read_word),
        .profile_logical_write_word_o(profile_logical_write_word),
        .profile_load_active_o       (profile_load_active),
        .profile_store_active_o      (profile_store_active),
        .profile_a_cache_lookup_o    (profile_a_cache_lookup),
        .profile_a_cache_hit_o       (profile_a_cache_hit),
        .profile_a_cache_miss_o      (profile_a_cache_miss),
        .profile_bias_cache_lookup_o (profile_bias_cache_lookup),
        .profile_bias_cache_hit_o    (profile_bias_cache_hit),
        .profile_bias_cache_miss_o   (profile_bias_cache_miss),
        .profile_b_bypass_o          (profile_b_bypass),
        .profile_frontend_error_o    (profile_frontend_error),
        .profile_a_vector_hit_word_delta_o(
            profile_m7_a_vector_hit_word_delta
        ),
        .profile_a_vector_protocol_error_o(
            profile_m7_a_vector_protocol_error
        ),
        .profile_result_generation_error_o(
            profile_m7_result_generation_error
        ),
        .mem_req_valid               (mem_req_valid),
        .mem_req_ready               (mem_req_ready),
        .mem_req_write               (mem_req_write),
        .mem_req_space               (mem_req_space),
        .mem_req_word_address        (mem_req_word_address),
        .mem_req_write_data          (mem_req_write_data),
        .mem_req_write_strobe        (mem_req_write_strobe),
        .mem_req_read_ahead_safe     (mem_req_read_ahead_safe),
        .mem_req_contiguous_words    (mem_req_contiguous_words),
        .mem_rsp_valid               (mem_rsp_valid),
        .mem_rsp_ready               (mem_rsp_ready),
        .mem_rsp_read_data           (mem_rsp_read_data),
        .mem_rsp_error               (mem_rsp_error),
        .gemm_token_base             (gemm_token_base),
        .gemm_output_base            (gemm_output_base),
        .gemm_k_base                 (gemm_k_base),
        .gemm_batch_index            (gemm_batch_index),
        .gemm_activation_data        (gemm_activation_data),
        .gemm_weight_data            (gemm_weight_data),
        .gemm_bias_data              (gemm_bias_data),
        .gemm_data_valid             (gemm_data_valid),
        .gemm_result_address_base_current_o(
            gemm_result_address_base_current
        ),
        .gemm_result_address_base_store_i(
            gemm_result_address_base_selected
        ),
        .gemm_result_generation_store_i(
            gemm_result_generation_selected
        ),
        .gemm_result_generation_expected_i(
            gemm_result_generation_q
        ),
        .gemm_result_token_base_store_i(gemm_result_token_base),
        .gemm_result_output_base_store_i(gemm_result_output_base),
        .gemm_result_batch_index_store_i(gemm_result_batch_index),
        .gemm_result_token_mask      (gemm_result_token_mask),
        .gemm_result_output_mask     (gemm_result_output_mask),
        .gemm_result_data            (gemm_result_data),
        .gemm_result_ready           (gemm_result_ready),
        .vector_element_base         (vector_element_base),
        .vector_input_a              (vector_input_a),
        .vector_input_b              (vector_input_b),
        .vector_data_valid           (vector_data_valid),
        .vector_result_base          (vector_result_base),
        .vector_result_lane_mask     (vector_result_lane_mask),
        .vector_result_data          (vector_result_data),
        .vector_result_ready         (vector_result_ready),
        .layout_source_address       (layout_source_address),
        .layout_source_data          (layout_source_data),
        .layout_data_valid           (layout_data_valid),
        .layout_result_address       (layout_result_address),
        .layout_result_data          (layout_result_data),
        .layout_result_ready         (layout_result_ready),
        .ln_data_pass                (ln_data_pass),
        .ln_data_index               (ln_data_index),
        .ln_data_channel_index       (ln_data_channel_index),
        .ln_input_data               (ln_input_data),
        .ln_gamma_data               (ln_gamma_data),
        .ln_beta_data                (ln_beta_data),
        .ln_input_valid              (ln_input_valid),
        .ln_result_index             (ln_result_index),
        .ln_result_data              (ln_result_data),
        .ln_result_ready             (ln_result_ready),
        .softmax_data_index          (softmax_data_index),
        .softmax_input_data          (softmax_input_data),
        .softmax_input_valid         (softmax_input_valid),
        .softmax_result_index        (softmax_result_index),
        .softmax_result_data         (softmax_result_data),
        .softmax_result_ready        (softmax_result_ready),
        .gelu_data_base_index        (gelu_data_base_index),
        .gelu_data_lane_mask         (gelu_data_lane_mask),
        .gelu_input_data             (gelu_input_data),
        .gelu_input_valid            (gelu_input_valid),
        .gelu_result_base_index      (gelu_result_base_index),
        .gelu_result_lane_mask       (gelu_result_lane_mask),
        .gelu_result_data            (gelu_result_data),
        .gelu_result_ready           (gelu_result_ready),
        .argmax_element_index        (argmax_element_index),
        .argmax_input_data           (argmax_input_data),
        .argmax_data_valid           (argmax_data_valid),
        .argmax_result_ready         (argmax_result_ready)
    );

    vit_gemm_dual_mode_array #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES),
        .FP16_STREAMS(FP16_STREAMS),
        .USE_EXTERNAL_MUL (1),
        .USE_EXTERNAL_ADD (1),
        .INCLUDE_LEGACY_GEMM(0)
    ) u_gemm (
        .clk                      (clk),
        .rst                      (engine_rst),
        .start                    (gemm_start),
        .cfg_m                    (active_cmd.dim1),
        .cfg_k                    (active_cmd.dim2),
        .cfg_n                    (active_cmd.dim3),
        .cfg_batch_count          (active_cmd.dim0),
        .cfg_bias_enable          (active_cmd.header.flags[0]),
        .cfg_fp16_enable          (
            (active_cmd.header.flags &
             vit_phase_e_pkg::PHASE_E_FLAG_GEMM_FP16) != 0
        ),
        .cfg_weight_fp16_packed2  (
            (active_cmd.header.flags &
             vit_phase_e_pkg::PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0
        ),
        .busy                     (gemm_busy),
        .done                     (gemm_done),
        .config_error             (gemm_config_error),
        .data_request             (gemm_data_request),
        .data_valid               (gemm_data_valid),
        .token_base               (gemm_token_base),
        .output_base              (gemm_output_base),
        .k_base                   (gemm_k_base),
        .batch_index              (gemm_batch_index),
        .activation_data          (gemm_activation_data),
        .weight_data              (gemm_weight_data),
        .bias_data                (gemm_bias_data),
        .result_address_base_i    (gemm_result_address_base_current),
        .result_generation_i      (gemm_result_generation_q),
        .result_valid             (gemm_result_valid),
        .result_ready             (gemm_result_ready),
        .result_address_base_o    (gemm_result_address_base_selected),
        .result_generation_o      (gemm_result_generation_selected),
        .result_token_base        (gemm_result_token_base),
        .result_output_base       (gemm_result_output_base),
        .result_batch_index       (gemm_result_batch_index),
        .result_token_mask        (gemm_result_token_mask),
        .result_output_mask       (gemm_result_output_mask),
        .result_data              (gemm_result_data),
        .mul_operand_a            (gemm_mul_operand_a),
        .mul_operand_b            (gemm_mul_operand_b),
        .external_mul_result      (shared_mul_result),
        .add_operand_a            (gemm_add_operand_a),
        .add_operand_b            (gemm_add_operand_b),
        .external_add_result      (shared_add_result),
        .profile_gemm_tile_step_o (profile_gemm_tile_step),
        .profile_valid_mac_delta_o(profile_valid_mac_delta),
        .profile_tail_mac_delta_o (profile_tail_mac_delta),
        .profile_m7_term_accept_delta_o(
            profile_m7_term_accept_delta
        ),
        .profile_m7_disabled_term_delta_o(
            profile_m7_disabled_term_delta
        ),
        .profile_m7_input_wait_o(profile_m7_input_wait),
        .profile_m7_term_stall_o(profile_m7_term_stall),
        .profile_m7_result_backpressure_o(
            profile_m7_result_backpressure
        ),
        .profile_m7_compute_active_o(profile_m7_compute_active),
        .profile_m7_dot_start_o(profile_m7_dot_start),
        .profile_m7_result_vector_o(profile_m7_result_vector),
        .profile_m7_invalid_delta_o(profile_m7_invalid_delta),
        .profile_m7_overflow_delta_o(profile_m7_overflow_delta),
        .profile_m7_length_error_delta_o(
            profile_m7_length_error_delta
        ),
        .profile_m7_subnormal_flushed_delta_o(
            profile_m7_subnormal_flushed_delta
        ),
        .profile_m7_panel_load_active_o(
            profile_m7_panel_load_active
        ),
        .profile_m7_panel_compute_active_o(
            profile_m7_panel_compute_active
        ),
        .profile_m7_panel_commit_o(profile_m7_panel_commit),
        .profile_m7_panel_claim_o(profile_m7_panel_claim),
        .profile_m7_panel_claim_mask_o(profile_m7_panel_claim_mask),
        .profile_m7_panel_release_o(profile_m7_panel_release),
        .profile_m7_panel_empty_stall_o(profile_m7_panel_empty_stall),
        .profile_m7_panel_full_stall_o(profile_m7_panel_full_stall),
        .profile_m7_panel_occupancy_o(profile_m7_panel_occupancy),
        .profile_m7_result_fifo_enqueue_o(
            profile_m7_result_fifo_enqueue
        ),
        .profile_m7_result_fifo_dequeue_o(
            profile_m7_result_fifo_dequeue
        ),
        .profile_m7_result_fifo_full_stall_o(
            profile_m7_result_fifo_full_stall
        ),
        .profile_m7_result_fifo_occupancy_o(
            profile_m7_result_fifo_occupancy
        )
    );

    vit_vector_engine_fp32 #(
        .LANES            (VECTOR_LANES),
        .USE_EXTERNAL_MUL (1),
        .USE_EXTERNAL_ADD (1)
    ) u_vector (
        .clk              (clk),
        .rst              (engine_rst),
        .start            (vector_start),
        .cfg_mode         (vector_engine_mode),
        .cfg_length       (active_cmd.dim0),
        .cfg_scalar       (active_cmd.immediate),
        .cfg_mask_enable  (active_cmd.header.flags[1]),
        .busy             (vector_busy),
        .done             (vector_done),
        .config_error     (vector_config_error),
        .data_request     (vector_data_request),
        .data_valid       (vector_data_valid),
        .element_base     (vector_element_base),
        .input_a          (vector_input_a),
        .input_b          (vector_input_b),
        .result_valid     (vector_result_valid),
        .result_ready     (vector_result_ready),
        .result_base      (vector_result_base),
        .result_lane_mask (vector_result_lane_mask),
        .result_data      (vector_result_data),
        .mul_operand_a    (vector_mul_operand_a),
        .mul_operand_b    (vector_mul_operand_b),
        .external_mul_result(shared_mul_result),
        .add_operand_a    (vector_add_operand_a),
        .add_operand_b    (vector_add_operand_b),
        .external_add_result(shared_add_result)
    );

    vit_layout_engine u_layout (
        .clk             (clk),
        .rst             (engine_rst),
        .start           (layout_start),
        .cfg_src_bank    (1'b0),
        .cfg_src_base    (active_cmd.src0_base),
        .cfg_dst_base    (active_cmd.dst_base),
        .cfg_dim0        (active_cmd.dim0),
        .cfg_dim1        (active_cmd.dim1),
        .cfg_dim2        (active_cmd.dim2),
        .cfg_src_stride0 (active_cmd.stride0),
        .cfg_src_stride1 (active_cmd.stride1),
        .cfg_src_stride2 (active_cmd.stride2),
        .busy            (layout_busy),
        .done            (layout_done),
        .config_error    (layout_config_error),
        .data_request    (layout_data_request),
        .data_valid      (layout_data_valid),
        .src_bank        (layout_src_bank),
        .source_address  (layout_source_address),
        .source_data     (layout_source_data),
        .result_valid    (layout_result_valid),
        .result_ready    (layout_result_ready),
        .result_address  (layout_result_address),
        .result_data     (layout_result_data)
    );

    vit_layernorm_engine_fp32 #(
        .USE_EXTERNAL_MUL         (1),
        .USE_EXTERNAL_ADD         (1),
        .ENABLE_ROW_AFFINE_BUFFER (1),
        .ROW_AFFINE_BUFFER_DEPTH  (1024)
    ) u_layernorm (
        .clk            (clk),
        .rst            (engine_rst),
        .start          (ln_start),
        .cfg_token_count(active_cmd.dim0),
        .cfg_hidden_size(active_cmd.dim1),
        .cfg_epsilon    (active_cmd.immediate),
        .busy           (ln_busy),
        .done           (ln_done),
        .config_error   (ln_config_error),
        .data_request   (ln_data_request),
        .input_valid    (ln_input_valid),
        .data_pass      (ln_data_pass),
        .data_index     (ln_data_index),
        .data_channel_index (ln_data_channel_index),
        .input_data     (ln_input_data),
        .gamma_data     (ln_gamma_data),
        .beta_data      (ln_beta_data),
        .result_valid   (ln_result_valid),
        .result_ready   (ln_result_ready),
        .result_index   (ln_result_index),
        .result_data    (ln_result_data),
        .debug_mean     (ln_debug_mean),
        .debug_variance (ln_debug_variance),
        .debug_inv_std  (ln_debug_inv_std),
        .mul_operand_a  (ln_mul_operand_a),
        .mul_operand_b  (ln_mul_operand_b),
        .external_mul_result(shared_mul_result),
        .add_operand_a  (ln_add_operand_a),
        .add_operand_b  (ln_add_operand_b),
        .external_add_result(shared_add_result)
    );

    vit_softmax_engine_fp32 #(
        .USE_EXTERNAL_MUL       (1),
        .USE_EXTERNAL_ADD       (1),
        .ENABLE_ROW_EXP_BUFFER  (1),
        .ROW_EXP_BUFFER_DEPTH   (1024)
    ) u_softmax (
        .clk              (clk),
        .rst              (engine_rst),
        .start            (softmax_start),
        .cfg_row_count    (active_cmd.dim0),
        .cfg_row_length   (active_cmd.dim1),
        .busy             (softmax_busy),
        .done             (softmax_done),
        .config_error     (softmax_config_error),
        .data_request     (softmax_data_request),
        .input_valid      (softmax_input_valid),
        .data_pass        (softmax_data_pass),
        .data_index       (softmax_data_index),
        .input_data       (softmax_input_data),
        .result_valid     (softmax_result_valid),
        .result_ready     (softmax_result_ready),
        .result_index     (softmax_result_index),
        .result_data      (softmax_result_data),
        .debug_row_max    (softmax_debug_row_max),
        .debug_exp_sum    (softmax_debug_exp_sum),
        .mul_operand_a    (softmax_mul_operand_a),
        .mul_operand_b    (softmax_mul_operand_b),
        .external_mul_result(shared_mul_result),
        .add_operand_a    (softmax_add_operand_a),
        .add_operand_b    (softmax_add_operand_b),
        .external_add_result(shared_add_result)
    );

    vit_gelu_engine_fp32 #(
        .LANES            (VECTOR_LANES),
        .USE_EXTERNAL_MUL (1),
        .USE_EXTERNAL_ADD (1)
    ) u_gelu (
        .clk                   (clk),
        .rst                   (engine_rst),
        .start                 (gelu_start),
        .cfg_length            (active_cmd.dim0),
        .busy                  (gelu_busy),
        .done                  (gelu_done),
        .config_error          (gelu_config_error),
        .data_request          (gelu_data_request),
        .input_valid           (gelu_input_valid),
        .data_base_index       (gelu_data_base_index),
        .data_lane_mask        (gelu_data_lane_mask),
        .input_data            (gelu_input_data),
        .result_valid          (gelu_result_valid),
        .result_ready          (gelu_result_ready),
        .result_base_index     (gelu_result_base_index),
        .result_lane_mask      (gelu_result_lane_mask),
        .result_data           (gelu_result_data),
        .mul_operand_a         (gelu_mul_operand_a),
        .mul_operand_b         (gelu_mul_operand_b),
        .external_mul_result   (shared_mul_result),
        .add_operand_a         (gelu_add_operand_a),
        .add_operand_b         (gelu_add_operand_b),
        .external_add_result   (shared_add_result)
    );

    vit_argmax_engine_fp32 u_argmax (
        .clk                   (clk),
        .rst                   (engine_rst),
        .start                 (argmax_start),
        .cfg_length            (active_cmd.dim0),
        .busy                  (argmax_busy),
        .done                  (argmax_done),
        .config_error          (argmax_config_error),
        .input_nonfinite_error (argmax_nonfinite_error),
        .data_request          (argmax_data_request),
        .data_valid            (argmax_data_valid),
        .element_index         (argmax_element_index),
        .input_data            (argmax_input_data),
        .result_valid          (argmax_result_valid),
        .result_ready          (argmax_result_ready),
        .result_index          (argmax_result_index),
        .result_value          (argmax_result_value)
    );

endmodule
