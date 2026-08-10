`timescale 1ns/1ps

// Compact, production-hierarchy E05 end-to-end test.
//
// The test executes one continuous job through:
//   embedding -> 12 encoder layers -> final/classifier -> class Softmax
//
// It intentionally does not define VIT_PURE_SV_BEHAVIORAL.  Every command is
// therefore executed by vit_phase_e_engine_top and its production leaf/block
// hierarchy.  Compact dimensions make all 249 E05 commands practical in a
// cycle-accurate simulator without changing the production RTL defaults.
//
// Golden model:
//   * prepared patch input, weights, beta, biases, CLS and position are +0;
//   * every LayerNorm gamma is +1;
//   * the final classifier bias is +7 only for TARGET_CLASS;
//   * all other classifier biases are +0.
//
// Consequently every ordinary destination write is exactly +0.  Attention
// Softmax and final Softmax are checked as known, finite probabilities, while
// final logits and the class result are checked against the programmed bias.
module tb_vit_phase_e_npu_e05_compact_rtl;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;

    localparam logic [31:0] E05_PATCH_COUNT = 32'd2;
    localparam logic [31:0] E05_TOKEN_COUNT = 32'd3;
    localparam logic [31:0] E05_HIDDEN_SIZE = 32'd16;
    localparam logic [31:0] E05_HEAD_COUNT = 32'd2;
    localparam logic [31:0] E05_HEAD_SIZE = 32'd8;
    localparam logic [31:0] E05_INTERMEDIATE_SIZE = 32'd16;
    localparam logic [31:0] E05_CLASS_COUNT = 32'd7;
    localparam logic [31:0] E05_ATTN_SCALE_FP32 = 32'h3f80_0000;

    localparam integer E05_ENCODER_LAYERS = 12;
    localparam integer PATCH_WORDS = 2 * 16;
    localparam integer HIDDEN_WORDS = 3 * 16;
    localparam integer HEAD_WORDS = 2 * 3 * 8;
    localparam integer ONE_HEAD_WORDS = 3 * 8;
    localparam integer SCORE_ROW_WORDS = 3 * 3;
    localparam integer SCORE_WORDS = 2 * 3 * 3;
    localparam integer FC1_WORDS = 3 * 16;
    localparam integer CLASS_WORDS = 7;

    localparam integer TARGET_CLASS = 3;
    localparam logic [7:0] JOB_TAG = 8'h80;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_ONE = 32'h3f80_0000;
    localparam logic [31:0] FP32_SEVEN = 32'h40e0_0000;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;

    localparam integer EXPECTED_COMMANDS = 249;
    localparam integer EXPECTED_LAYER_REQUESTS = 12;
    localparam integer EXPECTED_PARAMETER_REQUESTS = 101;
    localparam integer EXPECTED_GEMM_COMMANDS = 98;
    localparam integer EXPECTED_VECTOR_COMMANDS = 37;
    localparam integer EXPECTED_LAYOUT_COMMANDS = 63;
    localparam integer EXPECTED_LAYERNORM_COMMANDS = 25;
    localparam integer EXPECTED_SOFTMAX_COMMANDS = 13;
    localparam integer EXPECTED_GELU_COMMANDS = 12;
    localparam integer EXPECTED_ARGMAX_COMMANDS = 1;

    // Embedding writes 128 words, each compact encoder writes 870 words, and
    // the final section writes 78 words (Argmax itself writes no memory).
    localparam integer EXPECTED_WRITES =
        128 + (E05_ENCODER_LAYERS * 870) + 78;
    localparam integer WATCHDOG_CYCLES = 20_000_000;

    // Parameter memory is sparse and algorithmic.  Each layer owns a
    // non-overlapping 2-Kword slot so address classification stays obvious.
    localparam logic [31:0] PATCH_WEIGHT_BASE = 32'd0;
    localparam logic [31:0] PATCH_BIAS_BASE = 32'd256;
    localparam logic [31:0] CLS_BASE = 32'd272;
    localparam logic [31:0] POSITION_BASE = 32'd288;
    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'd336;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'd352;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'd368;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE = 32'd480;

    localparam logic [31:0] LAYER_PARAM_BASE = 32'd1024;
    localparam logic [31:0] LAYER_PARAM_STRIDE = 32'd2048;
    localparam logic [31:0] LAYER_LN1_GAMMA_OFFSET = 32'd0;
    localparam logic [31:0] LAYER_LN1_BETA_OFFSET = 32'd16;
    localparam logic [31:0] LAYER_Q_WEIGHT_OFFSET = 32'd32;
    localparam logic [31:0] LAYER_Q_BIAS_OFFSET = 32'd288;
    localparam logic [31:0] LAYER_K_WEIGHT_OFFSET = 32'd304;
    localparam logic [31:0] LAYER_K_BIAS_OFFSET = 32'd560;
    localparam logic [31:0] LAYER_V_WEIGHT_OFFSET = 32'd576;
    localparam logic [31:0] LAYER_V_BIAS_OFFSET = 32'd832;
    localparam logic [31:0] LAYER_O_WEIGHT_OFFSET = 32'd848;
    localparam logic [31:0] LAYER_O_BIAS_OFFSET = 32'd1104;
    localparam logic [31:0] LAYER_LN2_GAMMA_OFFSET = 32'd1120;
    localparam logic [31:0] LAYER_LN2_BETA_OFFSET = 32'd1136;
    localparam logic [31:0] LAYER_FC1_WEIGHT_OFFSET = 32'd1152;
    localparam logic [31:0] LAYER_FC1_BIAS_OFFSET = 32'd1408;
    localparam logic [31:0] LAYER_FC2_WEIGHT_OFFSET = 32'd1424;
    localparam logic [31:0] LAYER_FC2_BIAS_OFFSET = 32'd1680;
    localparam integer PARAM_WORDS = 32768;

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
    logic [31:0] mem_rsp_read_data = FP32_POS_ZERO;
    logic mem_rsp_error = 1'b0;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    logic [31:0] hidden_a_memory [0:HIDDEN_WORDS-1];
    logic [31:0] hidden_b_memory [0:HIDDEN_WORDS-1];
    logic [31:0] linear_memory [0:HIDDEN_WORDS-1];
    logic [31:0] q_memory [0:HEAD_WORDS-1];
    logic [31:0] k_memory [0:HEAD_WORDS-1];
    logic [31:0] v_memory [0:HEAD_WORDS-1];
    logic [31:0] score_memory [0:SCORE_WORDS-1];
    logic [31:0] fc1_memory [0:FC1_WORDS-1];
    logic [31:0] logits_memory [0:CLASS_WORDS-1];
    logic [31:0] probability_memory [0:CLASS_WORDS-1];

    logic response_pending = 1'b0;
    logic [1:0] response_delay = 2'd0;
    logic pending_write = 1'b0;
    phase_e_mem_space_t pending_space = PHASE_E_MEM_NONE;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [3:0] pending_write_strobe = 4'd0;
    logic [31:0] pending_read_data = FP32_POS_ZERO;
    logic pending_error = 1'b0;
    logic mem_request_address_valid;
    logic [31:0] mem_request_read_data;

    longint cycle_count = 0;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer layer_request_count = 0;
    integer parameter_request_count = 0;
    integer class_result_count = 0;
    integer read_transaction_count = 0;
    integer write_transaction_count = 0;
    integer invalid_transaction_count = 0;
    integer zero_write_failure_count = 0;
    integer opcode_gemm_count = 0;
    integer opcode_vector_count = 0;
    integer opcode_layout_count = 0;
    integer opcode_layernorm_count = 0;
    integer opcode_softmax_count = 0;
    integer opcode_gelu_count = 0;
    integer opcode_argmax_count = 0;

    logic command_active = 1'b0;
    integer active_command_index = 0;
    integer active_write_start = 0;
    integer active_zero_failure_start = 0;
    logic active_zero_expected = 1'b0;
    logic active_parameter_stage_seen = 1'b0;
    phase_e_cmd_t active_command_snapshot = '0;

    logic [31:0] captured_class_index = 32'd0;
    logic [31:0] captured_class_logit = FP32_QNAN;

    integer initialize_index;
    integer verify_index;

    always #1 clk = ~clk;

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $display(
                    "ERROR E05_COMPACT_RTL_CHECK cycle=%0d command=%0d: %s",
                    cycle_count,
                    active_command_index,
                    message
                );
            end
        end
    endtask

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

    function automatic logic [31:0] layer_base(
        input integer layer_number
    );
        begin
            layer_base =
                LAYER_PARAM_BASE + (layer_number * LAYER_PARAM_STRIDE);
        end
    endfunction

    function automatic phase_e_layer_params_t make_layer_params(
        input logic [3:0] layer_number
    );
        phase_e_layer_params_t value;
        logic [31:0] base;
        begin
            value = '0;
            base = layer_base(layer_number);
            value.ln1_gamma_base = base + LAYER_LN1_GAMMA_OFFSET;
            value.ln1_beta_base = base + LAYER_LN1_BETA_OFFSET;
            value.q_weight_base = base + LAYER_Q_WEIGHT_OFFSET;
            value.q_bias_base = base + LAYER_Q_BIAS_OFFSET;
            value.k_weight_base = base + LAYER_K_WEIGHT_OFFSET;
            value.k_bias_base = base + LAYER_K_BIAS_OFFSET;
            value.v_weight_base = base + LAYER_V_WEIGHT_OFFSET;
            value.v_bias_base = base + LAYER_V_BIAS_OFFSET;
            value.o_weight_base = base + LAYER_O_WEIGHT_OFFSET;
            value.o_bias_base = base + LAYER_O_BIAS_OFFSET;
            value.ln2_gamma_base = base + LAYER_LN2_GAMMA_OFFSET;
            value.ln2_beta_base = base + LAYER_LN2_BETA_OFFSET;
            value.fc1_weight_base = base + LAYER_FC1_WEIGHT_OFFSET;
            value.fc1_bias_base = base + LAYER_FC1_BIAS_OFFSET;
            value.fc2_weight_base = base + LAYER_FC2_WEIGHT_OFFSET;
            value.fc2_bias_base = base + LAYER_FC2_BIAS_OFFSET;
            make_layer_params = value;
        end
    endfunction

    function automatic logic [31:0] read_parameter_word(
        input logic [31:0] address
    );
        integer layer_number;
        integer class_number;
        logic gamma_hit;
        begin
            read_parameter_word = FP32_POS_ZERO;
            gamma_hit = address_in_range(
                address,
                FINAL_LN_GAMMA_BASE,
                E05_HIDDEN_SIZE
            );

            for (
                layer_number = 0;
                layer_number < E05_ENCODER_LAYERS;
                layer_number = layer_number + 1
            ) begin
                gamma_hit = gamma_hit || address_in_range(
                    address,
                    layer_base(layer_number) + LAYER_LN1_GAMMA_OFFSET,
                    E05_HIDDEN_SIZE
                );
                gamma_hit = gamma_hit || address_in_range(
                    address,
                    layer_base(layer_number) + LAYER_LN2_GAMMA_OFFSET,
                    E05_HIDDEN_SIZE
                );
            end

            if (gamma_hit) begin
                read_parameter_word = FP32_ONE;
            end else if (address_in_range(
                address,
                CLASSIFIER_BIAS_BASE,
                E05_CLASS_COUNT
            )) begin
                class_number = address - CLASSIFIER_BIAS_BASE;
                read_parameter_word =
                    (class_number == TARGET_CLASS)
                        ? FP32_SEVEN
                        : FP32_POS_ZERO;
            end
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
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_LOGITS, CLASS_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_CLASS_PROB, CLASS_WORDS
                );
        end
    endfunction

    function automatic logic logical_address_valid(
        input logic write_request,
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        begin
            if (write_request) begin
                logical_address_valid =
                    (space == PHASE_E_MEM_SCRATCH) &&
                    scratch_address_valid(address);
            end else begin
                case (space)
                    PHASE_E_MEM_SCRATCH:
                        logical_address_valid =
                            scratch_address_valid(address);
                    PHASE_E_MEM_PARAM:
                        logical_address_valid = address < PARAM_WORDS;
                    PHASE_E_MEM_INPUT:
                        logical_address_valid =
                            address_in_range(address, 32'd0, PATCH_WORDS);
                    default:
                        logical_address_valid = 1'b0;
                endcase
            end
        end
    endfunction

    function automatic logic [31:0] read_scratch_word(
        input logic [31:0] address
    );
        integer word_index;
        begin
            read_scratch_word = FP32_QNAN;
            if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_A, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_HIDDEN_A;
                read_scratch_word = hidden_a_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_B, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_HIDDEN_B;
                read_scratch_word = hidden_b_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_LINEAR_TMP, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_LINEAR_TMP;
                read_scratch_word = linear_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_Q_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_Q_HEAD;
                read_scratch_word = q_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_K_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_K_HEAD;
                read_scratch_word = k_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_V_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_V_HEAD;
                read_scratch_word = v_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_SCORE_PROB, SCORE_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_SCORE_PROB;
                read_scratch_word = score_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_FC1, FC1_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_FC1;
                read_scratch_word = fc1_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_LOGITS, CLASS_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_LOGITS;
                read_scratch_word = logits_memory[word_index];
            end else if (address_in_range(
                address, PHASE_E_ADDR_CLASS_PROB, CLASS_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_CLASS_PROB;
                read_scratch_word = probability_memory[word_index];
            end
        end
    endfunction

    function automatic logic [31:0] read_logical_word(
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        begin
            case (space)
                PHASE_E_MEM_INPUT:
                    read_logical_word = FP32_POS_ZERO;
                PHASE_E_MEM_PARAM:
                    read_logical_word = read_parameter_word(address);
                PHASE_E_MEM_SCRATCH:
                    read_logical_word = read_scratch_word(address);
                default:
                    read_logical_word = FP32_QNAN;
            endcase
        end
    endfunction

    task automatic write_scratch_word(
        input logic [31:0] address,
        input logic [31:0] data
    );
        integer word_index;
        begin
            if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_A, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_HIDDEN_A;
                hidden_a_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_B, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_HIDDEN_B;
                hidden_b_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_LINEAR_TMP, HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_LINEAR_TMP;
                linear_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_Q_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_Q_HEAD;
                q_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_K_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_K_HEAD;
                k_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_V_HEAD, HEAD_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_V_HEAD;
                v_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_SCORE_PROB, SCORE_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_SCORE_PROB;
                score_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_FC1, FC1_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_FC1;
                fc1_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_LOGITS, CLASS_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_LOGITS;
                logits_memory[word_index] = data;
            end else if (address_in_range(
                address, PHASE_E_ADDR_CLASS_PROB, CLASS_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_CLASS_PROB;
                probability_memory[word_index] = data;
            end else begin
                $fatal(
                    1,
                    "Unexpected committed scratch write address=%08x",
                    address
                );
            end
        end
    endtask

    function automatic phase_e_section_t expected_section(
        input integer command_index
    );
        begin
            if (command_index < 4)
                expected_section = PHASE_E_SECTION_EMBEDDING;
            else if (command_index < 244)
                expected_section = PHASE_E_SECTION_ENCODER;
            else
                expected_section = PHASE_E_SECTION_FINAL;
        end
    endfunction

    function automatic integer expected_context_layer(
        input integer command_index
    );
        begin
            if ((command_index >= 4) && (command_index < 244))
                expected_context_layer = (command_index - 4) / 20;
            else if (command_index < 4)
                expected_context_layer = 0;
            else
                expected_context_layer = E05_ENCODER_LAYERS - 1;
        end
    endfunction

    function automatic integer expected_checkpoint_layer(
        input integer command_index
    );
        begin
            if ((command_index >= 4) && (command_index < 244))
                expected_checkpoint_layer = (command_index - 4) / 20;
            else
                expected_checkpoint_layer = 15;
        end
    endfunction

    function automatic integer expected_step(
        input integer command_index
    );
        begin
            if (command_index < 4)
                expected_step = command_index;
            else if (command_index < 244)
                expected_step = (command_index - 4) % 20;
            else
                expected_step = command_index - 244;
        end
    endfunction

    function automatic phase_e_opcode_t expected_opcode(
        input integer command_index
    );
        integer step_number;
        begin
            step_number = expected_step(command_index);
            if (command_index < 4) begin
                case (step_number)
                    0: expected_opcode = PHASE_E_OP_GEMM;
                    1, 2: expected_opcode = PHASE_E_OP_LAYOUT;
                    default: expected_opcode = PHASE_E_OP_VECTOR;
                endcase
            end else if (command_index < 244) begin
                case (step_number)
                    0, 15: expected_opcode = PHASE_E_OP_LAYERNORM;
                    1, 3, 5, 8, 11, 13, 16, 18:
                        expected_opcode = PHASE_E_OP_GEMM;
                    2, 4, 6, 7, 12:
                        expected_opcode = PHASE_E_OP_LAYOUT;
                    9, 14, 19:
                        expected_opcode = PHASE_E_OP_VECTOR;
                    10: expected_opcode = PHASE_E_OP_SOFTMAX;
                    default: expected_opcode = PHASE_E_OP_GELU;
                endcase
            end else begin
                case (step_number)
                    0: expected_opcode = PHASE_E_OP_LAYERNORM;
                    1: expected_opcode = PHASE_E_OP_LAYOUT;
                    2: expected_opcode = PHASE_E_OP_GEMM;
                    3: expected_opcode = PHASE_E_OP_ARGMAX;
                    default: expected_opcode = PHASE_E_OP_SOFTMAX;
                endcase
            end
        end
    endfunction

    function automatic integer expected_command_writes(
        input integer command_index
    );
        integer step_number;
        begin
            step_number = expected_step(command_index);
            if (command_index < 4) begin
                case (step_number)
                    0: expected_command_writes = PATCH_WORDS;
                    1: expected_command_writes = E05_HIDDEN_SIZE;
                    2: expected_command_writes = PATCH_WORDS;
                    default:
                        expected_command_writes = HIDDEN_WORDS;
                endcase
            end else if (command_index < 244) begin
                case (step_number)
                    8, 9, 10:
                        expected_command_writes = SCORE_WORDS;
                    default:
                        expected_command_writes = HIDDEN_WORDS;
                endcase
            end else begin
                case (step_number)
                    0: expected_command_writes = HIDDEN_WORDS;
                    1: expected_command_writes = E05_HIDDEN_SIZE;
                    2: expected_command_writes = CLASS_WORDS;
                    3: expected_command_writes = 0;
                    default:
                        expected_command_writes = CLASS_WORDS;
                endcase
            end
        end
    endfunction

    function automatic integer descriptor_write_words(
        input phase_e_cmd_t value
    );
        begin
            case (value.header.opcode)
                PHASE_E_OP_GEMM:
                    descriptor_write_words =
                        value.dim0 * value.dim1 * value.dim3;
                PHASE_E_OP_VECTOR,
                PHASE_E_OP_GELU:
                    descriptor_write_words = value.dim0;
                PHASE_E_OP_LAYOUT:
                    descriptor_write_words =
                        value.dim0 * value.dim1 * value.dim2;
                PHASE_E_OP_LAYERNORM,
                PHASE_E_OP_SOFTMAX:
                    descriptor_write_words = value.dim0 * value.dim1;
                default:
                    descriptor_write_words = 0;
            endcase
        end
    endfunction

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

    function automatic logic zero_output_expected(
        input integer command_index
    );
        begin
            zero_output_expected =
                (expected_opcode(command_index) != PHASE_E_OP_SOFTMAX) &&
                (command_index != 246);
        end
    endfunction

    task automatic check_attention_probabilities;
        integer word_index;
        begin
            for (
                word_index = 0;
                word_index < SCORE_WORDS;
                word_index = word_index + 1
            ) begin
                check(
                    (^score_memory[word_index]) !== 1'bx,
                    "attention Softmax output is fully known"
                );
                check(
                    score_memory[word_index][31] == 1'b0 &&
                    score_memory[word_index][30:23] != 8'hff &&
                    score_memory[word_index] > FP32_POS_ZERO &&
                    score_memory[word_index] <= FP32_ONE,
                    "attention Softmax output is finite and in (0, 1]"
                );
                if (word_index != 0)
                    check(
                        score_memory[word_index] == score_memory[0],
                        "zero attention scores produce equal probabilities"
                    );
            end
        end
    endtask

    task automatic check_final_logits;
        integer class_number;
        begin
            for (
                class_number = 0;
                class_number < CLASS_WORDS;
                class_number = class_number + 1
            )
                check(
                    logits_memory[class_number] ==
                        ((class_number == TARGET_CLASS)
                            ? FP32_SEVEN
                            : FP32_POS_ZERO),
                    "final logit matches classifier bias"
                );
        end
    endtask

    task automatic check_final_probabilities;
        integer class_number;
        begin
            for (
                class_number = 0;
                class_number < CLASS_WORDS;
                class_number = class_number + 1
            ) begin
                check(
                    (^probability_memory[class_number]) !== 1'bx,
                    "final Softmax output is fully known"
                );
                check(
                    probability_memory[class_number][31] == 1'b0 &&
                    probability_memory[class_number][30:23] != 8'hff &&
                    probability_memory[class_number] > FP32_POS_ZERO &&
                    probability_memory[class_number] <= FP32_ONE,
                    "final Softmax output is finite and in (0, 1]"
                );
                if (
                    (class_number != TARGET_CLASS) &&
                    (class_number != 0)
                )
                    check(
                        probability_memory[class_number] ==
                            probability_memory[0],
                        "equal non-target logits produce equal probabilities"
                    );
            end
            check(
                probability_memory[TARGET_CLASS] >
                    probability_memory[0],
                "target-class probability is strictly maximal"
            );
        end
    endtask

    assign layer_param_data = make_layer_params(layer_param_index);
    assign layer_param_valid =
        layer_param_request && (cycle_count[2:0] != 3'd4);
    assign operand_load_ready =
        (cycle_count[2:0] != 3'd5);
    assign checkpoint_ready =
        (cycle_count[2:0] != 3'd6);

    // A single outstanding request is allowed.  Both request acceptance and
    // response latency are stalled by deterministic cycle/address patterns.
    assign mem_req_ready =
        !response_pending &&
        !mem_rsp_valid &&
        (cycle_count[2:0] != 3'd2);
    // Evaluate each request exactly once before the clocked response model.
    // Besides keeping the sampled address/data coherent, this avoids simulator
    // ordering differences when automatic helper functions are nested in NBAs.
    always_comb begin
        mem_request_address_valid = logical_address_valid(
            mem_req_write,
            mem_req_space,
            mem_req_word_address
        );
        mem_request_read_data = mem_req_write
            ? FP32_POS_ZERO
            : read_logical_word(mem_req_space, mem_req_word_address);
    end

    vit_phase_e_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES),
        .SCRATCH_WORDS(PHASE_E_SCRATCH_WORDS),
        .INPUT_WORDS(PATCH_WORDS),
        .PARAM_WORDS(PARAM_WORDS),
        .E05_PATCH_COUNT(E05_PATCH_COUNT),
        .E05_TOKEN_COUNT(E05_TOKEN_COUNT),
        .E05_HIDDEN_SIZE(E05_HIDDEN_SIZE),
        .E05_HEAD_COUNT(E05_HEAD_COUNT),
        .E05_HEAD_SIZE(E05_HEAD_SIZE),
        .E05_INTERMEDIATE_SIZE(E05_INTERMEDIATE_SIZE),
        .E05_CLASS_COUNT(E05_CLASS_COUNT),
        .E05_ENCODER_LAYERS(4'd12),
        .E05_ATTN_SCALE_FP32(E05_ATTN_SCALE_FP32)
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

    // Deterministic logical-memory response model.
    always @(posedge clk) begin
        if (rst) begin
            response_pending <= 1'b0;
            response_delay <= 2'd0;
            pending_write <= 1'b0;
            pending_space <= PHASE_E_MEM_NONE;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_write_strobe <= 4'd0;
            pending_read_data <= FP32_POS_ZERO;
            pending_error <= 1'b0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= FP32_POS_ZERO;
            mem_rsp_error <= 1'b0;
            read_transaction_count <= 0;
            write_transaction_count <= 0;
            invalid_transaction_count <= 0;
            zero_write_failure_count <= 0;
        end else begin
            if (mem_rsp_valid && mem_rsp_ready) begin
                if (pending_write && !mem_rsp_error) begin
                    write_scratch_word(
                        pending_address,
                        pending_write_data
                    );
                    write_transaction_count <=
                        write_transaction_count + 1;
                end
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= FP32_POS_ZERO;
                mem_rsp_error <= 1'b0;
            end

            if (response_pending) begin
                if (response_delay == 0) begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_read_data <= pending_read_data;
                    mem_rsp_error <= pending_error;
                    response_pending <= 1'b0;
                end else begin
                    response_delay <= response_delay - 1'b1;
                end
            end

            if (mem_req_valid && mem_req_ready) begin
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
                        "X/Z detected on accepted logical-memory request"
                    );

                pending_write <= mem_req_write;
                pending_space <= mem_req_space;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_write_strobe <= mem_req_write_strobe;
                pending_read_data <= mem_request_read_data;
                pending_error <= (mem_request_address_valid !== 1'b1);
                response_delay <=
                    {1'b0, mem_req_word_address[0]} +
                    {1'b0, cycle_count[0]};
                response_pending <= 1'b1;

                if (mem_request_address_valid !== 1'b1) begin
                    invalid_transaction_count <=
                        invalid_transaction_count + 1;
                    $display(
                        "ERROR invalid memory request write=%0b space=%0d address=%08x",
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address
                    );
                end

                if (mem_req_write) begin
                    check(
                        mem_req_write_strobe === 4'hf,
                        "every scratch write uses a full-word strobe"
                    );
                    if (
                        active_zero_expected &&
                        (mem_req_write_data !== FP32_POS_ZERO)
                    )
                        zero_write_failure_count <=
                            zero_write_failure_count + 1;
                end else begin
                    read_transaction_count <=
                        read_transaction_count + 1;
                end
            end
        end
    end

    // Command, checkpoint, parameter and result scoreboard.
    always @(posedge clk) begin
        integer command_layer;
        integer command_step;
        if (rst) begin
            cycle_count <= 0;
            command_count <= 0;
            checkpoint_count <= 0;
            layer_request_count <= 0;
            parameter_request_count <= 0;
            class_result_count <= 0;
            opcode_gemm_count <= 0;
            opcode_vector_count <= 0;
            opcode_layout_count <= 0;
            opcode_layernorm_count <= 0;
            opcode_softmax_count <= 0;
            opcode_gelu_count <= 0;
            opcode_argmax_count <= 0;
            command_active <= 1'b0;
            active_command_index <= 0;
            active_write_start <= 0;
            active_zero_failure_start <= 0;
            active_zero_expected <= 1'b0;
            active_parameter_stage_seen <= 1'b0;
            active_command_snapshot <= '0;
            captured_class_index <= 32'd0;
            captured_class_logit <= FP32_QNAN;
        end else begin
            cycle_count <= cycle_count + 1;

            if (
                busy &&
                (cycle_count != 0) &&
                ((cycle_count % 1_000_000) == 0)
            )
                $display(
                    "E05_COMPACT_RTL_PROGRESS cycles=%0d commands=%0d reads=%0d writes=%0d",
                    cycle_count,
                    command_count,
                    read_transaction_count,
                    write_transaction_count
                );

            if (dut.command_valid && dut.command_ready) begin
                if ((^dut.command) === 1'bx)
                    $fatal(1, "X/Z detected in accepted E05 command");

                command_layer = expected_context_layer(command_count);
                command_step = expected_step(command_count);
                check(
                    !command_active,
                    "a new command cannot overlap the prior checkpoint"
                );
                check(
                    command_count < EXPECTED_COMMANDS,
                    "sequencer does not emit an extra command"
                );
                check(
                    dut.command.header.opcode ==
                        expected_opcode(command_count),
                    "command opcode follows the complete E05 schedule"
                );
                check(
                    dut.command.header.tag ==
                        (JOB_TAG + command_count[7:0]),
                    "command tag follows the wrapping E05 ordinal"
                );
                check(
                    dut.command.header.reserved[7:6] ==
                        expected_section(command_count),
                    "command reserved context carries the expected section"
                );
                check(
                    dut.command.header.reserved[5:2] ==
                        command_layer[3:0],
                    "command reserved context carries the expected layer"
                );
                check(
                    dut.command.route.reserved[4:0] ==
                        command_step[4:0],
                    "command reserved context carries the expected step"
                );
                check(
                    (dut.command.header.flags &
                     PHASE_E_FLAG_CHECKPOINT) != 0,
                    "every command requests a checkpoint"
                );
                if (dut.command.header.opcode == PHASE_E_OP_GEMM)
                    check(
                        (dut.command.header.flags &
                         PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0,
                        "every built-in E05 GEMM enables safe cache reuse"
                    );
                check(
                    descriptor_write_words(dut.command) ==
                        expected_command_writes(command_count),
                    "descriptor dimensions imply the expected write count"
                );

                case (dut.command.header.opcode)
                    PHASE_E_OP_GEMM:
                        opcode_gemm_count <= opcode_gemm_count + 1;
                    PHASE_E_OP_VECTOR:
                        opcode_vector_count <= opcode_vector_count + 1;
                    PHASE_E_OP_LAYOUT:
                        opcode_layout_count <= opcode_layout_count + 1;
                    PHASE_E_OP_LAYERNORM:
                        opcode_layernorm_count <=
                            opcode_layernorm_count + 1;
                    PHASE_E_OP_SOFTMAX:
                        opcode_softmax_count <= opcode_softmax_count + 1;
                    PHASE_E_OP_GELU:
                        opcode_gelu_count <= opcode_gelu_count + 1;
                    PHASE_E_OP_ARGMAX:
                        opcode_argmax_count <= opcode_argmax_count + 1;
                    default:
                        check(1'b0, "unsupported opcode in E05 schedule");
                endcase

                command_active <= 1'b1;
                active_command_index <= command_count;
                active_write_start <= write_transaction_count;
                active_zero_failure_start <= zero_write_failure_count;
                active_zero_expected <=
                    zero_output_expected(command_count);
                active_parameter_stage_seen <= 1'b0;
                active_command_snapshot <= dut.command;
                command_count <= command_count + 1;
            end

            if (operand_load_request && operand_load_ready) begin
                check(
                    command_active,
                    "parameter staging belongs to an active command"
                );
                check(
                    !active_parameter_stage_seen,
                    "a command requests parameter staging exactly once"
                );
                check(
                    command_needs_parameters(active_command_snapshot),
                    "only parameter-backed commands request staging"
                );
                check(
                    operand_load_command === active_command_snapshot,
                    "parameter staging exposes the accepted descriptor"
                );
                active_parameter_stage_seen <= 1'b1;
                parameter_request_count <= parameter_request_count + 1;
            end

            if (layer_param_request && layer_param_valid) begin
                check(
                    layer_request_count < EXPECTED_LAYER_REQUESTS,
                    "sequencer does not request an extra layer table entry"
                );
                check(
                    layer_param_index == layer_request_count[3:0],
                    "layer table requests progress from layer 0 through 11"
                );
                layer_request_count <= layer_request_count + 1;
            end

            if (checkpoint_valid && checkpoint_ready) begin
                command_layer =
                    expected_checkpoint_layer(active_command_index);
                command_step = expected_step(active_command_index);
                if ((^{checkpoint_phase,
                       checkpoint_section,
                       checkpoint_layer,
                       checkpoint_step,
                       checkpoint_tag,
                       checkpoint_opcode,
                       checkpoint_dst_tensor}) === 1'bx)
                    $fatal(1, "X/Z detected in accepted checkpoint");

                check(command_active, "checkpoint belongs to an active command");
                check(
                    checkpoint_count == active_command_index,
                    "one ordered checkpoint follows every command"
                );
                check(
                    checkpoint_phase == PHASE_E_E05,
                    "checkpoint phase is E05"
                );
                check(
                    checkpoint_section ==
                        expected_section(active_command_index),
                    "checkpoint section follows the E05 schedule"
                );
                check(
                    checkpoint_layer ==
                        command_layer[3:0],
                    "checkpoint layer follows the E05 schedule"
                );
                check(
                    checkpoint_step ==
                        command_step[4:0],
                    "checkpoint step follows the E05 schedule"
                );
                check(
                    checkpoint_tag ==
                        (JOB_TAG + active_command_index[7:0]),
                    "checkpoint tag matches its command"
                );
                check(
                    checkpoint_opcode ==
                        expected_opcode(active_command_index),
                    "checkpoint opcode matches its command"
                );
                check(
                    checkpoint_dst_tensor ==
                        active_command_snapshot.route.dst_tensor,
                    "checkpoint destination matches its command"
                );
                check(
                    (write_transaction_count - active_write_start) ==
                        expected_command_writes(active_command_index),
                    "command produced its exact scratch-write delta"
                );
                check(
                    active_parameter_stage_seen ==
                        command_needs_parameters(active_command_snapshot),
                    "parameter staging presence matches command routing"
                );
                if (active_zero_expected)
                    check(
                        zero_write_failure_count ==
                            active_zero_failure_start,
                        "ordinary checkpoint output is exactly +0"
                    );

                if (
                    (expected_section(active_command_index) ==
                     PHASE_E_SECTION_ENCODER) &&
                    (expected_step(active_command_index) == 10)
                )
                    check_attention_probabilities();
                if (active_command_index == 246)
                    check_final_logits();
                if (active_command_index == 248)
                    check_final_probabilities();

                checkpoint_count <= checkpoint_count + 1;
                command_active <= 1'b0;
            end

            if (class_result_valid) begin
                if ((^{class_index, class_logit}) === 1'bx)
                    $fatal(1, "X/Z detected in class result");
                class_result_count <= class_result_count + 1;
                captured_class_index <= class_index;
                captured_class_logit <= class_logit;
            end
        end
    end

    initial begin
        for (
            initialize_index = 0;
            initialize_index < HIDDEN_WORDS;
            initialize_index = initialize_index + 1
        ) begin
            hidden_a_memory[initialize_index] = FP32_SENTINEL;
            hidden_b_memory[initialize_index] = FP32_SENTINEL;
            linear_memory[initialize_index] = FP32_SENTINEL;
        end
        for (
            initialize_index = 0;
            initialize_index < HEAD_WORDS;
            initialize_index = initialize_index + 1
        ) begin
            q_memory[initialize_index] = FP32_SENTINEL;
            k_memory[initialize_index] = FP32_SENTINEL;
            v_memory[initialize_index] = FP32_SENTINEL;
        end
        for (
            initialize_index = 0;
            initialize_index < SCORE_WORDS;
            initialize_index = initialize_index + 1
        )
            score_memory[initialize_index] = FP32_SENTINEL;
        for (
            initialize_index = 0;
            initialize_index < FC1_WORDS;
            initialize_index = initialize_index + 1
        )
            fc1_memory[initialize_index] = FP32_SENTINEL;
        for (
            initialize_index = 0;
            initialize_index < CLASS_WORDS;
            initialize_index = initialize_index + 1
        ) begin
            logits_memory[initialize_index] = FP32_SENTINEL;
            probability_memory[initialize_index] = FP32_SENTINEL;
        end

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        job = '0;
        job.phase = PHASE_E_E05;
        job.class_softmax_enable = 1'b1;
        job.checkpoint_enable = 1'b1;
        job.job_tag = JOB_TAG;
        job.patch_a_base = 32'd0;

        global_params = '0;
        global_params.patch_weight_base = PATCH_WEIGHT_BASE;
        global_params.patch_bias_base = PATCH_BIAS_BASE;
        global_params.cls_base = CLS_BASE;
        global_params.position_base = POSITION_BASE;
        global_params.final_ln_gamma_base = FINAL_LN_GAMMA_BASE;
        global_params.final_ln_beta_base = FINAL_LN_BETA_BASE;
        global_params.classifier_weight_base = CLASSIFIER_WEIGHT_BASE;
        global_params.classifier_bias_base = CLASSIFIER_BIAS_BASE;

        @(negedge clk);
        job_valid = 1'b1;
        while (!job_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        job_valid = 1'b0;

        wait (done || error);
        #1;

        check(!error, "E05 job completed without sequencer error");
        check(error_code == PHASE_E_ERROR_NONE, "error code is NONE");
        check(
            command_count == EXPECTED_COMMANDS,
            "all 249 production commands were accepted"
        );
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "all 249 checkpoints were accepted"
        );
        check(
            layer_request_count == EXPECTED_LAYER_REQUESTS,
            "all 12 encoder layer entries were requested"
        );
        check(
            parameter_request_count == EXPECTED_PARAMETER_REQUESTS,
            "exactly 101 parameter-backed commands were staged"
        );
        check(
            opcode_gemm_count == EXPECTED_GEMM_COMMANDS,
            "E05 emitted exactly 98 GEMM commands"
        );
        check(
            opcode_vector_count == EXPECTED_VECTOR_COMMANDS,
            "E05 emitted exactly 37 vector commands"
        );
        check(
            opcode_layout_count == EXPECTED_LAYOUT_COMMANDS,
            "E05 emitted exactly 63 layout commands"
        );
        check(
            opcode_layernorm_count == EXPECTED_LAYERNORM_COMMANDS,
            "E05 emitted exactly 25 LayerNorm commands"
        );
        check(
            opcode_softmax_count == EXPECTED_SOFTMAX_COMMANDS,
            "E05 emitted exactly 13 Softmax commands"
        );
        check(
            opcode_gelu_count == EXPECTED_GELU_COMMANDS,
            "E05 emitted exactly 12 GELU commands"
        );
        check(
            opcode_argmax_count == EXPECTED_ARGMAX_COMMANDS,
            "E05 emitted exactly one Argmax command"
        );
        check(
            write_transaction_count == EXPECTED_WRITES,
            "complete E05 job produced the exact total write count"
        );
        check(
            invalid_transaction_count == 0,
            "all logical-memory transactions were valid and in range"
        );
        check(
            class_result_count == 1,
            "Argmax produced exactly one class result"
        );
        check(
            captured_class_index == TARGET_CLASS,
            "class index matches the unique +7 classifier bias"
        );
        check(
            captured_class_logit == FP32_SEVEN,
            "class logit is exactly +7.0"
        );

        for (
            verify_index = 0;
            verify_index < HIDDEN_WORDS;
            verify_index = verify_index + 1
        ) begin
            check(
                hidden_a_memory[verify_index] == FP32_POS_ZERO,
                "final HIDDEN_A state remains +0"
            );
            check(
                hidden_b_memory[verify_index] == FP32_POS_ZERO,
                "final HIDDEN_B state remains +0"
            );
            check(
                linear_memory[verify_index] == FP32_POS_ZERO,
                "final LINEAR_TMP state remains +0"
            );
        end
        for (
            verify_index = 0;
            verify_index < HEAD_WORDS;
            verify_index = verify_index + 1
        ) begin
            check(
                q_memory[verify_index] == FP32_POS_ZERO,
                "final Q/PV scratch state remains +0"
            );
            check(
                k_memory[verify_index] == FP32_POS_ZERO,
                "final K scratch state remains +0"
            );
            check(
                v_memory[verify_index] == FP32_POS_ZERO,
                "final V scratch state remains +0"
            );
        end
        for (
            verify_index = 0;
            verify_index < FC1_WORDS;
            verify_index = verify_index + 1
        )
            check(
                fc1_memory[verify_index] == FP32_POS_ZERO,
                "final FC1 scratch state remains +0"
            );

        check_attention_probabilities();
        check_final_logits();
        check_final_probabilities();

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_NPU_E05_COMPACT_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d class=%0d logit=%08x",
                checks,
                cycle_count,
                command_count,
                checkpoint_count,
                read_transaction_count,
                write_transaction_count,
                captured_class_index,
                captured_class_logit
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_NPU_E05_COMPACT_RTL_E2E_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge clk);
        $fatal(
            1,
            "Timeout in compact E05 RTL end-to-end test after %0d cycles",
            WATCHDOG_CYCLES
        );
    end

endmodule
