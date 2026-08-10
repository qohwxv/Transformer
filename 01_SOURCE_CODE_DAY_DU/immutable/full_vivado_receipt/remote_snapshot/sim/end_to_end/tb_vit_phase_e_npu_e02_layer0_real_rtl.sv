`timescale 1ns/1ps

// Full-dimension, real-data E02 layer-0 test through the production NPU and
// its native logical-memory interface.
//
// This test deliberately excludes VIT_PURE_SV_BEHAVIORAL, AXI and Vivado:
//
//   real embedding checkpoint -> vit_phase_e_npu
//                             -> production engine/leaf hierarchy
//                             <-> deterministic logical DDR responder
//                             -> real layer-0 output comparison
//
// The model addresses are the canonical packed-model-v1 FP32-word offsets.
// All sixteen layer-0 tensors are read from their real parameter HEX files.
module tb_vit_phase_e_npu_e02_layer0_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer HEAD_COUNT = 12;
    localparam integer HEAD_SIZE = 64;
    localparam integer INTERMEDIATE_SIZE = 3072;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer HEAD_WORDS = HIDDEN_WORDS;
    localparam integer ONE_HEAD_WORDS = TOKEN_COUNT * HEAD_SIZE;
    localparam integer SCORE_WORDS =
        HEAD_COUNT * TOKEN_COUNT * TOKEN_COUNT;
    localparam integer SCORE_ROW_WORDS = TOKEN_COUNT * TOKEN_COUNT;
    localparam integer ATTENTION_ROWS = HEAD_COUNT * TOKEN_COUNT;
    localparam integer FC1_WORDS = TOKEN_COUNT * INTERMEDIATE_SIZE;

    // Canonical model-package-v1 FP32-word offsets, identical to the AXI E02
    // harness and generated runtime configuration.
    localparam logic [31:0] LN1_GAMMA_BASE = 32'h0017_16f0;
    localparam logic [31:0] LN1_BETA_BASE = 32'h0017_19f0;
    localparam logic [31:0] Q_WEIGHT_BASE = 32'h0017_1cf0;
    localparam logic [31:0] Q_BIAS_BASE = 32'h0020_1cf0;
    localparam logic [31:0] K_WEIGHT_BASE = 32'h0020_1ff0;
    localparam logic [31:0] K_BIAS_BASE = 32'h0029_1ff0;
    localparam logic [31:0] V_WEIGHT_BASE = 32'h0029_22f0;
    localparam logic [31:0] V_BIAS_BASE = 32'h0032_22f0;
    localparam logic [31:0] O_WEIGHT_BASE = 32'h0032_25f0;
    localparam logic [31:0] O_BIAS_BASE = 32'h003b_25f0;
    localparam logic [31:0] LN2_GAMMA_BASE = 32'h003b_28f0;
    localparam logic [31:0] LN2_BETA_BASE = 32'h003b_2bf0;
    localparam logic [31:0] FC1_WEIGHT_BASE = 32'h003b_2ef0;
    localparam logic [31:0] FC1_BIAS_BASE = 32'h005f_2ef0;
    localparam logic [31:0] FC2_WEIGHT_BASE = 32'h005f_3af0;
    localparam logic [31:0] FC2_BIAS_BASE = 32'h0083_3af0;

    localparam integer QKV_WEIGHT_WORDS = HIDDEN_SIZE * HIDDEN_SIZE;
    localparam integer FC_WEIGHT_WORDS =
        HIDDEN_SIZE * INTERMEDIATE_SIZE;
    localparam integer MODEL_BACKING_WORDS =
        FC2_BIAS_BASE + HIDDEN_SIZE;
    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [7:0] JOB_TAG = 8'h20;
    localparam integer EXPECTED_COMMANDS = 20;
    localparam integer EXPECTED_PARAMETER_REQUESTS = 8;
    localparam logic [19:0] EXPECTED_PARAMETER_STEP_MASK = 20'h5a02b;
    localparam integer EXPECTED_LAYER_REQUESTS = 1;
    localparam integer FORCED_STALL_BUDGET = 16;
    localparam integer TOKEN_TILES =
        (TOKEN_COUNT + ARRAY_ROWS - 1) / ARRAY_ROWS;

    // Exact traffic contract for ARRAY_ROWS=2/ARRAY_COLS=2.  These values lock
    // the present production cache schedule; an intentional cache/scheduling
    // change must update both the per-command and whole-layer contracts.
    localparam longint unsigned EXPECTED_PARAMETER_READS = 701_323_008;
    localparam longint unsigned EXPECTED_SCRATCH_READS = 36_672_732;
    localparam longint unsigned EXPECTED_READS =
        EXPECTED_PARAMETER_READS + EXPECTED_SCRATCH_READS;
    localparam integer EXPECTED_WRITES =
        (15 * HIDDEN_WORDS) + (3 * SCORE_WORDS) + (2 * FC1_WORDS);
    localparam longint unsigned EXPECTED_REQUESTS =
        EXPECTED_READS + EXPECTED_WRITES;
    localparam logic [31:0] EXPECTED_PARAM_MIN = LN1_GAMMA_BASE;
    localparam logic [31:0] EXPECTED_PARAM_MAX =
        FC2_BIAS_BASE + HIDDEN_SIZE - 1;
    localparam logic [31:0] EXPECTED_SCRATCH_MIN =
        PHASE_E_ADDR_HIDDEN_A;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX =
        PHASE_E_ADDR_FC1 + FC1_WORDS - 1;

    // The production layer contains many rounded FP32 operations, including
    // approximate exp/GELU/reciprocal paths.  Each of all 151,296 outputs must
    // satisfy abs(error) <= 2e-3 + 2e-3*abs(golden).  Exact mismatch, maximum
    // absolute error, maximum normalized error and mean absolute error are
    // reported separately.
    localparam real OUTPUT_ABS_TOLERANCE = 2.0e-3;
    localparam real OUTPUT_REL_TOLERANCE = 2.0e-3;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;
    localparam logic [63:0] WATCHDOG_CYCLES = 64'd20_000_000_000;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic job_valid = 1'b0;
    logic job_ready;
    phase_e_job_t job = '0;
    phase_e_global_params_t global_params = '0;

    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic layer_param_valid;
    phase_e_layer_params_t layer_param_data;
    phase_e_layer_params_t layer0_params = '0;

    logic operand_load_request;
    logic operand_load_ready;
    phase_e_cmd_t operand_load_command;

    logic checkpoint_valid;
    logic checkpoint_ready;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;

    logic busy;
    logic done;
    logic error;
    phase_e_error_t error_code;
    phase_e_section_t error_section;
    logic [3:0] error_layer;
    logic [4:0] error_step;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid = 1'b0;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data = 32'd0;
    logic mem_rsp_error = 1'b0;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    logic [31:0] model_memory [0:MODEL_BACKING_WORDS-1];
    logic [31:0] scratch_memory [0:SCRATCH_WORDS-1];
    logic [31:0] input_memory [0:INPUT_BACKING_WORDS-1];
    logic [31:0] golden_output [0:HIDDEN_WORDS-1];

    logic response_pending = 1'b0;
    logic pending_write = 1'b0;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [3:0] pending_write_strobe = 4'd0;
    logic [31:0] pending_read_data = 32'd0;

    logic request_address_valid;
    logic [31:0] request_read_data;
    logic responder_idle;
    logic force_request_stall;
    logic forced_stall_armed = 1'b0;

    logic stalled_request = 1'b0;
    logic stalled_write = 1'b0;
    phase_e_mem_space_t stalled_space = PHASE_E_MEM_NONE;
    logic [31:0] stalled_address = 32'd0;
    logic [31:0] stalled_write_data = 32'd0;
    logic [3:0] stalled_write_strobe = 4'd0;
    logic stalled_response = 1'b0;
    logic [31:0] stalled_response_data = 32'd0;
    logic stalled_response_error = 1'b0;

    logic [63:0] cycle_count = 64'd0;
    logic [63:0] accepted_request_count = 64'd0;
    logic [63:0] response_handshake_count = 64'd0;
    logic [63:0] write_request_accept_count = 64'd0;
    logic [63:0] read_transaction_count = 64'd0;
    logic [63:0] write_transaction_count = 64'd0;
    logic [63:0] parameter_read_count = 64'd0;
    logic [63:0] scratch_read_count = 64'd0;
    logic [63:0] input_read_count = 64'd0;
    logic [31:0] invalid_transaction_count = 32'd0;
    logic [31:0] parameter_min_address = 32'hffff_ffff;
    logic [31:0] parameter_max_address = 32'd0;
    logic [31:0] scratch_min_address = 32'hffff_ffff;
    logic [31:0] scratch_max_address = 32'd0;
    logic [63:0] backpressure_cycle_count = 64'd0;
    integer forced_stall_count = 0;

    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    integer initialize_index;
    integer exact_mismatches;
    integer tolerance_failures;
    integer unknown_failures;
    integer nonfinite_failures;
    integer max_error_index;
    integer max_ratio_index;
    logic [31:0] max_error_rtl_word;
    logic [31:0] max_error_golden_word;
    real rtl_value;
    real golden_value;
    real absolute_error;
    real allowed_error;
    real normalized_error;
    real max_abs_error;
    real max_normalized_error;
    real sum_abs_error;
    real mean_abs_error;

    phase_e_cmd_t accepted_commands [0:EXPECTED_COMMANDS-1];
    logic [19:0] parameter_step_seen = 20'd0;
    logic [63:0] command_parameter_read_start
        [0:EXPECTED_COMMANDS-1];
    logic [63:0] command_scratch_read_start
        [0:EXPECTED_COMMANDS-1];
    logic [63:0] command_write_start
        [0:EXPECTED_COMMANDS-1];

    integer progress_cycle_interval;
    integer progress_transaction_interval;
    integer probe_cycle_limit;
    integer progress_cycle_plusarg_status;
    integer progress_transaction_plusarg_status;
    integer probe_cycle_plusarg_status;
    logic [63:0] next_progress_cycle;
    logic [63:0] next_progress_transaction;

    always #1 clk = ~clk;

    function automatic logic address_in_range(
        input logic [31:0] address,
        input logic [31:0] base,
        input logic [31:0] word_count
    );
        logic [32:0] limit;
        begin
            limit = {1'b0, base} + {1'b0, word_count};
            address_in_range =
                ({1'b0, address} >= {1'b0, base}) &&
                ({1'b0, address} < limit);
        end
    endfunction

    function automatic logic parameter_address_valid(
        input logic [31:0] address
    );
        begin
            parameter_address_valid =
                address_in_range(
                    address, LN1_GAMMA_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, LN1_BETA_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, Q_WEIGHT_BASE, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, Q_BIAS_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, K_WEIGHT_BASE, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, K_BIAS_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, V_WEIGHT_BASE, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, V_BIAS_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, O_WEIGHT_BASE, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, O_BIAS_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, LN2_GAMMA_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, LN2_BETA_BASE, HIDDEN_SIZE
                ) ||
                address_in_range(
                    address, FC1_WEIGHT_BASE, FC_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, FC1_BIAS_BASE, INTERMEDIATE_SIZE
                ) ||
                address_in_range(
                    address, FC2_WEIGHT_BASE, FC_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, FC2_BIAS_BASE, HIDDEN_SIZE
                );
        end
    endfunction

    function automatic logic scratch_address_valid(
        input logic [31:0] address
    );
        begin
            scratch_address_valid =
                address_in_range(
                    address, PHASE_E_ADDR_HIDDEN_A, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_HIDDEN_B, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_LINEAR_TMP, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_Q_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_K_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_V_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_SCORE_PROB, SCORE_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_FC1, FC1_WORDS
                );
        end
    endfunction

    function automatic logic logical_request_valid(
        input logic write_request,
        input phase_e_mem_space_t space,
        input logic [31:0] address,
        input logic [3:0] write_strobe
    );
        begin
            if (write_request)
                logical_request_valid =
                    (space == PHASE_E_MEM_SCRATCH) &&
                    scratch_address_valid(address) &&
                    (write_strobe == 4'hf);
            else begin
                case (space)
                    PHASE_E_MEM_PARAM:
                        logical_request_valid =
                            parameter_address_valid(address);
                    PHASE_E_MEM_SCRATCH:
                        logical_request_valid =
                            scratch_address_valid(address);
                    default:
                        logical_request_valid = 1'b0;
                endcase
            end
        end
    endfunction

    function automatic logic [31:0] read_logical_word(
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        begin
            case (space)
                PHASE_E_MEM_PARAM:
                    read_logical_word = model_memory[address];
                PHASE_E_MEM_SCRATCH:
                    read_logical_word = scratch_memory[address];
                default:
                    read_logical_word = FP32_QNAN;
            endcase
        end
    endfunction

    function automatic logic fp32_is_finite(
        input logic [31:0] word
    );
        begin
            fp32_is_finite = (word[30:23] != 8'hff);
        end
    endfunction

    function automatic real fp32_to_real(
        input logic [31:0] word
    );
        integer exponent;
        integer scale_index;
        real significand;
        real scale;
        begin
            exponent = word[30:23];
            scale = 1.0;
            significand = 0.0;
            if (exponent == 0) begin
                significand = real'(word[22:0]) / 8388608.0;
                for (scale_index = 0; scale_index < 126;
                     scale_index = scale_index + 1)
                    scale = scale * 0.5;
            end else if (exponent != 255) begin
                significand =
                    1.0 + (real'(word[22:0]) / 8388608.0);
                if (exponent >= 127)
                    for (scale_index = 127; scale_index < exponent;
                         scale_index = scale_index + 1)
                        scale = scale * 2.0;
                else
                    for (scale_index = exponent; scale_index < 127;
                         scale_index = scale_index + 1)
                        scale = scale * 0.5;
            end
            if (exponent == 255)
                fp32_to_real = 0.0;
            else begin
                fp32_to_real = significand * scale;
                if (word[31])
                    fp32_to_real = -fp32_to_real;
            end
        end
    endfunction

    function automatic phase_e_opcode_t expected_opcode(
        input integer ordinal
    );
        begin
            case (ordinal)
                0, 15:
                    expected_opcode = PHASE_E_OP_LAYERNORM;
                1, 3, 5, 8, 11, 13, 16, 18:
                    expected_opcode = PHASE_E_OP_GEMM;
                2, 4, 6, 7, 12:
                    expected_opcode = PHASE_E_OP_LAYOUT;
                9, 14, 19:
                    expected_opcode = PHASE_E_OP_VECTOR;
                10:
                    expected_opcode = PHASE_E_OP_SOFTMAX;
                17:
                    expected_opcode = PHASE_E_OP_GELU;
                default:
                    expected_opcode = PHASE_E_OP_NOP;
            endcase
        end
    endfunction

    function automatic phase_e_cmd_route_t expected_route(
        input phase_e_tensor_id_t src0_tensor,
        input phase_e_tensor_id_t src1_tensor,
        input phase_e_tensor_id_t src2_tensor,
        input phase_e_tensor_id_t dst_tensor
    );
        phase_e_cmd_route_t value;
        begin
            value = '0;
            value.src0_tensor = src0_tensor;
            value.src1_tensor = src1_tensor;
            value.src2_tensor = src2_tensor;
            value.dst_tensor = dst_tensor;
            value.src0_space = phase_e_tensor_default_space(src0_tensor);
            value.src1_space = phase_e_tensor_default_space(src1_tensor);
            value.src2_space = phase_e_tensor_default_space(src2_tensor);
            value.dst_space = phase_e_tensor_default_space(dst_tensor);
            expected_route = value;
        end
    endfunction

    // Independent architectural contract for every layer-0 encoder command.
    // Comparing all 512 bits detects wrong bases, dimensions, strides, flags,
    // subops, tensor IDs/spaces, tag and reserved execution context.
    function automatic phase_e_cmd_t expected_command(
        input integer ordinal
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.tag = JOB_TAG + ordinal[7:0];
            value.header.flags = PHASE_E_FLAG_CHECKPOINT;

            case (ordinal)
                0: begin
                    value.header.opcode = PHASE_E_OP_LAYERNORM;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_A;
                    value.src1_base = LN1_GAMMA_BASE;
                    value.src2_base = LN1_BETA_BASE;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HIDDEN_SIZE;
                    value.immediate = VIT_LN_EPSILON_FP32;
                end

                1, 3, 5: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    if (ordinal == 1) begin
                        value.src1_base = Q_WEIGHT_BASE;
                        value.src2_base = Q_BIAS_BASE;
                    end else if (ordinal == 3) begin
                        value.src1_base = K_WEIGHT_BASE;
                        value.src2_base = K_BIAS_BASE;
                    end else begin
                        value.src1_base = V_WEIGHT_BASE;
                        value.src2_base = V_BIAS_BASE;
                    end
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                2, 4, 6: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        (ordinal == 2) ? PHASE_E_TENSOR_Q_HEAD :
                        ((ordinal == 4) ? PHASE_E_TENSOR_K_HEAD :
                                          PHASE_E_TENSOR_V_HEAD)
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dst_base =
                        (ordinal == 2) ? PHASE_E_ADDR_Q_HEAD :
                        ((ordinal == 4) ? PHASE_E_ADDR_K_HEAD :
                                          PHASE_E_ADDR_V_HEAD);
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.stride0 = HEAD_SIZE;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 1;
                end

                7: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_K_HEAD;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = HEAD_SIZE;
                    value.dim2 = TOKEN_COUNT;
                    value.stride0 = ONE_HEAD_WORDS;
                    value.stride1 = 1;
                    value.stride2 = HEAD_SIZE;
                end

                8: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_Q_HEAD;
                    value.src1_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.dim3 = TOKEN_COUNT;
                    value.stride0 = ONE_HEAD_WORDS;
                    value.stride1 = HEAD_SIZE;
                    value.stride2 = ONE_HEAD_WORDS;
                    value.stride3 = TOKEN_COUNT;
                    value.stride4 = SCORE_ROW_WORDS;
                    value.immediate = TOKEN_COUNT;
                end

                9: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_SCALE_MASK;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = SCORE_WORDS;
                    value.immediate = VIT_ATTN_SCALE_FP32;
                end

                10: begin
                    value.header.opcode = PHASE_E_OP_SOFTMAX;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = ATTENTION_ROWS;
                    value.dim1 = TOKEN_COUNT;
                end

                11: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_V_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_Q_HEAD
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.src1_base = PHASE_E_ADDR_V_HEAD;
                    value.dst_base = PHASE_E_ADDR_Q_HEAD;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = TOKEN_COUNT;
                    value.dim3 = HEAD_SIZE;
                    value.stride0 = SCORE_ROW_WORDS;
                    value.stride1 = TOKEN_COUNT;
                    value.stride2 = ONE_HEAD_WORDS;
                    value.stride3 = HEAD_SIZE;
                    value.stride4 = ONE_HEAD_WORDS;
                    value.immediate = HEAD_SIZE;
                end

                12: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_Q_HEAD;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HEAD_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.stride0 = HEAD_SIZE;
                    value.stride1 = ONE_HEAD_WORDS;
                    value.stride2 = 1;
                end

                13: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.src1_base = O_WEIGHT_BASE;
                    value.src2_base = O_BIAS_BASE;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                14: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    value.src1_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = HIDDEN_WORDS;
                end

                15: begin
                    value.header.opcode = PHASE_E_OP_LAYERNORM;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_A
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    value.src1_base = LN2_GAMMA_BASE;
                    value.src2_base = LN2_BETA_BASE;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HIDDEN_SIZE;
                    value.immediate = VIT_LN_EPSILON_FP32;
                end

                16: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_FC1
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_A;
                    value.src1_base = FC1_WEIGHT_BASE;
                    value.src2_base = FC1_BIAS_BASE;
                    value.dst_base = PHASE_E_ADDR_FC1;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = INTERMEDIATE_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = INTERMEDIATE_SIZE;
                    value.stride4 = FC1_WORDS;
                    value.immediate = INTERMEDIATE_SIZE;
                end

                17: begin
                    value.header.opcode = PHASE_E_OP_GELU;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_FC1
                    );
                    value.src0_base = PHASE_E_ADDR_FC1;
                    value.dst_base = PHASE_E_ADDR_FC1;
                    value.dim0 = FC1_WORDS;
                end

                18: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_FC1;
                    value.src1_base = FC2_WEIGHT_BASE;
                    value.src2_base = FC2_BIAS_BASE;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = INTERMEDIATE_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = FC1_WORDS;
                    value.stride1 = INTERMEDIATE_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                19: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_HIDDEN_A
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.src1_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dim0 = HIDDEN_WORDS;
                end

                default:
                    value.header.opcode = PHASE_E_OP_NOP;
            endcase

            value.header.reserved = {
                PHASE_E_SECTION_ENCODER,
                4'd0,
                2'b00
            };
            value.route.reserved = {3'd0, ordinal[4:0]};
            expected_command = value;
        end
    endfunction

    function automatic logic [4:0] expected_parameter_step(
        input integer request_ordinal
    );
        begin
            case (request_ordinal)
                0: expected_parameter_step = 5'd0;
                1: expected_parameter_step = 5'd1;
                2: expected_parameter_step = 5'd3;
                3: expected_parameter_step = 5'd5;
                4: expected_parameter_step = 5'd13;
                5: expected_parameter_step = 5'd15;
                6: expected_parameter_step = 5'd16;
                7: expected_parameter_step = 5'd18;
                default: expected_parameter_step = 5'h1f;
            endcase
        end
    endfunction

    function automatic logic parameter_step_expected(
        input logic [4:0] step
    );
        begin
            case (step)
                5'd0, 5'd1, 5'd3, 5'd5,
                5'd13, 5'd15, 5'd16, 5'd18:
                    parameter_step_expected = 1'b1;
                default:
                    parameter_step_expected = 1'b0;
            endcase
        end
    endfunction

    function automatic longint unsigned expected_parameter_reads_for_command(
        input integer ordinal
    );
        begin
            case (ordinal)
                0, 15:
                    expected_parameter_reads_for_command = 302_592;
                1, 3, 5, 13:
                    expected_parameter_reads_for_command = 58_393_344;
                16:
                    expected_parameter_reads_for_command = 233_573_376;
                18:
                    expected_parameter_reads_for_command = 233_571_072;
                default:
                    expected_parameter_reads_for_command = 0;
            endcase
        end
    endfunction

    function automatic longint unsigned expected_scratch_reads_for_command(
        input integer ordinal
    );
        begin
            case (ordinal)
                0, 15:
                    expected_scratch_reads_for_command = 453_888;
                1, 2, 3, 4, 5, 6, 7, 12, 13, 16:
                    expected_scratch_reads_for_command = 151_296;
                8:
                    expected_scratch_reads_for_command = 15_129_600;
                9:
                    expected_scratch_reads_for_command = 465_708;
                10:
                    expected_scratch_reads_for_command = 1_397_124;
                11:
                    expected_scratch_reads_for_command = 15_444_012;
                14, 19:
                    expected_scratch_reads_for_command = 302_592;
                17, 18:
                    expected_scratch_reads_for_command = 605_184;
                default:
                    expected_scratch_reads_for_command = 0;
            endcase
        end
    endfunction

    function automatic longint unsigned expected_writes_for_command(
        input integer ordinal
    );
        begin
            case (ordinal)
                8, 9, 10:
                    expected_writes_for_command = 465_708;
                16, 17:
                    expected_writes_for_command = 605_184;
                default:
                    expected_writes_for_command = 151_296;
            endcase
        end
    endfunction

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $display(
                    "ERROR E02_LAYER0_REAL_LOGICAL cycle=%0d command=%0d: %s",
                    cycle_count,
                    command_count,
                    message
                );
                $fflush();
            end
        end
    endtask

    assign layer_param_data = layer0_params;
    assign layer_param_valid = layer_param_request;
    assign operand_load_ready = 1'b1;
    assign checkpoint_ready = 1'b1;
    assign responder_idle = !response_pending && !mem_rsp_valid;
    assign force_request_stall =
        responder_idle &&
        (mem_req_valid === 1'b1) &&
        (forced_stall_count < FORCED_STALL_BUDGET) &&
        !forced_stall_armed;
    assign mem_req_ready = responder_idle && !force_request_stall;

    always_comb begin
        request_address_valid = logical_request_valid(
            mem_req_write,
            mem_req_space,
            mem_req_word_address,
            mem_req_write_strobe
        );
        // Never index a backing array until the complete address/space/strobe
        // tuple has passed the range checker.  This makes malformed/X traffic
        // fail closed instead of allowing an out-of-range simulator access.
        request_read_data = FP32_QNAN;
        if (
            (mem_req_write === 1'b0) &&
            (request_address_valid === 1'b1)
        )
            request_read_data =
                read_logical_word(mem_req_space, mem_req_word_address);
        else if (mem_req_write === 1'b1)
            request_read_data = 32'd0;
    end

    vit_phase_e_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .INPUT_WORDS(INPUT_BACKING_WORDS),
        .PARAM_WORDS(MODEL_BACKING_WORDS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .job_valid(job_valid),
        .job_ready(job_ready),
        .job(job),
        .global_params(global_params),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_valid),
        .layer_param_data(layer_param_data),
        .operand_load_request(operand_load_request),
        .operand_load_ready(operand_load_ready),
        .operand_load_command(operand_load_command),
        .checkpoint_valid(checkpoint_valid),
        .checkpoint_ready(checkpoint_ready),
        .checkpoint_phase(checkpoint_phase),
        .checkpoint_section(checkpoint_section),
        .checkpoint_layer(checkpoint_layer),
        .checkpoint_step(checkpoint_step),
        .checkpoint_tag(checkpoint_tag),
        .checkpoint_opcode(checkpoint_opcode),
        .checkpoint_dst_tensor(checkpoint_dst_tensor),
        .busy(busy),
        .done(done),
        .error(error),
        .error_code(error_code),
        .error_section(error_section),
        .error_layer(error_layer),
        .error_step(error_step),
        .input_write_enable(1'b0),
        .input_write_address(32'd0),
        .input_write_data(32'd0),
        .parameter_write_enable(1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data(32'd0),
        .scratch_write_enable(1'b0),
        .scratch_write_address(32'd0),
        .scratch_write_data(32'd0),
        .scratch_read_address(32'd0),
        .scratch_read_data(),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

    // One outstanding request, one registered response.  Accepted requests
    // are range-checked before a response can be generated.  Invalid traffic
    // is fatal because returning fabricated data would invalidate numerical
    // evidence.
    always @(posedge clk) begin
        if (rst) begin
            response_pending <= 1'b0;
            pending_write <= 1'b0;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_write_strobe <= 4'd0;
            pending_read_data <= 32'd0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= 32'd0;
            mem_rsp_error <= 1'b0;
            accepted_request_count <= 64'd0;
            response_handshake_count <= 64'd0;
            write_request_accept_count <= 64'd0;
            read_transaction_count <= 64'd0;
            write_transaction_count <= 64'd0;
            parameter_read_count <= 64'd0;
            scratch_read_count <= 64'd0;
            input_read_count <= 64'd0;
            invalid_transaction_count <= 32'd0;
            parameter_min_address <= 32'hffff_ffff;
            parameter_max_address <= 32'd0;
            scratch_min_address <= 32'hffff_ffff;
            scratch_max_address <= 32'd0;
            forced_stall_armed <= 1'b0;
            forced_stall_count <= 0;
        end else begin
            if (force_request_stall) begin
                forced_stall_armed <= 1'b1;
                forced_stall_count <= forced_stall_count + 1;
            end else if (!mem_req_valid) begin
                forced_stall_armed <= 1'b0;
            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                response_handshake_count <=
                    response_handshake_count + 1'b1;
                if (pending_write) begin
                    scratch_memory[pending_address] <=
                        pending_write_data;
                    write_transaction_count <=
                        write_transaction_count + 1'b1;
                end
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= 32'd0;
                mem_rsp_error <= 1'b0;
            end

            if (response_pending) begin
                mem_rsp_valid <= 1'b1;
                mem_rsp_read_data <= pending_read_data;
                mem_rsp_error <= 1'b0;
                response_pending <= 1'b0;
            end

            if (mem_req_valid && mem_req_ready) begin
                accepted_request_count <=
                    accepted_request_count + 1'b1;
                forced_stall_armed <= 1'b0;
                if (
                    ((^{mem_req_write,
                        mem_req_space,
                        mem_req_word_address}) === 1'bx) ||
                    (mem_req_write &&
                     ((^{mem_req_write_data,
                         mem_req_write_strobe}) === 1'bx))
                )
                    $fatal(
                        1,
                        "X/Z on accepted logical-memory request"
                    );

                if (request_address_valid !== 1'b1) begin
                    invalid_transaction_count <=
                        invalid_transaction_count + 1'b1;
                    $fatal(
                        1,
                        "Invalid E02 logical-memory request write=%0b space=%0d address=%08x strobe=%x",
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address,
                        mem_req_write_strobe
                    );
                end

                pending_write <= mem_req_write;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_write_strobe <= mem_req_write_strobe;
                pending_read_data <= request_read_data;
                response_pending <= 1'b1;
                if (mem_req_write)
                    write_request_accept_count <=
                        write_request_accept_count + 1'b1;

                if (mem_req_space == PHASE_E_MEM_PARAM) begin
                    parameter_read_count <= parameter_read_count + 1'b1;
                    if (mem_req_word_address < parameter_min_address)
                        parameter_min_address <= mem_req_word_address;
                    if (mem_req_word_address > parameter_max_address)
                        parameter_max_address <= mem_req_word_address;
                end else if (mem_req_space == PHASE_E_MEM_SCRATCH) begin
                    if (!mem_req_write)
                        scratch_read_count <= scratch_read_count + 1'b1;
                    if (mem_req_word_address < scratch_min_address)
                        scratch_min_address <= mem_req_word_address;
                    if (mem_req_word_address > scratch_max_address)
                        scratch_max_address <= mem_req_word_address;
                end else if (mem_req_space == PHASE_E_MEM_INPUT) begin
                    input_read_count <= input_read_count + 1'b1;
                end

                if (!mem_req_write)
                    read_transaction_count <=
                        read_transaction_count + 1'b1;
            end
        end
    end

    // Requests must remain stable while the responder applies backpressure.
    always @(posedge clk) begin
        if (rst) begin
            stalled_request <= 1'b0;
            stalled_write <= 1'b0;
            stalled_space <= PHASE_E_MEM_NONE;
            stalled_address <= 32'd0;
            stalled_write_data <= 32'd0;
            stalled_write_strobe <= 4'd0;
            backpressure_cycle_count <= 64'd0;
        end else if (stalled_request) begin
            check(
                mem_req_valid === 1'b1,
                "request valid remains asserted until handshake"
            );
            if (mem_req_valid === 1'b1) begin
                check(
                    mem_req_write == stalled_write &&
                    mem_req_space == stalled_space &&
                    mem_req_word_address == stalled_address &&
                    mem_req_write_data == stalled_write_data &&
                    mem_req_write_strobe == stalled_write_strobe,
                    "request payload remains stable until handshake"
                );
                if (mem_req_ready)
                    stalled_request <= 1'b0;
                else
                    backpressure_cycle_count <=
                        backpressure_cycle_count + 1'b1;
            end else begin
                // Clear after reporting a protocol violation so a single
                // dropped request cannot flood a long-running log.
                stalled_request <= 1'b0;
            end
        end else if (mem_req_valid && !mem_req_ready) begin
            stalled_request <= 1'b1;
            stalled_write <= mem_req_write;
            stalled_space <= mem_req_space;
            stalled_address <= mem_req_word_address;
            stalled_write_data <= mem_req_write_data;
            stalled_write_strobe <= mem_req_write_strobe;
            backpressure_cycle_count <= backpressure_cycle_count + 1'b1;
        end
    end

    // The registered response must likewise remain asserted and stable until
    // the production engine accepts it.
    always @(posedge clk) begin
        if (rst) begin
            stalled_response <= 1'b0;
            stalled_response_data <= 32'd0;
            stalled_response_error <= 1'b0;
        end else if (stalled_response) begin
            check(
                mem_rsp_valid === 1'b1,
                "response valid remains asserted until handshake"
            );
            if (mem_rsp_valid === 1'b1) begin
                check(
                    (mem_rsp_read_data == stalled_response_data) &&
                    (mem_rsp_error == stalled_response_error),
                    "response payload remains stable until handshake"
                );
                if (mem_rsp_ready)
                    stalled_response <= 1'b0;
            end else begin
                stalled_response <= 1'b0;
            end
        end else if (mem_rsp_valid && !mem_rsp_ready) begin
            stalled_response <= 1'b1;
            stalled_response_data <= mem_rsp_read_data;
            stalled_response_error <= mem_rsp_error;
        end
    end

    // Command, checkpoint and staging scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 64'd0;
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            parameter_step_seen <= 20'd0;
            layer_request_count <= 0;
            class_result_count <= 0;
            next_progress_cycle <= progress_cycle_interval;
            next_progress_transaction <= progress_transaction_interval;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (dut.command_valid && dut.command_ready) begin
                check(
                    command_count < EXPECTED_COMMANDS,
                    "no command beyond the twenty-step encoder layer"
                );
                if (command_count < EXPECTED_COMMANDS) begin
                    check(
                        dut.command === expected_command(command_count),
                        "all 512 command descriptor bits match layer-0 contract"
                    );
                    check(
                        dut.command.header.opcode ==
                            expected_opcode(command_count),
                        "command opcode follows encoder step order"
                    );
                    check(
                        dut.command.header.tag ==
                            JOB_TAG + command_count[7:0],
                        "command tag follows ordinal"
                    );
                    check(
                        dut.command.header.reserved[7:6] ==
                            PHASE_E_SECTION_ENCODER,
                        "command section is ENCODER"
                    );
                    check(
                        dut.command.header.reserved[5:2] == 4'd0,
                        "command layer is zero"
                    );
                    check(
                        dut.command.route.reserved[4:0] ==
                            command_count[4:0],
                        "command step follows ordinal"
                    );
                    accepted_commands[command_count] <= dut.command;
                    command_parameter_read_start[command_count] <=
                        parameter_read_count;
                    command_scratch_read_start[command_count] <=
                        scratch_read_count;
                    command_write_start[command_count] <=
                        write_transaction_count;
                end
                command_count <= command_count + 1;
            end

            if (checkpoint_valid && checkpoint_ready) begin
                check(
                    checkpoint_count < EXPECTED_COMMANDS,
                    "no checkpoint beyond the twenty-step encoder layer"
                );
                check(
                    checkpoint_phase == PHASE_E_E02,
                    "checkpoint phase is E02"
                );
                check(
                    checkpoint_section == PHASE_E_SECTION_ENCODER,
                    "checkpoint section is ENCODER"
                );
                check(
                    checkpoint_layer == 4'd0,
                    "checkpoint layer is zero"
                );
                check(
                    checkpoint_step == checkpoint_count[4:0],
                    "checkpoint step is ordered"
                );
                if (checkpoint_count < EXPECTED_COMMANDS) begin
                    check(
                        checkpoint_count < command_count,
                        "checkpoint follows its accepted command"
                    );
                    check(
                        checkpoint_tag ==
                            accepted_commands[checkpoint_count].header.tag,
                        "checkpoint tag matches accepted descriptor"
                    );
                    check(
                        checkpoint_opcode ==
                            accepted_commands[checkpoint_count].header.opcode,
                        "checkpoint opcode matches accepted descriptor"
                    );
                    check(
                        checkpoint_dst_tensor ==
                            accepted_commands[checkpoint_count].
                                route.dst_tensor,
                        "checkpoint destination matches accepted descriptor"
                    );
                    check(
                        checkpoint_tag ==
                            expected_command(checkpoint_count).header.tag &&
                        checkpoint_opcode ==
                            expected_command(checkpoint_count).header.opcode &&
                        checkpoint_dst_tensor ==
                            expected_command(checkpoint_count).
                                route.dst_tensor,
                        "checkpoint metadata matches independent contract"
                    );
                    check(
                        parameter_read_count -
                            command_parameter_read_start[checkpoint_count] ==
                            expected_parameter_reads_for_command(
                                checkpoint_count
                            ),
                        "command has exact PARAM-read traffic"
                    );
                    check(
                        scratch_read_count -
                            command_scratch_read_start[checkpoint_count] ==
                            expected_scratch_reads_for_command(
                                checkpoint_count
                            ),
                        "command has exact SCRATCH-read traffic"
                    );
                    check(
                        write_transaction_count -
                            command_write_start[checkpoint_count] ==
                            expected_writes_for_command(checkpoint_count),
                        "command has exact completed-write traffic"
                    );
                end
                checkpoint_count <= checkpoint_count + 1;
            end

            if (operand_load_request && operand_load_ready) begin
                check(
                    parameter_request_count < EXPECTED_PARAMETER_REQUESTS,
                    "no operand request beyond eight parameter commands"
                );
                check(
                    operand_load_command.header.reserved[7:6] ==
                        PHASE_E_SECTION_ENCODER,
                    "operand request section is ENCODER"
                );
                check(
                    operand_load_command.header.reserved[5:2] == 4'd0,
                    "operand request layer is zero"
                );
                check(
                    parameter_step_expected(
                        operand_load_command.route.reserved[4:0]
                    ),
                    "operand request occurs only on parameter-backed step"
                );
                if (
                    parameter_request_count <
                    EXPECTED_PARAMETER_REQUESTS
                ) begin
                    check(
                        operand_load_command.route.reserved[4:0] ==
                            expected_parameter_step(
                                parameter_request_count
                            ),
                        "operand request follows exact parameter-step order"
                    );
                    check(
                        !parameter_step_seen[
                            expected_parameter_step(
                                parameter_request_count
                            )
                        ],
                        "operand request step is unique"
                    );
                    check(
                        operand_load_command === expected_command(
                            expected_parameter_step(
                                parameter_request_count
                            )
                        ),
                        "operand request carries exact command descriptor"
                    );
                    parameter_step_seen[
                        expected_parameter_step(parameter_request_count)
                    ] <= 1'b1;
                end
                parameter_request_count <= parameter_request_count + 1;
            end

            if (layer_param_request && layer_param_valid) begin
                check(
                    layer_param_index == 4'd0,
                    "layer-table request selects layer zero"
                );
                layer_request_count <= layer_request_count + 1;
            end

            if (class_result_valid)
                class_result_count <= class_result_count + 1;

            if (busy && (cycle_count >= next_progress_cycle)) begin
                $display(
                    "E02_LAYER0_REAL_LOGICAL_CYCLE_PROGRESS cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    read_transaction_count,
                    write_transaction_count
                );
                $fflush();
                next_progress_cycle <=
                    next_progress_cycle + progress_cycle_interval;
            end

            if (
                busy &&
                (read_transaction_count >= next_progress_transaction)
            ) begin
                $display(
                    "E02_LAYER0_REAL_LOGICAL_TRANSACTION_PROGRESS cycles=%0d commands=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d",
                    cycle_count,
                    command_count,
                    read_transaction_count,
                    write_transaction_count,
                    parameter_read_count,
                    scratch_read_count
                );
                $fflush();
                next_progress_transaction <=
                    next_progress_transaction +
                    progress_transaction_interval;
            end

            if (cycle_count >= WATCHDOG_CYCLES)
                $fatal(
                    1,
                    "E02 logical-memory watchdog after %0d cycles",
                    WATCHDOG_CYCLES
                );
        end
    end

    initial begin
        progress_cycle_interval = 50_000_000;
        progress_transaction_interval = 10_000_000;
        probe_cycle_limit = 0;
        progress_cycle_plusarg_status = $value$plusargs(
            "E02_LOGICAL_PROGRESS_CYCLES=%d",
            progress_cycle_interval
        );
        progress_transaction_plusarg_status = $value$plusargs(
            "E02_LOGICAL_PROGRESS_TRANSACTIONS=%d",
            progress_transaction_interval
        );
        probe_cycle_plusarg_status = $value$plusargs(
            "E02_LOGICAL_PROBE_CYCLES=%d",
            probe_cycle_limit
        );
        if (
            (progress_cycle_interval <= 0) ||
            (progress_transaction_interval <= 0) ||
            (probe_cycle_limit < 0)
        )
            $fatal(1, "E02 logical progress/probe configuration invalid");
        $display(
            "E02_LAYER0_REAL_LOGICAL_RUN_CONFIG progress_cycles=%0d progress_transactions=%0d probe_cycles=%0d plusarg_hits=%0d/%0d/%0d",
            progress_cycle_interval,
            progress_transaction_interval,
            probe_cycle_limit,
            progress_cycle_plusarg_status,
            progress_transaction_plusarg_status,
            probe_cycle_plusarg_status
        );
        $fflush();
    end

    initial begin
        layer0_params = '0;
        layer0_params.ln1_gamma_base = LN1_GAMMA_BASE;
        layer0_params.ln1_beta_base = LN1_BETA_BASE;
        layer0_params.q_weight_base = Q_WEIGHT_BASE;
        layer0_params.q_bias_base = Q_BIAS_BASE;
        layer0_params.k_weight_base = K_WEIGHT_BASE;
        layer0_params.k_bias_base = K_BIAS_BASE;
        layer0_params.v_weight_base = V_WEIGHT_BASE;
        layer0_params.v_bias_base = V_BIAS_BASE;
        layer0_params.o_weight_base = O_WEIGHT_BASE;
        layer0_params.o_bias_base = O_BIAS_BASE;
        layer0_params.ln2_gamma_base = LN2_GAMMA_BASE;
        layer0_params.ln2_beta_base = LN2_BETA_BASE;
        layer0_params.fc1_weight_base = FC1_WEIGHT_BASE;
        layer0_params.fc1_bias_base = FC1_BIAS_BASE;
        layer0_params.fc2_weight_base = FC2_WEIGHT_BASE;
        layer0_params.fc2_bias_base = FC2_BIAS_BASE;

        $display("E02_LAYER0_REAL_LOGICAL_PRELOAD_BEGIN tensors=18");
        $fflush();
        $readmemh(
            "results/embedding_step_06_hidden_states_f32.hex",
            scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $readmemh(
            "results/encoder_layer_00_step_20_layer_output_f32.hex",
            golden_output
        );

        $readmemh(
            "parameters/encoder_layer_00_ln_before_gamma_f32.hex",
            model_memory,
            LN1_GAMMA_BASE,
            LN1_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_before_beta_f32.hex",
            model_memory,
            LN1_BETA_BASE,
            LN1_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_q_weight_B_f32.hex",
            model_memory,
            Q_WEIGHT_BASE,
            Q_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_q_bias_f32.hex",
            model_memory,
            Q_BIAS_BASE,
            Q_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_k_weight_B_f32.hex",
            model_memory,
            K_WEIGHT_BASE,
            K_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_k_bias_f32.hex",
            model_memory,
            K_BIAS_BASE,
            K_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_v_weight_B_f32.hex",
            model_memory,
            V_WEIGHT_BASE,
            V_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_v_bias_f32.hex",
            model_memory,
            V_BIAS_BASE,
            V_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_o_weight_B_f32.hex",
            model_memory,
            O_WEIGHT_BASE,
            O_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_o_bias_f32.hex",
            model_memory,
            O_BIAS_BASE,
            O_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_after_gamma_f32.hex",
            model_memory,
            LN2_GAMMA_BASE,
            LN2_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_after_beta_f32.hex",
            model_memory,
            LN2_BETA_BASE,
            LN2_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc1_weight_B_f32.hex",
            model_memory,
            FC1_WEIGHT_BASE,
            FC1_WEIGHT_BASE + FC_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc1_bias_f32.hex",
            model_memory,
            FC1_BIAS_BASE,
            FC1_BIAS_BASE + INTERMEDIATE_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc2_weight_B_f32.hex",
            model_memory,
            FC2_WEIGHT_BASE,
            FC2_WEIGHT_BASE + FC_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc2_bias_f32.hex",
            model_memory,
            FC2_BIAS_BASE,
            FC2_BIAS_BASE + HIDDEN_SIZE - 1
        );

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_LINEAR_TMP + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_Q_HEAD + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_K_HEAD + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_V_HEAD + initialize_index
            ] = FP32_SENTINEL;
        end
        for (initialize_index = 0;
             initialize_index < SCORE_WORDS;
             initialize_index = initialize_index + 1)
            scratch_memory[
                PHASE_E_ADDR_SCORE_PROB + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0;
             initialize_index < FC1_WORDS;
             initialize_index = initialize_index + 1)
            scratch_memory[
                PHASE_E_ADDR_FC1 + initialize_index
            ] = FP32_SENTINEL;
        input_memory[0] = 32'd0;

        $display(
            "E02_LAYER0_REAL_LOGICAL_PRELOAD_DONE embedding_words=%0d model_backing_words=%0d golden_words=%0d",
            HIDDEN_WORDS,
            MODEL_BACKING_WORDS,
            HIDDEN_WORDS
        );
        $fflush();

        repeat (8)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        job = '0;
        job.phase = PHASE_E_E02;
        job.first_layer = 4'd0;
        job.last_layer = 4'd0;
        job.class_softmax_enable = 1'b0;
        job.checkpoint_enable = 1'b1;
        job.job_tag = JOB_TAG;
        job.patch_a_base = 32'd0;
        global_params = '0;

        @(negedge clk);
        job_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!job_ready);
        @(negedge clk);
        job_valid = 1'b0;

        $display(
            "E02_LAYER0_REAL_LOGICAL_STARTED cycle=%0d expected_commands=%0d expected_writes=%0d",
            cycle_count,
            EXPECTED_COMMANDS,
            EXPECTED_WRITES
        );
        $fflush();

        wait (done || error);
        #1;

        check(!error, "E02 completed without sequencer error");
        check(error_code == PHASE_E_ERROR_NONE, "error code is NONE");
        check(command_count == EXPECTED_COMMANDS, "twenty commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "twenty checkpoints observed"
        );
        check(
            parameter_request_count == EXPECTED_PARAMETER_REQUESTS,
            "eight parameter-bearing commands staged"
        );
        check(
            parameter_step_seen == EXPECTED_PARAMETER_STEP_MASK,
            "parameter-bearing command set is exact"
        );
        check(
            layer_request_count == EXPECTED_LAYER_REQUESTS,
            "one layer-table request observed"
        );
        check(class_result_count == 0, "encoder emits no class result");

        check(
            parameter_read_count == EXPECTED_PARAMETER_READS,
            "exact encoder-layer PARAM read count"
        );
        check(
            scratch_read_count == EXPECTED_SCRATCH_READS,
            "exact encoder-layer SCRATCH read count"
        );
        check(
            read_transaction_count == EXPECTED_READS,
            "exact encoder-layer total read count"
        );
        check(
            write_transaction_count == EXPECTED_WRITES,
            "exact encoder-layer scratch write count"
        );
        check(
            write_request_accept_count == EXPECTED_WRITES,
            "every expected write request was accepted"
        );
        check(
            accepted_request_count == EXPECTED_REQUESTS,
            "exact total logical-memory request count"
        );
        check(
            response_handshake_count == EXPECTED_REQUESTS,
            "exact total logical-memory response count"
        );
        check(
            accepted_request_count == response_handshake_count,
            "no outstanding request at terminal state"
        );
        check(
            !response_pending && !mem_rsp_valid && !stalled_response,
            "response channel is quiescent at terminal state"
        );
        check(
            !stalled_request,
            "request channel is quiescent at terminal state"
        );
        check(
            forced_stall_count == FORCED_STALL_BUDGET,
            "bounded forced-backpressure campaign completed"
        );
        check(
            backpressure_cycle_count >= FORCED_STALL_BUDGET,
            "request stability was exercised under backpressure"
        );
        check(
            read_transaction_count ==
                parameter_read_count + scratch_read_count,
            "every read maps to PARAM or SCRATCH"
        );
        check(input_read_count == 0, "E02 never reads INPUT");
        check(
            invalid_transaction_count == 0,
            "all logical-memory transactions are valid"
        );
        check(
            parameter_min_address == EXPECTED_PARAM_MIN,
            "PARAM minimum is layer-0 LN1 gamma"
        );
        check(
            parameter_max_address == EXPECTED_PARAM_MAX,
            "PARAM maximum is layer-0 FC2 bias end"
        );
        check(
            scratch_min_address == EXPECTED_SCRATCH_MIN,
            "SCRATCH minimum is HIDDEN_A"
        );
        check(
            scratch_max_address == EXPECTED_SCRATCH_MAX,
            "SCRATCH maximum is FC1 end"
        );

        exact_mismatches = 0;
        tolerance_failures = 0;
        unknown_failures = 0;
        nonfinite_failures = 0;
        max_error_index = 0;
        max_ratio_index = 0;
        max_error_rtl_word = 32'd0;
        max_error_golden_word = 32'd0;
        max_abs_error = 0.0;
        max_normalized_error = 0.0;
        sum_abs_error = 0.0;

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (
                scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + initialize_index
                ] !== golden_output[initialize_index]
            )
                exact_mismatches = exact_mismatches + 1;

            if (
                $isunknown(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                ) ||
                $isunknown(golden_output[initialize_index])
            ) begin
                unknown_failures = unknown_failures + 1;
                tolerance_failures = tolerance_failures + 1;
            end else if (
                !fp32_is_finite(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_output[initialize_index])
            ) begin
                nonfinite_failures = nonfinite_failures + 1;
                tolerance_failures = tolerance_failures + 1;
            end else begin
                rtl_value = fp32_to_real(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                );
                golden_value = fp32_to_real(golden_output[initialize_index]);
                absolute_error = rtl_value - golden_value;
                if (absolute_error < 0.0)
                    absolute_error = -absolute_error;
                allowed_error = golden_value;
                if (allowed_error < 0.0)
                    allowed_error = -allowed_error;
                allowed_error =
                    OUTPUT_ABS_TOLERANCE +
                    (OUTPUT_REL_TOLERANCE * allowed_error);
                normalized_error = absolute_error / allowed_error;
                sum_abs_error = sum_abs_error + absolute_error;
                if (absolute_error > max_abs_error) begin
                    max_abs_error = absolute_error;
                    max_error_index = initialize_index;
                    max_error_rtl_word =
                        scratch_memory[
                            PHASE_E_ADDR_HIDDEN_A + initialize_index
                        ];
                    max_error_golden_word =
                        golden_output[initialize_index];
                end
                if (normalized_error > max_normalized_error) begin
                    max_normalized_error = normalized_error;
                    max_ratio_index = initialize_index;
                end
                if (absolute_error > allowed_error)
                    tolerance_failures = tolerance_failures + 1;
            end
        end
        mean_abs_error = sum_abs_error / real'(HIDDEN_WORDS);

        $display(
            "E02_LAYER0_REAL_LOGICAL_TRAFFIC reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d input_reads=%0d invalid=%0d param_min=%08x param_max=%08x scratch_min=%08x scratch_max=%08x",
            read_transaction_count,
            write_transaction_count,
            parameter_read_count,
            scratch_read_count,
            input_read_count,
            invalid_transaction_count,
            parameter_min_address,
            parameter_max_address,
            scratch_min_address,
            scratch_max_address
        );
        $display(
            "E02_LAYER0_REAL_LOGICAL_NUMERIC words=%0d exact_mismatch=%0d tolerance_failures=%0d unknown=%0d nonfinite=%0d max_abs=%0.9e mean_abs=%0.9e max_index=%0d max_ratio=%0.9e max_ratio_index=%0d rtl=%08x golden=%08x abs_tol=%0.9e rel_tol=%0.9e",
            HIDDEN_WORDS,
            exact_mismatches,
            tolerance_failures,
            unknown_failures,
            nonfinite_failures,
            max_abs_error,
            mean_abs_error,
            max_error_index,
            max_normalized_error,
            max_ratio_index,
            max_error_rtl_word,
            max_error_golden_word,
            OUTPUT_ABS_TOLERANCE,
            OUTPUT_REL_TOLERANCE
        );
        $fflush();

        check(unknown_failures == 0, "no X/Z output or golden word");
        check(nonfinite_failures == 0, "no NaN/Inf output or golden word");
        check(
            tolerance_failures == 0,
            "all 151296 layer-0 outputs match documented tolerance"
        );

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d input_reads=%0d invalid=%0d requests=%0d responses=%0d outstanding=%0d stalls=%0d forced_stalls=%0d tolerance_failures=%0d nonfinite=%0d unknown=%0d exact_mismatch=%0d max_abs=%0.9e mean_abs=%0.9e",
                checks,
                cycle_count,
                command_count,
                read_transaction_count,
                write_transaction_count,
                parameter_read_count,
                scratch_read_count,
                input_read_count,
                invalid_transaction_count,
                accepted_request_count,
                response_handshake_count,
                accepted_request_count - response_handshake_count,
                backpressure_cycle_count,
                forced_stall_count,
                tolerance_failures,
                nonfinite_failures,
                unknown_failures,
                exact_mismatches,
                max_abs_error,
                mean_abs_error
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_E2E_FAIL checks=%0d failures=%0d commands=%0d",
                checks,
                failures,
                command_count
            );
        end
    end

    initial begin
        wait (!rst);
        if (probe_cycle_limit > 0) begin
            repeat (probe_cycle_limit)
                @(posedge clk);
            #1;
            if (
                (failures == 0) &&
                (error === 1'b0) &&
                (done === 1'b0) &&
                (busy === 1'b1) &&
                (invalid_transaction_count == 0) &&
                (command_count > 0) &&
                (accepted_request_count > 0) &&
                (forced_stall_count == FORCED_STALL_BUDGET) &&
                (backpressure_cycle_count >= FORCED_STALL_BUDGET) &&
                (accepted_request_count >= response_handshake_count) &&
                ((accepted_request_count - response_handshake_count) <= 1)
            ) begin
                $display(
                    "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_PROBE_PASS cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d requests=%0d responses=%0d outstanding=%0d stalls=%0d forced_stalls=%0d invalid=0 failures=0",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    read_transaction_count,
                    write_transaction_count,
                    parameter_read_count,
                    scratch_read_count,
                    accepted_request_count,
                    response_handshake_count,
                    accepted_request_count - response_handshake_count,
                    backpressure_cycle_count,
                    forced_stall_count
                );
                $fflush();
                $finish;
            end else begin
                $fatal(
                    1,
                    "VIT_PHASE_E_NPU_E02_LAYER0_REAL_LOGICAL_RTL_PROBE_FAIL cycles=%0d commands=%0d requests=%0d responses=%0d stalls=%0d forced_stalls=%0d invalid=%0d failures=%0d error=%0b",
                    cycle_count,
                    command_count,
                    accepted_request_count,
                    response_handshake_count,
                    backpressure_cycle_count,
                    forced_stall_count,
                    invalid_transaction_count,
                    failures,
                    error
                );
            end
        end
    end

endmodule
