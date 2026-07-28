`timescale 1ns/1ps

// Synthesizable Phase-E execution adapter.
//
// Descriptor addresses are 32-bit FP32 word addresses.  This module contains
// no activation, input, or parameter arrays.  Instead it serializes each
// native engine's packed operand request onto one logical word transaction
// interface.  A downstream adapter maps the logical memory space and word
// address to DDR/AXI.
//
// Correct ordering is deliberate:
//   1. gather every operand word for one native request;
//   2. pulse that engine's data-valid;
//   3. wait for its registered result;
//   4. scatter every valid result word and wait for every response;
//   5. pulse result-ready.
//
// Thus an in-place command cannot read past an uncommitted write, and cmd_done
// cannot precede the final DDR write response.
module vit_phase_e_engine_top #(
    parameter integer ARRAY_ROWS      = 2,
    parameter integer ARRAY_COLS      = 2,
    parameter integer PE_LANES        = 16,
    parameter integer VECTOR_LANES    = 16,
    // Retained for source compatibility and integration-time assertions.  The
    // actual limits are programmed in vit_phase_e_axi_mem_adapter.
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

    // One-outstanding logical word transaction interface.
    output logic                           mem_req_valid,
    input  logic                           mem_req_ready,
    output logic                           mem_req_write,
    output vit_phase_e_pkg::phase_e_mem_space_t mem_req_space,
    output logic [31:0]                    mem_req_word_address,
    output logic [31:0]                    mem_req_write_data,
    output logic [3:0]                     mem_req_write_strobe,
    input  logic                           mem_rsp_valid,
    output logic                           mem_rsp_ready,
    input  logic [31:0]                    mem_rsp_read_data,
    input  logic                           mem_rsp_error,

    // Deprecated array-loader/debug pins are kept so older named-port NPU
    // instantiations still compile.  Hardware software must access DDR
    // directly; these inputs do not create hidden storage.
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
    output logic [31:0]                    class_logit
);

    import vit_phase_e_pkg::*;

    localparam integer GEMM_RESULT_WORDS = ARRAY_ROWS * ARRAY_COLS;
    localparam integer GEMM_A_WORDS      = ARRAY_ROWS * PE_LANES;
    localparam integer GEMM_B_WORDS      = ARRAY_COLS * PE_LANES;
    localparam integer GEMM_READ_WORDS   =
        GEMM_A_WORDS + GEMM_B_WORDS + ARRAY_COLS;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WAIT_PARAMETER,
        STATE_LAUNCH,
        STATE_EXECUTE,
        STATE_REPORT
    } state_t;

    typedef enum logic [3:0] {
        MEM_IDLE,
        MEM_READ_SELECT,
        MEM_READ_REQUEST,
        MEM_READ_RESPONSE,
        MEM_READ_DELIVER,
        MEM_WRITE_SELECT,
        MEM_WRITE_REQUEST,
        MEM_WRITE_RESPONSE,
        MEM_WRITE_DELIVER
    } mem_state_t;

    state_t state;
    mem_state_t mem_state;
    phase_e_cmd_t active_cmd;
    logic report_error;
    logic memory_error_latched;
    logic engine_rst;
    logic [15:0] mem_word_index;

    // GEMM engine signals.
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
    logic [31:0] gemm_result_token_base;
    logic [31:0] gemm_result_output_base;
    logic [31:0] gemm_result_batch_index;
    logic [ARRAY_ROWS-1:0] gemm_result_token_mask;
    logic [ARRAY_COLS-1:0] gemm_result_output_mask;
    logic [GEMM_RESULT_WORDS*32-1:0] gemm_result_data;

    // Vector engine signals.
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

    // Layout engine signals.
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

    // LayerNorm engine signals.
    logic ln_start;
    logic ln_busy;
    logic ln_done;
    logic ln_config_error;
    logic ln_data_request;
    logic ln_input_valid;
    logic [1:0] ln_data_pass;
    logic [31:0] ln_data_index;
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

    // Softmax engine signals.
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

    // GELU engine signals.
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

    // Argmax engine signals.
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

    logic selected_done;
    logic selected_error;
    logic incoming_needs_parameters;
    logic selected_data_request;
    logic selected_result_valid;

    logic [15:0] read_word_count;
    logic [15:0] write_word_count;
    logic read_candidate_needed;
    phase_e_mem_space_t read_candidate_space;
    logic [95:0] read_candidate_address_wide;
    logic [31:0] read_candidate_address;
    logic read_candidate_address_overflow;
    logic write_candidate_needed;
    phase_e_mem_space_t write_candidate_space;
    logic [95:0] write_candidate_address_wide;
    logic [31:0] write_candidate_address;
    logic write_candidate_address_overflow;
    logic [31:0] write_candidate_data;

    integer read_candidate_row;
    integer read_candidate_col;
    integer read_candidate_lane;
    integer write_candidate_row;
    integer write_candidate_col;
    integer write_candidate_lane;
    logic [1:0] vector_engine_mode;

    // Keep deprecated inputs observable to lint without creating behavior.
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

    function automatic logic command_needs_parameters(
        input phase_e_cmd_t value
    );
        begin
            command_needs_parameters =
                (value.route.src0_space == PHASE_E_MEM_PARAM) ||
                (value.route.src1_space == PHASE_E_MEM_PARAM) ||
                (value.route.src2_space == PHASE_E_MEM_PARAM);
        end
    endfunction

    function automatic logic [95:0] widen_word_address(
        input logic [31:0] value
    );
        begin
            widen_word_address = {64'd0, value};
        end
    endfunction

    assign cmd_ready = (state == STATE_IDLE);
    assign busy = (state != STATE_IDLE);
    assign engine_rst = rst || memory_error_latched;
    assign parameter_request = (state == STATE_WAIT_PARAMETER);
    assign parameter_command = active_cmd;
    assign incoming_needs_parameters = command_needs_parameters(cmd);

    assign gemm_start = (state == STATE_LAUNCH) &&
                        (active_cmd.header.opcode == PHASE_E_OP_GEMM);
    assign vector_start = (state == STATE_LAUNCH) &&
                          (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_start = (state == STATE_LAUNCH) &&
                          (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_start = (state == STATE_LAUNCH) &&
                      (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_start = (state == STATE_LAUNCH) &&
                           (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_start = (state == STATE_LAUNCH) &&
                        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_start = (state == STATE_LAUNCH) &&
                          (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    always_comb begin
        selected_done = 1'b0;
        selected_error = memory_error_latched;
        selected_data_request = 1'b0;
        selected_result_valid = 1'b0;
        read_word_count = 16'd1;
        write_word_count = 16'd1;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                selected_done = gemm_done;
                selected_error = memory_error_latched || gemm_config_error;
                selected_data_request = gemm_data_request;
                selected_result_valid = gemm_result_valid;
                read_word_count = GEMM_READ_WORDS;
                write_word_count = GEMM_RESULT_WORDS;
            end
            PHASE_E_OP_VECTOR: begin
                selected_done = vector_done;
                selected_error = memory_error_latched || vector_config_error;
                selected_data_request = vector_data_request;
                selected_result_valid = vector_result_valid;
                read_word_count = 2 * VECTOR_LANES;
                write_word_count = VECTOR_LANES;
            end
            PHASE_E_OP_LAYOUT: begin
                selected_done = layout_done;
                selected_error = memory_error_latched || layout_config_error;
                selected_data_request = layout_data_request;
                selected_result_valid = layout_result_valid;
            end
            PHASE_E_OP_LAYERNORM: begin
                selected_done = ln_done;
                selected_error = memory_error_latched || ln_config_error;
                selected_data_request = ln_data_request;
                selected_result_valid = ln_result_valid;
                read_word_count = 16'd3;
            end
            PHASE_E_OP_SOFTMAX: begin
                selected_done = softmax_done;
                selected_error = memory_error_latched || softmax_config_error;
                selected_data_request = softmax_data_request;
                selected_result_valid = softmax_result_valid;
            end
            PHASE_E_OP_GELU: begin
                selected_done = gelu_done;
                selected_error = memory_error_latched || gelu_config_error;
                selected_data_request = gelu_data_request;
                selected_result_valid = gelu_result_valid;
                read_word_count = VECTOR_LANES;
                write_word_count = VECTOR_LANES;
            end
            PHASE_E_OP_ARGMAX: begin
                selected_done = argmax_done;
                selected_error = memory_error_latched ||
                                 argmax_config_error ||
                                 argmax_nonfinite_error;
                selected_data_request = argmax_data_request;
                selected_result_valid = argmax_result_valid;
            end
            default: begin
                selected_done = 1'b1;
                selected_error = 1'b1;
            end
        endcase
    end

    // Calculate the current read candidate. Invalid tail lanes are filled
    // locally with zero and MEM_NONE has the legacy zero-source semantics.
    always_comb begin
        read_candidate_needed = 1'b0;
        read_candidate_space = PHASE_E_MEM_NONE;
        read_candidate_address_wide = 96'd0;
        read_candidate_row = 0;
        read_candidate_col = 0;
        read_candidate_lane = 0;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                if (mem_word_index < GEMM_A_WORDS) begin
                    read_candidate_row = mem_word_index / PE_LANES;
                    read_candidate_lane = mem_word_index % PE_LANES;
                    read_candidate_needed =
                        ((widen_word_address(gemm_token_base) +
                          widen_word_address(read_candidate_row[31:0])) <
                         widen_word_address(active_cmd.dim1)) &&
                        ((widen_word_address(gemm_k_base) +
                          widen_word_address(read_candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim2));
                    read_candidate_space = active_cmd.route.src0_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src0_base) +
                        widen_word_address(gemm_batch_index) *
                            widen_word_address(active_cmd.stride0) +
                        (widen_word_address(gemm_token_base) +
                         widen_word_address(read_candidate_row[31:0])) *
                            widen_word_address(active_cmd.stride1) +
                        widen_word_address(gemm_k_base) +
                        widen_word_address(read_candidate_lane[31:0]);
                end else if (mem_word_index <
                             (GEMM_A_WORDS + GEMM_B_WORDS)) begin
                    read_candidate_col =
                        (mem_word_index - GEMM_A_WORDS) / PE_LANES;
                    read_candidate_lane =
                        (mem_word_index - GEMM_A_WORDS) % PE_LANES;
                    read_candidate_needed =
                        ((widen_word_address(gemm_output_base) +
                          widen_word_address(read_candidate_col[31:0])) <
                         widen_word_address(active_cmd.dim3)) &&
                        ((widen_word_address(gemm_k_base) +
                          widen_word_address(read_candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim2));
                    read_candidate_space = active_cmd.route.src1_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src1_base) +
                        widen_word_address(gemm_batch_index) *
                            widen_word_address(active_cmd.stride2) +
                        (widen_word_address(gemm_k_base) +
                         widen_word_address(read_candidate_lane[31:0])) *
                            widen_word_address(active_cmd.stride3) +
                        widen_word_address(gemm_output_base) +
                        widen_word_address(read_candidate_col[31:0]);
                end else begin
                    read_candidate_col = mem_word_index -
                                         GEMM_A_WORDS - GEMM_B_WORDS;
                    read_candidate_needed =
                        active_cmd.header.flags[0] &&
                        ((widen_word_address(gemm_k_base) + PE_LANES) >=
                         widen_word_address(active_cmd.dim2)) &&
                        ((widen_word_address(gemm_output_base) +
                          widen_word_address(read_candidate_col[31:0])) <
                         widen_word_address(active_cmd.dim3));
                    read_candidate_space = active_cmd.route.src2_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src2_base) +
                        widen_word_address(gemm_output_base) +
                        widen_word_address(read_candidate_col[31:0]);
                end
            end

            PHASE_E_OP_VECTOR: begin
                if (mem_word_index < VECTOR_LANES) begin
                    read_candidate_lane = mem_word_index;
                    read_candidate_needed =
                        ((widen_word_address(vector_element_base) +
                          widen_word_address(read_candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim0));
                    read_candidate_space = active_cmd.route.src0_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src0_base) +
                        widen_word_address(vector_element_base) +
                        widen_word_address(read_candidate_lane[31:0]);
                end else begin
                    read_candidate_lane = mem_word_index - VECTOR_LANES;
                    read_candidate_needed =
                        ((widen_word_address(vector_element_base) +
                          widen_word_address(read_candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim0)) &&
                        ((active_cmd.header.subop ==
                            PHASE_E_SUBOP_VECTOR_ADD) ||
                         ((active_cmd.header.subop ==
                            PHASE_E_SUBOP_VECTOR_SCALE_MASK) &&
                          active_cmd.header.flags[1]));
                    read_candidate_space = active_cmd.route.src1_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src1_base) +
                        widen_word_address(vector_element_base) +
                        widen_word_address(read_candidate_lane[31:0]);
                end
            end

            PHASE_E_OP_LAYOUT: begin
                read_candidate_needed = 1'b1;
                read_candidate_space = active_cmd.route.src0_space;
                read_candidate_address_wide =
                    widen_word_address(layout_source_address);
            end

            PHASE_E_OP_LAYERNORM: begin
                if (mem_word_index == 0) begin
                    read_candidate_needed = 1'b1;
                    read_candidate_space = active_cmd.route.src0_space;
                    read_candidate_address_wide =
                        widen_word_address(active_cmd.src0_base) +
                        widen_word_address(ln_data_index);
                end else if (mem_word_index == 1) begin
                    read_candidate_needed =
                        (ln_data_pass == 2'd2) && (active_cmd.dim1 != 0);
                    read_candidate_space = active_cmd.route.src1_space;
                    if (active_cmd.dim1 != 0)
                        read_candidate_address_wide =
                            widen_word_address(active_cmd.src1_base) +
                            widen_word_address(
                                ln_data_index % active_cmd.dim1
                            );
                end else begin
                    read_candidate_needed =
                        (ln_data_pass == 2'd2) && (active_cmd.dim1 != 0);
                    read_candidate_space = active_cmd.route.src2_space;
                    if (active_cmd.dim1 != 0)
                        read_candidate_address_wide =
                            widen_word_address(active_cmd.src2_base) +
                            widen_word_address(
                                ln_data_index % active_cmd.dim1
                            );
                end
            end

            PHASE_E_OP_SOFTMAX: begin
                read_candidate_needed = 1'b1;
                read_candidate_space = active_cmd.route.src0_space;
                read_candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(softmax_data_index);
            end

            PHASE_E_OP_GELU: begin
                read_candidate_lane = mem_word_index;
                read_candidate_needed =
                    gelu_data_lane_mask[read_candidate_lane];
                read_candidate_space = active_cmd.route.src0_space;
                read_candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(gelu_data_base_index) +
                    widen_word_address(read_candidate_lane[31:0]);
            end

            PHASE_E_OP_ARGMAX: begin
                read_candidate_needed = 1'b1;
                read_candidate_space = active_cmd.route.src0_space;
                read_candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(argmax_element_index);
            end

            default: begin
            end
        endcase

        read_candidate_address = read_candidate_address_wide[31:0];
        read_candidate_address_overflow =
            |read_candidate_address_wide[95:32];
    end

    // Calculate the current result candidate.  Result buses and metadata are
    // guaranteed by the native engines to remain stable until result_ready.
    always_comb begin
        write_candidate_needed = 1'b0;
        write_candidate_space = active_cmd.route.dst_space;
        write_candidate_address_wide = 96'd0;
        write_candidate_data = 32'd0;
        write_candidate_row = 0;
        write_candidate_col = 0;
        write_candidate_lane = 0;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                write_candidate_row = mem_word_index / ARRAY_COLS;
                write_candidate_col = mem_word_index % ARRAY_COLS;
                write_candidate_needed =
                    gemm_result_token_mask[write_candidate_row] &&
                    gemm_result_output_mask[write_candidate_col];
                write_candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(gemm_result_batch_index) *
                        widen_word_address(active_cmd.stride4) +
                    (widen_word_address(gemm_result_token_base) +
                     widen_word_address(write_candidate_row[31:0])) *
                        widen_word_address(active_cmd.immediate) +
                    widen_word_address(gemm_result_output_base) +
                    widen_word_address(write_candidate_col[31:0]);
                write_candidate_data =
                    gemm_result_data[mem_word_index*32 +: 32];
            end

            PHASE_E_OP_VECTOR: begin
                write_candidate_lane = mem_word_index;
                write_candidate_needed =
                    vector_result_lane_mask[write_candidate_lane];
                write_candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(vector_result_base) +
                    widen_word_address(write_candidate_lane[31:0]);
                write_candidate_data =
                    vector_result_data[write_candidate_lane*32 +: 32];
            end

            PHASE_E_OP_LAYOUT: begin
                write_candidate_needed = 1'b1;
                write_candidate_address_wide =
                    widen_word_address(layout_result_address);
                write_candidate_data = layout_result_data;
            end

            PHASE_E_OP_LAYERNORM: begin
                write_candidate_needed = 1'b1;
                write_candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(ln_result_index);
                write_candidate_data = ln_result_data;
            end

            PHASE_E_OP_SOFTMAX: begin
                write_candidate_needed = 1'b1;
                write_candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(softmax_result_index);
                write_candidate_data = softmax_result_data;
            end

            PHASE_E_OP_GELU: begin
                write_candidate_lane = mem_word_index;
                write_candidate_needed =
                    gelu_result_lane_mask[write_candidate_lane];
                write_candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(gelu_result_base_index) +
                    widen_word_address(write_candidate_lane[31:0]);
                write_candidate_data =
                    gelu_result_data[write_candidate_lane*32 +: 32];
            end

            // Argmax has a scalar sideband result and no DDR write.
            default: begin
            end
        endcase

        write_candidate_address = write_candidate_address_wide[31:0];
        write_candidate_address_overflow =
            |write_candidate_address_wide[95:32];
    end

    assign mem_req_valid =
        (mem_state == MEM_READ_REQUEST) ||
        (mem_state == MEM_WRITE_REQUEST);
    assign mem_req_write = (mem_state == MEM_WRITE_REQUEST);
    always_comb begin
        if (mem_req_write)
            mem_req_space = write_candidate_space;
        else
            mem_req_space = read_candidate_space;
    end
    assign mem_req_word_address =
        mem_req_write ? write_candidate_address : read_candidate_address;
    assign mem_req_write_data = write_candidate_data;
    assign mem_req_write_strobe = 4'hf;
    assign mem_rsp_ready =
        (mem_state == MEM_READ_RESPONSE) ||
        (mem_state == MEM_WRITE_RESPONSE);

    assign gemm_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM);
    assign vector_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    assign gemm_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM);
    assign vector_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    assign vector_engine_mode =
        (active_cmd.header.subop ==
         vit_phase_e_pkg::PHASE_E_SUBOP_VECTOR_SCALE_MASK) ? 2'd1 : 2'd0;

    // Gather/scatter controller.
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_state <= MEM_IDLE;
            mem_word_index <= 16'd0;
            memory_error_latched <= 1'b0;
            gemm_activation_data <= '0;
            gemm_weight_data <= '0;
            gemm_bias_data <= '0;
            vector_input_a <= '0;
            vector_input_b <= '0;
            layout_source_data <= 32'd0;
            ln_input_data <= 32'd0;
            ln_gamma_data <= 32'd0;
            ln_beta_data <= 32'd0;
            softmax_input_data <= 32'd0;
            gelu_input_data <= '0;
            argmax_input_data <= 32'd0;
        end else begin
            if (cmd_valid && cmd_ready)
                memory_error_latched <= 1'b0;

            // Once a transaction fails, do not allow a still-high native
            // request/result signal to restart the memory frontend while the
            // engine reset and command REPORT transitions take effect.
            if (memory_error_latched) begin
                mem_state <= MEM_IDLE;
                mem_word_index <= 16'd0;
            end else begin
            case (mem_state)
                MEM_IDLE: begin
                    mem_word_index <= 16'd0;
                    if ((state == STATE_EXECUTE) &&
                        selected_data_request) begin
                        case (active_cmd.header.opcode)
                            PHASE_E_OP_GEMM: begin
                                gemm_activation_data <= '0;
                                gemm_weight_data <= '0;
                                gemm_bias_data <= '0;
                            end
                            PHASE_E_OP_VECTOR: begin
                                vector_input_a <= '0;
                                vector_input_b <= '0;
                            end
                            PHASE_E_OP_LAYOUT:
                                layout_source_data <= 32'd0;
                            PHASE_E_OP_LAYERNORM: begin
                                ln_input_data <= 32'd0;
                                ln_gamma_data <= 32'd0;
                                ln_beta_data <= 32'd0;
                            end
                            PHASE_E_OP_SOFTMAX:
                                softmax_input_data <= 32'd0;
                            PHASE_E_OP_GELU:
                                gelu_input_data <= '0;
                            PHASE_E_OP_ARGMAX:
                                argmax_input_data <= 32'd0;
                            default: begin
                            end
                        endcase
                        mem_state <= MEM_READ_SELECT;
                    end else if ((state == STATE_EXECUTE) &&
                                 selected_result_valid) begin
                        if (active_cmd.header.opcode == PHASE_E_OP_ARGMAX)
                            mem_state <= MEM_WRITE_DELIVER;
                        else
                            mem_state <= MEM_WRITE_SELECT;
                    end
                end

                MEM_READ_SELECT: begin
                    if (read_candidate_needed &&
                        (read_candidate_space != PHASE_E_MEM_NONE) &&
                        read_candidate_address_overflow) begin
                        // Never truncate a descriptor calculation back into
                        // the 32-bit logical word-address space.
                        memory_error_latched <= 1'b1;
                        mem_state <= MEM_IDLE;
                    end else if (!read_candidate_needed ||
                        (read_candidate_space == PHASE_E_MEM_NONE)) begin
                        if ((mem_word_index + 1) >= read_word_count)
                            mem_state <= MEM_READ_DELIVER;
                        else
                            mem_word_index <= mem_word_index + 1'b1;
                    end else begin
                        mem_state <= MEM_READ_REQUEST;
                    end
                end

                MEM_READ_REQUEST: begin
                    if (mem_req_valid && mem_req_ready)
                        mem_state <= MEM_READ_RESPONSE;
                end

                MEM_READ_RESPONSE: begin
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        if (mem_rsp_error) begin
                            memory_error_latched <= 1'b1;
                            // Abort this command before any compute/write can
                            // consume corrupt data. engine_rst resets the
                            // native engine on the following edge.
                            mem_state <= MEM_IDLE;
                        end else begin
                            case (active_cmd.header.opcode)
                                PHASE_E_OP_GEMM: begin
                                    if (mem_word_index < GEMM_A_WORDS)
                                        gemm_activation_data[
                                            mem_word_index*32 +: 32
                                        ] <= mem_rsp_read_data;
                                    else if (mem_word_index <
                                             (GEMM_A_WORDS + GEMM_B_WORDS))
                                        gemm_weight_data[
                                            (mem_word_index-GEMM_A_WORDS)*32
                                            +: 32
                                        ] <= mem_rsp_read_data;
                                    else
                                        gemm_bias_data[
                                            (mem_word_index-GEMM_A_WORDS-
                                             GEMM_B_WORDS)*32 +: 32
                                        ] <= mem_rsp_read_data;
                                end
                                PHASE_E_OP_VECTOR: begin
                                    if (mem_word_index < VECTOR_LANES)
                                        vector_input_a[
                                            mem_word_index*32 +: 32
                                        ] <= mem_rsp_read_data;
                                    else
                                        vector_input_b[
                                            (mem_word_index-VECTOR_LANES)*32
                                            +: 32
                                        ] <= mem_rsp_read_data;
                                end
                                PHASE_E_OP_LAYOUT:
                                    layout_source_data <= mem_rsp_read_data;
                                PHASE_E_OP_LAYERNORM: begin
                                    if (mem_word_index == 0)
                                        ln_input_data <= mem_rsp_read_data;
                                    else if (mem_word_index == 1)
                                        ln_gamma_data <= mem_rsp_read_data;
                                    else
                                        ln_beta_data <= mem_rsp_read_data;
                                end
                                PHASE_E_OP_SOFTMAX:
                                    softmax_input_data <= mem_rsp_read_data;
                                PHASE_E_OP_GELU:
                                    gelu_input_data[
                                        mem_word_index*32 +: 32
                                    ] <= mem_rsp_read_data;
                                PHASE_E_OP_ARGMAX:
                                    argmax_input_data <= mem_rsp_read_data;
                                default: begin
                                end
                            endcase

                            if ((mem_word_index + 1) >= read_word_count)
                                mem_state <= MEM_READ_DELIVER;
                            else begin
                                mem_word_index <= mem_word_index + 1'b1;
                                mem_state <= MEM_READ_SELECT;
                            end
                        end
                    end
                end

                MEM_READ_DELIVER:
                    mem_state <= MEM_IDLE;

                MEM_WRITE_SELECT: begin
                    if (write_candidate_needed &&
                        write_candidate_address_overflow) begin
                        // A wrapped destination could corrupt unrelated DDR,
                        // so fail before presenting any truncated request.
                        memory_error_latched <= 1'b1;
                        mem_state <= MEM_IDLE;
                    end else if (!write_candidate_needed) begin
                        if ((mem_word_index + 1) >= write_word_count)
                            mem_state <= MEM_WRITE_DELIVER;
                        else
                            mem_word_index <= mem_word_index + 1'b1;
                    end else begin
                        mem_state <= MEM_WRITE_REQUEST;
                    end
                end

                MEM_WRITE_REQUEST: begin
                    if (mem_req_valid && mem_req_ready)
                        mem_state <= MEM_WRITE_RESPONSE;
                end

                MEM_WRITE_RESPONSE: begin
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        if (mem_rsp_error) begin
                            memory_error_latched <= 1'b1;
                            // Stop before issuing any later result words.
                            mem_state <= MEM_IDLE;
                        end else begin
                            if ((mem_word_index + 1) >= write_word_count)
                                mem_state <= MEM_WRITE_DELIVER;
                            else begin
                                mem_word_index <= mem_word_index + 1'b1;
                                mem_state <= MEM_WRITE_SELECT;
                            end
                        end
                    end
                end

                MEM_WRITE_DELIVER:
                    mem_state <= MEM_IDLE;

                default:
                    mem_state <= MEM_IDLE;
            endcase
            end
        end
    end

    vit_gemm_tree_array #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES)
    ) u_gemm (
        .clk(clk),
        .rst(engine_rst),
        .start(gemm_start),
        .cfg_m(active_cmd.dim1),
        .cfg_k(active_cmd.dim2),
        .cfg_n(active_cmd.dim3),
        .cfg_batch_count(active_cmd.dim0),
        .cfg_bias_enable(active_cmd.header.flags[0]),
        .busy(gemm_busy),
        .done(gemm_done),
        .config_error(gemm_config_error),
        .data_request(gemm_data_request),
        .data_valid(gemm_data_valid),
        .token_base(gemm_token_base),
        .output_base(gemm_output_base),
        .k_base(gemm_k_base),
        .batch_index(gemm_batch_index),
        .activation_data(gemm_activation_data),
        .weight_data(gemm_weight_data),
        .bias_data(gemm_bias_data),
        .result_valid(gemm_result_valid),
        .result_ready(gemm_result_ready),
        .result_token_base(gemm_result_token_base),
        .result_output_base(gemm_result_output_base),
        .result_batch_index(gemm_result_batch_index),
        .result_token_mask(gemm_result_token_mask),
        .result_output_mask(gemm_result_output_mask),
        .result_data(gemm_result_data)
    );

    vit_vector_engine_fp32 #(
        .LANES(VECTOR_LANES)
    ) u_vector (
        .clk(clk),
        .rst(engine_rst),
        .start(vector_start),
        .cfg_mode(vector_engine_mode),
        .cfg_length(active_cmd.dim0),
        .cfg_scalar(active_cmd.immediate),
        .cfg_mask_enable(active_cmd.header.flags[1]),
        .busy(vector_busy),
        .done(vector_done),
        .config_error(vector_config_error),
        .data_request(vector_data_request),
        .data_valid(vector_data_valid),
        .element_base(vector_element_base),
        .input_a(vector_input_a),
        .input_b(vector_input_b),
        .result_valid(vector_result_valid),
        .result_ready(vector_result_ready),
        .result_base(vector_result_base),
        .result_lane_mask(vector_result_lane_mask),
        .result_data(vector_result_data)
    );

    vit_layout_engine u_layout (
        .clk(clk),
        .rst(engine_rst),
        .start(layout_start),
        .cfg_src_bank(1'b0),
        .cfg_src_base(active_cmd.src0_base),
        .cfg_dst_base(active_cmd.dst_base),
        .cfg_dim0(active_cmd.dim0),
        .cfg_dim1(active_cmd.dim1),
        .cfg_dim2(active_cmd.dim2),
        .cfg_src_stride0(active_cmd.stride0),
        .cfg_src_stride1(active_cmd.stride1),
        .cfg_src_stride2(active_cmd.stride2),
        .busy(layout_busy),
        .done(layout_done),
        .config_error(layout_config_error),
        .data_request(layout_data_request),
        .data_valid(layout_data_valid),
        .src_bank(layout_src_bank),
        .source_address(layout_source_address),
        .source_data(layout_source_data),
        .result_valid(layout_result_valid),
        .result_ready(layout_result_ready),
        .result_address(layout_result_address),
        .result_data(layout_result_data)
    );

    vit_layernorm_engine_fp32 u_layernorm (
        .clk(clk),
        .rst(engine_rst),
        .start(ln_start),
        .cfg_token_count(active_cmd.dim0),
        .cfg_hidden_size(active_cmd.dim1),
        .cfg_epsilon(active_cmd.immediate),
        .busy(ln_busy),
        .done(ln_done),
        .config_error(ln_config_error),
        .data_request(ln_data_request),
        .input_valid(ln_input_valid),
        .data_pass(ln_data_pass),
        .data_index(ln_data_index),
        .input_data(ln_input_data),
        .gamma_data(ln_gamma_data),
        .beta_data(ln_beta_data),
        .result_valid(ln_result_valid),
        .result_ready(ln_result_ready),
        .result_index(ln_result_index),
        .result_data(ln_result_data),
        .debug_mean(ln_debug_mean),
        .debug_variance(ln_debug_variance),
        .debug_inv_std(ln_debug_inv_std)
    );

    vit_softmax_engine_fp32 u_softmax (
        .clk(clk),
        .rst(engine_rst),
        .start(softmax_start),
        .cfg_row_count(active_cmd.dim0),
        .cfg_row_length(active_cmd.dim1),
        .busy(softmax_busy),
        .done(softmax_done),
        .config_error(softmax_config_error),
        .data_request(softmax_data_request),
        .input_valid(softmax_input_valid),
        .data_pass(softmax_data_pass),
        .data_index(softmax_data_index),
        .input_data(softmax_input_data),
        .result_valid(softmax_result_valid),
        .result_ready(softmax_result_ready),
        .result_index(softmax_result_index),
        .result_data(softmax_result_data),
        .debug_row_max(softmax_debug_row_max),
        .debug_exp_sum(softmax_debug_exp_sum)
    );

    vit_gelu_engine_fp32 #(
        .LANES(VECTOR_LANES)
    ) u_gelu (
        .clk(clk),
        .rst(engine_rst),
        .start(gelu_start),
        .cfg_length(active_cmd.dim0),
        .busy(gelu_busy),
        .done(gelu_done),
        .config_error(gelu_config_error),
        .data_request(gelu_data_request),
        .input_valid(gelu_input_valid),
        .data_base_index(gelu_data_base_index),
        .data_lane_mask(gelu_data_lane_mask),
        .input_data(gelu_input_data),
        .result_valid(gelu_result_valid),
        .result_ready(gelu_result_ready),
        .result_base_index(gelu_result_base_index),
        .result_lane_mask(gelu_result_lane_mask),
        .result_data(gelu_result_data)
    );

    vit_argmax_engine_fp32 u_argmax (
        .clk(clk),
        .rst(engine_rst),
        .start(argmax_start),
        .cfg_length(active_cmd.dim0),
        .busy(argmax_busy),
        .done(argmax_done),
        .config_error(argmax_config_error),
        .input_nonfinite_error(argmax_nonfinite_error),
        .data_request(argmax_data_request),
        .data_valid(argmax_data_valid),
        .element_index(argmax_element_index),
        .input_data(argmax_input_data),
        .result_valid(argmax_result_valid),
        .result_ready(argmax_result_ready),
        .result_index(argmax_result_index),
        .result_value(argmax_result_value)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            active_cmd <= '0;
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            report_error <= 1'b0;
            class_result_valid <= 1'b0;
            class_index <= 32'd0;
            class_logit <= FP32_QNAN;
        end else begin
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            class_result_valid <= 1'b0;

            if (argmax_result_valid && argmax_result_ready) begin
                class_index <= argmax_result_index;
                class_logit <= argmax_result_value;
                class_result_valid <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    if (cmd_valid) begin
                        active_cmd <= cmd;
                        report_error <= 1'b0;
                        if (incoming_needs_parameters)
                            state <= STATE_WAIT_PARAMETER;
                        else
                            state <= STATE_LAUNCH;
                    end
                end

                STATE_WAIT_PARAMETER: begin
                    if (parameter_ready)
                        state <= STATE_LAUNCH;
                end

                STATE_LAUNCH: begin
                    if ((active_cmd.header.opcode < PHASE_E_OP_GEMM) ||
                        (active_cmd.header.opcode > PHASE_E_OP_ARGMAX)) begin
                        report_error <= 1'b1;
                        state <= STATE_REPORT;
                    end else begin
                        state <= STATE_EXECUTE;
                    end
                end

                STATE_EXECUTE: begin
                    if (memory_error_latched) begin
                        report_error <= 1'b1;
                        state <= STATE_REPORT;
                    end else if (selected_done) begin
                        report_error <= selected_error;
                        state <= STATE_REPORT;
                    end
                end

                STATE_REPORT: begin
                    cmd_done <= !report_error;
                    cmd_error <= report_error;
                    state <= STATE_IDLE;
                end

                default: begin
                    report_error <= 1'b1;
                    state <= STATE_REPORT;
                end
            endcase
        end
    end

endmodule
